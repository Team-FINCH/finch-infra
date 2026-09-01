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

# [EC2] 4. CI/CD 스택 기동 후 Jenkins 재설정 (jenkins_home 볼륨은 새로 만드는 편이 깔끔하다)
#   - Credentials 2건 재등록: finch-env, finch-ai-env (Secret file)
#   - job: Pipeline from SCM, branch master
#   - GitLab webhook URL 변경: http://finchapp.org/jenkins/project/<job이름>
```

이전 완료 후 GitLab webhook 이 새 서버로만 가는지 확인하고 NCP 쪽 Jenkins 는 내려둔다
(두 서버가 동시에 배포를 받으면 안 된다).

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
docker run --rm   -v $PWD/infra/nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro   -v /etc/letsencrypt:/etc/letsencrypt:ro   nginx:1.27-alpine nginx -t
```

## 남은 작업 (초안 상태)

- [ ] `docker/backend.Dockerfile` — backend 파트가 `build.gradle`·`gradlew` 커밋 후 동작. Java 버전 확인
- [ ] nginx `/api` 프리픽스 전달 방식 — backend 컨트롤러 매핑이 정해지면 확정
- [ ] 루트 `.gitlab-ci.yml` 에 `include: - local: ai/.gitlab-ci.yml` 추가 (팀 결정, ADR-0002)
- [ ] Jenkins job 생성: Pipeline from SCM + GitLab webhook 연결 + Credentials 2건 등록
- [x] HTTPS 적용: 443 종단, 80 → 443 리다이렉트, webroot 갱신 cron (2026-09-01, FINCH-114)
- [x] EC2 전환: `setup-server.sh` Ubuntu/ufw 대응, 접속 정보·이전 절차 문서화 (2026-08-31)
