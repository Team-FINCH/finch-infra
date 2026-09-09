#!/usr/bin/env bash
set -euo pipefail

# 호스트의 Let's Encrypt 인증서를 k8s TLS Secret 으로 밀어 넣는다.
#
#   최초 등록   sudo ./infra/k8s/scripts/sync-tls-secret.sh
#   갱신 반영   certbot deploy 훅이 같은 스크립트를 부른다
#
# 왜 갱신마다 다시 밀어야 하는가
#   인증서는 90일마다 바뀐다. Secret 은 그때 만든 값을 그대로 들고 있으므로,
#   호스트가 갱신해도 이쪽을 다시 채우지 않으면 클러스터는 만료된 인증서를 계속 쓴다.
#   증상이 두 달 뒤에 나타나므로 지금 자동화해 둔다.
#
# 왜 cert-manager 를 쓰지 않는가
#   클러스터 안에서 ACME 를 처리하는 것이 표준이지만 새 컴포넌트가 하나 늘고,
#   발표까지 남은 기간에 검증된 갱신 경로(호스트 certbot)를 흔들 이유가 없다.
#   커트오버 이후 여유가 생기면 그때 옮긴다.

DOMAIN="${DOMAIN:-finchapp.org}"
NS="${NS:-finch}"
SECRET="${SECRET:-finch-tls}"
LIVE="/etc/letsencrypt/live/${DOMAIN}"

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ root 권한이 필요합니다 (인증서 키를 읽는다): sudo $0" >&2
  exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

for f in fullchain.pem privkey.pem; do
  if [ ! -f "${LIVE}/${f}" ]; then
    echo "✗ ${LIVE}/${f} 가 없습니다. certbot 발급이 선행돼야 합니다." >&2
    exit 1
  fi
done

if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  echo "✗ 네임스페이스 '${NS}' 가 없습니다. manifests/namespace.yaml 을 먼저 적용하세요." >&2
  exit 1
fi

# 만료일을 먼저 찍는다. 갱신 훅에서 이 줄이 로그에 남아, 훅이 돌았는지와
# 어떤 인증서를 넣었는지를 나중에 대조할 수 있다.
echo "▶ 인증서 $(openssl x509 -enddate -noout -in "${LIVE}/fullchain.pem" | sed 's/notAfter=/만료 /')"

# create --dry-run | apply 로 최초 등록과 갱신을 한 경로로 처리한다.
# kubectl create secret tls 는 이미 있으면 실패하고, apply 는 갱신을 덮어쓴다.
kubectl -n "$NS" create secret tls "$SECRET" \
  --cert="${LIVE}/fullchain.pem" \
  --key="${LIVE}/privkey.pem" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "▶ Secret ${NS}/${SECRET} 갱신"

# ingress-nginx 는 Secret 변경을 watch 해서 자동으로 다시 읽는다. 파드 재시작이 필요 없다.
# 실제로 반영됐는지는 아래 지문 대조로 확인한다 — watch 가 늦거나 실패할 수 있다.
host_fp=$(openssl x509 -noout -fingerprint -sha256 -in "${LIVE}/fullchain.pem" | cut -d= -f2)
k8s_fp=$(kubectl -n "$NS" get secret "$SECRET" -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)

if [ "$host_fp" = "$k8s_fp" ]; then
  echo "✓ 지문 일치 — 호스트 인증서가 Secret 에 들어갔다"
else
  echo "✗ 지문이 다릅니다. Secret 이 갱신되지 않았습니다." >&2
  echo "  호스트 ${host_fp}" >&2
  echo "  Secret ${k8s_fp}" >&2
  exit 1
fi
