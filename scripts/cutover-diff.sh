#!/usr/bin/env bash
# 커트오버 대조 — 기존 경로와 k3s 경로의 응답을 맞댄다 (FINCH-136).
#
# 왜 필요한가
#   커트오버는 전환 작업에서 **유일하게 사용자에게 보이는 단계**이고 되돌리기가
#   가장 어렵다. 넘기고 나서 다른 것을 발견하면 이미 사용자가 겪은 뒤다.
#   그래서 넘기기 전에 두 경로가 같은 답을 하는지 본다.
#
#   실제로 이 대조가 잡은 것이 둘 있다 (FINCH-227).
#     index.html 의 no-cache 가 k3s 쪽에만 없었다 — 설정이 두 벌이라 한쪽만 고쳤다
#     HSTS 가 30일이 아니라 ingress-nginx 기본값인 1년이었다
#
# 쓰는 법
#   sudo infra/scripts/cutover-diff.sh
#
# 무엇을 하지 않는가
#   **읽기만 한다.** 주문·충전·출금 같은 쓰기는 부르지 않는다.
#   AI 엔드포인트는 인증에서 막히므로 GMS 크레딧이 나가지 않는다.
set -u

HOST=${HOST:-finchapp.org}
OLD=${OLD:-https://$HOST}
NEW=${NEW:-https://$HOST:8443}
# k3s 쪽은 8443 이 hostPort 라 DNS 가 아니라 로컬로 붙인다.
CURL="curl -sk -m 10 --resolve $HOST:8443:127.0.0.1"

pass=0
fail=0

ok()   { printf '  OK    %-40s %s\n' "$1" "$2"; pass=$((pass + 1)); }
diff_() { printf '  DIFF  %-40s\n        기존 [%s]\n        k3s  [%s]\n' "$1" "$2" "$3"; fail=$((fail + 1)); }

# 상태 코드가 같은지 본다. 인증이 필요한 경로는 양쪽 다 401 이면 같은 것이다 —
# 라우팅이 같은 곳으로 갔다는 뜻이고, 그것이 여기서 확인할 것이다.
cmp_code() {
    local label=$1 path=$2 method=${3:-GET} a b
    a=$($CURL -o /dev/null -w '%{http_code}' -X "$method" "$OLD$path")
    b=$($CURL -o /dev/null -w '%{http_code}' -X "$method" "$NEW$path")
    if [ "$a" = "$b" ]; then ok "$label" "$a"; else diff_ "$label" "$a" "$b"; fi
}

cmp_body() {
    local label=$1 path=$2 a b
    a=$($CURL "$OLD$path" | sha256sum | cut -c1-12)
    b=$($CURL "$NEW$path" | sha256sum | cut -c1-12)
    if [ "$a" = "$b" ]; then ok "$label" "$a"; else diff_ "$label" "$a" "$b"; fi
}

# 헤더 값만 뽑는다. cut -d' ' 는 값에 공백이 있으면 잘리므로 awk 로 첫 칸만 지운다.
hdr() {
    $CURL -I "$1" | tr -d '\r' \
        | awk -v h="$2" 'BEGIN { IGNORECASE = 1 } $1 == h":" { sub($1 FS, ""); print }'
}

cmp_hdr() {
    local path=$1 name=$2 a b
    a=$(hdr "$OLD$path" "$name")
    b=$(hdr "$NEW$path" "$name")
    if [ "$a" = "$b" ]; then ok "$name ($path)" "${a:-<없음>}"; else diff_ "$name ($path)" "$a" "$b"; fi
}

echo "기존  $OLD"
echo "k3s   $NEW"
echo

echo "── 화면 (SPA) ──"
cmp_code "루트"                "/"
cmp_body "루트 본문"           "/"
cmp_code "SPA 폴백 /portfolio" "/portfolio"
cmp_code "없는 자산 404"       "/assets/nope-0000.js"

echo "── 인증 ──"
cmp_code "users/me 무토큰"     "/api/v1/users/me"
cmp_code "auth/kakao 무본문"   "/api/v1/auth/kakao"   POST
cmp_code "auth/refresh"        "/api/v1/auth/refresh" POST

echo "── 계좌 · 잔고 ──"
cmp_code "account"             "/api/v1/account"
cmp_code "portfolio"           "/api/v1/portfolio"
cmp_code "transactions"        "/api/v1/transactions"
cmp_code "deposits/limit"      "/api/v1/deposits/limit"

echo "── 종목 · 시세 ──"
cmp_code "stocks/search"       "/api/v1/stocks/search"
cmp_code "stocks/005930"       "/api/v1/stocks/005930"
cmp_code "candles"             "/api/v1/stocks/005930/candles"
cmp_code "prices"              "/api/v1/stocks/prices"

echo "── 주문 (읽기만) ──"
cmp_code "orders/available"    "/api/v1/orders/available"

echo "── AI 중계 (인증에서 막힘, 크레딧 0) ──"
cmp_code "ai/briefing"         "/api/v1/ai/briefing"
cmp_code "ai/chat"             "/api/v1/ai/chat"                    POST
cmp_code "ai/analysis"         "/api/v1/ai/stocks/005930/analysis"  POST
cmp_code "ai/wiki"             "/api/v1/ai/wiki"

echo "── 관심 · 최근 ──"
cmp_code "watchlist"           "/api/v1/watchlist"
cmp_code "stocks/recent"       "/api/v1/stocks/recent"

# 헤더는 라우팅이 같아도 갈린다. 설정이 두 벌이기 때문이다 —
# compose 는 infra/nginx/nginx.conf, k8s 는 차트의 frontend-nginx.conf 와
# ingress-nginx 컨트롤러 ConfigMap 이다. 그래서 따로 본다.
echo "── 응답 헤더 ──"
for path in "/" "/assets/"; do
    for name in cache-control strict-transport-security x-content-type-options \
                x-frame-options referrer-policy; do
        cmp_hdr "$path" "$name"
    done
done

echo "────────────────────────────────"
printf '일치 %d건, 불일치 %d건\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    echo "✗ 불일치가 있다. 커트오버 전에 맞춘다." >&2
    exit 1
fi
echo "✓ 두 경로의 응답이 같다"
