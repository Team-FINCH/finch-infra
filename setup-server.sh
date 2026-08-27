#!/usr/bin/env bash
# NCP VM (Rocky 8.8) 초기 세팅. EC2 이전 시에도 이 스크립트를 그대로 실행한다.
# 사용법: sudo ./setup-server.sh [저장소_경로]
#   예:   sudo ./setup-server.sh /srv/FINCH
# 여러 번 실행해도 안전하도록(멱등) 작성했다.
set -euo pipefail

APP_DIR="${1:-/srv/FINCH}"

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ root 권한이 필요합니다: sudo $0" >&2
  exit 1
fi

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
else
  echo "▶ docker 설치 (공식 저장소)"
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

# sudo 없이 docker를 쓰도록 실행한 사용자를 docker 그룹에 추가
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  usermod -aG docker "$SUDO_USER"
  echo "▶ $SUDO_USER 를 docker 그룹에 추가 (재로그인 후 적용)"
fi

echo "▶ git·cron 설치"
dnf -y install git cronie
systemctl enable --now crond

# ── 로컬 방화벽(firewalld) ────────────────────────────────
# NCP ACG(콘솔에서 설정)와 별개로 VM 내부 방화벽도 통과해야 한다.
if systemctl is-active --quiet firewalld; then
  echo "▶ firewalld: 80(Nginx)·8080(Jenkins) 개방"
  firewall-cmd --permanent --add-port=80/tcp
  firewall-cmd --permanent --add-port=8080/tcp
  firewall-cmd --reload
else
  echo "▶ firewalld 비활성 — 건너뜀 (ACG만 적용됨)"
fi

# ── DB 백업 cron ─────────────────────────────────────────
echo "▶ 매일 04:00 DB 백업 cron 등록"
cat > /etc/cron.d/finch-db-backup <<EOF
0 4 * * * root ${APP_DIR}/infra/scripts/backup-db.sh >> /var/log/finch-backup.log 2>&1
EOF
chmod 644 /etc/cron.d/finch-db-backup

echo
echo "✓ 서버 세팅 완료. 다음 단계:"
echo "  1. NCP 콘솔 ACG에서 22, 80, 8080 만 개방 (5432·6379 등 DB 포트 금지)"
echo "  2. git clone → ${APP_DIR}"
echo "  3. infra/.env.example → infra/.env 작성 (DB 비밀번호 등)"
echo "     ai/.env.example    → infra/ai.env 작성 (AI 외부 API 키)"
echo "  4. cd ${APP_DIR}/infra && docker compose up -d --build"
echo "  5. docker compose -f docker-compose.infra.yml up -d --build  (Jenkins·runner)"
echo "  ※ docker 그룹 적용을 위해 한 번 재로그인할 것"
