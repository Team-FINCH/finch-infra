#!/usr/bin/env sh
set -eu

# 배경과 판정 기준은 infra/README.md 의 'AI 외부 데이터 키 검증' 절에 있다.
# 값을 출력하지 않는다. 길이와 응답 코드만 남긴다.

set +x

fail=0
skip=0

# Protected 로 등록된 CI 변수는 protected 브랜치의 잡에만 주입된다.
# 이 저장소는 master 만 protected 다. 작업 브랜치에서 값이 비어 보이는 것과
# 실제로 등록되지 않은 것을 구분하지 않으면 없는 문제를 만들어낸다.
unprotected=0
if [ "${CI_COMMIT_REF_PROTECTED:-}" = "false" ]; then
    unprotected=1
fi

mask_len() {
    if [ -z "${1:-}" ]; then echo "<빈값>"; else echo "len=${#1}"; fi
}

report_fail() {
    fail=$((fail + 1))
    printf '  ✗ %s\n' "$1" >&2
}

report_skip() {
    skip=$((skip + 1))
    printf '  - %s\n' "$1"
}

if [ "$unprotected" -eq 1 ]; then
    echo "! 이 브랜치(${CI_COMMIT_REF_NAME:-?})는 protected 가 아니다."
    echo "  Protected 로 등록된 변수는 여기 주입되지 않으므로,"
    echo "  값이 비어 있어도 미등록으로 판정하지 않는다."
    echo "  실제 판정은 master 파이프라인에서 한다."
    echo
fi

echo "── 키 존재 확인 ──"
printf '  %-22s %s\n' "DART_API_KEY"        "$(mask_len "${DART_API_KEY:-}")"
printf '  %-22s %s\n' "NAVER_CLIENT_ID"     "$(mask_len "${NAVER_CLIENT_ID:-}")"
printf '  %-22s %s\n' "NAVER_CLIENT_SECRET" "$(mask_len "${NAVER_CLIENT_SECRET:-}")"
printf '  %-22s %s\n' "KRX_API_KEY"         "$(mask_len "${KRX_API_KEY:-}")"
echo

# ── DART ──────────────────────────────────────────────
# status 는 문서화된 코드다. 적재 코드(ai/app/rag/dart.py:121)는 000 이 아니면
# log.debug 만 남기고 종목을 건너뛰므로, 키 오류가 '0건 적재' 로 보인다.
# 여기서만 코드를 명시적으로 갈라 그 구분을 만든다.
echo "── DART (opendart.fss.or.kr) ──"
if [ -z "${DART_API_KEY:-}" ]; then
    report_skip "DART_API_KEY 가 비어 있어 호출하지 않았다"
else
    # busybox date 는 '7 days ago' 를 못 읽는다. epoch 산술은 GNU/busybox 양쪽에서 된다.
    now=$(date -u +%s)
    end_de=$(date -u +%Y%m%d)
    bgn_de=$(date -u -d "@$((now - 604800))" +%Y%m%d)
    body=$(curl -sS -m 30 -G "https://opendart.fss.or.kr/api/list.json" \
        --data-urlencode "crtfc_key=${DART_API_KEY}" \
        --data-urlencode "bgn_de=${bgn_de}" \
        --data-urlencode "end_de=${end_de}" \
        --data-urlencode "page_count=1" 2>/dev/null || echo '{"status":"NETWORK"}')
    status=$(printf '%s' "$body" | sed -n 's/.*"status" *: *"\([0-9A-Z]*\)".*/\1/p')
    case "$status" in
        000) echo "  ✓ status=000 정상" ;;
        013) echo "  ✓ status=013 (기간 내 데이터 없음 — 키는 유효하다)" ;;
        010) report_fail "status=010 등록되지 않은 키다" ;;
        011) report_fail "status=011 사용할 수 없는 키다 (사용중지 또는 미승인)" ;;
        012) report_fail "status=012 접근할 수 없는 IP 다. DART 에 서버 IP 등록이 필요하다" ;;
        020) report_fail "status=020 요청 제한 초과 (일일 20,000회)" ;;
        100) report_fail "status=100 필드값이 부적절하다. 이 스크립트의 요청을 확인하라" ;;
        800) report_fail "status=800 DART 시스템 점검 중이다. 키 문제가 아니다" ;;
        NETWORK) report_fail "네트워크 오류로 호출하지 못했다" ;;
        *)   report_fail "status=${status:-미상} 예상하지 못한 응답이다" ;;
    esac
fi
echo

# ── NAVER ─────────────────────────────────────────────
# 일반 개발자센터가 아니라 NAVER Cloud API HUB 다 (ai/ingest/news.py:37).
# 헤더 이름이 X-Naver-Client-* 가 아니라 X-NCP-APIGW-* 인 이유가 그것이다.
echo "── NAVER API HUB (naverapihub.apigw.ntruss.com) ──"
if [ -z "${NAVER_CLIENT_ID:-}" ] || [ -z "${NAVER_CLIENT_SECRET:-}" ]; then
    report_skip "NAVER 키가 비어 있어 호출하지 않았다"
else
    code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -G \
        "https://naverapihub.apigw.ntruss.com/search/v1/news" \
        --data-urlencode "query=삼성전자" \
        --data-urlencode "display=1" \
        --data-urlencode "format=json" \
        -H "X-NCP-APIGW-API-KEY-ID: ${NAVER_CLIENT_ID}" \
        -H "X-NCP-APIGW-API-KEY: ${NAVER_CLIENT_SECRET}" 2>/dev/null || echo 000)
    case "$code" in
        200) echo "  ✓ HTTP 200 정상" ;;
        401) report_fail "HTTP 401 인증 실패. CLIENT_ID 나 SECRET 이 틀렸다" ;;
        403) report_fail "HTTP 403 권한 없음. API HUB 에서 뉴스 검색 상품이 신청됐는지 확인하라" ;;
        429) report_fail "HTTP 429 요청 제한 초과" ;;
        000) report_fail "네트워크 오류로 호출하지 못했다" ;;
        *)   report_fail "HTTP ${code} 예상하지 못한 응답이다" ;;
    esac
fi
echo

# ── KRX ───────────────────────────────────────────────
# 키를 쿼리가 아니라 AUTH_KEY 헤더로만 보낸다. 쿼리에 실으면 URL 이 로그에 남는다
# (ai/ingest/krx.py:124 주석과 같은 이유다).
echo "── KRX OpenAPI (data-dbg.krx.co.kr) ──"
if [ -z "${KRX_API_KEY:-}" ]; then
    report_skip "KRX_API_KEY 가 비어 있어 호출하지 않았다"
else
    basDd=$(date -u -d "@$(( $(date -u +%s) - 259200 ))" +%Y%m%d)
    code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -G \
        "https://data-dbg.krx.co.kr/svc/apis/idx/kospi_dd_trd" \
        --data-urlencode "basDd=${basDd}" \
        -H "AUTH_KEY: ${KRX_API_KEY}" 2>/dev/null || echo 000)
    case "$code" in
        200) echo "  ✓ HTTP 200 정상" ;;
        401|403) report_fail "HTTP ${code} 인증 실패. 키가 틀렸거나 승인되지 않았다" ;;
        429) report_fail "HTTP 429 요청 제한 초과" ;;
        000) report_fail "네트워크 오류로 호출하지 못했다" ;;
        *)   report_fail "HTTP ${code} 예상하지 못한 응답이다" ;;
    esac
fi
echo

echo "────────────────────────────────"
if [ "$fail" -gt 0 ]; then
    echo "✗ 유효하지 않은 키 ${fail}건" >&2
    echo "  값은 GitLab CI/CD Variables 에 있고 hidden 이라 사람이 읽을 수 없다." >&2
    echo "  재등록이 필요하면 발급자에게 요청한다 (FINCH-179)." >&2
    exit 1
fi
if [ "$skip" -gt 0 ]; then
    if [ "$unprotected" -eq 1 ]; then
        echo "· 판정 불가 — 값이 없는 키 ${skip}건"
        echo "  이 브랜치가 protected 가 아니라서 Protected 변수를 받지 못했다."
        echo "  키가 없다는 뜻이 아니다. master 파이프라인에서 다시 돌린다."
        exit 0
    fi
    echo "✗ 값이 없는 키 ${skip}건 — 적재를 진행할 수 없다" >&2
    echo "  CI/CD Variables 에 등록됐는지 확인한다." >&2
    exit 1
fi
echo "✓ 키 4개 전부 유효하다"
