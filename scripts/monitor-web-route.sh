#!/usr/bin/env bash
set -Eeuo pipefail

RUN_DIR=${RUN_DIR:?}
REMOTE_HOST=${REMOTE_HOST:-server3}
REMOTE_RUN_DIR=${REMOTE_RUN_DIR:?}
REMOTE_RELAY_HOST=${REMOTE_RELAY_HOST:-server4}
REMOTE_RELAY_PID=${REMOTE_RELAY_PID:-903094}
mkdir -p "$RUN_DIR"
printf 'epoch\tserver_status\tclient_status\trelay_status\n' >"$RUN_DIR/monitor.tsv"

while :; do
  epoch=$(date +%s)
  server_status=$(curl -sS --max-time 5 http://127.0.0.1:28088/api/status 2>/dev/null | tr '\n' ' ' || true)
  client_status=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" "curl -sS --max-time 5 http://127.0.0.1:28089/api/status 2>/dev/null" | tr '\n' ' ' || true)
  relay_status=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_RELAY_HOST" "ps -o pid=,stat=,etime= -p '$REMOTE_RELAY_PID' 2>/dev/null; ss -lntup | grep ':4102 '" | tr '\n' ' ' || true)
  printf '%s\t%s\t%s\t%s\n' "$epoch" "$server_status" "$client_status" "$relay_status" >>"$RUN_DIR/monitor.tsv"
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" "test -f '$REMOTE_RUN_DIR/soak-3h/summary.env'" >/dev/null 2>&1; then
    exit 0
  fi
  sleep 30
done
