# infra — 배포 인프라

인프라 결정의 배경과 근거는 팀 결정서(FINCH 인프라 결정서)를 참고한다.
모든 서버 설정은 이 디렉터리에 코드로 남긴다 — 서버에서 손으로 만진 설정은 서버 이사 때 잃어버린다.

## 서버 (EC2)

| 항목 | 값 |
|---|---|
| 서버명 | finch |
| 호스트명 | `finchapp.org` (지급) |
| OS / 계정 | Ubuntu / `ubuntu` |
| 접속 | `ssh -i finchT.pem ubuntu@finchapp.org` |
| 서비스 URL | **`https://finchapp.org/`** — 아래 참고. 옛 주소도 같은 서비스를 계속 받는다 |
| Jenkins | `http://finchapp.org/jenkins/` (nginx 80 경유) |

- `*.pem` 은 `.gitignore` 에 있다 — 절대 커밋하지 않는다. 팀원 간 공유는 별도 채널로. 키 유출 = 서버 무방비 노출.
- 제공 기간: 프로젝트 종료 시까지 (종료 후 7일 이내 삭제). 웹 콘솔 없음, SSH 만 가능.
- **ufw 는 반드시 enable 상태로 유지한다** (규정 — 지급 시 이미 enable + 22 만 허용 상태).
  `setup-server.sh` 가 22·80·443 만 허용하고 enable 한다. `sudo ufw status numbered` 로 확인.

  - 포트 추가: `sudo ufw allow <port>/tcp` (active 상태에서 즉시 반영). 절대 `ufw disable` 하지 않는다.
  - 포트 삭제: `sudo ufw status numbered` 로 번호 확인 → `sudo ufw delete <번호>` (하나씩) → **`sudo ufw enable` 다시 실행해야 적용**.
  - 방화벽 작업 전 ssh 터미널을 2~3개 열어 둔다. 22 가 막히면 복구 불가(초기화 요청만 가능).
- 솔루션 기본 포트(8080·9000·5000 등)는 외부에 열지 않는다. 우리 구성은 host 에 80 만 publish 하고
  Jenkins·backend·ai·DB 는 Docker 내부 네트워크에만 둔다 — 이것이 공지의 "기본 포트 변경" 요구를 충족하는 방식이다.
- `/home`·시스템 디렉터리 퍼미션, `~/.ssh/authorized_keys` 를 건드리지 않는다. 해킹·감염 시 복구 불가(초기화만 가능).
- DB 비밀번호 등은 `.env.example` 의 `change-me` 를 반드시 강한 값으로 바꾼다.
- **비밀값의 원본은 Jenkins Credentials 다** (`finch-env`, `finch-ai-env`). 배포 때마다 서버의
  `infra/.env`·`infra/ai.env` 로 주입되고 배포 후 삭제되므로, 서버 파일과 팀원 로컬 사본은
  **재설정용 백업일 뿐 원본이 아니다.** 값을 바꿀 때는 Credentials 를 먼저 고치고 나머지를 맞춘다 —
  사본이 세 곳(로컬·서버·Credentials)이라 원본을 정해두지 않으면 조용히 갈라진다.
- Jenkins 설치는 Jenkins 공식 문서 게시판의 "[CI/CD] Jenkins 설치 가이드" 도 참고 (우리는 Docker 로 띄운다 — 아래).
- 이전에 쓰던 NCP VM(Rocky 8.8) 은 폐기 예정. `setup-server.sh` 는 두 OS 를 모두 지원하므로 필요 시 재사용 가능.

### 주소가 둘이다

`finchapp.org` 로 전환한 것은 2026-09-11(`1548cb0`, `e4527c6`)이다. 지급받은 호스트명이 없어진
것이 아니라 **서비스 진입점이 하나 더 생긴 것**이고, 둘 다 살아 있다.

| 주소 | 무엇을 받나 |
|---|---|
| `finchapp.org`, `www.finchapp.org` | 서비스. Cloudflare Tunnel 이 앞에 선다 |
| `swagger.finchapp.org` | API 문서 (Basic 인증) |
| `finchapp.org` | 서비스도 그대로 받는다. **SSH 와 Jenkins 는 이 주소로만 간다** |

정본은 `infra/k8s/charts/finch/values.yaml` 의 `publicBaseUrl`, `frontBaseUrl`, `ingress.hosts` 다.

**문서에 남은 옛 주소를 일괄 치환하면 안 된다.** 인증서 경로(`/etc/letsencrypt/live/finchapp.org/`)는
certbot 이 만든 실제 디렉터리명이고, SSH 는 터널을 지나지 않으며, 날짜가 붙은 실측 기록은
그때 실제로 부른 주소를 적어 둔 것이다.

## 구성

| 파일 | 역할 |
|---|---|
| `setup-server.sh` | 서버 초기 세팅: swap 4GB, docker, 방화벽(ufw), 백업 cron |
| `docker-compose.yml` | 앱 스택: nginx(+frontend) · backend · ai · PostgreSQL×2 · Redis |
| `docker-compose.infra.yml` | CI/CD 스택: Jenkins · gitlab-runner (앱과 수명 주기 분리) |
| `nginx/nginx.conf` | 단일 진입점 라우팅: `/`→정적파일, `/api`→backend, `/jenkins`→Jenkins |
| `docker/*.Dockerfile` | 파트별 이미지 정의 (파트 디렉터리 소유권을 건드리지 않도록 여기 모음) |
| `scripts/backup-db.sh` | DB 2종 pg_dump 백업 (cron 이 매일 04:00 실행) |
| `scripts/restore-db.sh` | 백업 파일로 DB 복원 (서버 이전과 롤백용) |
| `scripts/notify-lib.sh` | 크론 스크립트가 실패했을 때 Mattermost 로 알린다 (아래 알림 절) |
| `.env.example` | 서버 `.env` 템플릿 — 실제 값은 Jenkins Credentials 에 보관 |

## 서버 첫 구축 순서

```bash
# 0. EC2 보안그룹: 22, 80, 443 만 개방 (Jenkins 는 80의 /jenkins 경로 경유). DB 포트(5432·6379)는 절대 열지 않는다.
#    VM 내부 ufw 는 1번 스크립트가 같은 포트로 맞춘다.
#    (Jenkins 는 nginx 경유 https://finchapp.org/jenkins/ 로 접근·수신한다.
#     github.com 이 webhook 대상에 유효한 인증서를 요구하므로 https 가 전제다)

# 1. 서버 세팅 (재로그인 필요 — docker 그룹 적용)
sudo mkdir -p /srv && sudo chown ubuntu:ubuntu /srv
git clone <repo> /srv/FINCH
cd /srv/FINCH
sudo ./infra/setup-server.sh /srv/FINCH

# 2. 비밀값 배치 (git 에 커밋 금지)
cp infra/.env.example infra/.env   # DB 계정 작성
cp ai/.env.example   infra/ai.env  # AI 외부 API 키 작성

# 3. 앱 스택 기동
cd infra
docker compose up -d --build

# 4. CI/CD 스택 기동
docker compose -f docker-compose.infra.yml up -d --build
# 초기 비밀번호: docker exec finch-jenkins cat /var/jenkins_home/secrets/initialAdminPassword

# 5. gitlab-runner 등록 (토큰: GitLab → Settings → CI/CD → Runners)
docker exec -it finch-gitlab-runner gitlab-runner register \
  --url https://github.com \
  --executor docker --docker-image alpine:latest \
  --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
  --docker-volumes /cache

# 6. 단일 VM CPU 격리 (CI job이 없는 시점에 실행)
sudo infra/scripts/tune-gitlab-runner.sh
```

Runner는 job 두 개를 병렬 실행하고 각 job은 CPU 1개, 메모리 3GB까지 쓴다.
운영 k3s와 같은 4 vCPU를 공유하므로 CI 처리량을 유지하면서 총 CPU를 2코어로 제한한다.
`/cache` 볼륨은 Gradle·npm·pip 캐시를 job 사이에 유지한다. Docker 29의 BuildKit과
Jenkins의 동일 Docker daemon도 이미지 빌드 캐시를 유지하므로 정기 정리에서 build cache를
무조건 삭제하지 않는다.

## NCP → EC2 이전 절차 (데이터 옮기기)

앱은 이미지로 다시 빌드되므로 옮길 것은 **DB 2종 + 비밀값 파일 + Jenkins 설정** 뿐이다.

```bash
# [NCP] 1. 최신 덤프 생성 → 로컬로 가져오기
sudo /srv/FINCH/infra/scripts/backup-db.sh
scp -i <ncp키> <ncp계정>@<ncp공인IP>:/var/backups/finch/*.sql.gz ./
scp -i <ncp키> <ncp계정>@<ncp공인IP>:/srv/FINCH/infra/{.env,ai.env} ./   # 비밀값

# [EC2] 2. 위 "서버 첫 구축 순서" 0~3 까지 진행 (DB 컨테이너가 healthy 상태여야 한다)
scp -i finchT.pem backend-*.sql.gz ai-*.sql.gz .env ai.env ubuntu@finchapp.org:/tmp/
mv /tmp/.env /tmp/ai.env /srv/FINCH/infra/

# [EC2] 3. 복원 (기존 데이터를 지우고 덮어쓴다 — 첫 기동 직후 빈 DB 상태에서 실행)
cd /srv/FINCH/infra
docker compose stop backend ai
sudo ./scripts/restore-db.sh /tmp/backend-<stamp>.sql.gz /tmp/ai-<stamp>.sql.gz
docker compose start backend ai

# [EC2] 4. CI/CD 스택 기동 후 Jenkins 설정
#   jenkins_home 백업이 있으면 아래 "백업과 복원" 의 복원 절차를 쓴다 (손으로 재설정할 필요 없음).
#   백업이 없을 때만 수동 재설정:
#   - Credentials 3건 재등록: finch-env, finch-ai-env (Secret file), GitLab 접근 토큰
#   - job: Pipeline from SCM, branch master
#   - GitLab webhook URL 변경: https://finchapp.org/jenkins/project/<job이름>
```

이전 완료 후 GitLab webhook 이 새 서버로만 가는지 확인하고 NCP 쪽 Jenkins 는 내려둔다
(두 서버가 동시에 배포를 받으면 안 된다).

## 백업과 복원

공지상 **서버 사고 시 복구는 지원되지 않고 초기화만 가능**하다. 초기화 후 백업으로 되살리는 경로가 유일한 방어선이므로, 아래 절차는 실제로 돌려본 것만 적는다.

### 무엇을 언제 백업하는가

| 대상 | 스크립트 | cron | 크기 | 보존 |
|---|---|---|---|---|
| DB 2종 (`finch_back`, `finch_ai`) | `backup-db.sh` | 매일 04:00 | 각 수 KB | 7일 |
| `jenkins_home` 볼륨 | `backup-jenkins.sh` | 매일 04:10 | 약 157MB | 7일 |

cron 은 `/etc/cron.d/finch-db-backup`, `/etc/cron.d/finch-jenkins-backup` 에 있고 로그는 `/var/log/finch-backup.log` 로 간다. 저장 위치는 `/var/backups/finch`.

`jenkins_home` 백업은 `workspace`, `caches`, `war` 를 제외한다. 재생성 가능하기 때문이다. 그래도 157MB 인 것은 **`plugins` 가 198MB** 라서인데, 플러그인이 Dockerfile 에 고정돼 있지 않고 UI 로 설치돼 있어 **이 백업이 플러그인의 유일한 사본**이다. 제외하면 복원 시 94개를 손으로 다시 깔아야 하고 버전도 어긋난다.

### DB 복원

```bash
cd /srv/FINCH/infra
docker compose stop backend ai          # 앱을 먼저 멈춘다
sudo ./scripts/restore-db.sh /var/backups/finch/backend-<stamp>.sql.gz \
                             /var/backups/finch/ai-<stamp>.sql.gz
docker compose start backend ai
```

스크립트는 **대상 DB 를 DROP 후 다시 만든다.** 기존 데이터가 사라지므로 대상을 확인하고 실행할 것.

### jenkins_home 복원

```bash
docker compose -f docker-compose.cicd.yml stop jenkins
docker run --rm -v finch-infra_jenkins_home:/dest -v /var/backups/finch:/src:ro alpine \
  sh -c 'rm -rf /dest/* /dest/.[!.]* 2>/dev/null; tar xzf /src/jenkins-home-<stamp>.tar.gz -C /dest'
docker compose -f docker-compose.cicd.yml start jenkins
```

job 설정, credentials, 플러그인이 함께 살아난다. `secrets/master.key` 와 `secrets/hudson.util.Secret` 이 백업에 들어 있어 credentials 복호화도 된다 — 이 둘이 빠지면 credentials 는 복구 불가다.

### 실측 (2026-09-04 리허설)

라이브를 건드리지 않고, 덤프를 임시 DB 로 복원하고 백업 tar 로 임시 Jenkins 를 별도 포트에 띄워 확인했다.

| 항목 | 결과 |
|---|---|
| backend DB 복원 | 0.3초, 12개 테이블 행 수 원본과 일치 |
| ai DB 복원 | 0.3초, 16개 테이블 행 수 원본과 일치 |
| 확장 생존 | `vector 0.8.6`, `pg_trgm 1.6` 복원 후 유지 |
| jenkins_home 압축 해제 | 2초 (205MB) |
| 임시 Jenkins 기동 | 12초, job `finch-deploy` 적재, 플러그인 94개, credentials 3건 |
| 기동 중 SEVERE, 복호화 실패 | 0건 |
| **총 소요** | **DB 1초 미만 + Jenkins 16초** |

**주의: 현재 DB 에 데이터가 거의 없다** (`users` 2행). 위 0.3초는 지금 데이터량 기준이고, 시연 데이터가 쌓이면 달라진다. 데이터가 들어온 뒤 한 번 더 재야 한다.

credentials 는 기동 시점에 복호화 오류가 없다는 것까지 확인했다. Jenkins 는 실제 사용 시점에 복호화하므로 완전한 증명은 빌드 실행인데, 그러면 운영에 배포되므로 리허설에서는 하지 않았다.

### 리허설 다시 돌리는 법

운영에 영향을 주지 않는 방식이다. 인프라 변경 전마다 한 번씩 돌린다.

- **DB**: 원본 DB 이름 뒤에 `_restoretest` 를 붙인 임시 DB 를 만들어 덤프를 붓고, `information_schema.tables` 기준으로 테이블별 `count(*)` 를 원본과 대조한 뒤 임시 DB 를 지운다.
- **Jenkins**: tar 를 `/tmp` 에 풀고 `--user root` 로 `127.0.0.1:18080` 에 임시 컨테이너를 띄운다. 인증 없는 `/api/json` 이 **403** 이면 보안 설정이 복원된 것이고, 200 이면서 셋업 마법사가 뜨면 실패다.

## 배포 (루트 `Jenkinsfile` 이 수행)

> **2026-09-11 커트오버 이후 배포 대상은 k3s 다.** 아래가 지금 도는 흐름이고,
> compose 로 배포하던 옛 절차는 롤백 경로로만 남는다.

master 머지 webhook → Jenkins 가 자기 워크스페이스에서:

1. 직전 성공 빌드와 `git diff` 로 변경 파트 감지 (backend / ai / nginx)
2. Credentials(`finch-env`, `finch-ai-env`)를 `infra/.env`, `infra/ai.env` 로 주입
3. `docker compose build <변경 서비스>` 로 **이미지만** 만든다
4. `helm upgrade --install finch infra/k8s/charts/finch -n finch --atomic` (`Jenkinsfile:193`)
5. 종료 시 워크스페이스의 비밀값 파일 삭제

**이미지 태그가 `latest` 가 아니다.** 파트별로 `git log -1 --format=%h -- <그 파트 경로>` 로
**그 파트를 마지막으로 건드린 커밋 해시**를 뽑아 `--set <파트>.image.tag=<해시>` 로 넘긴다.
태그가 그대로면 helm 이 차이를 못 찾아 파드를 건드리지 않기 때문이다.

`--atomic` 이라 롤아웃이 실패하면 직전 리비전으로 자동 롤백된다. `--timeout 5m` 이므로
빌드와 롤아웃이 그보다 길어지면 성공한 배포도 되돌아간다.

**변경 감지 범위에 주의한다.** `infra/nginx/` 를 건드리면 nginx(프론트) 이미지가 통째로
다시 빌드돼 그 시점 master 의 `frontend/` 전부가 함께 나간다 (`Jenkinsfile:45~72`).
설정 한 줄만 고칠 때도 프론트에 미배포 변경이 쌓여 있는지 먼저 본다.

Jenkins job 설정(최초 1회)과 Credentials 목록은 `Jenkinsfile` 상단 주석 참고.
수동 전체 배포가 필요하면 job 의 `FORCE_ALL` 파라미터를 켜고 실행한다.

**k3s 쪽 상세는 아래 `## k8s 배포` 절과 `infra/k8s/README.md` 에 있다.**

## healthcheck

배포는 `docker compose up -d --wait` 로 한다. `--wait` 는 **healthcheck 가 있는 서비스는
healthy 를, 없는 서비스는 started 만** 기다린다. 즉 healthcheck 가 없으면 뜨자마자 죽는
배포도 성공으로 기록된다.

| 서비스 | 판정 | 명령 |
|---|---|---|
| backend | healthy | `curl -fsS http://localhost:8080/actuator/health` |
| ai | healthy | `python -c "urllib.request.urlopen('http://localhost:8000/health')"` |
| postgres-backend, postgres-ai | healthy | `pg_isready` |
| nginx | healthy | `curl -fsS -k -o /dev/null https://127.0.0.1/` |
| redis | healthy | `redis-cli ping` |
| jenkins, gitlab-runner, 관측 5종 | 없음 | 사용자 요청 경로가 아니고 배포 판정에 관여하지 않는다 |

`backend` 는 `postgres-backend` 와 `redis` 를 `condition: service_healthy` 로 기다린다.
**떴다는 것과 접속을 받는다는 것은 다르다.**

### healthcheck 에 `localhost` 를 쓰면 안 되는 경우가 있다

nginx 는 IPv4 만 듣는다 (`listen 80;`, `listen 443 ssl;`). 컨테이너의 `/etc/hosts` 는
`localhost` 를 `127.0.0.1` 과 `::1` 양쪽에 매핑하므로, 클라이언트가 `::1` 을 먼저 고르면
연결이 거부된다.

```
docker exec finch-nginx wget -O /dev/null http://localhost/
  → wget: can't connect to remote host: Connection refused

http://127.0.0.1/  301        https://127.0.0.1/ (-k)  200
http://localhost/  301        http://[::1]/            000
```

`curl` 은 IPv4 로 폴백해서 되고 `wget` 은 실패한다. **도구에 따라 결과가 갈리므로 주소를
명시한다.** nginx healthcheck 가 `127.0.0.1` 을 쓰는 이유다.

`https` 로 확인하는 이유는 신호가 더 강하기 때문이다 — 인증서 로드와 정적 파일 존재까지
함께 검증된다. `-k` 는 루프백 자기 점검이라 인증서 검증을 건너뛴다.

## 응답 헤더

`infra/nginx/nginx.conf` 가 내려보내는 헤더다. 실측은 `curl -D - https://finchapp.org/` 로 한다.

| 헤더 | 값 | 이유 |
|---|---|---|
| `Strict-Transport-Security` | `max-age=2592000` | HTTPS 종단이 nginx 다. 이후 접속을 https 로 고정한다 |
| `X-Content-Type-Options` | `nosniff` | 브라우저가 Content-Type 을 추측해 실행하는 것을 막는다 |
| `X-Frame-Options` | `SAMEORIGIN` | 외부 페이지가 우리 화면을 iframe 으로 감싸는 클릭재킹을 막는다 |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | 외부로 나갈 때 경로와 쿼리를 흘리지 않는다 |
| `Cache-Control` | 경로에 따라 둘 | 번들은 `immutable`, `index.html` 은 `no-cache`. 아래 캐시 절 참고 |

`server_tokens off` 은 `http` 레벨(파일 최상단)에 둔다. 그래야 80 과 443 양쪽에 적용된다.
없으면 `server: nginx/1.27.5` 로 버전이 나가고, 버전 문자열은 알려진 취약점을 골라
시도하는 데 쓰인다.

`/jenkins/` 프록시는 `proxy_hide_header` 로 `X-Jenkins`, `X-Hudson` 계열을 지운다.
Jenkins 가 자기 버전을 헤더로 알리는데 프록시가 그대로 통과시키기 때문이다.

### `add_header` 는 상속되지 않는 조건이 있다

**location 블록이 자기 `add_header` 를 하나라도 가지면, 상위 레벨의 `add_header` 를 전혀
물려받지 않는다.** 일부가 아니라 전부다.

그래서 `location /assets/` 에 보안 헤더 네 줄이 `server` 레벨과 중복으로 적혀 있다. 지우면
정적 파일 응답에서만 보안 헤더가 사라진다 — **JS 번들에 `nosniff` 가 빠지는 것이 특히 나쁘다.**

`always` 를 붙이는 이유는 별개다. 이것이 없으면 2xx·3xx 응답에만 헤더가 붙고 4xx·5xx 에는
빠진다. 에러 응답에도 필요하다.

### 캐시 지시자는 두 갈래다 — index.html 과 번들

| 경로 | `Cache-Control` | 이유 |
|---|---|---|
| `/assets/*` | `public, max-age=2592000, immutable` | Vite 가 파일명에 내용 해시를 붙인다. 내용이 바뀌면 이름이 바뀌므로 오래 캐시해도 안전하다 |
| 그 밖(`/`, `/index.html`, `favicon`, `brand/`) | `no-cache` | 이름이 고정이라 캐시하면 새 배포가 안 보인다 |

**`index.html` 에 지시자가 없던 것이 실제 사고였다** (FINCH-217). "배포했는데 옛날 화면이 보인다" 는 제보로 들어왔다.

지시자가 없으면 브라우저가 **휴리스틱으로** 캐시한다(RFC 9111 §4.2.2). 흔한 구현은 `(Date - Last-Modified)` 의 10% 이고, 그 창 안에서는 재검증조차 하지 않는다. 그런데 `index.html` 이 가리키는 번들은 위에서 30일 `immutable` 로 못 박아 뒀다. 그래서 이렇게 된다.

1. 사용자가 페이지를 연다. `index.html` 과 번들이 캐시에 들어간다
2. 배포가 나간다. 새 `index.html` 은 새 해시의 번들을 가리킨다
3. 브라우저는 휴리스틱 창 안이라 `index.html` 을 재검증하지 않는다. 옛 `index.html` 을 읽고, 거기 적힌 옛 번들도 캐시에 `immutable` 로 있다
4. **옛 앱이 조용히 계속 돈다.** 오류도 콘솔 흔적도 없다

**창은 파일이 오래될수록 커진다.** 배포 직후에는 몇 초지만 3일간 배포가 없으면 7시간가량이 된다. 배포가 드물수록 나빠지는 종류의 버그다.

`no-store` 가 아니라 `no-cache` 인 것이 중요하다. `no-store` 는 캐시 자체를 금지해 매번 전체를 다시 받는다. `no-cache` 는 재검증만 요구하고, ETag 가 있어 실측하면 **304 로 끝난다 — 본문 0바이트다.**

```
$ curl -sI -H 'If-None-Match: "6aa24fd7-2e0"' https://finchapp.org/
HTTP/2 304
```

`favicon.svg` 와 `brand/` 도 함께 `no-cache` 가 된다. 이름에 해시가 없어 맞는 처리이고, 비용은 요청당 304 한 번이다.

**이미 옛 `index.html` 을 물고 있는 브라우저는 이 수정으로 즉시 낫지 않는다.** 그 캐시는 지시자 없이 저장된 것이라, 휴리스틱 창이 끝나거나 강제 새로고침(Ctrl+Shift+R)을 해야 새 `index.html` 을 받는다. 고쳐지는 것은 그 이후의 모든 배포다.

### HSTS 기간을 30일로 둔 이유

관례는 1년(`31536000`)이다. 짧게 잡은 것은 의도다.

HSTS 는 브라우저가 기억하는 값이라, 인증서 갱신이 실패하면 **사용자가 경고를 무시하고
들어갈 수단이 없다.** 기간이 곧 사고 시 복구 불가 기간이다. 이 프로젝트는 수 주 뒤 끝나므로
1년을 걸어 얻을 것이 없다. 갱신 자동화가 오래 검증된 뒤에 늘린다.

### 넣지 않은 것

`Content-Security-Policy` 는 넣지 않았다. 잘못 쓰면 화면이 조용히 깨지고, 카카오 인가
리다이렉트와 인라인 스타일까지 확인해야 정확한 값이 나온다. 별건으로 다룬다.

## 환경변수 계약 검사

`infra/scripts/check-env-contract.py` 가 `backend/src/main/resources/application.yaml` 의
`${NAME}` 목록과 `infra/docker-compose.yml` 의 backend `environment:` 키를 대조한다.
`infra/.gitlab-ci.yml` 의 `infra:env-contract` job 이 MR 파이프라인에서 돌린다.

### 왜 필요한가

2026-09-07~08 에 같은 구조의 버그가 네 건 나왔다. 전부 **계약은 선언됐고 주입이 없었다.**

| 티켓 | 이름 | 증상 |
|---|---|---|
| FINCH-151 | `FINCH_PUBLIC_BASE_URL`, `FINCH_FRONT_BASE_URL` | 운영이 localhost 기본값으로 뜸. 결제 복귀 깨짐 |
| FINCH-159 | `KAKAOPAY_SECRET_KEY` | 기동 성공, 결제 시점 인증 실패 |
| FINCH-171 | `FINCH_AI_BASE_URL` | backend 가 자기 자신의 8000 을 호출. AI 중계 전부 실패 |

compose 는 `environment:` 에 적힌 키만 컨테이너로 넘긴다. `--env-file` 은 `${VAR}` 치환용
변수를 주는 것이지 컨테이너 환경변수가 아니다. 그래서 `.env` 에 값이 있어도 `environment:` 에
참조가 없으면 전달되지 않는다.

**기존 장치가 이 누락을 못 잡는다.**

- `${VAR:?}` 가드는 `.env` 에 값이 없는 것을 잡는다. 여기서 빠진 것은 compose 의 참조 자체라 검사 대상이 없다
- 애플리케이션에 기본값이 있으면 조용히 그 값으로 뜬다
- 기본값이 없어도 `@ConfigurationProperties` 바인딩은 해석 안 되는 placeholder 를 예외 대신
  문자열로 남긴다. `@Value` 와 다르다 (FINCH-159 실측)

세 경우 모두 신호가 없다. 사람이 두 파일을 기억으로 대조할 일이 아니다.

### 판정

| 상황 | 결과 |
|---|---|
| 요구되는 이름이 모두 주입됨 | 통과 |
| 주입 안 된 이름이 있음 | **실패.** 기본값 유무에 따라 다른 설명을 출력한다 |
| 값이 아직 없어 주입 못 하는 이름 | 스크립트의 `PENDING` 에 이유와 함께 넣으면 통과 |
| `PENDING` 의 이름이 이미 주입됨 | **실패.** 목록이 낡았으니 지우라고 알린다 |
| `PENDING` 에 계약에 없는 이름이 있음 | **실패.** 같은 이유 |
| 파싱 결과가 비정상 (요구·주입이 5개 미만) | **실패.** 구조가 바뀌어 조용히 통과하는 것을 막는다 |

`PENDING` 은 "아직 값이 없다" 와 "주입을 빠뜨렸다" 를 구분하기 위한 장치다. 지금은 네 건이
들어 있다 — 내부 인증 토큰 2건(backend 와 AI 가 같은 값을 써야 한다)과 KIS 앱키 2건(외부 발급).
넣을 때는 이유와 티켓 번호를 함께 적는다.

### 로컬에서 돌리는 법

```bash
python3 infra/scripts/check-env-contract.py
```

### 범위

backend 만 본다. AI 파트는 Python 에서 환경변수를 직접 읽어 계약 모양이 달라 넣지 않았다.
필요해지면 별건으로 다룬다.

## HTTPS 와 인증서

발급처는 Let's Encrypt, 대상은 `finchapp.org` 한 건이다.

**발급과 갱신의 방식이 다르다.** 최초 발급은 nginx 가 없던 시점이라 `standalone`
(certbot 이 직접 80 을 점유해 검증) 으로 했다. 갱신까지 standalone 으로 두면 갱신할 때마다
nginx 를 내려야 해서 서비스가 끊긴다. 그래서 갱신은 `webroot` 로 한다 — nginx 가 뜬 채로
`/.well-known/acme-challenge/` 만 서빙하면 되므로 무중단이다.

- 인증서: `/etc/letsencrypt/live/finchapp.org/` (호스트). nginx 컨테이너에 읽기 전용 마운트
- 챌린지 경로: `/var/www/certbot` (호스트). certbot 이 쓰고 nginx 가 읽는다
- 갱신: `infra/scripts/renew-cert.sh`, 매일 04:20 cron. 만료가 임박하지 않으면 아무것도 하지 않는다
- 로그: `/var/log/finch-cert.log`

수동 확인:

```bash
sudo openssl x509 -in /etc/letsencrypt/live/finchapp.org/fullchain.pem -noout -dates
sudo /home/ubuntu/FINCH/infra/scripts/renew-cert.sh
```

**nginx.conf 를 고칠 때 주의.** 80 의 `/.well-known/acme-challenge/` location 을 지우거나
`location /` 리다이렉트 뒤로 옮기면 갱신이 조용히 실패한다. 인증서가 만료되기 전까지
증상이 나타나지 않으므로 발견이 늦는다.

**배포 전 검증.** 인증서 경로가 틀리면 nginx 가 기동 자체에 실패해 사이트 전체가 죽는다.
설정을 바꾸면 반드시 실제 인증서를 마운트한 채 문법 검사를 돌린다.

```bash
docker run --rm \n  -v $PWD/infra/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro \n  -v /etc/letsencrypt:/etc/letsencrypt:ro \n  nginx:1.27-alpine nginx -t
```

## 관측 스택 (Prometheus, Grafana, Loki, Alloy)

`docker-compose.observability.yml`. 앱과 CI 스택에서 분리해 띄운다 — 앱을 재배포해도 지표 이력이 남는다.

```bash
cd infra
docker compose -f docker-compose.observability.yml up -d
```

### 왜 지표와 로그를 둘 다 두는가

지표는 "언제 이상한가"에 답하고 로그는 "왜 그런가"에 답한다. 둘은 대체재가 아니다.
지연이 튀는 것은 지표에서만 보이고, 그 순간 무슨 예외가 났는지는 로그에만 있다.
장애 대응은 지표에서 시각을 찾고 로그에서 원인을 찾는 순서로 흐른다.

### 구성

| 컨테이너 | 역할 | 접근 |
|---|---|---|
| `finch-prometheus` | 지표 수집과 저장 (15일, 4GB 상한) | `127.0.0.1:9090` |
| `finch-grafana` | 지표와 로그 조회 | `127.0.0.1:3000` |
| `finch-loki` | 로그 저장 (7일) | 내부 전용 |
| `finch-alloy` | 컨테이너 stdout 수집 → Loki | 내부 전용 |
| `finch-node-exporter` | 호스트 CPU, 메모리, 디스크 | 내부 전용 |

**외부에 포트를 열지 않는다.** Grafana 와 Prometheus 는 `127.0.0.1` 에만 바인딩한다.
커널이 외부 인터페이스에 소켓을 붙이지 않으므로 ufw 규칙과 무관하게 외부에서 닿지 않는다.
보는 방법은 SSH 터널이다.

```bash
ssh -i finchT.pem -L 3000:127.0.0.1:3000 ubuntu@finchapp.org
# 브라우저에서 http://localhost:3000
```

nginx 로 `/grafana` 를 열지 않은 이유는 공개 로그인 화면을 하나 더 늘리지 않기 위해서다.
팀 전원이 이미 서버 pem 을 갖고 있어 터널로 충분하다. 공개가 필요해지면 그때 논의한다.

### 앱 코드를 고치지 않는다

Alloy 는 도커 API 로 컨테이너 목록을 가져와 각 컨테이너의 stdout 을 읽는다.
애플리케이션은 평소대로 표준 출력에 찍기만 하면 되고, 로깅 라이브러리나 파일 경로를 맞출 필요가 없다.
새 컨테이너가 뜨면 자동으로 수집 대상이 되므로 배포마다 설정을 고칠 일도 없다.

k3s 로 옮겨도 같은 원리가 유지된다. 컨테이너 런타임의 로그 규약(stdout → 런타임 로그 파일)이
같기 때문에, 오케스트레이터가 바뀌어도 수집 방식은 그대로다.

### 조회 축

Loki 는 로그 본문을 색인하지 않고 **라벨만** 색인한다. 그래서 먼저 라벨로 좁힌 뒤 본문을 훑는다.

| 라벨 | 값 예 | 출처 |
|---|---|---|
| `container` | `finch-backend` | 도커 컨테이너 이름 |
| `service` | `backend` | compose 서비스명 (컨테이너를 다시 만들어도 유지) |
| `stack` | `finch`, `finch-infra` | compose 프로젝트명 |

```logql
{service="backend"}                          # 백엔드 로그
{stack="finch"} |= "ERROR"                     # 앱 스택 전체에서 ERROR
{job="docker"} |= "3fa85f64-5717-4562"        # 요청 ID 로 backend 와 ai 교차 조회
```

마지막 것이 중요하다. 분산 추적(Jaeger 등)을 도입하지 않기로 한 대신,
`X-Request-Id` 로 서비스 간 로그를 잇는다. 홉이 최대 3단계라 이 방법으로 충분하다.

### 지금 없는 것

- **AI 애플리케이션 지표** — FastAPI 가 `/metrics` 를 노출하지 않는다(실측 404).
  계측 추가는 `ai/` 소유인 AI 파트에 요청해야 한다 (ADR-0002).
- **컨테이너별 자원 지표** — cAdvisor 를 넣으려 했으나 이 서버의 Docker 스토리지 드라이버가
  `overlayfs`(Docker 25+ 의 새 이름)라 cAdvisor v0.49~v0.52 가 컨테이너를 식별하지 못한다.
  `FINCH-59`(리소스 실측) 때는 `docker stats` 로 직접 재고,
  `FINCH-39`(k3s 전환) 후에는 kubelet 이 같은 지표를 내장 노출하므로 그때 job 을 추가한다.

### 설정을 고칠 때

배포 전에 각 도구로 검증한다. 잘못된 설정은 컨테이너가 조용히 재시작 루프에 빠지는 형태로 나타난다.

```bash
cd infra/observability
docker run --rm --entrypoint promtool -v $PWD/prometheus.yml:/p.yml prom/prometheus:v3.1.0 check config /p.yml
docker run --rm -v $PWD/loki-config.yml:/c.yml grafana/loki:3.3.2 -config.file=/c.yml -verify-config
docker run --rm -v $PWD/alloy-config.alloy:/c.alloy grafana/alloy:v1.5.1 fmt /c.alloy
```

`GRAFANA_ADMIN_PASSWORD` 가 비어 있으면 Grafana 는 기동을 거부한다.
설정을 빠뜨린 배포가 `admin/admin` 으로 뜨는 것을 막기 위한 의도적 설계다.

## 운영 스크립트와 정기 작업

### `/srv/FINCH` 의 git 상태는 믿지 마라

`setup-server.sh` 가 저장소를 `/srv/FINCH` 로 클론해 부트스트랩하는데, **그 클론은 갱신되지 않는다.** root 로는 fetch 가 되지 않아(비공개 저장소 자격증명이 없다) `origin/master` 조차 클론한 시점에 멈춰 있다.

실제로 `renew-cert.sh` 가 두 달 뒤에 터질 상태로 방치돼 있었다 — master 에는 TLS Secret 동기화가 들어갔는데 cron 이 부르는 파일에는 없었다(FINCH-204).

그래서 **`infra/scripts/` 와 `infra/k8s/` 두 디렉터리는 배포가 덮어쓴다.**

```
docker-compose.infra.yml   ${OPS_DIR:-/srv/FINCH}/infra:/opt/ops
Jenkinsfile                '운영 스크립트 동기화' 스테이지 (when 게이트 없음)
```

`when` 을 걸지 않은 것이 핵심이다. `infra/scripts/` 만 고친 커밋은 `SERVICES` 를 세우지 않아서, 게이트를 걸면 그 배포에서 스테이지가 건너뛰어지고 문제가 그대로 재현된다.

**그 두 디렉터리를 서버에서 직접 고치지 마라.** 다음 배포가 덮는다. 나머지 파일(`docker-compose*.yml`, `.env` 등)은 배포가 건드리지 않으므로 수동 반영이 맞다 — 특히 `docker-compose.infra.yml` 은 **Jenkins 자신의 정의**라 Jenkins 가 배포할 수 없다. 배포 도구가 자기를 배포하면 도중에 죽는다.

### cron

`setup-server.sh` 가 `/etc/cron.d/` 에 등록한다. `crontab -l` 로는 보이지 않는다 — 별개의 등록처다.

| 시각 | 파일 | 하는 일 |
| :--- | :--- | :--- |
| 04:00 | `finch-db-backup` | DB 덤프 |
| 04:10 | `finch-jenkins-backup` | `jenkins_home` (플러그인 제외) |
| 04:20 | `finch-cert-renew` | 인증서 갱신 + k8s TLS Secret 동기화 |
| 04:30 | `finch-image-prune` | dangling 이미지 정리 |
| 06:00 / 07:00 / 09:20 / 16:30 / 18:40 | `finch-ingest` | AI 근거 데이터 적재 (FINCH-179) |
| 06:50 | `finch-ai-keys` | AI 외부 API 키 점검 (FINCH-213) |

적재는 `ingest-batch.sh <단계>` 이고 단계는 `master`, `market`, `docs`, `news`, `briefing`, `all` 이다. 전역 잠금(`flock`)이 있어 시각이 겹쳐도 뒤엣것이 기다린다. 실행 시 `deploy/ai` 존재 여부로 k3s를 우선 감지하고, 없으면 compose를 사용한다. 장애 복구처럼 런타임을 고정해야 할 때는 `OPS_RUNTIME=k3s|compose`를 명시한다.

`docs` 단계는 공시 원문(`app.rag.dart`, 7일)과 공시 이벤트 표(`ingest.events`, 30일)를 같은 종목 목록으로 적재한다. 이벤트 표는 목록 API 만 써 비용이 없고, 브리핑·성과 요인·다가오는 일정이 읽는다.

`news` 단계는 DB에 남은 과거 종목을 합치지 않고 `Settings.service_tickers`의 확정
30종목만 수집한다. 기본값은 최근 2일·종목당 최대 20건이며 `NEWS_DAYS`와
`NEWS_MAX_DOCS`로 조정한다. URL 해시 unique 제약으로 중복 기사는 다시 저장하지 않고,
신규 청크만 임베딩한다. 모든 기사는 `documents/document_chunks`에서 채팅 검색에
재사용되고, 종목별 하루 최대 3건의 중요 기사는 `events`로 승격되어 07:30 데일리
브리핑 배치가 같은 문서와 인용을 재사용한다. 따라서 06:00 뉴스 적재가 07:30 브리핑보다
항상 먼저 실행되어야 한다.

**대상 종목을 문서가 아니라 DB 에서 만든다** — 이미 적재된 종목과 백엔드 보유·거래 종목의 합집합이다. 시드 목록을 쓰면 시연 계정이 그 밖의 종목을 사는 순간 낡고, 실제로 그 일이 나서 포트폴리오 진단이 통째로 409 였다.

로그는 `/var/log/finch-*.log` 이고 `/etc/logrotate.d/finch` 이 주 1회 4세대로 돌린다. **`su root syslog` 가 있어야 한다** — `/var/log` 가 `root:syslog 775` 라 그 지시자가 없으면 logrotate 가 대상 전부를 건너뛴다. 설정 파일은 놓여 있는데 아무것도 돌지 않는 상태가 된다.

### AI 외부 데이터 키 검증

`infra/scripts/verify-ai-keys.sh` 가 DART, NAVER, KRX 키 3종(값 4개)이 실제로 유효한지 본다. 매일 06:50 에 돈다 — 07:00 첫 적재 10분 전이다.

**왜 필요한가.** 적재 코드는 키가 틀려도 그 종목을 건너뛰고 **"0건 적재" 로 끝난다**(`ai/app/rag/dart.py:121`). 키 문제와 데이터 없음이 화면에서 구분되지 않는다.

**어디서 읽는가가 이 스크립트의 핵심이다.**

2026-09-09 에 이런 일이 있었다.

```
master 파이프라인   infra:ai-keys-verify   →  유효     (CI 변수를 검사)
운영 컨테이너        DART_API_KEY           →  빈 값
                    NAVER_CLIENT_ID        →  빈 값
                    NAVER_CLIENT_SECRET    →  빈 값

instruments 0,  price_daily 0,  documents 0,  document_chunks 0
```

**초록불이 거짓이었다.** 같은 값의 집이 둘인데 검사는 CI 변수만 봤다. 앱이 실제로 읽는 것은 Jenkins 크리덴셜을 거쳐 컨테이너에 주입된 값이다. 그 초록 때문에 원인을 다른 데서 찾느라 하루를 썼다.

그래서 **기본 검사 대상이 배포된 컨테이너다.** 값을 읽는 쪽과 검사하는 쪽이 같아야 한다.

| `AI_KEY_SOURCE` | 읽는 곳 | 쓰는 자리 |
|---|---|---|
| `container` (기본) | `$AI_EXEC printenv <KEY>` | cron, 사람이 손으로 |
| `env` | 이 셸의 환경변수 | GitLab CI job `infra:ai-keys-verify` |

CI job 이 `env` 인 이유는 둘이다. 그 job 의 목적이 **CI 변수 자체**의 유효성이고, 그 alpine 이미지에는 docker CLI 가 없어 `container` 모드가 돌지도 않는다.

`AI_EXEC` 는 커트오버(FINCH-136) 때 한 줄만 바꾸면 되게 뺐다. `ingest-batch.sh` 와 같은 방식이다.

```
compose   docker exec finch-ai
k8s       kubectl -n finch exec deploy/ai --
```

**컨테이너에 못 닿는 것과 키가 빈 것을 구분한다.** 이 구분이 없으면 컨테이너가 죽었을 때 "키 4개가 전부 비었다" 로 보고되고, 사람은 키를 다시 발급받으러 간다. 이 스크립트가 고치려는 사고와 같은 종류다. 그래서 `APP_ENV` 를 먼저 읽어 보고 실패하면 거기서 끊는다.

**값은 절대 출력하지 않는다.** 길이(`len=40`)와 외부 API 응답 코드만 남긴다.

**경보로 잇지 않았다.** 적재가 비는 증상은 관측 경보가 `ai_ingest_*` 로 이미 잡는다(FINCH-187). 이 검사가 하는 일은 그때 **원인이 키인지** 를 로그 한 줄로 가려 주는 것이다. 같은 사건에 알림을 두 번 보내면 둘 다 무시하게 된다.

**판정이 외부 API 장애와 섞이지 않게 했다.** DART 는 키가 틀려도 HTTP 200 에 본문 `status` 코드로 알려 주므로 코드를 갈라서 본다 — `800`(시스템 점검)은 키 문제가 아니라고 명시한다. NAVER 는 개발자센터가 아니라 **NCP API HUB** 라 헤더가 `X-NCP-APIGW-API-KEY-ID` 다(`ai/ingest/news.py:37`). 엔드포인트와 헤더가 앱이 쓰는 것과 같아야 하고, 다르면 멀쩡한 키를 무효로 판정한다.

### 알림

**세 곳이 같은 형식으로 한 채널에 보낸다.** 형식이 갈리면 읽는 사람이 매번 다시 파악해야 한다.

| 보내는 것 | 발신자 | 언제 |
| :--- | :--- | :--- |
| 관측 경보 (AI 헬스, 적재 상태) | `Finch 관측` | Grafana 알림 규칙 (FINCH-187) |
| 배포 실패와 복구 | `Finch 배포` | Jenkins `notifyDeploy` |
| 크론 배치 실패와 복구 | `Finch 배치` | `notify-lib.sh` (FINCH-216) |

본문은 다섯 줄로 고정이다.

```
[경보] DB 백업 실패
상태  발생
증상  backup-db.sh 42행에서 종료 코드 1 (docker exec finch-postgres-ai pg_dump ...)
조치  sudo /srv/FINCH/infra/scripts/backup-db.sh, 로그는 /var/log/finch-backup.log
대상  DB 백업
시각  2026-09-10 04:00:12
```

**Mattermost 로 보내지만 페이로드는 Slack 형식이다.** Incoming Webhook 이 Slack 호환이라 `attachments` 를 이해한다. Grafana 쪽도 같은 이유로 컨택트 포인트 타입이 `webhook` 이 아니라 `slack` 이다 — `webhook` 은 Grafana 자체 JSON 을 보내서 본문이 빈 줄로 뜬다.

**URL 은 `/etc/finch/notify-webhook` (600 root) 에 두고 저장소에 넣지 않는다.** URL 을 가진 사람은 누구나 팀 채널에 글을 쓸 수 있다. `setup-server.sh` 는 디렉터리만 만들고 파일은 사람이 넣는다.

k8s 쪽 Grafana 는 같은 파일에서 Secret 을 만들어 쓴다.

```
kubectl -n finch-observability create secret generic alert-webhook   --from-file=url=/etc/finch/notify-webhook
```

**파일이 없으면 배치는 그대로 돌고 알림만 건너뛴다.** 알림 전송 실패가 배치 판정을 바꾸면 더 나쁘다 — 백업이 성공했는데 알림이 안 갔다는 이유로 실패로 기록되면, 실제 실패와 구별되지 않는다. Grafana 만 예외로 Secret 이 없으면 파드가 뜨지 않는다. 관측만 돌고 알림은 죽어 있는 상태를 조용히 지나가지 않게 한 것이다.

### AI 토큰 대시보드

개요 대시보드의 "AI — 토큰" 행은 AI DB 를 Grafana 가 직접 읽는다. AI 가 요청마다
`ai_responses` 에, LLM 정산마다 `ai_token_daily` 에 토큰을 남기므로 지표를 따로
내보내지 않는다 — 재시작해도 0 이 되지 않고 청구와 대조할 숫자가 그대로 있다.

계정은 두 테이블만 읽는 역할로 만든다. AI DB 에서 한 번:

```sql
CREATE ROLE grafana_ro LOGIN PASSWORD '<비밀번호>';
GRANT CONNECT ON DATABASE ai_invest TO grafana_ro;
GRANT USAGE ON SCHEMA public TO grafana_ro;
GRANT SELECT ON ai_responses, ai_token_daily TO grafana_ro;
```

그 값을 Secret 으로 넣는다. `alert-webhook` 과 같이 **없으면 Grafana 파드가 뜨지 않는다.**

```
kubectl -n finch-observability create secret generic grafana-ai-db \
  --from-literal=user=grafana_ro --from-literal=password='<비밀번호>' --from-literal=database=ai_invest
```

비용 패널은 gpt-5-nano 공시 단가를 SQL 상수로 들고 있다. 모델을 바꾸면 대시보드
JSON 의 그 상수를 같이 고친다.

**같은 실패가 이어지는 동안에는 한 번만 보낸다.** `market` 은 장중 매시 도는데 원인이 그대로면 아홉 통이 온다. `/var/lib/finch/notify-state/<이름>` 에 마지막 상태를 두고 전이할 때만 보낸다. 실패한 뒤 처음 성공하면 `[복구]` 가 온다.

이름별로 상태를 가른다. **이름이 한글이라 파일명을 그대로 쓸 수 없어 해시를 붙인다** — 안전한 문자만 남기면 한글이 전부 밑줄이 되어 `DB 백업` 과 `시세 적재` 가 같은 파일을 쓴다.

`ERR` 트랩을 걸 때 **`set -E` 를 함께 켜는 것이 핵심이다.** 대상 스크립트들은 `set -euo pipefail` 이고 `-E` 가 없다. `-E` 가 없으면 **함수 안에서 실패해도 `ERR` 트랩이 걸리지 않는다.** `ingest-batch.sh` 는 전부 `main()` 안에서 도는 구조라 그것을 빼면 알림이 한 번도 오지 않는다. 붙였다고 믿는데 안 오는 것이 안 붙인 것보다 나쁘다.

## Jenkins 이미지

`infra/docker/jenkins.Dockerfile` 이 만든다. 베이스는 **움직이는 태그가 아니라 정확한 버전**으로 고정한다(`2.568.2-lts-jdk21`) — `lts` 는 재빌드 시점에 따라 다른 Jenkins 가 나오고 그때 무엇이 바뀌었는지 남지 않는다.

담긴 것은 docker CLI, `kubectl`, `helm`, 그리고 `jenkins-plugins.txt` 의 플러그인 94개다. 플러그인 목록을 갱신하려면 컨테이너에서 뽑아 파일을 덮는다 — 명령은 그 파일 머리에 있다.

`jenkins-plugin-cli` 는 `/usr/share/jenkins/ref/plugins` 에 넣고 Jenkins 는 기동할 때 **`jenkins_home` 에 없는 것만** 복사한다. 그래서 이미지를 바꿔도 지금 볼륨의 플러그인을 덮어쓰지 않는다.

이 고정 덕분에 백업에서 플러그인을 뺐다(159MB → 3.2MB). **되돌려야 하면 `backup-jenkins.sh` 의 `--exclude='./plugins'` 한 줄만 지운다.**

## k8s 배포

앱 계층은 Helm 릴리스 `finch` 가, 상태를 가진 계층은 원시 매니페스트가 관리한다.

```
infra/k8s/charts/finch/       ai · backend · frontend · ingress      (helm)
infra/k8s/manifests/          namespace · postgres × 2 · redis · resourcequota  (kubectl apply)
```

k3s 의 컨테이너 런타임이 docker 라 **로컬에서 빌드한 이미지를 그대로 본다.** 레지스트리가 필요 없고 `imagePullPolicy` 가 `IfNotPresent` 다.

그래서 태그가 중요하다. `:latest` 를 다시 빌드해도 helm 은 값이 그대로라 파드를 바꾸지 않는다. 파이프라인은 **그 파트를 마지막으로 건드린 커밋**을 태그로 준다 — 매 빌드의 HEAD 를 쓰면 문서만 고친 머지에도 파드 전체가 교체되고, 안 바뀐 파트는 태그가 그대로라 helm 이 그냥 넘어간다.

### helm 을 왜 임시 컨테이너에서 부르는가

Jenkins 컨테이너 안에서 직접 부르면 k8s API 서버에 닿지 못한다.

```
docker run (기본 브리지 docker0)    → 도달
finch-jenkins (finch-infra_default)   → i/o timeout
```

ufw 가 `docker0` 과 `cni0` 만 허용하는데(Testcontainers 때문에 넣은 규칙) Jenkins 는 compose 네트워크에 있다. 노드 IP, compose 게이트웨이, docker0 게이트웨이, 클러스터 서비스 IP 가 전부 막힌다.

기본 브리지에 컨테이너를 띄우면 그 규칙에 걸려 통과한다. Jenkins 가 이미 `docker.sock` 으로 이미지를 빌드하는 것과 같은 경로라 **방화벽을 새로 열지 않아도 된다.** `--volumes-from` 이라 워크스페이스가 같은 경로로 보이고, `-w "$PWD"` 가 없으면 helm 이 상대 경로를 저장소 이름으로 오해한다.

kubeconfig 는 읽기 전용 마운트다. k3s 가 만든 파일의 `server` 가 `127.0.0.1` 이라 컨테이너에서는 못 쓰므로, 파일을 고치는 대신 `--kube-apiserver` 로 주소만 바꾼다. API 서버 인증서 SAN 에 노드 IP 가 있어 TLS 검증은 그대로 통과한다. 주소는 `infra/.env` 의 `KUBE_APISERVER` 다.

## 커트오버 (80/443 인계)

트래픽을 compose 에서 k3s 로 넘기는 단계다. **전환 작업 전체에서 유일하게 사용자에게 보이고, 유일하게 되돌리기 어렵다.**

제약은 단순하다. **80과 443은 서버당 하나씩이다.** 지금은 compose nginx 가 잡고 있고 ingress-nginx 는 8081/8443 에 있다. 둘 다 가질 수 없다.

```
finch-nginx                 0.0.0.0:80->80, 0.0.0.0:443->443    docker-proxy
ingress-nginx-controller   hostPort 8081 / 8443                 DaemonSet
```

`hostPort` 는 리스닝 소켓이 아니라 **CNI portmap 이 거는 iptables DNAT** 이다. 그래서 `ss -lntp` 에 8081 이 안 보인다. 없는 것이 아니라 방식이 다르다.

### 1. 대조 — 넘기기 전에 두 경로가 같은 답을 하는지 본다

```sh
sudo infra/scripts/cutover-diff.sh
```

같은 요청을 기존(443)과 k3s(8443)에 보내 32건을 맞댄다. **읽기만 하고 주문, 충전은 부르지 않는다.** AI 엔드포인트는 인증에서 막혀 GMS 크레딧이 나가지 않는다.

**이 대조가 실제로 둘을 잡았다** (FINCH-227). 넘긴 뒤였으면 사용자가 먼저 겪었을 것들이다.

| 잡힌 것 | 원인 |
|---|---|
| `/` 의 `Cache-Control: no-cache` 가 k3s 에만 없었다 | **nginx 설정이 두 벌이다.** MR !200 에서 compose 쪽만 고쳤다 |
| HSTS 가 30일이 아니라 1년 + `includeSubDomains` | ingress-nginx 기본값이 그렇다 |

**설정이 두 벌이라는 것이 이 단계의 핵심 위험이다.**

```
compose   infra/nginx/nginx.conf
k8s       infra/k8s/charts/finch/files/frontend-nginx.conf   (정적 서빙, SPA 폴백)
          ingress-nginx 컨트롤러 ConfigMap                    (TLS 종단, HSTS)
```

한쪽만 고치면 **커트오버 순간에 그 수정이 사라진다.** 응답 헤더를 건드릴 때는 두 곳을 함께 본다.

**HSTS 는 Ingress 애노테이션으로 못 정한다.** 컨트롤러 ConfigMap 옵션이다 — 애노테이션을 넣어 배포해 보고 값이 안 바뀌는 것을 확인했다. `infra/k8s/install-ingress-nginx.sh` 의 `controller.config.hsts-max-age` 에 있다.

### 2. 커트오버

```sh
# 기존 nginx 를 내린다. 이 순간부터 다운타임이 시작된다
docker compose -f infra/docker-compose.yml stop nginx

# ingress-nginx 를 80/443 으로 옮긴다
sudo HTTP_PORT=80 HTTPS_PORT=443 infra/k8s/install-ingress-nginx.sh
```

설치 스크립트가 `helm upgrade --install` 이라 **포트만 바꿔 다시 부르는 것이 커트오버 절차 그 자체다.**

### 3. 관찰

최소 하루. 로그와 지표를 본다.

```sh
sudo k3s kubectl -n finch get pod
sudo k3s kubectl -n ingress-nginx logs -l app.kubernetes.io/name=ingress-nginx --tail=50
```

### 4. 보존 — compose 를 지우지 않는다

**정지 상태로 남긴다.** 시연이 걸린 서비스라 돌아갈 곳을 없애면 안 된다. 디스크는 286GB 남아 있어 아낄 이유도 없다.

## 커트오버 롤백

**되돌리는 방법을 아는 것과 적어 두는 것은 다르다.** 사고는 대개 당황한 상태에서 처리하므로 이 절만 보고 따라 할 수 있어야 한다.

```sh
# 1. ingress-nginx 를 80/443 에서 비킨다  (약 40초)
sudo HTTP_PORT=8081 HTTPS_PORT=8443 infra/k8s/install-ingress-nginx.sh

# 2. compose nginx 를 다시 올린다  (약 5초)
docker compose -f infra/docker-compose.yml start nginx

# 3. 확인
curl -sI https://finchapp.org/ | head -1
docker ps --filter name=finch-nginx --format '{{.Status}}'
```

**순서가 중요하다.** 1번을 건너뛰고 2번을 하면 **80/443 을 ingress 가 아직 잡고 있어 compose nginx 가 기동에 실패한다.** 포트를 먼저 비우고 나서 올린다.

**데이터는 되돌릴 것이 없다.** compose 와 k3s 가 **같은 호스트 볼륨의 PostgreSQL 을 쓰지 않는다** — 각자의 DB 를 갖고 있다. 커트오버 후 k3s 에서 생긴 주문은 compose DB 에 없다. 그래서 **롤백은 "그 사이의 거래를 잃는다" 는 뜻이다.** 관찰 기간에 시연 계정으로만 쓰는 이유가 그것이다.

**되돌린 뒤에 할 일.** 무엇 때문에 되돌렸는지 적고, 대조 스크립트를 다시 돌려 그 항목이 잡히는지 본다. 잡히지 않으면 대조 목록에 그 항목을 추가한다.

## 구축 이력

- [x] `docker/backend.Dockerfile` — 배포에 쓰이고 있다
- [x] nginx `/api` 프리픽스 전달 — 프리픽스를 벗기지 않고 그대로 넘긴다 (`nginx.conf` 의 `location /api/`)
- [x] 루트 `.gitlab-ci.yml` 에 파트별 include (`.gitlab-ci.yml:25~29`, 네 파트 전부)
- [x] Jenkins job 생성: Pipeline from SCM + GitLab webhook + Credentials (FINCH-115)
- [x] HTTPS 적용: 443 종단, 80 → 443 리다이렉트, webroot 갱신 cron (2026-09-01, FINCH-114)
- [x] 관측 스택: Prometheus, Grafana, Loki, Alloy 와 기본 대시보드 (2026-09-01, FINCH-52, -116)
- [x] EC2 전환: `setup-server.sh` Ubuntu/ufw 대응, 접속 정보와 이전 절차 문서화 (2026-08-31)
- [x] k3s 커트오버: 80/443 을 Ingress 로 넘기고 Helm 으로 배포 (2026-09-11, FINCH-136)

### 아직 안 한 것

- [ ] **배치 실패 알림이 꺼져 있다.** `notify-lib.sh` 는 서버에 있는데
      `/etc/finch/notify-webhook`(600 root)이 없어 알림이 조용히 건너뛰어진다.
      파일 하나를 놓으면 산다 (`FINCH-216`)
- [ ] 부하 측정 2차와 컨테이너 자원 상한 실측 (`FINCH-58`, `-59`, `-62`)
- [ ] 시세 워커가 생기면 앱 차트에 Deployment 추가
