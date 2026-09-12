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

### 이미지 GC 임계값을 85/80 으로 올린 이유 (2026-09-07 실측)

레지스트리가 없다. `--docker` 에서 kubelet 의 이미지 GC 가 도는 대상은 **Docker 의 이미지
저장소 그 자체**다. 추정이 아니라 확인했다 — `crictl images` 와 `docker images` 가 같은 29개를
반환한다. 별도의 k8s 전용 저장소가 없다.

따라서 GC 회수 대상에는 `finch/*` 네 개뿐 아니라 Compose 스택과 CI 가 의존하는 것이 전부 들어간다.

    finch/backend, finch/ai, finch/nginx, finch/jenkins
    eclipse-temurin:21-jdk, gitlab/gitlab-runner, gitlab-runner-helper,
    testcontainers/ryuk, pgvector/pgvector:pg17, postgres:17, redis:7-alpine ...

`finch/*` 는 Jenkins 재빌드로 복구되지만, GC 가 CI 가 쓰는 helper 와 ryuk 이미지를 지우면
**파이프라인이 조용히 깨진다.** 디스크는 309G 중 9%(26G) 사용이라 85% 는 사실상 닿지 않는
값이고(약 262G 에서 발동), `imageMinimumGCAge` 기본값 2분도 함께 걸린다. 안전판은 남기되
오작동 여지를 줄인 값이다.

적용 확인은 kubelet configz 로 한다.

```bash
NODE=$(kubectl get node -o jsonpath='{.items[0].metadata.name}')
kubectl get --raw "/api/v1/nodes/$NODE/proxy/configz" | tr ',' '
' | grep imageGC
# "imageGCHighThresholdPercent":85
# "imageGCLowThresholdPercent":80
```

`ps` 로는 확인되지 않는다. k3s 는 kubelet 을 별도 프로세스가 아니라 `k3s server` 안에서
돌리므로 명령줄에 `--image-gc-*` 가 그대로 보이지 않는다.

## 설치 실측 (2026-09-07, FINCH-39)

| 항목 | 값 |
|---|---|
| k3s 버전 | v1.36.4+k3s1 |
| 런타임 | `docker://29.7.2` (cri-dockerd) |
| 메모리 오버헤드 | **약 500~590MB** (`free` 기준 2.9Gi → 3.4Gi, `k3s.service` MemoryCurrent 589MB). 예상치 800MB 아래 |
| iptables 규칙 | filter 146 → 233, nat 24 → 73 |
| 기존 서비스 | 영향 없음. `https://finchapp.org/` 200, finch 컨테이너 13개 유지 |
| 로컬 이미지 참조 | `finch/backend:latest` 파드가 반입 단계 없이 기동 확인 |

시스템 파드(coredns, local-path-provisioner, metrics-server)는 기동 직후 readiness probe
실패로 각 1회 재시작한 뒤 안정화됐다. 기동 순서 문제로 보이며 이후 재발하지 않았다.

설치는 CI 유휴 상태를 확인하고 실행했다. k3s 가 iptables 를 다시 쓰므로 gitlab-runner 빌드나
Testcontainers 가 도는 중에 설치하면 남의 파이프라인이 중간에 깨질 수 있다.

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

# backend 비밀값. 값의 원본은 Jenkins Credentials 다 (finch-env, finch-extra-env,
# finch-kakaopay-secret). compose 는 .env 로 받고 여기서는 Secret 으로 받는다 —
# 주입 경로만 다르고 이름과 값은 같다.
#
# 이 목록이 곧 계약이다. infra/scripts/check-env-contract.py 가 아래 --from-literal
# 이름을 읽어 application.yaml 의 요구와 대조한다. 키를 늘리면 여기도 늘린다.
kubectl -n finch create secret generic backend-secret \
  --from-literal=JWT_SECRET=... \
  --from-literal=KAKAO_CLIENT_ID=... \
  --from-literal=KAKAO_CLIENT_SECRET=... \
  --from-literal=KAKAOPAY_SECRET_KEY=... \
  --from-literal=KIS_APP_KEY=... \
  --from-literal=KIS_APP_SECRET=... \
  --from-literal=BACKEND_INTERNAL_TOKEN=... \
  --from-literal=AI_INTERNAL_TOKEN=...

# 3. 인프라 계층 (DB, Redis, ResourceQuota)
kubectl apply -f infra/k8s/manifests/

# 4. 앱 계층. 이미지 반입 단계는 없다 — 런타임이 Docker 라 docker build 결과를 그대로 참조한다.
#    다만 imagePullPolicy 가 IfNotPresent 여야 한다 (:latest 는 기본이 Always 라 레지스트리를 친다).
helm upgrade --install finch infra/k8s/charts/finch -n finch --atomic --timeout 5m

# 고정 테스트 계정(testUserNo=1)을 한 번 로그인해 생성한 뒤 시연 데이터를 초기화한다.
kubectl -n finch exec -i statefulset/postgres-backend -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < infra/k8s/scripts/seed-demo-account.sql

# 5. Ingress 는 커트오버 때만 (FINCH-133, 136).
#    Compose nginx 가 80/443 을 놓기 전에는 스크립트가 스스로 거부한다.
sudo ./infra/k8s/install-ingress-nginx.sh

# 6. 관측 계층 (FINCH-134). 네임스페이스가 다르다.
#    Grafana 비밀번호는 차트가 만들지 않는다 — 없으면 파드가 뜨지 않는다(의도).
kubectl -n finch-observability create secret generic grafana-admin-secret   --from-literal=admin-user=admin --from-literal=admin-password=...
helm upgrade --install finch-obs infra/k8s/charts/finch-observability   -n finch-observability --atomic --timeout 10m
```

## Ingress 와 TLS (FINCH-133)

**포트를 인자로 받는다.** 검증과 커트오버가 같은 스크립트를 쓴다.

```bash
sudo ./infra/k8s/install-ingress-nginx.sh                       # 8081 / 8443 (검증)
sudo HTTP_PORT=80 HTTPS_PORT=443 ./infra/k8s/install-ingress-nginx.sh   # 커트오버
```

`hostNetwork` 대신 **`hostPort`** 를 쓴다. hostNetwork 는 파드가 호스트 네트워크를 그대로
써서 컨트롤러가 여는 포트를 바꾸기 번거롭고, 두 스택을 나란히 띄울 수 없다.

> [!warning] hostPort 는 `ss` 에 리스너로 나타나지 않는다
> CNI portmap 플러그인이 **iptables DNAT** 로 처리하므로 리스닝 소켓이 없다.
> `ss -tlnp | grep 8443` 은 비어 있는데 `curl https://127.0.0.1:8443/` 은 200 이다.
> 처음 이걸로 "포트가 열리지 않았다" 고 오판했다. **포트 판정은 응답으로 한다.**
> 규칙 확인은 `sudo iptables -t nat -S | grep 8443` 이다.

### TLS Secret 은 차트가 만들지 않는다

인증서는 호스트 certbot 이 발급하고 `infra/k8s/scripts/sync-tls-secret.sh` 가 Secret 으로 옮긴다.

```bash
sudo ./infra/k8s/scripts/sync-tls-secret.sh
```

**차트에 넣지 않는 이유는 갱신 주기가 다르기 때문이다.** 인증서는 클러스터 밖에서 90일마다
바뀌는데 helm 릴리스는 배포마다 갱신된다. 차트가 Secret 을 소유하면 두 주기가 어긋난다.

`renew-cert.sh` 가 갱신 후 이 스크립트를 부른다. **호스트 인증서만 갱신하고 Secret 을 두면
클러스터는 만료된 인증서를 계속 쓰고, 증상이 90일 뒤에 나타난다.**

스크립트는 마지막에 **지문을 대조한다.** ingress-nginx 가 Secret 변경을 watch 해서 자동으로
다시 읽지만, watch 가 늦거나 실패할 수 있어 "넣었다" 와 "반영됐다" 를 따로 확인한다.

### ACME 챌린지는 커트오버 때 켠다

`values.yaml` 의 `ingress.acmeChallenge.enabled` 가 `false` 다. 지금은 80 을 호스트 nginx 가
잡고 있어 `/var/www/certbot` 서빙이 그대로 동작한다.

**커트오버로 80 이 Ingress 로 넘어오면 webroot 갱신이 깨진다.** 갱신은 90일마다 오므로
직후에는 아무 증상이 없고 두 달 뒤에 만료된다. 그 Ingress 규칙과 대상 서비스는
FINCH-136 에서 만든다.

그 규칙의 `ssl-redirect: "false"` 가 핵심이다. **챌린지는 HTTP 로 와야 한다** — 인증서를
받기 전에는 HTTPS 가 성립하지 않으므로 리다이렉트를 걸면 갱신이 영구 실패한다.

### 검증 단계에서 8081 리다이렉트는 포트가 빠진다

```
http://finchapp.org:8081/  →  308  https://finchapp.org/
```

`ssl-redirect` 가 포트를 붙이지 않아 **443(기존 Compose)으로 간다.** 검증 중에는 혼란스럽지만
커트오버 후에는 정확한 동작이므로 그대로 둔다. 8443 을 검증할 때는 HTTPS 로 직접 호출한다.

## helm upgrade 의 values 유지 함정

`helm upgrade` 는 이전 릴리스에서 `--set` 으로 준 값을 **다음 upgrade 에도 유지한다.**
그래서 `--set` 없이 다시 upgrade 해도 차트의 `values.yaml` 기본값으로 돌아가지 않는다.

```bash
helm upgrade finch . --set backend.image.tag=test1   # tag=test1
helm upgrade finch .                                 # tag 가 여전히 test1 이다
helm upgrade finch . --reset-values                  # 여기서야 values.yaml 기본값으로 돌아온다
```

2026-09-09 에 rolling update 를 검증하려고 임시 태그를 준 뒤 되돌리려다 걸렸다.
`imagePullPolicy: IfNotPresent` 라 그 이미지가 로컬에 남아 있는 동안은 파드가 계속 도는데,
**태그만 지우고 릴리스를 되돌리지 않으면 다음 파드 재시작에서** `ErrImagePull` **로 죽는다.**
도는 파드만 보고 정상이라고 판정할 수 없다 — `helm get values` 나 Deployment 의 image 를 본다.

배포 파이프라인이 매번 `--set backend.image.tag=<커밋해시>` 를 주게 되면(FINCH-135)
이 문제는 사라진다. 손으로 실험한 뒤에만 주의한다.

## 관측 스택에서 밟은 함정 (FINCH-134)

### `discovery.docker` 는 파드 컨테이너를 대상으로 만들지 않는다

런타임이 Docker 라(`--docker`) 파드 컨테이너도 같은 도커 데몬 위에 있고 `docker ps`
에 그대로 보인다. 그래서 도커 소켓 하나로 파드 로그와 클러스터 밖 로그를 동시에
수집할 수 있을 것 같지만 **안 된다.**

`discovery.docker` 는 (컨테이너, 네트워크) 쌍으로 대상을 만든다. 파드 컨테이너는
pause 컨테이너의 네트워크 이름공간을 공유하므로 자기 네트워크가 없다.

```
파드 컨테이너      NetworkMode=container:<sandbox>  Networks=0  Ports=map[]
compose 컨테이너   NetworkMode=finch_default         Networks=1  Ports=8080/tcp
```

실측에서 발견된 대상 24개 중 쿠버네티스 라벨을 가진 것이 **0개**였다.
**`docker ps` 로는 보이는데 디스커버리로는 안 보인다** — 확인한 도구와 쓰는 도구가
달랐던 경우다. 파드 로그는 `/var/log/pods` 파일을 읽는 별도 파이프라인으로 받는다.

`/var/log/pods` 의 파일은 `/var/lib/docker/containers/.../*-json.log` 로 가는 심볼릭
링크다. **두 경로를 모두 마운트해야 한다.** 하나만 마운트하면 링크는 보이는데 내용을
읽을 수 없고, 증상은 "로그가 안 온다" 로만 나타난다.

파일 내용이 도커 JSON 이라 `loki.process` 에 `stage.docker` 가 필요하다. 런타임을
containerd 로 바꾸면 CRI 텍스트 형식이 되므로 `stage.cri` 로 바꿔야 한다 —
**이 설정은 런타임 결정에 묶여 있다.**

### Alloy 수집 위치를 잃으면 Loki 가 막힌다

Alloy 의 위치 파일(`/var/lib/alloy-data`)이 비어 있으면 모든 컨테이너 로그를
**처음부터** 읽는다. jenkins 와 gitlab-runner 는 몇 주치가 쌓여 있어 Loki 의 기본
수집 유량(4MB/s)을 넘기고, 넘긴 배치는 429 로 되돌아와 재시도가 쌓인다. 그 뒤에
새 로그가 줄을 서므로 **파드 로그가 안 들어오는 것처럼 보인다.**

`retention_period`(168h)보다 오래된 줄은 `reject_old_samples` 에 걸려 400 으로
영구 거부된다. 이건 맞는 동작이다 — 어차피 보관 기간 밖이다.

대응은 둘이다. 위치 파일을 `hostPath` 에 두어 재시작에도 유지하고, 첫 배수를 위해
`ingestion_rate_mb` 를 올렸다.

### 대시보드가 라벨에 묶여 있다

기존 대시보드가 `job="backend"` 로 4개 패널을 그린다. 애노테이션 기반 범용 job
하나로 서비스 디스커버리를 짜면 job 이름이 `kubernetes-pods` 가 되어 **그 패널이
전부 빈다.** 그래서 서비스별로 job 을 따로 두고 이름을 그대로 유지했다.

로그 패널은 `{job="docker", stack=~"finch.*"}` 였다. 파드 로그의 `job` 은 `k8s` 이고
compose 프로젝트 라벨도 없어 이 필터에 걸리지 않는다. 파드에 `stack="finch-k8s"` 를
붙이고 쿼리에서 `job` 조건을 뺐다. **파드 로그에 `job="docker"` 를 붙이면 쿼리는
그대로 동작하지만 라벨이 거짓이 된다** — 도커 소켓이 아니라 파일로 읽은 것이다.

### node-exporter 도 함께 옮겨야 한다

compose 의 node-exporter 는 포트를 퍼블리시하지 않아 compose 네트워크 안에서만
닿는다. 클러스터의 Prometheus 가 긁을 수 없어 CPU, 메모리, 디스크 패널이 빈다.

### cAdvisor 는 kubelet 이 대신한다

compose 에서 cAdvisor 컨테이너가 overlayfs 때문에 컨테이너를 식별하지 못해 제거했다.
kubelet 이 `/metrics/cadvisor` 로 같은 지표를 내장 노출하고, 컨테이너 식별을 자기가
띄운 파드 정보로 하므로 스토리지 드라이버와 무관하다. **이관으로 되찾은 지표다.**

`nodes/metrics` RBAC 이 있어야 한다. `nodes` 만 주면 대상은 발견되는데 스크레이프가
401 이 된다 — 설정이 맞는 것처럼 보이고 `up` 만 0 으로 남는다.

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
