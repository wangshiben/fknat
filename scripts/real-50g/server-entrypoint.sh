#!/usr/bin/env bash

set -euo pipefail
umask 077

: "${FKNAT_INDEX:?}"
: "${FKNAT_RELAY:?}"
: "${FKNAT_CA_URL:?}"
: "${SERVER_NAME:?}"

mkdir -p /results/sdk-logs

http_pid=""
fknat_pid=""
cleanup() {
  [[ -n $fknat_pid ]] && kill "$fknat_pid" 2>/dev/null || true
  [[ -n $http_pid ]] && kill "$http_pid" 2>/dev/null || true
  [[ -n $fknat_pid ]] && wait "$fknat_pid" 2>/dev/null || true
  [[ -n $http_pid ]] && wait "$http_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

/opt/httpfileserver \
  -bind 127.0.0.1 \
  -port 5173 \
  -size 100 \
  -max-size 200 \
  -send-rate-mibps "${SERVER_RATE_MIBPS:-4}" \
  > >(tee -a /results/httpfileserver.log) 2>&1 &
http_pid=$!

for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 http://127.0.0.1:5173/health >/dev/null; then
    break
  fi
  kill -0 "$http_pid" 2>/dev/null || exit 1
  sleep 1
done
curl -fsS --max-time 2 http://127.0.0.1:5173/health >/dev/null

/opt/fknat \
  --non-interactive \
  --mode server \
  --index "$FKNAT_INDEX" \
  --relay "$FKNAT_RELAY" \
  --ca "$FKNAT_CA_URL" \
  --billing-key /state/billing-key.json \
  --identity /state/identity.key \
  --target 127.0.0.1:5173 \
  --max-sessions 64 \
  --accept-queue 128 \
  > >(tee -a /results/fknat.log) 2>&1 &
fknat_pid=$!

status=0
wait "$fknat_pid" || status=$?
exit "$status"
