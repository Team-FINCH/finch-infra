#!/usr/bin/env bash
# backup-db.sh 가 만든 덤프(.sql.gz)로 DB 2종을 복원한다. 서버 이전(NCP → EC2)·롤백용.
# 사용법: sudo infra/scripts/restore-db.sh <backend-덤프.sql.gz> <ai-덤프.sql.gz>
#   예:   sudo infra/scripts/restore-db.sh /tmp/backend-20260831-040000.sql.gz /tmp/ai-20260831-040000.sql.gz
# 주의: 대상 DB 를 DROP 후 다시 만든다 — 기존 데이터가 사라진다. 앱 컨테이너는 먼저 멈추는 것이 안전하다.
#       (docker compose stop backend ai → 복원 → docker compose start backend ai)
set -euo pipefail

BACKEND_DUMP="${1:?backend 덤프 파일 경로가 필요합니다}"
AI_DUMP="${2:?ai 덤프 파일 경로가 필요합니다}"
[ -f "$BACKEND_DUMP" ] || { echo "✗ 없음: $BACKEND_DUMP" >&2; exit 1; }
[ -f "$AI_DUMP" ]      || { echo "✗ 없음: $AI_DUMP" >&2; exit 1; }

# infra/.env 에서 DB 계정을 읽는다
ENV_FILE="$(dirname "$0")/../.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
: "${BACKEND_DB_USER:?infra/.env 에 BACKEND_DB_USER 가 없습니다}"
: "${BACKEND_DB_NAME:?infra/.env 에 BACKEND_DB_NAME 가 없습니다}"
: "${AI_DB_USER:?infra/.env 에 AI_DB_USER 가 없습니다}"
: "${AI_DB_NAME:?infra/.env 에 AI_DB_NAME 가 없습니다}"

# 인자: 컨테이너, 사용자, DB, 덤프
restore() {
  local container="$1" user="$2" db="$3" dump="$4"
  echo "▶ $db 복원 ($container) ← $dump"
  # 접속 중인 세션이 있으면 DROP 이 실패하므로 끊고 진행. 접속 DB 는 postgres 로.
  docker exec "$container" psql -U "$user" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();" \
    -c "DROP DATABASE IF EXISTS \"$db\";" \
    -c "CREATE DATABASE \"$db\" OWNER \"$user\";"
  gunzip -c "$dump" | docker exec -i "$container" psql -U "$user" -d "$db" -v ON_ERROR_STOP=1 -q
}

restore finch-postgres-backend "$BACKEND_DB_USER" "$BACKEND_DB_NAME" "$BACKEND_DUMP"
restore finch-postgres-ai      "$AI_DB_USER"      "$AI_DB_NAME"      "$AI_DUMP"

echo "✓ 복원 완료. 앱을 재기동할 것: docker compose start backend ai"
