#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ root 권한이 필요합니다: sudo $0" >&2
  exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if ss -tlnp 2>/dev/null | grep -qE ':(80|443) .*docker-proxy'; then
  echo "✗ 80/443 을 Compose nginx 가 잡고 있습니다." >&2
  echo "  hostNetwork 로 뜨는 ingress-nginx 와 충돌합니다. 커트오버 절차를 먼저 수행하세요." >&2
  exit 1
fi

if helm status ingress-nginx -n ingress-nginx >/dev/null 2>&1; then
  echo "▶ ingress-nginx: 이미 설치됨 — 건너뜀"
else
  echo "▶ ingress-nginx 설치"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.hostNetwork=true \
    --set controller.kind=DaemonSet \
    --set controller.service.enabled=false
fi

kubectl -n ingress-nginx get pods
