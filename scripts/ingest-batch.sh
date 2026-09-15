#!/usr/bin/env bash
# AI 근거 데이터 정기 적재. cron 이 단계별로 실행한다.
# 수동 실행: sudo infra/scripts/ingest-batch.sh <단계>
#
# 단계: master | market | docs | news | briefing | all
#
# 운영 런타임은 k3s를 우선 자동 감지하고, 없으면 compose로 돌아간다.
# OPS_RUNTIME=k3s|compose로 명시할 수 있으며 AI_EXEC·AI_DB·BACKEND_DB도 재정의 가능하다.
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

OPS_RUNTIME=${OPS_RUNTIME:-auto}
K8S_NAMESPACE=${K8S_NAMESPACE:-finch}

if [ "$OPS_RUNTIME" = auto ]; then
    if command -v k3s >/dev/null 2>&1 \
        && k3s kubectl -n "$K8S_NAMESPACE" get deploy/ai >/dev/null 2>&1; then
        OPS_RUNTIME=k3s
    else
        OPS_RUNTIME=compose
    fi
fi

case "$OPS_RUNTIME" in
    k3s)
        AI_EXEC=${AI_EXEC:-k3s kubectl -n $K8S_NAMESPACE exec deploy/ai --}
        AI_DB=${AI_DB:-postgres-ai-0}
        BACKEND_DB=${BACKEND_DB:-postgres-backend-0}
        ;;
    compose)
        AI_EXEC=${AI_EXEC:-docker exec finch-ai}
        AI_DB=${AI_DB:-finch-postgres-ai}
        BACKEND_DB=${BACKEND_DB:-finch-postgres-backend}
        ;;
    *)
        echo "✗ OPS_RUNTIME은 auto, k3s, compose 중 하나여야 한다: $OPS_RUNTIME" >&2
        exit 2
        ;;
esac

PRICE_DAYS=${PRICE_DAYS:-7}
# 이력이 아예 없는 종목에 쓰는 폭. PRICE_DAYS 는 이미 적재된 종목을 이어받는 값이라
# 새 종목에 그것을 쓰면 며칠치만 들어오고, _common_days() 가 교집합이라 그 한 종목이
# 포트폴리오 전체를 며칠로 잘라 버린다 (FINCH-214). 400캘린더일이 268거래일이고
# 위험 지표 요건인 60거래일의 네 배 이상이다.
BACKFILL_DAYS=${BACKFILL_DAYS:-400}
DART_DAYS=${DART_DAYS:-7}
NEWS_DAYS=${NEWS_DAYS:-2}

LOCK_FILE=${LOCK_FILE:-/var/lock/finch-ingest.lock}
LOCK_WAIT=${LOCK_WAIT:-1800}

. "$(dirname "$0")/notify-lib.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

psql_in() {
    local container="$1" sql="$2" user db
    if [ "$OPS_RUNTIME" = k3s ]; then
        user=$(k3s kubectl -n "$K8S_NAMESPACE" exec "$container" -- printenv POSTGRES_USER)
        db=$(k3s kubectl -n "$K8S_NAMESPACE" exec "$container" -- printenv POSTGRES_DB)
        k3s kubectl -n "$K8S_NAMESPACE" exec "$container" -- \
            psql -U "$user" -d "$db" -tAc "$sql"
    else
        user=$(docker exec "$container" printenv POSTGRES_USER)
        db=$(docker exec "$container" printenv POSTGRES_DB)
        docker exec "$container" psql -U "$user" -d "$db" -tAc "$sql"
    fi
}

_codes() {
    printf '%s\n' "$1" | tr -d ' \r' | grep -E '^[0-9]{6}$' | sort -u
}

_loaded_codes() {
    _codes "$(psql_in "$AI_DB" "select distinct ticker from price_daily;" || true)"
}

_held_codes() {
    _codes "$(psql_in "$BACKEND_DB" \
        "select stock_code from holding union select stock_code from trade;" || true)"
}

resolve_tickers() {
    local all
    all=$(printf '%s\n%s\n' "$(_loaded_codes)" "$(_held_codes)" \
        | grep -E '^[0-9]{6}$' | sort -u | paste -sd, -)

    if [ -z "$all" ]; then
        log "✗ 대상 종목을 하나도 못 구했다. DB 접속이나 적재 상태를 확인할 것" >&2
        return 1
    fi
    printf '%s' "$all"
}

# 백엔드가 들고 있는데 시세가 한 행도 없는 종목. 시연 중 새로 산 것이 여기 잡힌다.
new_tickers() {
    comm -23 <(_held_codes) <(_loaded_codes) | paste -sd, -
}

run_ai() {
    log "▶ $*"
    $AI_EXEC python -m "$@"
}

step_master() {
    run_ai ingest.instruments
}

step_market() {
    local t n
    t=$(resolve_tickers)

    # 새 종목을 먼저 전체 이력으로 받는다. 뒤의 증분 호출은 종목별 마지막 적재일
    # 다음날부터만 받으므로 여기서 받은 것을 다시 긁지 않는다.
    n=$(new_tickers)
    if [ -n "$n" ]; then
        log "신규 종목 $(printf '%s' "$n" | tr ',' '\n' | grep -c .)종 — 전체 이력을 받는다"
        run_ai ingest.prices --days "$BACKFILL_DAYS" --tickers "$n"
    fi

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

    # 실패하면 Mattermost 로 알린다 (FINCH-216). 사용법 검사 뒤에 거는 이유는
    # 인자를 잘못 준 수동 실행까지 경보로 올리지 않기 위해서다 — 크론의 인자는 고정이다.
    #
    # 이름에 단계를 넣는다. 같은 실패가 이어질 때 한 번만 알리는 장치가 이름 단위로
    # 도는데, 이름을 하나로 두면 market 이 실패한 동안 docs 실패가 묻힌다.
    notify_on_failure "적재 배치 (${step})"         "sudo /srv/FINCH/infra/scripts/ingest-batch.sh ${step}, 로그는 /var/log/finch-ingest.log"

    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -w "$LOCK_WAIT" 9; then
        log "✗ ${LOCK_WAIT}초를 기다려도 잠금을 못 잡았다. 앞 단계가 멈춰 있는지 확인할 것" >&2
        exit 1
    fi

    log "=== 적재 시작: $step ==="
    log "런타임 $OPS_RUNTIME"
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
