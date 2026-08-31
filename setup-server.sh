#!/usr/bin/env bash
# 서버 초기 세팅 — EC2(Ubuntu) 기준. 이전에 쓰던 NCP VM(Rocky 8.8)도 그대로 지원한다.
# 사용법: sudo ./setup-server.sh [저장소_경로]
#   예:   sudo ./setup-server.sh /srv/FINCH
# 여러 번 실행해도 안전하도록(멱등) 작성했다.
#
# EC2 주의사항 (서버 공지 요약):
#   - 지급 상태: ufw 활성(enable) + 22 만 허용. 웹 콘솔 없음 → 방화벽 실수로 SSH 가 막히면 초기화밖에 없다.
#   - ufw 는 반드시 enable 상태로 유지한다. 이 스크립트는 22·80·443 만 열고 enable 한다.
#   - 22 를 먼저 허용한 뒤 enable 해야 SSH 세션이 끊기지 않는다 (순서 바꾸지 말 것).
#   - 실행 전 ssh 터미널을 2~3개 열어 두고, 끝나면 새 터미널로 재접속이 되는지 확인한다.
#   - 8080·5000 등 솔루션 기본 포트는 외부에 열지 않는다 (compose 가 host 에 publish 하는 포트는 80 뿐).
#   - /home·시스템 디렉터리 퍼미션, 공개키(~/.ssh/authorized_keys)는 건드리지 않는다.
set -euo pipefail

APP_DIR="${1:-/srv/FINCH}"

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ root 권한이 필요합니다: sudo $0" >&2
  exit 1
fi

# ── OS 판별 ──────────────────────────────────────────────
# ubuntu → apt + ufw (EC2), rocky/rhel 계열 → dnf + firewalld (구 NCP VM)
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian)      PKG=apt ;;
  rocky|rhel|centos|almalinux) PKG=dnf ;;
  *) echo "✗ 지원하지 않는 OS: ${ID:-unknown} (ubuntu 또는 rocky 계열만 지원)" >&2; exit 1 ;;
esac
echo "▶ OS: ${PRETTY_NAME:-$ID} (패키지 관리자: $PKG)"

echo "▶ 타임존 Asia/Seoul 설정 (cron·로그 시각 기준)"
timedatectl set-timezone Asia/Seoul

# ── swap 4GB ─────────────────────────────────────────────
# swap 0 상태에서 RAM이 차면 OOM Killer가 프로세스를 강제 종료한다.
# 배포 순간(서비스 + Jenkins 빌드 + runner 테스트)의 보험.
if swapon --show | grep -q '/swapfile'; then
  echo "▶ swap: 이미 활성화됨 — 건너뜀"
else
  echo "▶ swap 4GB 생성"
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ── Docker ───────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  echo "▶ docker: 이미 설치됨 — 건너뜀"
elif [ "$PKG" = apt ]; then
  echo "▶ docker 설치 (공식 apt 저장소)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "▶ docker 설치 (공식 dnf 저장소)"
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  # Rocky 는 $releasever 가 "8.8" 처럼 마이너 버전까지 풀려 404 가 난다 — 메이저 버전으로 고정
  sed -i "s/\$releasever/$(rpm -E %rhel)/g" /etc/yum.repos.d/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

# sudo 없이 docker를 쓰도록 실행한 사용자를 docker 그룹에 추가
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  usermod -aG docker "$SUDO_USER"
  echo "▶ $SUDO_USER 를 docker 그룹에 추가 (재로그인 후 적용)"
fi

echo "▶ git·cron 설치"
if [ "$PKG" = apt ]; then
  apt-get install -y git cron
  systemctl enable --now cron
else
  dnf -y install git cronie
  systemctl enable --now crond
fi

# ── 로컬 방화벽 ──────────────────────────────────────────
# 클라우드 보안그룹(콘솔에서 설정)과 별개로 VM 내부 방화벽도 통과해야 한다.
# 개방 포트는 22·80·443 뿐이다 (Jenkins 는 nginx 80 의 /jenkins 경로 경유).
# DB 포트(5432·6379)는 compose 가 호스트에 publish 하지 않으므로 여기서도 열지 않는다.
#
# ※ Docker 는 iptables 를 직접 조작해 `ports:` 로 publish 한 포트는 ufw 규칙을 우회한다.
#   그래서 "ufw 로 막았으니 안전" 이 아니라 "compose 에서 publish 하지 않는 것" 이 DB 보호의 근거다.
if [ "$PKG" = apt ]; then
  echo "▶ ufw: 22(SSH)·80(Nginx)·443(HTTPS) 허용 후 enable (규정 — 항상 enable 유지)"
  apt-get install -y ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp    # SSH — enable 전에 반드시 먼저 허용 (세션 유지)
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable  # --force: 대화형 확인 생략 (멱등 — 이미 enable 이면 그대로)
  ufw status verbose
elif systemctl is-active --quiet firewalld; then
  echo "▶ firewalld: 80·443 개방"
  firewall-cmd --permanent --add-port=80/tcp
  firewall-cmd --permanent --add-port=443/tcp
  firewall-cmd --reload
else
  echo "▶ firewalld 비활성 — 건너뜀 (보안그룹만 적용됨)"
fi

# ── DB 백업 cron ─────────────────────────────────────────
echo "▶ 매일 04:00 DB 백업 cron 등록"
cat > /etc/cron.d/finch-db-backup <<CRON
0 4 * * * root ${APP_DIR}/infra/scripts/backup-db.sh >> /var/log/finch-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/finch-db-backup

# ── jenkins_home 백업 cron ───────────────────────────────
# job·credentials·플러그인 설정은 이 볼륨에만 있다. DB 덤프만으로는 서버 사고 시
# Jenkins 를 손으로 전부 재설정해야 한다 (공지: 복구 불가, 초기화만 가능).
echo "▶ 매일 04:10 jenkins_home 백업 cron 등록"
cat > /etc/cron.d/finch-jenkins-backup <<CRON
10 4 * * * root ${APP_DIR}/infra/scripts/backup-jenkins.sh >> /var/log/finch-backup.log 2>&1
CRON
chmod 644 /etc/cron.d/finch-jenkins-backup

# ── dangling 이미지 정리 cron ────────────────────────────
# 매 배포가 같은 태그(finch/*:latest)를 재빌드하므로 이전 레이어가 dangling 으로 쌓인다.
# prune -f 는 dangling(태그 없는 이미지)만 지운다 — -a 는 미사용 이미지 전체를 지워
# 롤백용 이미지까지 날리므로 쓰지 않는다.
echo "▶ 매일 04:30 dangling 이미지 정리 cron 등록"
cat > /etc/cron.d/finch-image-prune <<CRON
30 4 * * * root docker image prune -f >> /var/log/finch-prune.log 2>&1
CRON
chmod 644 /etc/cron.d/finch-image-prune

echo
echo "✓ 서버 세팅 완료. 다음 단계:"
echo "  1. 보안그룹(EC2 콘솔)에서 22, 80, 443 만 개방 (5432·6379 등 DB 포트 금지)"
echo "  2. git clone → ${APP_DIR}"
echo "  3. infra/.env.example → infra/.env 작성 (DB 비밀번호 등)"
echo "     ai/.env.example    → infra/ai.env 작성 (AI 외부 API 키)"
echo "  4. cd ${APP_DIR}/infra && docker compose up -d --build"
echo "  5. docker compose -f docker-compose.infra.yml up -d --build  (Jenkins·runner)"
echo "  ※ docker 그룹 적용을 위해 한 번 재로그인할 것"
echo "  ※ ufw 는 절대 disable 하지 말 것 (sudo ufw status 로 확인)"
