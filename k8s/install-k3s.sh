#!/usr/bin/env bash
# k3s + ingress-nginx 설치. EC2(또는 새 VM) 발급 직후 setup-server.sh 다음에 실행한다.
# 사용법: sudo ./infra/k8s/install-k3s.sh
# 여러 번 실행해도 안전하도록(멱등) 작성했다.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ root 권한이 필요합니다: sudo $0" >&2
  exit 1
fi

# ── k3s ──────────────────────────────────────────────────
# --disable traefik : Ingress 는 ingress-nginx 하나만 쓴다. 둘 다 두면 80/443 을 다툰다.
# image-gc-threshold: 매 배포마다 이미지가 노드에 쌓이므로(레지스트리 없는 반입 방식)
#                     디스크 70% 도달 시 GC 가 50% 까지 회수하게 한다.
# write-kubeconfig-mode 644: root 아닌 사용자(Jenkins 배포 스크립트)도 kubectl 을 쓰게 한다.
if command -v k3s >/dev/null 2>&1; then
  echo "▶ k3s: 이미 설치됨 — 건너뜀"
else
  echo "▶ k3s 설치"
  curl -sfL https://get.k3s.io | sh -s - server \
    --disable traefik \
    --kubelet-arg=image-gc-high-threshold=70 \
    --kubelet-arg=image-gc-low-threshold=50 \
    --write-kubeconfig-mode 644
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "▶ 노드 준비 대기"
until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 3; done
kubectl get nodes

# ── helm ─────────────────────────────────────────────────
if command -v helm >/dev/null 2>&1; then
  echo "▶ helm: 이미 설치됨 — 건너뜀"
else
  echo "▶ helm 설치"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ── ingress-nginx ────────────────────────────────────────
# hostNetwork: 단일 노드라 LoadBalancer 없이 노드의 80/443 을 직접 문다.
# (k3s 기본 ServiceLB 를 써도 되지만, compose 시절과 같은 "호스트 80 = 진입점" 모델을 유지)
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

echo
echo "✓ k3s 설치 완료. 다음 단계는 infra/k8s/README.md 의 적용 순서 2번(시크릿)부터."
