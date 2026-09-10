#!/usr/bin/env bash
# jenkins_home 볼륨 백업. cron 이 매일 04:10 실행한다 (setup-server.sh 가 등록).
# job·credentials·플러그인 설정이 이 볼륨에만 존재한다 — DB 덤프만으로는 서버 사고 시
# Jenkins 를 전부 손으로 재설정해야 하는 반쪽 복구가 된다 (공지: 복구 불가, 초기화만).
# 수동 실행: sudo infra/scripts/backup-jenkins.sh
set -euo pipefail

# 실패하면 Mattermost 로 알린다 (FINCH-216). 이 두 줄이 없으면 실패가
# 로그에만 남는다.
. "$(dirname "$0")/notify-lib.sh"
notify_on_failure "Jenkins 백업" "sudo /srv/FINCH/infra/scripts/backup-jenkins.sh, 로그는 /var/log/finch-backup.log"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/finch}"
KEEP_DAYS="${KEEP_DAYS:-7}"
STAMP="$(date +%Y%m%d-%H%M%S)"
# compose 프로젝트명(finch-infra) + 볼륨명(jenkins_home)
VOLUME="finch-infra_jenkins_home"

mkdir -p "$BACKUP_DIR"

# workspace(체크아웃 사본)·캐시·war 는 재생성 가능하므로 제외한다 — 복구에 필요한 것만 백업
#
# plugins 도 제외한다 (FINCH-137). 백업의 대부분이 플러그인이었는데, 이제
# jenkins-plugin-cli 가 이미지에 94개를 버전까지 박아 넣으므로 볼륨이 유일한 사본이
# 아니다. 빈 볼륨에 새 이미지로 기동해 94개가 그대로 올라오는 것을 확인한 뒤에 뺐다 —
# 순서를 뒤집으면 복원 경로가 끊긴 상태로 남는다.
#
# 되돌려야 하면 이 --exclude 한 줄만 지운다.
docker run --rm -v "$VOLUME":/src:ro -v "$BACKUP_DIR":/dest alpine \
  tar czf "/dest/jenkins-home-$STAMP.tar.gz" -C /src \
  --exclude='./workspace' --exclude='./caches' --exclude='./war' \
  --exclude='./plugins' .

find "$BACKUP_DIR" -name 'jenkins-home-*.tar.gz' -mtime +"$KEEP_DAYS" -delete

echo "jenkins_home 백업 완료: $BACKUP_DIR/jenkins-home-$STAMP.tar.gz"
ls -lh "$BACKUP_DIR" | tail -3
