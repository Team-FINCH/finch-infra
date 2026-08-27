#!/usr/bin/env bash
# DB 2종(backend·ai) pg_dump 백업. cron 이 매일 04:00 에 실행한다 (setup-server.sh 가 등록).
# 수동 실행: sudo infra/scripts/backup-db.sh
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/finch}"
KEEP_DAYS="${KEEP_DAYS:-7}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# infra/.env 에서 DB 계정을 읽는다
ENV_FILE="$(dirname "$0")/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
: "${BACKEND_DB_USER:?infra/.env 에 BACKEND_DB_USER 가 없습니다}"
: "${AI_DB_USER:?infra/.env 에 AI_DB_USER 가 없습니다}"

mkdir -p "$BACKUP_DIR"

echo "▶ backend DB 백업"
docker exec finch-postgres-backend pg_dump -U "$BACKEND_DB_USER" "$BACKEND_DB_NAME" \
  | gzip > "$BACKUP_DIR/backend-$STAMP.sql.gz"

echo "▶ ai DB 백업"
docker exec finch-postgres-ai pg_dump -U "$AI_DB_USER" "$AI_DB_NAME" \
  | gzip > "$BACKUP_DIR/ai-$STAMP.sql.gz"

echo "▶ ${KEEP_DAYS}일 지난 백업 삭제"
find "$BACKUP_DIR" -name '*.sql.gz' -mtime +"$KEEP_DAYS" -delete

echo "✓ 완료: $BACKUP_DIR"
ls -lh "$BACKUP_DIR" | tail -5
