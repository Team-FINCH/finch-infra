#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ root 권한이 필요합니다: sudo $0" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "✗ docker 가 없습니다. 런타임이 Docker 이므로 setup-server.sh 를 먼저 실행하세요." >&2
  exit 1
fi

if command -v k3s >/dev/null 2>&1; then
  echo "▶ k3s: 이미 설치됨 — 건너뜀"
else
  echo "▶ k3s 설치 (런타임 Docker, traefik 비활성)"
  curl -sfL https://get.k3s.io | sh -s - server \
    --docker \
    --secrets-encryption \
    --disable traefik \
    --kubelet-arg=image-gc-high-threshold=85 \
    --kubelet-arg=image-gc-low-threshold=80 \
    --write-kubeconfig-mode 644
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
  echo "▶ ufw 에 파드 네트워크(cni0) 허용 추가"
  echo "   ufw 기본값이 deny(incoming)/deny(routed) 라서, 규칙이 없으면"
  echo "   파드가 API 서버(10.43.0.1)에 닿지 못해 coredns 가 Ready 되지 않는다."
  ufw allow in on cni0 >/dev/null
  ufw route allow in on cni0 >/dev/null
  ufw route allow out on cni0 >/dev/null
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "▶ 노드 준비 대기 (최대 180초)"
deadline=$((SECONDS + 180))
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ 180초 안에 노드가 Ready 가 되지 않았습니다." >&2
    systemctl status k3s --no-pager --lines=30 >&2 || true
    exit 1
  fi
  sleep 3
done

echo "▶ 시스템 파드 Ready 대기 (최대 180초)"
deadline=$((SECONDS + 180))
not_ready() {
  kubectl get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if (a[1]!=a[2]) print}' | wc -l
}
until [ "$(not_ready)" -eq 0 ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ 180초 안에 시스템 파드가 전부 Ready 가 되지 않았습니다." >&2
    kubectl get pods -A >&2
    echo "  coredns 가 'Plugins not ready: kubernetes' 로 멈춰 있으면 파드 네트워크가" >&2
    echo "  막힌 것이다. 'journalctl -k | grep \"UFW BLOCK\" | grep cni0' 로 확인한다." >&2
    exit 1
  fi
  sleep 5
done

TARGET_USER="${SUDO_USER:-ubuntu}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ]; then
  echo "▶ kubeconfig 배치: $TARGET_HOME/.kube/config"
  install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 700 "$TARGET_HOME/.kube"
  install -o "$TARGET_USER" -g "$TARGET_USER" -m 600 \
    /etc/rancher/k3s/k3s.yaml "$TARGET_HOME/.kube/config"
fi

if command -v helm >/dev/null 2>&1; then
  echo "▶ helm: 이미 설치됨 — 건너뜀"
else
  echo "▶ helm 설치"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo
echo "── 설치 결과 ──"
k3s --version | head -1
kubectl get nodes -o wide
kubectl get pods -A
echo
echo "── 런타임 확인 (docker 여야 한다) ──"
kubectl get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}{"\n"}'
echo
echo "✓ k3s 설치 완료. ingress-nginx 는 아직 설치하지 않았다 (FINCH-133)."
echo "  다음 단계는 infra/k8s/README.md 의 적용 순서 2번(시크릿)부터."
