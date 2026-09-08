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
    --disable traefik \
    --kubelet-arg=image-gc-high-threshold=85 \
    --kubelet-arg=image-gc-low-threshold=80 \
    --write-kubeconfig-mode 644
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
