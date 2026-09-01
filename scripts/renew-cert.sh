#!/usr/bin/env bash
# Let's Encrypt 인증서 갱신. cron 이 매일 04:20 에 실행한다 (setup-server.sh 가 등록).
# 수동 실행: sudo infra/scripts/renew-cert.sh
#
# 발급은 standalone(certbot 이 직접 80 을 점유) 으로 했지만 갱신은 webroot 로 한다.
# standalone 은 갱신할 때마다 nginx 를 내려야 해서 서비스 중단이 생긴다.
# webroot 는 nginx 가 뜬 채로 챌린지 파일만 서빙하면 되므로 무중단이다.
# certonly --keep-until-expiring 은 만료가 임박하지 않으면 아무것도 하지 않으므로
# 매일 돌려도 Let's Encrypt 발급 한도에 걸리지 않는다.
set -euo pipefail

DOMAIN="${DOMAIN:-finchapp.org}"
WEBROOT="${WEBROOT:-/var/www/certbot}"
EMAIL="${CERTBOT_EMAIL:-}"

mkdir -p "$WEBROOT"

echo "▶ 인증서 갱신 확인 ($DOMAIN)"
docker run --rm \
  -v /etc/letsencrypt:/etc/letsencrypt \
  -v /var/lib/letsencrypt:/var/lib/letsencrypt \
  -v "$WEBROOT:$WEBROOT" \
  certbot/certbot certonly \
    --webroot -w "$WEBROOT" \
    -d "$DOMAIN" \
    --non-interactive --agree-tos --keep-until-expiring \
    ${EMAIL:+--email "$EMAIL"} ${EMAIL:+--no-eff-email}

# 갱신 여부와 무관하게 reload 한다. reload 는 기존 연결을 끊지 않는 무중단 동작이라
# "갱신됐는지" 를 판별하는 로직을 두는 것보다 단순하고 안전하다.
if docker ps --format '{{.Names}}' | grep -qx finch-nginx; then
  echo "▶ nginx reload"
  docker exec finch-nginx nginx -s reload
else
  echo "▶ finch-nginx 미실행 — reload 건너뜀"
fi

echo "✓ 완료"
