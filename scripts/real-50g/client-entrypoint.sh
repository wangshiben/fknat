#!/usr/bin/env bash

set -euo pipefail
umask 077

: "${FKNAT_INDEX:?}"
: "${FKNAT_RELAY:?}"
: "${SERVER_NODE_ID:?}"
: "${CLIENT_NAME:?}"
CLIENT_LISTEN_PORT=${CLIENT_LISTEN_PORT:-18081}
CLIENT_BASE_URL="http://127.0.0.1:${CLIENT_LISTEN_PORT}"
PREFLIGHT_SIZE_MIB=${PREFLIGHT_SIZE_MIB:-16}
PREFLIGHT_MAX_TIME_SECONDS=${PREFLIGHT_MAX_TIME_SECONDS:-300}

mkdir -p /results/sdk-logs
fknat_pid=""
cleanup() {
  [[ -n $fknat_pid ]] && kill "$fknat_pid" 2>/dev/null || true
  [[ -n $fknat_pid ]] && wait "$fknat_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

/opt/fknat \
  --non-interactive \
  --mode client \
  --index "$FKNAT_INDEX" \
  --relay "$FKNAT_RELAY" \
  --billing-key /state/billing-key.json \
  --identity /state/identity.key \
  --server-id "$SERVER_NODE_ID" \
  --listen "127.0.0.1:${CLIENT_LISTEN_PORT}" \
  --dial-attempts 30 \
  --retry-delay 3s \
  --reconnect-delay 3s \
  > >(tee -a /results/fknat.log) 2>&1 &
fknat_pid=$!

ready=0
for _ in $(seq 1 240); do
  if grep -q 'Client 已就绪' /results/fknat.log 2>/dev/null; then
    ready=1
    break
  fi
  kill -0 "$fknat_pid" 2>/dev/null || {
    wait "$fknat_pid" || true
    exit 1
  }
  sleep 1
done
[[ $ready == 1 ]]

variant="preflight-${CLIENT_NAME}"
expected=$(curl -fsS --max-time 60 \
  "${CLIENT_BASE_URL}/checksum?size_mb=${PREFLIGHT_SIZE_MIB}&variant=${variant}")
preflight_started=$(date +%s)
curl -fsS --max-time "$PREFLIGHT_MAX_TIME_SECONDS" -o /results/preflight.bin \
  "${CLIENT_BASE_URL}/file?size_mb=${PREFLIGHT_SIZE_MIB}&variant=${variant}"
preflight_finished=$(date +%s)
actual=$(sha256sum /results/preflight.bin | awk '{print $1}')
rm -f /results/preflight.bin
if [[ $expected != "$actual" || ! $actual =~ ^[0-9a-f]{64}$ ]]; then
  printf 'status\texpected_sha\tactual_sha\nFAIL\t%s\t%s\n' "$expected" "$actual" > /results/preflight.tsv
  exit 1
fi
printf 'status\tbytes\tduration_seconds\tsha256\nPASS\t%s\t%s\t%s\n' \
  "$((PREFLIGHT_SIZE_MIB * 1024 * 1024))" \
  "$((preflight_finished - preflight_started))" "$actual" > /results/preflight.tsv
touch /results/ready

while [[ ! -f /control/start ]]; do
  kill -0 "$fknat_pid" 2>/dev/null || exit 1
  sleep 1
done

set +e
/opt/client-worker.sh
worker_status=$?
set -e
printf '%s\n' "$worker_status" > /results/worker.exit
exit "$worker_status"
