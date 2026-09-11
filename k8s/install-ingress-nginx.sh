#!/usr/bin/env bash
set -euo pipefail

# ingress-nginx 설치. 포트를 인자로 받는다.
#
#   검증 단계    sudo ./install-ingress-nginx.sh              (8081 / 8443)
#   커트오버     sudo HTTP_PORT=80 HTTPS_PORT=443 ./install-ingress-nginx.sh
#
# 80/443 은 서버당 하나씩이고 지금은 Compose nginx 가 잡고 있다. 그래서 기본값을
# 8081/8443 으로 두고, 두 스택을 나란히 띄운 상태에서 응답을 대조한 뒤 커트오버한다
# (FINCH-136).
#
# hostNetwork 대신 hostPort 를 쓴다. hostNetwork 는 파드가 호스트 네트워크를 그대로
# 쓰므로 컨트롤러가 여는 포트를 바꾸기 번거롭다. hostPort 는 노드의 지정 포트만
# 파드로 넘겨 두 스택 공존이 쉽다.

HTTP_PORT="${HTTP_PORT:-8081}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
NS="${NS:-ingress-nginx}"

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ root 권한이 필요합니다: sudo $0" >&2
  exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# 이미 이 컨트롤러가 그 포트를 쓰고 있는가 (재실행이면 통과시킨다)
ours() {
  kubectl -n "$NS" get ds ingress-nginx-controller \
    -o jsonpath='{.spec.template.spec.containers[0].ports[*].hostPort}' 2>/dev/null \
    | tr ' ' '\n' | grep -qx "$1"
}

# 목표 포트가 이미 쓰이고 있으면 멈춘다. 커트오버(80/443)에서 이 검사가 특히 중요하다 —
# Compose nginx 를 내리기 전에 실행하면 두 프로세스가 같은 포트를 다툰다.
#
# ss 로 리스너를 보는 것은 docker-proxy(Compose)만 잡는다. hostPort 로 뜬 파드는
# CNI portmap 이 iptables DNAT 로 처리해 리스너가 없으므로 ss 에 나타나지 않는다.
# 그래서 리스너와 실제 응답을 둘 다 본다.
for port in "$HTTP_PORT" "$HTTPS_PORT"; do
  holder=""
  if ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
    holder=$(ss -tlnp 2>/dev/null | grep -E ":${port}[[:space:]]" | grep -oE '"[a-z0-9_-]+"' | head -1)
  elif curl -s -o /dev/null -m 3 "http://127.0.0.1:${port}/" 2>/dev/null; then
    holder="(리스너 없음 — hostPort 파드로 보인다)"
  elif curl -s -o /dev/null -m 3 -k "https://127.0.0.1:${port}/" 2>/dev/null; then
    holder="(리스너 없음 — hostPort 파드로 보인다)"
  fi

  if [ -n "$holder" ]; then
    if ours "$port"; then
      echo "▶ 포트 ${port} 는 이미 이 컨트롤러가 쓰고 있다 — 재설치로 진행"
      continue
    fi
    echo "✗ 포트 ${port} 가 이미 쓰이고 있습니다 ${holder}" >&2
    if [ "$port" = "80" ] || [ "$port" = "443" ]; then
      echo "  Compose nginx 가 잡고 있으면 커트오버 절차(FINCH-136)를 먼저 수행하세요." >&2
    fi
    exit 1
  fi
done

# HSTS 를 30일로 맞춘다 (FINCH-227).
#
# ingress-nginx 기본값은 max-age=31536000 에 includeSubDomains 까지 붙는다.
# 우리가 정한 값은 30일이고 이유가 infra/README.md 'HSTS 기간' 절에 있다 —
# HSTS 는 브라우저가 기억하는 값이라 **인증서 갱신이 실패하면 사용자가 경고를
# 무시하고 들어갈 수단이 없다. 기간이 곧 사고 시 복구 불가 기간이다.**
#
# 한번 브라우저에 박히면 그 기간 동안 되돌릴 수 없다. 커트오버로 1년짜리가
# 나가면 그 뒤에 무엇을 해도 못 줄인다. 발표가 2주 뒤다.
#
# Ingress 애노테이션으로는 안 된다. 컨트롤러 ConfigMap 옵션이다 (실측 확인).
HSTS_MAX_AGE=${HSTS_MAX_AGE:-2592000}

echo "▶ ingress-nginx 설치 (http ${HTTP_PORT}, https ${HTTPS_PORT}, HSTS ${HSTS_MAX_AGE}초)"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null

# --install 로 재실행에도 안전하게 만든다. 포트를 바꿔 다시 부르는 것이 커트오버 절차다.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "$NS" --create-namespace \
  --set controller.kind=DaemonSet \
  --set controller.hostPort.enabled=true \
  --set controller.hostPort.ports.http="$HTTP_PORT" \
  --set controller.hostPort.ports.https="$HTTPS_PORT" \
  --set controller.service.enabled=false \
  --set controller.ingressClassResource.default=true \
  --set controller.config.use-forwarded-headers=true \
  --set controller.config.server-tokens=false \
  --set controller.config.hsts-max-age="$HSTS_MAX_AGE" \
  --set controller.config.hsts-include-subdomains=false \
  --atomic --timeout 5m

echo
echo "▶ 컨트롤러 Ready 대기 (최대 120초)"
deadline=$((SECONDS + 120))
not_ready() {
  kubectl -n "$NS" get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1]!=a[2]) print}' | wc -l
}
until [ "$(not_ready)" -eq 0 ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "✗ 120초 안에 컨트롤러가 Ready 가 되지 않았습니다." >&2
    kubectl -n "$NS" get pods >&2
    echo "  hostPort 충돌이면 파드가 Pending 에 머문다. 'kubectl -n $NS describe pod' 로 확인한다." >&2
    exit 1
  fi
  sleep 5
done

echo
echo "── 설치 결과 ──"
kubectl -n "$NS" get pods -o wide
kubectl get ingressclass

echo
echo "── 응답 확인 ──"
# hostPort 는 리스너가 아니라 iptables DNAT 라 ss 로는 보이지 않는다. 응답으로 판정한다.
http_code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://127.0.0.1:${HTTP_PORT}/" || echo 000)
https_code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -k "https://127.0.0.1:${HTTPS_PORT}/" || echo 000)
echo "  http  ${HTTP_PORT}  ${http_code}"
echo "  https ${HTTPS_PORT} ${https_code}"

if [ "$http_code" = "000" ] || [ "$https_code" = "000" ]; then
  echo "✗ 포트가 응답하지 않습니다." >&2
  echo "  hostPort DNAT 규칙 확인: sudo iptables -t nat -S | grep ${HTTPS_PORT}" >&2
  exit 1
fi

echo
echo "✓ ingress-nginx 준비 완료 (http ${HTTP_PORT}, https ${HTTPS_PORT})"
echo "  TLS Secret 은 infra/k8s/scripts/sync-tls-secret.sh 가 만든다."
