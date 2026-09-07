# infra/k8s — Kubernetes(k3s) 전환

운영을 k3s + Helm 으로 가는 것은 260819 회의록의 원래 설계다. 현재 EC2 가 Docker Compose 로
도는 것은 EC2 를 늦게 받아 로컬용 구성을 그대로 올린 임시 상태다.

전환은 스프린트 세 개에 걸친다. **커트오버 전까지 Compose 스택은 그대로 둔다.**

| 티켓 | 범위 |
|---|---|
| FINCH-39 | k3s 설치와 노드 검증 (이 문서의 1번) |
| FINCH-132 | Helm Chart 뼈대 |
| FINCH-133 | Ingress Controller 와 인증서 이관 |
| FINCH-134 | 관측 스택 이식 |
| FINCH-135 | Jenkins 배포 스테이지를 helm 으로 교체 |
| FINCH-136 | 커트오버와 롤백 — 80/443 인계 |

## 런타임은 Docker 다 (cri-dockerd)

`install-k3s.sh` 는 `--docker` 로 설치한다. k3s 기본값인 containerd 가 아니다.

containerd 를 쓰면 이미지 저장소가 둘로 갈린다 — `docker build` 결과는
`/var/lib/docker/` 에, 파드가 찾는 곳은 `/var/lib/rancher/k3s/agent/containerd/` 다.
그래서 매 배포마다 `docker save | k3s ctr images import` 로 옮겨야 하고, 빠뜨리면
`ErrImagePull` 로 죽는다. **`--docker` 면 이 전달 단계 자체가 없다.**

Docker 는 어차피 없앨 수 없다. 이미지 빌드, gitlab-runner 의 docker executor,
백엔드 테스트의 Testcontainers 가 전부 Docker 를 쓴다. 남는다면 창고를 둘로 유지할 이유가 없다.

대가는 cri-dockerd 가 dockershim 제거 이후의 호환 경로라 업스트림 주류가 아니라는 점이다.
되돌리는 비용은 낮다 — 재설치면 되고, Chart 와 매니페스트는 런타임과 무관하다.

근거 상세는 `Finch-인프라-QnA.md` §3, §5.

### 이미지 GC 임계값을 85/80 으로 올린 이유

레지스트리가 없다. kubelet 의 이미지 GC 가 도는 대상은 `--docker` 에서는 **Docker 의 이미지
저장소**이므로, 회수 대상에 `finch/*` 뿐 아니라 Jenkins 와 Testcontainers 가 쓰는 베이스
이미지까지 들어간다. 지워지면 다시 받아올 곳이 없거나 빌드를 다시 돌려야 한다.

디스크는 309G 중 9% 사용이라 85% 는 사실상 닿지 않는다. 안전판은 남기되 오작동 여지를 줄인 값이다.
**GC 가 실제로 무엇을 지우는지는 아직 실측하지 않았다.**

## 소유권 분리 (인프라 명세 v0.5 §5.4)

같은 리소스를 두 도구가 번갈아 만지면 소유권 충돌이 난다. 처음부터 최종 도구로 배포한다.

| 계층 | 도구 | 대상 | 이유 |
|---|---|---|---|
| 앱 | **Helm** (`charts/finch`) | backend, ai, frontend + Service, Ingress | 머지마다 교체되므로 태그 주입, 이력, `--atomic` 롤백의 가치가 매번 발휘된다 |
| 인프라 | **kubectl** (`manifests/`) | PostgreSQL 2종, Redis, ResourceQuota | 변경이 거의 없고, **DB가 앱 차트에 있으면 앱 배포 실패의 롤백에 DB까지 휘말린다** (폭발 반경 격리) |
| CI/CD | Docker Compose 유지 | Jenkins, gitlab-runner | 클러스터 밖에서 클러스터를 배포하는 도구라 수명 주기를 분리 |

## 적용 순서

```bash
# 1. k3s 설치 (FINCH-39). helm 바이너리까지 함께 들어간다.
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

# 4. 앱 계층. 이미지 반입 단계는 없다 — 런타임이 Docker 라 docker build 결과를 그대로 참조한다.
#    다만 imagePullPolicy 가 IfNotPresent 여야 한다 (:latest 는 기본이 Always 라 레지스트리를 친다).
helm upgrade --install finch infra/k8s/charts/finch -n finch --atomic --timeout 5m

# 5. Ingress 는 커트오버 때만 (FINCH-133, 136).
#    Compose nginx 가 80/443 을 놓기 전에는 스크립트가 스스로 거부한다.
sudo ./infra/k8s/install-ingress-nginx.sh
```

## Compose 대비 달라지는 것 (전환 시 확인 목록)

- [x] **`imagePullPolicy: IfNotPresent`** — 태그가 `latest` 면 k8s 기본값이 `Always` 라,
      로컬에 이미지가 있어도 레지스트리를 찾다가 `ErrImagePull` 로 죽는다. `--docker` 를 써도
      이 함정은 남는다. backend, ai, frontend 세 템플릿에 모두 명시돼 있다 (확인함).
- [ ] **frontend 이미지의 nginx.conf 조정 필요** — 현재 conf 는 Docker 내장 DNS(127.0.0.11)
      resolver 로 backend/jenkins 를 프록시한다. k8s 에서는 라우팅을 ingress-nginx 가 맡으므로
      frontend 는 **정적 서빙 전용 conf** 로 바꾼다 (차트의 Ingress 가 /api 라우팅을 대체).
- [ ] backend 접속 계약은 이미 k8s 전제다 — `application.yaml` 이 Service 이름
      `postgres`, `redis` 를 호스트로 쓰고 `postgres-secret` 주입을 가정한다. 매니페스트가 이 이름을 따른다.
- [ ] Jenkinsfile 배포 스테이지를 `compose up` → `helm upgrade --install` 로 교체.
- [ ] 이미지 태그를 latest → 커밋 해시로 전환 (차트 values 의 tag 를 `--set` 으로 주입).
- [ ] 시세 워커가 생기면 앱 차트에 Deployment 추가 (별도 프로세스 결정 — 인프라 QnA §7).
- [ ] 관측 스택은 공식 Helm 차트로 별도 릴리스 (앱 차트에 넣지 않는다 — 앱 롤백과 생명주기 분리):
      Prometheus, Grafana, **Loki + Alloy(DaemonSet)**. 로그는 각 서비스 stdout → CRI 로그 파일
      (`/var/log/pods/...`) → Alloy 수집이라 앱 코드 수정 없음. 로테이션은 kubelet 기본값(10Mi×5)이
      compose 설정을 승계. Loki retention 기간은 팀 결정 대기. 도입 시점(compose 먼저 vs 전환과 함께) 미정.

## 로컬 검증 (서버 없이)

```bash
helm lint infra/k8s/charts/finch
helm template finch infra/k8s/charts/finch
```
