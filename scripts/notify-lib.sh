#!/usr/bin/env bash
# 크론으로 도는 스크립트가 실패했을 때 Mattermost 로 알린다 (FINCH-216).
#
# 왜 필요한가
#   /etc/cron.d 의 8줄 전부가 `>> /var/log/... 2>&1` 로만 끝난다. 실패하면 로그에만
#   남고 아무도 보지 않는다. 백업이 일주일 내내 실패해도 복원이 필요한 날에야 알고,
#   인증서 갱신 실패는 만료되는 날에 사이트가 죽어서 알게 된다.
#
# 쓰는 법 — 스크립트 상단에 두 줄
#   . "$(dirname "$0")/notify-lib.sh"
#   notify_on_failure "DB 백업" "sudo infra/scripts/backup-db.sh, 로그는 /var/log/finch-backup.log"
#
# 형식은 FINCH-187 의 Grafana 템플릿(finch_notification)과 같은 다섯 줄이다.
# 채널에 두 가지 모양이 섞이면 읽는 사람이 매번 형식을 다시 파악해야 한다.

NOTIFY_WEBHOOK_FILE="${NOTIFY_WEBHOOK_FILE:-/etc/finch/notify-webhook}"
NOTIFY_STATE_DIR="${NOTIFY_STATE_DIR:-/var/lib/finch/notify-state}"
NOTIFY_USERNAME="${NOTIFY_USERNAME:-Finch 배치}"
NOTIFY_ICON="${NOTIFY_ICON:-:gear:}"

_notify_json_escape() {
    # JSON 문자열 안에서 깨지는 것은 역슬래시, 따옴표, 제어문자다. 줄바꿈은 \n 으로
    # 바꿔야 하는데 sed 로는 다루기 번거로워 여기서만 python 을 쓴다.
    # python3 이 없는 환경은 없다 — ingest-batch.sh 도 psql 컨테이너를 쓰지만
    # 이 스크립트들은 모두 python3 가 있는 호스트에서만 돈다.
    python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read())[1:-1])'
}

_notify_send() {
    local color="$1" title="$2" body="$3"
    local url payload rc

    if [ ! -r "$NOTIFY_WEBHOOK_FILE" ]; then
        echo "알림 건너뜀: $NOTIFY_WEBHOOK_FILE 을 읽을 수 없다"
        return 0
    fi
    url="$(tr -d ' \t\r\n' < "$NOTIFY_WEBHOOK_FILE")"
    if [ -z "$url" ]; then
        echo "알림 건너뜀: 웹훅 파일이 비어 있다"
        return 0
    fi

    # Mattermost 의 Incoming Webhook 은 Slack 호환 페이로드를 받는다. attachments 로
    # 보내면 좌측 색 띠와 제목이 붙고, text 만 보내면 평문 한 덩어리가 된다.
    payload=$(printf '{"username":"%s","icon_emoji":"%s","attachments":[{"color":"%s","title":"%s","fallback":"%s","text":"%s"}]}' \
        "$(printf '%s' "$NOTIFY_USERNAME" | _notify_json_escape)" \
        "$NOTIFY_ICON" \
        "$color" \
        "$(printf '%s' "$title" | _notify_json_escape)" \
        "$(printf '%s' "$title" | _notify_json_escape)" \
        "$(printf '%s' "$body" | _notify_json_escape)")

    # 알림 실패가 배치 판정을 바꾸면 안 된다. curl 의 종료 코드를 삼키고 로그만 남긴다.
    rc=0
    printf '%s' "$payload" | curl -fsS -m 10 -X POST \
        -H 'Content-Type: application/json' --data @- "$url" -o /dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "알림 전송 실패 (curl exit $rc)"
    fi
    return 0
}

_notify_state_file() {
    # 이름이 한글이라 문자를 그대로 쓸 수 없다. tr 로 안전한 문자만 남기면
    # 한글이 전부 밑줄이 되어 **이름이 다른 작업끼리 같은 파일을 쓴다** (실측).
    # 해시를 붙여 구분하고, 앞의 밑줄 부분은 사람이 목록을 볼 때의 힌트로만 둔다.
    local slug hash
    slug="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-16)"
    hash="$(printf '%s' "$1" | sha256sum | cut -c1-12)"
    printf '%s/%s-%s' "$NOTIFY_STATE_DIR" "$slug" "$hash"
}

_notify_state_get() {
    local f
    f="$(_notify_state_file "$1")"
    [ -r "$f" ] && cat "$f" || echo ok
}

_notify_state_set() {
    local f
    f="$(_notify_state_file "$1")"
    mkdir -p "$NOTIFY_STATE_DIR" 2>/dev/null || return 0
    printf '%s' "$2" > "$f" 2>/dev/null || true
}

# 실패했을 때 보낸다. 같은 실패가 이어지는 동안에는 한 번만 보낸다 — 시세 배치는
# 하루 아홉 번 도는데 원인이 그대로면 아홉 통이 온다.
notify_failure() {
    local name="$1" symptom="$2" runbook="$3"
    local body
    body="$(printf '상태  발생\n증상  %s\n조치  %s\n대상  %s\n시각  %s' \
        "$symptom" "$runbook" "$name" "$(date '+%Y-%m-%d %H:%M:%S')")"
    if [ "$(_notify_state_get "$name")" = "failed" ]; then
        echo "알림 생략: $name 은 이미 실패 상태다"
        return 0
    fi
    _notify_state_set "$name" failed
    _notify_send '#D63232' "[경보] ${name} 실패" "$body"
}

# 실패한 뒤 처음 성공했을 때만 보낸다. 매번 성공을 보내면 도배다.
notify_recovery() {
    local name="$1"
    local body
    [ "$(_notify_state_get "$name")" = "failed" ] || return 0
    body="$(printf '상태  해소\n증상  이전 실패 이후 정상 완료됐다\n조치  없음\n대상  %s\n시각  %s' \
        "$name" "$(date '+%Y-%m-%d %H:%M:%S')")"
    _notify_state_set "$name" ok
    _notify_send '#36A64F' "[복구] ${name} 정상" "$body"
}

# ERR 트랩과 EXIT 트랩을 걸어 준다. 호출자는 이 한 줄만 쓴다.
#
# set -E 를 여기서 켠다
#   호출자들은 모두 `set -euo pipefail` 인데 -E(errtrace)가 없다. -E 가 없으면
#   **함수 안에서 실패해도 ERR 트랩이 안 걸린다.** ingest-batch.sh 는 전부 함수
#   안에서 도는 구조(main())라 트랩만 걸고 끝내면 알림이 한 번도 오지 않는다.
#   붙였다고 믿는데 안 오는 것이 지금보다 나쁘므로 라이브러리가 직접 켠다.
notify_on_failure() {
    _NOTIFY_NAME="$1"
    _NOTIFY_RUNBOOK="$2"
    set -E
    trap '_notify_trap_err $? "$LINENO" "$BASH_COMMAND"' ERR
    trap '_notify_trap_exit $?' EXIT
}

_notify_trap_err() {
    local rc="$1" line="$2" cmd="$3"
    # 트랩 안에서 다시 실패해도 재귀로 들어가지 않게 먼저 해제한다.
    trap - ERR
    _NOTIFY_FAILED=1
    notify_failure "$_NOTIFY_NAME" \
        "$(basename "$0") ${line}행에서 종료 코드 ${rc} (${cmd})" \
        "$_NOTIFY_RUNBOOK"
}

_notify_trap_exit() {
    local rc="$1"
    trap - EXIT
    # ERR 트랩이 못 잡는 실패도 있다 — set -e 가 안 걸리는 자리에서의 exit,
    # 혹은 명시적 `exit 1`. 종료 코드로 다시 판정한다.
    if [ "$rc" -ne 0 ]; then
        [ -n "${_NOTIFY_FAILED:-}" ] || notify_failure "$_NOTIFY_NAME" \
            "$(basename "$0") 가 종료 코드 ${rc} 로 끝났다" "$_NOTIFY_RUNBOOK"
    else
        notify_recovery "$_NOTIFY_NAME"
    fi
    exit "$rc"
}
