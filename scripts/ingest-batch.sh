#!/usr/bin/env bash
# AI 근거 데이터 정기 적재. cron 이 단계별로 실행한다.
# 수동 실행: sudo infra/scripts/ingest-batch.sh <단계>
#
# 단계: master | market | docs | news | briefing | all
#
# 실행 대상을 AI_EXEC 로 뽑아 둔 것은 커트오버 때문이다. 지금은 compose 컨테이너를
# docker exec 로 부르지만 k8s 로 넘어가면 kubectl -n finch exec deploy/ai -- 가 된다.
# 호출부마다 명령을 박아 두면 그때 스무 군데를 고쳐야 한다.
#
# 종목 목록을 문서가 아니라 DB 에서 만든다. 시드 30종은 ai/docs/seed-dataset.md 의
# 표에 있지만 그 파일은 서버로 배포되지 않고, 무엇보다 시연 계정이 30종 밖 종목을
# 사면 목록이 곧바로 낡는다. 2026-09-09 에 실제로 그 일이 나서 포트폴리오 진단이
# 통째로 409 였다 — _common_days() 가 교집합이라 보유 종목 하나만 시세가 비어도
# 거래일이 빈 튜플이 되고 원장을 못 읽은 것으로 처리된다.
# 그래서 이미 적재된 종목과 백엔드 보유·거래 종목의 합집합을 매번 다시 만든다.
#
# 잠금은 단계별이 아니라 전역이다. dart 와 news 가 같은 시각에 겹치면 GMS 임베딩
# 한도를 함께 깎고, 백필이 서로의 중간 상태를 보게 된다. 실패시키지 않고 기다린다.
set -euo pipefail

AI_EXEC=${AI_EXEC:-docker exec finch-ai}
AI_DB=${AI_DB:-finch-postgres-ai}
BACKEND_DB=${BACKEND_DB:-finch-postgres-backend}

PRICE_DAYS=${PRICE_DAYS:-7}
DART_DAYS=${DART_DAYS:-7}
NEWS_DAYS=${NEWS_DAYS:-2}

LOCK_FILE=${LOCK_FILE:-/var/lock/finch-ingest.lock}
LOCK_WAIT=${LOCK_WAIT:-1800}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

psql_in() {
    local container="$1" sql="$2" user db
    user=$(docker exec "$container" printenv POSTGRES_USER)
    db=$(docker exec "$container" printenv POSTGRES_DB)
    docker exec "$container" psql -U "$user" -d "$db" -tAc "$sql"
}

resolve_tickers() {
    local loaded held all
    loaded=$(psql_in "$AI_DB" "select distinct ticker from price_daily;" || true)
    held=$(psql_in "$BACKEND_DB" \
        "select stock_code from holding union select stock_code from trade;" || true)

    all=$(printf '%s\n%s\n' "$loaded" "$held" \
        | tr -d ' \r' | grep -E '^[0-9]{6}$' | sort -u | paste -sd, -)

    if [ -z "$all" ]; then
        log "✗ 대상 종목을 하나도 못 구했다. DB 접속이나 적재 상태를 확인할 것" >&2
        return 1
    fi
    printf '%s' "$all"
}

run_ai() {
    log "▶ $*"
    $AI_EXEC python -m "$@"
}

step_master() {
    run_ai ingest.instruments
}

step_market() {
    local t
    t=$(resolve_tickers)
    log "대상 종목 $(printf '%s' "$t" | tr ',' '\n' | grep -c .)종"
    run_ai ingest.prices --days "$PRICE_DAYS" --tickers "$t"
    run_ai ingest.krx marketcap
    run_ai ingest.krx index
}

step_docs() {
    local t
    t=$(resolve_tickers)
    run_ai app.rag.dart --tickers "$t" --days "$DART_DAYS"
    run_ai app.rag.search --backfill
}

step_news() {
    local t
    t=$(resolve_tickers)
    run_ai ingest.news --tickers "$t" --days "$NEWS_DAYS"
    run_ai app.rag.search --backfill
}

step_briefing() {
    run_ai ingest.briefings
}

main() {
    local step="${1:-}"
    case "$step" in
        master|market|docs|news|briefing) ;;
        all) ;;
        *)
            echo "사용법: $0 {master|market|docs|news|briefing|all}" >&2
            exit 2
            ;;
    esac

    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -w "$LOCK_WAIT" 9; then
        log "✗ ${LOCK_WAIT}초를 기다려도 잠금을 못 잡았다. 앞 단계가 멈춰 있는지 확인할 것" >&2
        exit 1
    fi

    log "=== 적재 시작: $step ==="
    if [ "$step" = all ]; then
        step_master
        step_market
        step_docs
        step_news
        step_briefing
    else
        "step_$step"
    fi
    log "=== 적재 완료: $step ==="
}

main "$@"
