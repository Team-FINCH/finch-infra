# infra/k8s — Kubernetes(k3s) 전환 선행 작업

EC2 미발급 상태에서 미리 만들어 두는 전환 준비물이다. **EC2가 발급되면
`install-k3s.sh` 실행 → 시크릿 생성 → 매니페스트 적용 → 차트 설치** 순서로 바로 올린다.
그 전까지 운영 배포는 기존 Docker Compose(infra/)가 담당한다.

## 소유권 분리 (인프라 명세 v0.5 §5.4)

같은 리소스를 두 도구가 번갈아 만지면 소유권 충돌이 난다. 처음부터 최종 도구로 배포한다.

| 계층 | 도구 | 대상 | 이유 |
|---|---|---|---|
| 앱 | **Helm** (`charts/finch`) | backend, ai, frontend + Service, Ingress | 머지마다 교체되므로 태그 주입, 이력, `--atomic` 롤백의 가치가 매번 발휘된다 |
| 인프라 | **kubectl** (`manifests/`) | PostgreSQL 2종, Redis, ResourceQuota | 변경이 거의 없고, **DB가 앱 차트에 있으면 앱 배포 실패의 롤백에 DB까지 휘말린다** (폭발 반경 격리) |
| CI/CD | Docker Compose 유지 | Jenkins, gitlab-runner | 클러스터 밖에서 클러스터를 배포하는 도구라 수명 주기를 분리 |

## EC2 발급 후 적용 순서

```bash
# 0. 서버 기본 세팅 (기존 스크립트 그대로 — docker, swap, cron)
sudo ./infra/setup-server.sh /srv/FINCH

# 1. k3s + ingress-nginx 설치
sudo ./infra/k8s/install-k3s.sh

# 2. 네임스페이스와 시크릿 (시크릿은 절대 커밋하지 않는다 — 값은 Jenkins Credentials 원본)
kubectl apply -f infra/k8s/manifests/namespace.yaml
kubectl -n finch create secret generic postgres-secret \
  --from-literal=POSTGRES_USER=... --from-literal=POSTGRES_PASSWORD=... --from-literal=POSTGRES_DB=...
kubectl -n finch create secret generic postgres-ai-secret \
  --from-literal=POSTGRES_USER=... --from-literal=POSTGRES_PASSWORD=... --from-literal=POSTGRES_DB=...
kubectl -n finch create secret generic ai-env --from-env-file=infra/ai.env

# 3. 인프라 계층 (DB, Redis, ResourceQuota)
kubectl apply -f infra/k8s/manifests/

# 4. 이미지 반입 (레지스트리 없음 — 단일 노드라 성립, infra/README.md 참고)
docker save finch/backend:latest | sudo k3s ctr images import -
docker save finch/ai:latest      | sudo k3s ctr images import -
docker save finch/nginx:latest   | sudo k3s ctr images import -

# 5. 앱 계층
helm upgrade --install finch infra/k8s/charts/finch -n finch --atomic --timeout 5m
```

## Compose 대비 달라지는 것 (전환 시 확인 목록)

- [ ] **frontend 이미지의 nginx.conf 조정 필요** — 현재 conf 는 Docker 내장 DNS(127.0.0.11)
      resolver 로 backend/jenkins 를 프록시한다. k8s 에서는 라우팅을 ingress-nginx 가 맡으므로
      frontend 는 **정적 서빙 전용 conf** 로 바꾼다 (차트의 Ingress 가 /api 라우팅을 대체).
- [ ] backend 접속 계약은 이미 k8s 전제다 — `application.yaml` 이 Service 이름
      `postgres`, `redis` 를 호스트로 쓰고 `postgres-secret` 주입을 가정한다. 매니페스트가 이 이름을 따른다.
- [ ] Jenkinsfile 배포 스테이지를 `compose up` → `helm upgrade --install` + `ctr images import` 로 교체.
- [ ] 이미지 태그를 latest → 커밋 해시로 전환 (차트 values 의 tag 를 `--set` 으로 주입).
- [ ] 시세 워커가 생기면 앱 차트에 Deployment 추가 (별도 프로세스 결정 — 인프라 QnA §7).
- [ ] 관측 스택은 공식 Helm 차트로 별도 릴리스 (앱 차트에 넣지 않는다 — 앱 롤백과 생명주기 분리):
      Prometheus, Grafana, **Loki + Alloy(DaemonSet)**. 로그는 각 서비스 stdout → CRI 로그 파일
      (`/var/log/pods/...`) → Alloy 수집이라 앱 코드 수정 없음. 로테이션은 kubelet 기본값(10Mi×5)이
      compose 설정을 승계. Loki retention 기간은 팀 결정 대기. 도입 시점(compose 먼저 vs 전환과 함께) 미정.

## 로컬 검증 (서버 없이)

```bash
helm lint infra/k8s/charts/finch
helm template finch infra/k8s/charts/finch   # 렌더링 결과 확인

# 클러스터까지 띄워 보려면 (Docker Desktop 실행 상태에서)
k3d cluster create finch-dev
kubectl apply -f infra/k8s/manifests/
helm install finch infra/k8s/charts/finch -n finch
```
