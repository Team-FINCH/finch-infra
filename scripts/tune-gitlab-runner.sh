#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${RUNNER_CONTAINER:-finch-gitlab-runner}"
CONCURRENCY="${RUNNER_CONCURRENCY:-2}"
CPUS="${RUNNER_JOB_CPUS:-1.0}"
MEMORY="${RUNNER_JOB_MEMORY:-3g}"

if docker ps --format '{{.Names}}' | grep -Eq '^runner-.*-project-'; then
  echo "✗ 실행 중인 CI job이 있습니다. 완료된 뒤 다시 실행하세요." >&2
  exit 1
fi

stamp=$(date +%Y%m%d%H%M%S)
docker exec "$CONTAINER" cp /etc/gitlab-runner/config.toml \
  "/etc/gitlab-runner/config.toml.before-cpu-isolation.${stamp}"

docker exec -e RUNNER_CONCURRENCY="$CONCURRENCY" -e RUNNER_JOB_CPUS="$CPUS" \
  -e RUNNER_JOB_MEMORY="$MEMORY" \
  "$CONTAINER" sh -eu -c '
    cfg=/etc/gitlab-runner/config.toml
    sed -i "s/^concurrent = .*/concurrent = $RUNNER_CONCURRENCY/" "$cfg"
    sed -i "s/^  request_concurrency = .*/  request_concurrency = $RUNNER_CONCURRENCY/" "$cfg"

    if grep -q "^    cpus = " "$cfg"; then
      sed -i "s/^    cpus = .*/    cpus = \"$RUNNER_JOB_CPUS\"/" "$cfg"
    else
      sed -i "/^    image = /a\\    cpus = \"$RUNNER_JOB_CPUS\"" "$cfg"
    fi

    if grep -q "^    memory = " "$cfg"; then
      sed -i "s/^    memory = .*/    memory = \"$RUNNER_JOB_MEMORY\"/" "$cfg"
    else
      sed -i "/^    cpus = /a\\    memory = \"$RUNNER_JOB_MEMORY\"" "$cfg"
    fi
  '

docker restart "$CONTAINER" >/dev/null
docker exec "$CONTAINER" gitlab-runner verify
docker exec "$CONTAINER" sh -c \
  'grep -E "^(concurrent|  request_concurrency|    cpus|    memory|    volumes)" /etc/gitlab-runner/config.toml'

echo "✓ Runner 격리 적용: concurrent=${CONCURRENCY}, job cpu=${CPUS}, memory=${MEMORY}"
