#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# Deploy all Relay roles on 193.112.62.9, then run the local HTTP/NAT workload.
# The payload remains in pipes; local-3h-http-soak.sh records only headers,
# SHA256 values, byte counts, and process/resource evidence.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RUN_ID=${RUN_ID:-remote-3h-http-$(date -u +%Y%m%dT%H%M%SZ)}
RUN_DIR=${RUN_DIR:-$ROOT_DIR/.private-remote-3h-http/$RUN_ID}
REMOTE_HOST=${REMOTE_HOST:-server4}
REMOTE_PUBLIC_IP=${REMOTE_PUBLIC_IP:-193.112.62.9}
INDEX_PORT=${INDEX_PORT:-4010}
CLIENT_RELAY_PORT=${CLIENT_RELAY_PORT:-4011}
SERVER_RELAY_PORT=${SERVER_RELAY_PORT:-4012}
FKNAT_BIN=${FKNAT_BIN:-$ROOT_DIR/../natP2p/dist/review-final-20260908T124500Z/fkNat-review-final-20260908T124500Z-linux-amd64}
RELAY_BIN=${RELAY_BIN:-$ROOT_DIR/../natP2p/dist/review-final-20260908T124500Z/relayServer-review-final-20260908T124500Z-linux-amd64}
HTTP_BIN=${HTTP_BIN:-$ROOT_DIR/.private-local-3h-http/tools/httpfileserver}
BILLING_KEY_FILE=${BILLING_KEY_FILE:-$ROOT_DIR/test-results/public3h-bounded-r6-20260905T230830Z/relay.billing-key.json}
DURATION_SECONDS=${DURATION_SECONDS:-10800}
ALLOW_SHORT_PREFLIGHT=${ALLOW_SHORT_PREFLIGHT:-0}
REQUEST_INTERVAL_SECONDS=${REQUEST_INTERVAL_SECONDS:-1}
REQUEST_CONCURRENCY=${REQUEST_CONCURRENCY:-1}
MIN_AGGREGATE_BYTES_PER_SECOND=${MIN_AGGREGATE_BYTES_PER_SECOND:-1048576}
MIN_CLIENT_BYTES_PER_SECOND=${MIN_CLIENT_BYTES_PER_SECOND:-65536}
BNFS_MAX_PENDING_BILLING_DATA_SENDS=${BNFS_MAX_PENDING_BILLING_DATA_SENDS:-${MAX_PENDING_BILLING_DATA_SENDS:-16}}
BNFS_DISABLE_KCP=${BNFS_DISABLE_KCP:-0}
# Match the tuned public transfer profile while keeping every value overridable
# for controlled preflight comparisons.
TUNNEL_MAX_CHUNK=${TUNNEL_MAX_CHUNK:-262144}
TUNNEL_STREAM_SEND_WINDOW=${TUNNEL_STREAM_SEND_WINDOW:-32}
TUNNEL_SEND_WINDOW=${TUNNEL_SEND_WINDOW:-128}
BNFS_KCP_SEND_WINDOW=${BNFS_KCP_SEND_WINDOW:-1536}
BNFS_KCP_RECEIVE_WINDOW=${BNFS_KCP_RECEIVE_WINDOW:-6144}
BNFS_KCP_SESSION_BUFFER_BYTES=${BNFS_KCP_SESSION_BUFFER_BYTES:-16777216}
BRIDGE_WIDTH=${BRIDGE_WIDTH:-4}
FILE_SIZE_MB=${FILE_SIZE_MB:-4}
HTTP_BASE_PORT=${HTTP_BASE_PORT:-18100}
CLIENT_BASE_PORT=${CLIENT_BASE_PORT:-29200}
REMOTE_CLEANUP=${REMOTE_CLEANUP:-1}
RELEASE_SHA256SUMS=${RELEASE_SHA256SUMS:-$(dirname -- "$RELAY_BIN")/SHA256SUMS}

die() { printf '[remote-3h-http] FAIL: %s\n' "$*" >&2; exit 1; }
[[ $RUN_ID =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid RUN_ID"
[[ -x $FKNAT_BIN ]] || die "FKNAT_BIN is not executable: $FKNAT_BIN"
[[ -x $RELAY_BIN ]] || die "RELAY_BIN is not executable: $RELAY_BIN"
[[ -x $HTTP_BIN ]] || die "HTTP_BIN is not executable: $HTTP_BIN"
[[ -f $BILLING_KEY_FILE ]] || die "BILLING_KEY_FILE is missing: $BILLING_KEY_FILE"
[[ -f $RELEASE_SHA256SUMS ]] || die "release SHA256 manifest is missing: $RELEASE_SHA256SUMS"
[[ $INDEX_PORT =~ ^[0-9]+$ && $CLIENT_RELAY_PORT =~ ^[0-9]+$ && $SERVER_RELAY_PORT =~ ^[0-9]+$ ]] || die 'remote ports must be numeric'
for relay_port in "$INDEX_PORT" "$CLIENT_RELAY_PORT" "$SERVER_RELAY_PORT"; do
  ((relay_port >= 3999 && relay_port <= 4222)) || die "remote Relay port must be within 3999..4222: $relay_port"
done
[[ $INDEX_PORT != "$CLIENT_RELAY_PORT" && $INDEX_PORT != "$SERVER_RELAY_PORT" && $CLIENT_RELAY_PORT != "$SERVER_RELAY_PORT" ]] || die 'remote Relay ports must be distinct'
[[ $REMOTE_CLEANUP == 0 || $REMOTE_CLEANUP == 1 ]] || die 'REMOTE_CLEANUP must be 0 or 1'
[[ $BNFS_MAX_PENDING_BILLING_DATA_SENDS =~ ^[0-9]+$ && $BNFS_MAX_PENDING_BILLING_DATA_SENDS -ge 1 && $BNFS_MAX_PENDING_BILLING_DATA_SENDS -le 4096 ]] || die 'BNFS_MAX_PENDING_BILLING_DATA_SENDS must be 1..4096'
[[ $BNFS_DISABLE_KCP == 0 || $BNFS_DISABLE_KCP == 1 ]] || die 'BNFS_DISABLE_KCP must be 0 or 1'
[[ $TUNNEL_MAX_CHUNK =~ ^[0-9]+$ && $TUNNEL_MAX_CHUNK -ge 1024 ]] || die 'TUNNEL_MAX_CHUNK must be >= 1024'
[[ $TUNNEL_STREAM_SEND_WINDOW =~ ^[0-9]+$ && $TUNNEL_STREAM_SEND_WINDOW -ge 1 ]] || die 'TUNNEL_STREAM_SEND_WINDOW must be >= 1'
[[ $TUNNEL_SEND_WINDOW =~ ^[0-9]+$ && $TUNNEL_SEND_WINDOW -ge 1 ]] || die 'TUNNEL_SEND_WINDOW must be >= 1'
[[ $BNFS_KCP_SEND_WINDOW =~ ^[0-9]+$ && $BNFS_KCP_SEND_WINDOW -ge 32 && $BNFS_KCP_SEND_WINDOW -le 65535 ]] || die 'BNFS_KCP_SEND_WINDOW must be 32..65535'
[[ $BNFS_KCP_RECEIVE_WINDOW =~ ^[0-9]+$ && $BNFS_KCP_RECEIVE_WINDOW -ge 32 && $BNFS_KCP_RECEIVE_WINDOW -le 65535 ]] || die 'BNFS_KCP_RECEIVE_WINDOW must be 32..65535'
[[ $BNFS_KCP_SESSION_BUFFER_BYTES =~ ^[0-9]+$ && $BNFS_KCP_SESSION_BUFFER_BYTES -ge 1048576 && $BNFS_KCP_SESSION_BUFFER_BYTES -le 268435456 ]] || die 'BNFS_KCP_SESSION_BUFFER_BYTES must be 1MiB..256MiB'
[[ $BRIDGE_WIDTH =~ ^[0-9]+$ && $BRIDGE_WIDTH -ge 1 && $BRIDGE_WIDTH -le 8 ]] || die 'BRIDGE_WIDTH must be 1..8'
[[ $MIN_AGGREGATE_BYTES_PER_SECOND =~ ^[0-9]+$ && $MIN_AGGREGATE_BYTES_PER_SECOND -gt 0 ]] || die 'MIN_AGGREGATE_BYTES_PER_SECOND must be positive'
[[ $MIN_CLIENT_BYTES_PER_SECOND =~ ^[0-9]+$ && $MIN_CLIENT_BYTES_PER_SECOND -gt 0 ]] || die 'MIN_CLIENT_BYTES_PER_SECOND must be positive'
[[ $REMOTE_PUBLIC_IP == 193.112.62.9 ]] || die 'REMOTE_PUBLIC_IP must be 193.112.62.9 for the single-host Relay topology'

verify_release_binary() {
  local binary=$1 basename expected actual
  basename=$(basename -- "$binary")
  expected=$(awk -v name="$basename" '$2==name {print $1; exit}' "$RELEASE_SHA256SUMS")
  [[ $expected =~ ^[[:xdigit:]]{64}$ ]] || die "release manifest has no SHA256 for $basename"
  actual=$(sha256sum "$binary" | awk '{print $1}')
  [[ $actual == "$expected" ]] || die "release manifest mismatch for $basename expected=$expected actual=$actual"
}
verify_release_binary "$FKNAT_BIN"
verify_release_binary "$RELAY_BIN"

INDEX_ADDRESS=$REMOTE_PUBLIC_IP:$INDEX_PORT
CLIENT_RELAY_ADDRESS=$REMOTE_PUBLIC_IP:$CLIENT_RELAY_PORT
SERVER_RELAY_ADDRESS=$REMOTE_PUBLIC_IP:$SERVER_RELAY_PORT
SHORT_ID=${RUN_ID#remote-3h-http-}
REMOTE_DIR=/root/fknat-remote-http-$SHORT_ID
UNIT_INDEX=fknat-remote-http-${SHORT_ID}-index.service
UNIT_CLIENT=fknat-remote-http-${SHORT_ID}-client.service
UNIT_SERVER=fknat-remote-http-${SHORT_ID}-server.service

mkdir -p "$RUN_DIR" "$RUN_DIR/remote"
chmod 700 "$RUN_DIR" "$RUN_DIR/remote"
printf 'run_id=%s\nstarted_epoch=%s\nremote_host=%s\nremote_public_ip=%s\nremote_dir=%s\nindex_address=%s\nclient_relay_address=%s\nserver_relay_address=%s\nindex_unit=%s\nclient_relay_unit=%s\nserver_relay_unit=%s\nduration_seconds=%s\nrequest_interval_seconds=%s\nfile_size_mb=%s\n' \
  "$RUN_ID" "$(date +%s)" "$REMOTE_HOST" "$REMOTE_PUBLIC_IP" "$REMOTE_DIR" \
  "$INDEX_ADDRESS" "$CLIENT_RELAY_ADDRESS" "$SERVER_RELAY_ADDRESS" \
  "$UNIT_INDEX" "$UNIT_CLIENT" "$UNIT_SERVER" "$DURATION_SECONDS" "$REQUEST_INTERVAL_SECONDS" "$FILE_SIZE_MB" \
  > "$RUN_DIR/remote-deployment.env"
printf 'request_concurrency=%s\nmax_pending_billing_data_sends=%s\nbnfs_disable_kcp=%s\ntunnel_max_chunk=%s\ntunnel_stream_send_window=%s\ntunnel_send_window=%s\nbnfs_kcp_send_window=%s\nbnfs_kcp_receive_window=%s\nbnfs_kcp_session_buffer_bytes=%s\nrelay_topology=single-host:%s\n' \
  "$REQUEST_CONCURRENCY" "$BNFS_MAX_PENDING_BILLING_DATA_SENDS" "$BNFS_DISABLE_KCP" \
  "$TUNNEL_MAX_CHUNK" "$TUNNEL_STREAM_SEND_WINDOW" "$TUNNEL_SEND_WINDOW" \
  "$BNFS_KCP_SEND_WINDOW" "$BNFS_KCP_RECEIVE_WINDOW" "$BNFS_KCP_SESSION_BUFFER_BYTES" \
  "$REMOTE_PUBLIC_IP" >> "$RUN_DIR/remote-deployment.env"
printf 'bridge_width=%s\n' "$BRIDGE_WIDTH" >> "$RUN_DIR/remote-deployment.env"
printf 'release_sha256_manifest=%s\nminimum_aggregate_bytes_per_second=%s\nminimum_client_bytes_per_second=%s\n' \
  "$RELEASE_SHA256SUMS" "$MIN_AGGREGATE_BYTES_PER_SECOND" "$MIN_CLIENT_BYTES_PER_SECOND" >> "$RUN_DIR/remote-deployment.env"

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" "$@"
}

remote_sha256=''
relay_started=0
monitor_pid=''
cleanup_done=0

collect_remote_evidence() {
  remote "systemctl status '$UNIT_INDEX' '$UNIT_CLIENT' '$UNIT_SERVER' --no-pager" > "$RUN_DIR/remote/systemd-status.txt" 2>&1 || true
  remote "systemctl show '$UNIT_INDEX' '$UNIT_CLIENT' '$UNIT_SERVER' -p Id -p ActiveState -p SubState -p NRestarts -p ExecMainStartTimestamp -p MainPID" > "$RUN_DIR/remote/systemd-show.txt" 2>&1 || true
  remote "journalctl -u '$UNIT_INDEX' -u '$UNIT_CLIENT' -u '$UNIT_SERVER' --no-pager -o short-iso" > "$RUN_DIR/remote/relay-journal.log" 2>&1 || true
  remote "sha256sum '$REMOTE_DIR/relayServer' '$REMOTE_DIR/billing-key.json'" > "$RUN_DIR/remote/remote-sha256.txt" 2>&1 || true
  remote "ss -lntup | awk 'NR==1 || /:$INDEX_PORT |:$CLIENT_RELAY_PORT |:$SERVER_RELAY_PORT /'" > "$RUN_DIR/remote/listeners.txt" 2>&1 || true
}

stop_remote() {
  collect_remote_evidence
  if ((relay_started == 1)) && [[ $REMOTE_CLEANUP == 1 ]]; then
    remote "systemctl stop '$UNIT_INDEX' '$UNIT_CLIENT' '$UNIT_SERVER' >/dev/null 2>&1 || true; systemctl reset-failed '$UNIT_INDEX' '$UNIT_CLIENT' '$UNIT_SERVER' >/dev/null 2>&1 || true; rm -rf -- '$REMOTE_DIR'" || true
  fi
}

cleanup() {
  local rc=$?
  if ((cleanup_done == 1)); then
    exit "$rc"
  fi
  cleanup_done=1
  trap - EXIT INT TERM
  set +e
  [[ -z $monitor_pid ]] || kill "$monitor_pid" 2>/dev/null || true
  [[ -z $monitor_pid ]] || wait "$monitor_pid" 2>/dev/null || true
  stop_remote
  printf 'finished_epoch=%s\nexit_code=%s\n' "$(date +%s)" "$rc" >> "$RUN_DIR/remote-deployment.env"
  exit "$rc"
}
trap cleanup EXIT INT TERM

local_sha=$(sha256sum "$RELAY_BIN" | awk '{print $1}')
remote "if ss -lntup | awk 'NR>1 {print \$5}' | grep -Eq ':(($INDEX_PORT)|($CLIENT_RELAY_PORT)|($SERVER_RELAY_PORT))$'; then echo remote relay port is already occupied >&2; exit 20; fi; mkdir -p '$REMOTE_DIR'/logs/{index,client,server}; chmod 700 '$REMOTE_DIR' '$REMOTE_DIR'/logs '$REMOTE_DIR'/logs/{index,client,server}"
scp -q "$RELAY_BIN" "$REMOTE_HOST:$REMOTE_DIR/relayServer"
scp -q "$BILLING_KEY_FILE" "$REMOTE_HOST:$REMOTE_DIR/billing-key.json"
remote "chmod 700 '$REMOTE_DIR/relayServer'; chmod 600 '$REMOTE_DIR/billing-key.json'; sha256sum '$REMOTE_DIR/relayServer' | awk '{print \$1}' > '$REMOTE_DIR/relayServer.sha256'; test \"\$(cat '$REMOTE_DIR/relayServer.sha256')\" = '$local_sha'"
remote_sha256=$(remote "cat '$REMOTE_DIR/relayServer.sha256'")
[[ $remote_sha256 == "$local_sha" ]] || die "remote relay SHA256 mismatch local=$local_sha remote=$remote_sha256"
printf 'local_relay_sha256=%s\nremote_relay_sha256=%s\n' "$local_sha" "$remote_sha256" >> "$RUN_DIR/remote-deployment.env"

start_remote_relay() {
  local unit=$1 name=$2 listen_port=$3 mode=$4 extra=$5
  remote "systemd-run --unit='$unit' --property=Restart=on-failure --property=RestartSec=3s --setenv=BNFS_LOG_CONSOLE=true --setenv=BNFS_LOG_DIRECTORY='$REMOTE_DIR/logs/$name' --setenv=BNFS_MAX_PENDING_BILLING_DATA_SENDS='$BNFS_MAX_PENDING_BILLING_DATA_SENDS' --setenv=BNFS_DISABLE_KCP='$BNFS_DISABLE_KCP' --setenv=TUNNEL_MAX_CHUNK='$TUNNEL_MAX_CHUNK' --setenv=TUNNEL_STREAM_SEND_WINDOW='$TUNNEL_STREAM_SEND_WINDOW' --setenv=TUNNEL_SEND_WINDOW='$TUNNEL_SEND_WINDOW' --setenv=BNFS_KCP_SEND_WINDOW='$BNFS_KCP_SEND_WINDOW' --setenv=BNFS_KCP_RECEIVE_WINDOW='$BNFS_KCP_RECEIVE_WINDOW' --setenv=BNFS_KCP_SESSION_BUFFER_BYTES='$BNFS_KCP_SESSION_BUFFER_BYTES' '$REMOTE_DIR/relayServer' -mode '$mode' -listen ':$listen_port' -public '$REMOTE_PUBLIC_IP:$listen_port' -key '$REMOTE_DIR/$name.identity' -billing-key '$REMOTE_DIR/billing-key.json' -billing-queue '$REMOTE_DIR/$name.waitsubmit' -revocation-state '$REMOTE_DIR/$name.revocations.json' -bridge-width '$BRIDGE_WIDTH' $extra >/dev/null"
}

start_remote_relay "$UNIT_INDEX" index "$INDEX_PORT" index "-peer '$SERVER_RELAY_ADDRESS'"
start_remote_relay "$UNIT_CLIENT" client "$CLIENT_RELAY_PORT" relay "-index '$INDEX_ADDRESS' -peer '$SERVER_RELAY_ADDRESS'"
start_remote_relay "$UNIT_SERVER" server "$SERVER_RELAY_PORT" relay "-index '$INDEX_ADDRESS'"
relay_started=1

for port in "$INDEX_PORT" "$CLIENT_RELAY_PORT" "$SERVER_RELAY_PORT"; do
  for _ in $(seq 1 90); do
    if remote "ss -lntup | grep -q ':$port '"; then break; fi
    sleep 1
  done
  remote "ss -lntup | grep -q ':$port '" || die "remote Relay port $port did not become ready"
done
remote "systemctl is-active '$UNIT_INDEX' '$UNIT_CLIENT' '$UNIT_SERVER'" > "$RUN_DIR/remote/active-units.txt"
remote "ss -lntup | awk 'NR==1 || /:$INDEX_PORT |:$CLIENT_RELAY_PORT |:$SERVER_RELAY_PORT /'" > "$RUN_DIR/remote/listeners-ready.txt"
printf 'relay_addresses=%s,%s,%s\n' "$INDEX_ADDRESS" "$CLIENT_RELAY_ADDRESS" "$SERVER_RELAY_ADDRESS" >> "$RUN_DIR/remote-deployment.env"

monitor_remote() {
  printf 'epoch\tindex\tclient\tserver\tlisteners\tindex_restarts\tclient_restarts\tserver_restarts\n' > "$RUN_DIR/remote/health.tsv"
  while :; do
    printf '%s\t' "$(date +%s)" >> "$RUN_DIR/remote/health.tsv"
    unit_states=$(remote "systemctl is-active '$UNIT_INDEX' '$UNIT_CLIENT' '$UNIT_SERVER'" 2>/dev/null | paste -sd $'\t' - || true)
    printf '%s\t' "${unit_states:-unknown$'\t'unknown$'\t'unknown}" >> "$RUN_DIR/remote/health.tsv"
    listener_count=$(remote "ss -lntup | grep -Ec ':($INDEX_PORT|$CLIENT_RELAY_PORT|$SERVER_RELAY_PORT) '" 2>/dev/null || true)
    printf '%s\t' "${listener_count:-0}" >> "$RUN_DIR/remote/health.tsv"
    remote "systemctl show '$UNIT_INDEX' '$UNIT_CLIENT' '$UNIT_SERVER' -p NRestarts --value" 2>/dev/null | paste -sd $'\t' - >> "$RUN_DIR/remote/health.tsv" || printf 'unknown\tunknown\tunknown\n' >> "$RUN_DIR/remote/health.tsv"
    sleep 30
  done
}
monitor_remote & monitor_pid=$!

RUN_ID="$RUN_ID" RUN_DIR="$RUN_DIR/soak" FKNAT_BIN="$FKNAT_BIN" HTTP_BIN="$HTTP_BIN" \
  INDEX_ADDRESS="$INDEX_ADDRESS" CLIENT_RELAY_ADDRESS="$CLIENT_RELAY_ADDRESS" \
  SERVER_RELAY_ADDRESS="$SERVER_RELAY_ADDRESS" SECURITY_PROFILE=production \
  BILLING_KEY_FILE="$BILLING_KEY_FILE" DURATION_SECONDS="$DURATION_SECONDS" \
  ALLOW_SHORT_PREFLIGHT="$ALLOW_SHORT_PREFLIGHT" REQUEST_INTERVAL_SECONDS="$REQUEST_INTERVAL_SECONDS" \
  FILE_SIZE_MB="$FILE_SIZE_MB" HTTP_BASE_PORT="$HTTP_BASE_PORT" CLIENT_BASE_PORT="$CLIENT_BASE_PORT" \
  REQUEST_CONCURRENCY="$REQUEST_CONCURRENCY" \
  MIN_AGGREGATE_BYTES_PER_SECOND="$MIN_AGGREGATE_BYTES_PER_SECOND" \
  MIN_CLIENT_BYTES_PER_SECOND="$MIN_CLIENT_BYTES_PER_SECOND" \
  FKNAT_LEGACY_FLAGS="${FKNAT_LEGACY_FLAGS:-0}" \
  BNFS_MAX_PENDING_BILLING_DATA_SENDS="$BNFS_MAX_PENDING_BILLING_DATA_SENDS" \
  BNFS_DISABLE_KCP="$BNFS_DISABLE_KCP" \
  TUNNEL_MAX_CHUNK="$TUNNEL_MAX_CHUNK" TUNNEL_STREAM_SEND_WINDOW="$TUNNEL_STREAM_SEND_WINDOW" \
  TUNNEL_SEND_WINDOW="$TUNNEL_SEND_WINDOW" BNFS_KCP_SEND_WINDOW="$BNFS_KCP_SEND_WINDOW" \
  BNFS_KCP_RECEIVE_WINDOW="$BNFS_KCP_RECEIVE_WINDOW" BNFS_KCP_SESSION_BUFFER_BYTES="$BNFS_KCP_SESSION_BUFFER_BYTES" \
  BRIDGE_WIDTH="$BRIDGE_WIDTH" \
  bash "$ROOT_DIR/scripts/local-3h-http-soak.sh"

remote "systemctl is-active '$UNIT_INDEX' '$UNIT_CLIENT' '$UNIT_SERVER' >/dev/null"
restart_counts=$(remote "systemctl show '$UNIT_INDEX' '$UNIT_CLIENT' '$UNIT_SERVER' -p NRestarts --value" | awk 'NF {print}')
[[ $(printf '%s\n' "$restart_counts" | awk '$1 != 0 {bad++} END {print bad+0}') == 0 ]] || die "one or more remote Relay units restarted: ${restart_counts//$'\n'/,}"
final_remote_sha256=$(remote "sha256sum '$REMOTE_DIR/relayServer' | awk '{print \$1}'")
[[ $final_remote_sha256 == "$local_sha" ]] || die "remote Relay binary changed during soak local=$local_sha remote=$final_remote_sha256"
printf 'final_restart_counts=%s\n' "${restart_counts//$'\n'/,}" >> "$RUN_DIR/remote-deployment.env"
printf 'final_remote_relay_sha256=%s\n' "$final_remote_sha256" >> "$RUN_DIR/remote-deployment.env"
printf 'status=PASS\n' >> "$RUN_DIR/remote-deployment.env"
printf '[remote-3h-http] PASS run=%s evidence=%s remote=%s\n' "$RUN_ID" "$RUN_DIR" "$REMOTE_PUBLIC_IP"
