# infra — 배포 인프라

인프라 결정의 배경과 근거는 팀 결정서(FINCH 인프라 결정서)를 참고한다.
모든 서버 설정은 이 디렉터리에 코드로 남긴다 — 서버에서 손으로 만진 설정은 EC2 이사 때 잃어버린다.

## 구성

| 파일 | 역할 |
|---|---|
| `setup-server.sh` | 서버 초기 세팅: swap 4GB, docker, 방화벽, 백업 cron |
| `docker-compose.yml` | 앱 스택: nginx(+frontend) · backend · ai · PostgreSQL×2 · Redis |
| `docker-compose.infra.yml` | CI/CD 스택: Jenkins · gitlab-runner (앱과 수명 주기 분리) |
| `nginx/nginx.conf` | 단일 진입점 라우팅: `/`→정적파일, `/api`→backend, `/ai`→ai |
| `docker/*.Dockerfile` | 파트별 이미지 정의 (파트 디렉터리 소유권을 건드리지 않도록 여기 모음) |
| `scripts/backup-db.sh` | DB 2종 pg_dump 백업 (cron 이 매일 04:00 실행) |
| `.env.example` | 서버 `.env` 템플릿 — 실제 값은 Jenkins Credentials 에 보관 |

## 서버 첫 구축 순서

```bash
# 0. 방화벽(ACG/보안그룹): 22, 80, 3000(Jenkins) 만 개방. DB 포트(5432·6379)는 절대 열지 않는다.
#    (NCP ACG 는 22·80·443·3000 고정이라 Jenkins 를 3000 으로 노출한다)

# 1. 서버 세팅 (재로그인 필요 — docker 그룹 적용)
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

## 남은 작업 (초안 상태)

- [ ] `docker/backend.Dockerfile` — backend 파트가 `build.gradle`·`gradlew` 커밋 후 동작. Java 버전 확인
- [ ] nginx `/api` 프리픽스 전달 방식 — backend 컨트롤러 매핑이 정해지면 확정
- [ ] 루트 `.gitlab-ci.yml` 에 `include: - local: ai/.gitlab-ci.yml` 추가 (팀 결정, ADR-0002)
- [ ] Jenkins job 생성: Pipeline from SCM + GitLab webhook 연결 + Credentials 2건 등록
- [ ] EC2 전환 시: 이 README 순서 그대로 재실행 + webhook URL 변경 + 도메인/HTTPS(certbot)
