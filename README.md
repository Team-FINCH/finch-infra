# infra — 배포 인프라

인프라 결정의 배경과 근거는 팀 결정서(FINCH 인프라 결정서)를 참고한다.
모든 서버 설정은 이 디렉터리에 코드로 남긴다 — 서버에서 손으로 만진 설정은 서버 이사 때 잃어버린다.

## 서버 (EC2)

| 항목 | 값 |
|---|---|
| 서버명 | finch |
| 도메인 | `finchapp.org` |
| OS / 계정 | Ubuntu / `ubuntu` |
| 접속 | `ssh -i finchT.pem ubuntu@finchapp.org` |
| 서비스 URL | `https://finchapp.org/` (http 접근은 443 으로 301) |
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

## 구성

| 파일 | 역할 |
|---|---|
| `setup-server.sh` | 서버 초기 세팅: swap 4GB, docker, 방화벽(ufw), 백업 cron |
| `docker-compose.yml` | 앱 스택: nginx(+frontend) · backend · ai · PostgreSQL×2 · Redis |
| `docker-compose.infra.yml` | CI/CD 스택: Jenkins · gitlab-runner (앱과 수명 주기 분리) |
| `nginx/nginx.conf` | 단일 진입점 라우팅: `/`→정적파일, `/api`→backend, `/jenkins`→Jenkins |
| `docker/*.Dockerfile` | 파트별 이미지 정의 (파트 디렉터리 소유권을 건드리지 않도록 여기 모음) |
| `scripts/backup-db.sh` | DB 2종 pg_dump 백업 (cron 이 매일 04:00 실행) |
| `scripts/restore-db.sh` | 백업 파일로 DB 복원 (서버 이전·롤백용) |
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
  --docker-volumes /var/run/docker.sock:/var/run/docker.sock
```

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

master 머지 webhook → Jenkins 가 자기 워크스페이스에서:

1. 직전 성공 빌드와 `git diff` 로 변경 파트 감지 (backend / ai / nginx)
2. Credentials(`finch-env`, `finch-ai-env`)를 `infra/.env`·`infra/ai.env` 로 주입
3. `docker compose build <변경 서비스>` → `up -d <변경 서비스>` (수 초 다운타임)
4. 종료 시 워크스페이스의 비밀값 파일 삭제

compose 프로젝트 이름을 `finch` 로 고정했으므로, 수동 기동(위 3번)과 Jenkins 배포가
서로 다른 디렉터리에서 실행돼도 같은 컨테이너·볼륨을 관리한다.

Jenkins job 설정(최초 1회)과 Credentials 목록은 `Jenkinsfile` 상단 주석 참고.
수동 전체 배포가 필요하면 job 의 `FORCE_ALL` 파라미터를 켜고 실행한다.

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
| 07:00 / 07:30 / 16:30 / 18:40 / 6시간마다 | `finch-ingest` | AI 근거 데이터 적재 (FINCH-179) |

적재는 `ingest-batch.sh <단계>` 이고 단계는 `master`, `market`, `docs`, `news`, `briefing`, `all` 이다. 전역 잠금(`flock`)이 있어 시각이 겹쳐도 뒤엣것이 기다린다.

**대상 종목을 문서가 아니라 DB 에서 만든다** — 이미 적재된 종목과 백엔드 보유·거래 종목의 합집합이다. 시드 목록을 쓰면 시연 계정이 그 밖의 종목을 사는 순간 낡고, 실제로 그 일이 나서 포트폴리오 진단이 통째로 409 였다.

로그는 `/var/log/finch-*.log` 이고 `/etc/logrotate.d/finch` 이 주 1회 4세대로 돌린다. **`su root syslog` 가 있어야 한다** — `/var/log` 가 `root:syslog 775` 라 그 지시자가 없으면 logrotate 가 대상 전부를 건너뛴다. 설정 파일은 놓여 있는데 아무것도 돌지 않는 상태가 된다.

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

## 남은 작업 (초안 상태)

- [ ] `docker/backend.Dockerfile` — backend 파트가 `build.gradle`·`gradlew` 커밋 후 동작. Java 버전 확인
- [ ] nginx `/api` 프리픽스 전달 방식 — backend 컨트롤러 매핑이 정해지면 확정
- [ ] 루트 `.gitlab-ci.yml` 에 `include: - local: ai/.gitlab-ci.yml` 추가 (팀 결정, ADR-0002)
- [ ] Jenkins job 생성: Pipeline from SCM + GitLab webhook 연결 + Credentials 2건 등록 (FINCH-115)
- [x] HTTPS 적용: 443 종단, 80 → 443 리다이렉트, webroot 갱신 cron (2026-09-01, FINCH-114)
- [x] 관측 스택: Prometheus, Grafana, Loki, Alloy 와 기본 대시보드 (2026-09-01, FINCH-52, -116)
- [x] EC2 전환: `setup-server.sh` Ubuntu/ufw 대응, 접속 정보·이전 절차 문서화 (2026-08-31)
