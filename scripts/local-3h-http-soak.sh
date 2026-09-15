#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# Run two local NatServers and three local NatClients against a Relay-backed
# tunnel. HTTP response bytes stay in pipes; only headers, hashes, and counters
# are written to the evidence directory.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RUN_ID=${RUN_ID:-local-3h-http-$(date -u +%Y%m%dT%H%M%SZ)}
RUN_DIR=${RUN_DIR:-$ROOT_DIR/.private-local-3h-http/$RUN_ID}
FKNAT_BIN=${FKNAT_BIN:-$ROOT_DIR/../natP2p/dist/dev/fkNat-dev-linux-amd64}
HTTP_BIN=${HTTP_BIN:-$ROOT_DIR/../natP2p/test-results/local-httpfileserver}
INDEX_ADDRESS=${INDEX_ADDRESS:-}
RELAY_ADDRESS=${RELAY_ADDRESS:-}
CLIENT_RELAY_ADDRESS=${CLIENT_RELAY_ADDRESS:-$RELAY_ADDRESS}
SERVER_RELAY_ADDRESS=${SERVER_RELAY_ADDRESS:-$RELAY_ADDRESS}
BILLING_KEY_FILE=${BILLING_KEY_FILE:-}
SECURITY_PROFILE=${SECURITY_PROFILE:-development}
DURATION_SECONDS=${DURATION_SECONDS:-10800}
ALLOW_SHORT_PREFLIGHT=${ALLOW_SHORT_PREFLIGHT:-0}
REQUEST_INTERVAL_SECONDS=${REQUEST_INTERVAL_SECONDS:-20}
FILE_SIZE_MB=${FILE_SIZE_MB:-4}
HTTP_BASE_PORT=${HTTP_BASE_PORT:-18100}
CLIENT_BASE_PORT=${CLIENT_BASE_PORT:-19100}
REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS:-300}
REQUEST_CONCURRENCY=${REQUEST_CONCURRENCY:-1}
MIN_AGGREGATE_BYTES_PER_SECOND=${MIN_AGGREGATE_BYTES_PER_SECOND:-0}
MIN_CLIENT_BYTES_PER_SECOND=${MIN_CLIENT_BYTES_PER_SECOND:-0}
# The Relay holdback is an 8 MiB per-logical-connection security boundary.
# Keep the NAT billing sender at its production default so a slow voucher
# claim cannot queue more complete records than that boundary can retain.
BNFS_MAX_PENDING_BILLING_DATA_SENDS=${BNFS_MAX_PENDING_BILLING_DATA_SENDS:-${MAX_PENDING_BILLING_DATA_SENDS:-16}}
BNFS_DISABLE_KCP=${BNFS_DISABLE_KCP:-0}
# Keep the soak path aligned with the tuned public transfer profile. These
# remain environment overrides so a preflight can compare smaller windows.
TUNNEL_MAX_CHUNK=${TUNNEL_MAX_CHUNK:-262144}
TUNNEL_STREAM_SEND_WINDOW=${TUNNEL_STREAM_SEND_WINDOW:-32}
TUNNEL_SEND_WINDOW=${TUNNEL_SEND_WINDOW:-128}
BNFS_KCP_SEND_WINDOW=${BNFS_KCP_SEND_WINDOW:-1536}
BNFS_KCP_RECEIVE_WINDOW=${BNFS_KCP_RECEIVE_WINDOW:-6144}
BNFS_KCP_SESSION_BUFFER_BYTES=${BNFS_KCP_SESSION_BUFFER_BYTES:-16777216}
# Older formal release builds predate the optional stream-limit flags. Keep
# their exact CLI invocation available without changing the release binary.
FKNAT_LEGACY_FLAGS=${FKNAT_LEGACY_FLAGS:-0}

die() { printf '[local-3h-http] FAIL: %s\n' "$*" >&2; exit 1; }
[[ $RUN_ID =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid RUN_ID"
if [[ $ALLOW_SHORT_PREFLIGHT == 1 ]]; then
  [[ $DURATION_SECONDS =~ ^[0-9]+$ && $DURATION_SECONDS -gt 0 ]] || die "DURATION_SECONDS must be positive"
else
  [[ $DURATION_SECONDS =~ ^[0-9]+$ && $DURATION_SECONDS -ge 10800 ]] || die "DURATION_SECONDS must be >= 10800"
fi
[[ $REQUEST_INTERVAL_SECONDS =~ ^[0-9]+$ && $REQUEST_INTERVAL_SECONDS -gt 0 ]] || die "REQUEST_INTERVAL_SECONDS must be positive"
[[ $REQUEST_CONCURRENCY =~ ^[0-9]+$ && $REQUEST_CONCURRENCY -ge 1 && $REQUEST_CONCURRENCY -le 32 ]] || die "REQUEST_CONCURRENCY must be 1..32"
[[ $MIN_AGGREGATE_BYTES_PER_SECOND =~ ^[0-9]+$ ]] || die "MIN_AGGREGATE_BYTES_PER_SECOND must be non-negative"
[[ $MIN_CLIENT_BYTES_PER_SECOND =~ ^[0-9]+$ ]] || die "MIN_CLIENT_BYTES_PER_SECOND must be non-negative"
[[ $BNFS_MAX_PENDING_BILLING_DATA_SENDS =~ ^[0-9]+$ && $BNFS_MAX_PENDING_BILLING_DATA_SENDS -ge 1 && $BNFS_MAX_PENDING_BILLING_DATA_SENDS -le 4096 ]] || die "BNFS_MAX_PENDING_BILLING_DATA_SENDS must be 1..4096"
[[ $BNFS_DISABLE_KCP == 0 || $BNFS_DISABLE_KCP == 1 ]] || die "BNFS_DISABLE_KCP must be 0 or 1"
[[ $TUNNEL_MAX_CHUNK =~ ^[0-9]+$ && $TUNNEL_MAX_CHUNK -ge 1024 ]] || die "TUNNEL_MAX_CHUNK must be >= 1024"
[[ $TUNNEL_STREAM_SEND_WINDOW =~ ^[0-9]+$ && $TUNNEL_STREAM_SEND_WINDOW -ge 1 ]] || die "TUNNEL_STREAM_SEND_WINDOW must be >= 1"
[[ $TUNNEL_SEND_WINDOW =~ ^[0-9]+$ && $TUNNEL_SEND_WINDOW -ge 1 ]] || die "TUNNEL_SEND_WINDOW must be >= 1"
[[ $BNFS_KCP_SEND_WINDOW =~ ^[0-9]+$ && $BNFS_KCP_SEND_WINDOW -ge 32 && $BNFS_KCP_SEND_WINDOW -le 65535 ]] || die "BNFS_KCP_SEND_WINDOW must be 32..65535"
[[ $BNFS_KCP_RECEIVE_WINDOW =~ ^[0-9]+$ && $BNFS_KCP_RECEIVE_WINDOW -ge 32 && $BNFS_KCP_RECEIVE_WINDOW -le 65535 ]] || die "BNFS_KCP_RECEIVE_WINDOW must be 32..65535"
[[ $BNFS_KCP_SESSION_BUFFER_BYTES =~ ^[0-9]+$ && $BNFS_KCP_SESSION_BUFFER_BYTES -ge 1048576 && $BNFS_KCP_SESSION_BUFFER_BYTES -le 268435456 ]] || die "BNFS_KCP_SESSION_BUFFER_BYTES must be 1MiB..256MiB"
[[ $FILE_SIZE_MB =~ ^[0-9]+$ && $FILE_SIZE_MB -gt 0 ]] || die "FILE_SIZE_MB must be positive"
[[ $HTTP_BASE_PORT =~ ^[0-9]+$ && $CLIENT_BASE_PORT =~ ^[0-9]+$ ]] || die "ports must be numeric"
[[ -x $FKNAT_BIN ]] || die "FKNAT_BIN is not executable: $FKNAT_BIN"
[[ -x $HTTP_BIN ]] || die "HTTP_BIN is not executable: $HTTP_BIN"
[[ -n $CLIENT_RELAY_ADDRESS && -n $SERVER_RELAY_ADDRESS ]] || die "client and server relay addresses are required"
if [[ -z $INDEX_ADDRESS && $SECURITY_PROFILE != production ]]; then
  die "automatic Index discovery requires the production security profile"
fi
if [[ $SECURITY_PROFILE == production ]]; then
  [[ -f $BILLING_KEY_FILE ]] || die "BILLING_KEY_FILE is required in production"
elif [[ $SECURITY_PROFILE != development && $SECURITY_PROFILE != staging ]]; then
  die "SECURITY_PROFILE must be development, staging, or production"
fi

kcp_socket_rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || printf '0')
kcp_socket_wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || printf '0')
[[ $kcp_socket_rmem_max =~ ^[0-9]+$ ]] || kcp_socket_rmem_max=0
[[ $kcp_socket_wmem_max =~ ^[0-9]+$ ]] || kcp_socket_wmem_max=0
if [[ $BNFS_DISABLE_KCP == 0 ]] &&
  ((kcp_socket_rmem_max < BNFS_KCP_SESSION_BUFFER_BYTES || kcp_socket_wmem_max < BNFS_KCP_SESSION_BUFFER_BYTES)); then
  die "KCP socket buffer ceiling is below BNFS_KCP_SESSION_BUFFER_BYTES=$BNFS_KCP_SESSION_BUFFER_BYTES (net.core.rmem_max=$kcp_socket_rmem_max net.core.wmem_max=$kcp_socket_wmem_max)"
fi

billing_args=()
[[ -n $BILLING_KEY_FILE ]] && billing_args=(--billing-key "$BILLING_KEY_FILE")
index_args=()
[[ -n $INDEX_ADDRESS ]] && index_args=(--index "$INDEX_ADDRESS")

mkdir -p "$RUN_DIR"/{logs,state,requests,failures}
chmod 700 "$RUN_DIR" "$RUN_DIR"/{logs,state,requests,failures}
printf 'run_id=%s\nstarted_epoch=%s\nduration_seconds=%s\nrequest_interval_seconds=%s\nrequest_concurrency=%s\nmax_pending_billing_data_sends=%s\nfile_size_mb=%s\nindex_address=%s\nrelay_address=%s\nclient_relay_address=%s\nserver_relay_address=%s\n' \
  "$RUN_ID" "$(date +%s)" "$DURATION_SECONDS" "$REQUEST_INTERVAL_SECONDS" "$REQUEST_CONCURRENCY" "$BNFS_MAX_PENDING_BILLING_DATA_SENDS" "$FILE_SIZE_MB" "$INDEX_ADDRESS" "${RELAY_ADDRESS:-split}" "$CLIENT_RELAY_ADDRESS" "$SERVER_RELAY_ADDRESS" > "$RUN_DIR/metadata.env"
printf 'security_profile=%s\n' "$SECURITY_PROFILE" >> "$RUN_DIR/metadata.env"
if [[ -n $INDEX_ADDRESS ]]; then
  printf 'index_discovery=explicit\n' >> "$RUN_DIR/metadata.env"
else
  printf 'index_discovery=ca-web\n' >> "$RUN_DIR/metadata.env"
fi
printf 'fknat_legacy_flags=%s\n' "$FKNAT_LEGACY_FLAGS" >> "$RUN_DIR/metadata.env"
printf 'minimum_aggregate_bytes_per_second=%s\nminimum_client_bytes_per_second=%s\n' \
  "$MIN_AGGREGATE_BYTES_PER_SECOND" "$MIN_CLIENT_BYTES_PER_SECOND" >> "$RUN_DIR/metadata.env"
printf 'bnfs_disable_kcp=%s\ntunnel_max_chunk=%s\ntunnel_stream_send_window=%s\ntunnel_send_window=%s\nbnfs_kcp_send_window=%s\nbnfs_kcp_receive_window=%s\nbnfs_kcp_session_buffer_bytes=%s\n' \
  "$BNFS_DISABLE_KCP" "$TUNNEL_MAX_CHUNK" "$TUNNEL_STREAM_SEND_WINDOW" "$TUNNEL_SEND_WINDOW" \
  "$BNFS_KCP_SEND_WINDOW" "$BNFS_KCP_RECEIVE_WINDOW" "$BNFS_KCP_SESSION_BUFFER_BYTES" >> "$RUN_DIR/metadata.env"
printf 'kernel_rmem_max=%s\nkernel_wmem_max=%s\n' "$kcp_socket_rmem_max" "$kcp_socket_wmem_max" >> "$RUN_DIR/metadata.env"
sha256sum "$FKNAT_BIN" "$HTTP_BIN" > "$RUN_DIR/binaries.sha256"

snapshot_udp_counters() {
  local phase=$1 epoch
  epoch=$(date +%s)
  awk -v epoch="$epoch" -v phase="$phase" '
    $1 == "Udp:" && !have_header {
      for (i = 2; i <= NF; i++) name[i] = $i
      have_header = 1
      next
    }
    $1 == "Udp:" && have_header {
      printf "%s\t%s", epoch, phase
      for (i = 2; i <= NF; i++) printf "\t%s=%s", name[i], $i
      printf "\n"
      exit
    }
  ' /proc/net/snmp >> "$RUN_DIR/udp-counters.tsv"
}

server_pids=()
client_pids=()
load_pids=()
monitor_pid=''
cleanup() {
  local pid alive state
  set +e
  [[ -n $monitor_pid ]] && kill "$monitor_pid" 2>/dev/null || true
  for pid in "${load_pids[@]}"; do
    [[ -n $pid ]] && kill "$pid" 2>/dev/null || true
  done
  for pid in "${client_pids[@]}" "${server_pids[@]}"; do
    [[ -n $pid ]] && kill "$pid" 2>/dev/null || true
  done
  # A transport blocked in shutdown must not keep the soak wrapper and remote
  # Relay cleanup alive forever. Give exact child PIDs a bounded grace period,
  # then reap them after a forced stop.
  for _ in $(seq 1 50); do
    alive=0
    for pid in "${client_pids[@]}" "${server_pids[@]}"; do
      [[ -n $pid ]] || continue
      state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
      [[ -z $state || $state == Z* ]] || alive=1
    done
    ((alive == 0)) && break
    sleep 0.2
  done
  for pid in "${client_pids[@]}" "${server_pids[@]}"; do
    [[ -n $pid ]] && kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${load_pids[@]}" "${client_pids[@]}" "${server_pids[@]}"; do
    [[ -n $pid ]] && wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

start_http() {
  local index=$1 port=$2
  "$HTTP_BIN" -bind 127.0.0.1 -port "$port" -size "$FILE_SIZE_MB" -max-size "$FILE_SIZE_MB" \
    >"$RUN_DIR/logs/http-server-$index.log" 2>&1 &
  server_pids+=("$!")
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null; then return 0; fi
    kill -0 "${server_pids[-1]}" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

start_natserver() {
  local index=$1 target_port=$2
  local stream_limit_args=()
  if [[ $FKNAT_LEGACY_FLAGS != 1 ]]; then
    stream_limit_args=(--max-streams 256 --max-streams-per-session 64)
  fi
  BNFS_SECURITY_PROFILE="$SECURITY_PROFILE" BNFS_MAX_PENDING_BILLING_DATA_SENDS="$BNFS_MAX_PENDING_BILLING_DATA_SENDS" BNFS_DISABLE_KCP="$BNFS_DISABLE_KCP" \
  TUNNEL_MAX_CHUNK="$TUNNEL_MAX_CHUNK" TUNNEL_STREAM_SEND_WINDOW="$TUNNEL_STREAM_SEND_WINDOW" TUNNEL_SEND_WINDOW="$TUNNEL_SEND_WINDOW" \
  BNFS_KCP_SEND_WINDOW="$BNFS_KCP_SEND_WINDOW" BNFS_KCP_RECEIVE_WINDOW="$BNFS_KCP_RECEIVE_WINDOW" \
  BNFS_KCP_SESSION_BUFFER_BYTES="$BNFS_KCP_SESSION_BUFFER_BYTES" "$FKNAT_BIN" --non-interactive --mode server "${index_args[@]}" --relay "$SERVER_RELAY_ADDRESS" \
    "${billing_args[@]}" --identity "$RUN_DIR/state/server-$index.identity" \
    --target "127.0.0.1:$target_port" --max-sessions 32 --accept-queue 64 \
    "${stream_limit_args[@]}" \
    >"$RUN_DIR/logs/natserver-$index.log" 2>"$RUN_DIR/logs/natserver-$index.err" &
  server_pids+=("$!")
}

start_natclient() {
  local index=$1 target_id=$2 listen_port=$3
  BNFS_SECURITY_PROFILE="$SECURITY_PROFILE" BNFS_MAX_PENDING_BILLING_DATA_SENDS="$BNFS_MAX_PENDING_BILLING_DATA_SENDS" BNFS_DISABLE_KCP="$BNFS_DISABLE_KCP" \
  TUNNEL_MAX_CHUNK="$TUNNEL_MAX_CHUNK" TUNNEL_STREAM_SEND_WINDOW="$TUNNEL_STREAM_SEND_WINDOW" TUNNEL_SEND_WINDOW="$TUNNEL_SEND_WINDOW" \
  BNFS_KCP_SEND_WINDOW="$BNFS_KCP_SEND_WINDOW" BNFS_KCP_RECEIVE_WINDOW="$BNFS_KCP_RECEIVE_WINDOW" \
  BNFS_KCP_SESSION_BUFFER_BYTES="$BNFS_KCP_SESSION_BUFFER_BYTES" "$FKNAT_BIN" --non-interactive --mode client "${index_args[@]}" --relay "$CLIENT_RELAY_ADDRESS" \
    "${billing_args[@]}" --identity "$RUN_DIR/state/client-$index.identity" \
    --server-id "$target_id" --listen "127.0.0.1:$listen_port" \
    --dial-attempts 30 --retry-delay 2s --reconnect-delay 2s \
    >"$RUN_DIR/logs/natclient-$index.log" 2>"$RUN_DIR/logs/natclient-$index.err" &
  client_pids+=("$!")
}

wait_server_id() {
  local index=$1
  for _ in $(seq 1 120); do
    local id
    id=$(awk '/本节点 ID:/{print $NF; exit}' "$RUN_DIR/logs/natserver-$index.log" 2>/dev/null || true)
    if [[ $id =~ ^[[:xdigit:]]{64}$ ]]; then printf '%s\n' "$id"; return 0; fi
    kill -0 "${server_pids[$((index + 1))]}" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

wait_client_ready() {
  local index=$1 port=$2
  for _ in $(seq 1 120); do
    if grep -q 'Client 已就绪' "$RUN_DIR/logs/natclient-$index.log" && curl -fsS --max-time 2 "http://127.0.0.1:$port/health" >/dev/null; then return 0; fi
    kill -0 "${client_pids[$((index - 1))]}" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

request_one() {
  local client=$1 port=$2 expected=$3 request_no=$4
  local dir="$RUN_DIR/requests/$client" headers hash bytes started_ns ended_ns ended elapsed_ms bytes_per_second status content_length received actual rc tee_rc wc_rc
  local -a pipeline_status
  mkdir -p "$dir"
  headers=$(mktemp "$dir/headers.XXXXXX")
  hash=$(mktemp "$dir/hash.XXXXXX")
  bytes=$(mktemp "$dir/bytes.XXXXXX")
  started_ns=$(date +%s%N)
  set +e
  curl --silent --show-error --fail --connect-timeout 15 --max-time "$REQUEST_TIMEOUT_SECONDS" \
    -D "$headers" "http://127.0.0.1:$port/file?size_mb=$FILE_SIZE_MB" \
    | tee >(sha256sum | awk '{print $1}' >"$hash") | wc -c >"$bytes"
  pipeline_status=("${PIPESTATUS[@]}")
  rc=${pipeline_status[0]:-1}
  tee_rc=${pipeline_status[1]:-1}
  wc_rc=${pipeline_status[2]:-1}
  set -e
  for _ in $(seq 1 50); do [[ -s $hash ]] && break; sleep 0.1; done
  status=$(awk 'tolower($1) ~ /^http\// {code=$2} END {print code+0}' "$headers")
  content_length=$(awk -F': *' 'tolower($1)=="content-length" {gsub(/[[:space:]]/,"",$2); value=$2} END {print value+0}' "$headers")
  received=$(tr -d '[:space:]' <"$bytes")
  actual=$(tr -d '[:space:]' <"$hash")
  ended_ns=$(date +%s%N)
  ended=$((ended_ns / 1000000000))
  elapsed_ms=$(((ended_ns - started_ns) / 1000000))
  ((elapsed_ms > 0)) || elapsed_ms=1
  bytes_per_second=$((received * 1000 / elapsed_ms))
  if ((rc == 0 && tee_rc == 0 && wc_rc == 0)) && ((status >= 200 && status < 300)) && ((content_length == FILE_SIZE_MB * 1024 * 1024)) \
    && ((received == content_length)) && [[ $actual == "$expected" ]]; then
    {
      flock 9
      printf '%s\t%s\t%s\t%s\t%s\t%s\tPASS\t%s\t%s\n' \
        "$ended" "$client" "$request_no" "$status" "$received" "$actual" "$elapsed_ms" "$bytes_per_second" >> "$RUN_DIR/results.tsv"
    } 9>"$RUN_DIR/results.lock"
    rm -f -- "$headers" "$hash" "$bytes"
    return 0
  fi
  {
    flock 9
    printf '%s\t%s\t%s\t%s\t%s\t%s\tFAIL\t%s\t%s\trc=%s content_length=%s received=%s expected=%s actual=%s\n' \
      "$ended" "$client" "$request_no" "$status" "$received" "$actual" "$elapsed_ms" "$bytes_per_second" \
      "$rc/$tee_rc/$wc_rc" "$content_length" "$received" "$expected" "$actual" >> "$RUN_DIR/results.tsv"
  } 9>"$RUN_DIR/results.lock"
  rm -f -- "$headers" "$hash" "$bytes"
  return 1
}

start_http 1 "$HTTP_BASE_PORT" || die 'local HTTP server 1 did not become ready'
start_http 2 "$((HTTP_BASE_PORT + 1))" || die 'local HTTP server 2 did not become ready'
start_natserver 1 "$HTTP_BASE_PORT"
start_natserver 2 "$((HTTP_BASE_PORT + 1))"
server1_id=$(wait_server_id 1) || die 'NatServer 1 did not report NodeID'
server2_id=$(wait_server_id 2) || die 'NatServer 2 did not report NodeID'
printf 'server1_id=%s\nserver2_id=%s\n' "$server1_id" "$server2_id" >> "$RUN_DIR/metadata.env"

# Stagger admission handshakes so a transient CA/pubkey latency on one client
# cannot race the other registrations during startup.
start_natclient 1 "$server1_id" "$CLIENT_BASE_PORT"
wait_client_ready 1 "$CLIENT_BASE_PORT" || die 'NatClient 1 did not become ready'
start_natclient 2 "$server1_id" "$((CLIENT_BASE_PORT + 1))"
wait_client_ready 2 "$((CLIENT_BASE_PORT + 1))" || die 'NatClient 2 did not become ready'
start_natclient 3 "$server2_id" "$((CLIENT_BASE_PORT + 2))"
wait_client_ready 3 "$((CLIENT_BASE_PORT + 2))" || die 'NatClient 3 did not become ready'
{
  printf 'role\tname\tpid\n'
  printf 'http\tserver-1\t%s\n' "${server_pids[0]}"
  printf 'http\tserver-2\t%s\n' "${server_pids[1]}"
  printf 'natserver\tserver-1\t%s\n' "${server_pids[2]}"
  printf 'natserver\tserver-2\t%s\n' "${server_pids[3]}"
  printf 'natclient\tclient-1\t%s\n' "${client_pids[0]}"
  printf 'natclient\tclient-2\t%s\n' "${client_pids[1]}"
  printf 'natclient\tclient-3\t%s\n' "${client_pids[2]}"
} > "$RUN_DIR/pids.tsv"

expected1=$(curl -fsS "http://127.0.0.1:$HTTP_BASE_PORT/checksum?size_mb=$FILE_SIZE_MB" | tr -d '[:space:]')
expected2=$(curl -fsS "http://127.0.0.1:$((HTTP_BASE_PORT + 1))/checksum?size_mb=$FILE_SIZE_MB" | tr -d '[:space:]')
[[ $expected1 =~ ^[[:xdigit:]]{64}$ && $expected2 =~ ^[[:xdigit:]]{64}$ ]] || die 'failed to obtain source SHA256'
printf 'expected_sha_server1=%s\nexpected_sha_server2=%s\n' "$expected1" "$expected2" >> "$RUN_DIR/metadata.env"
printf 'epoch\tclient\trequest\thttp_status\treceived_bytes\tsha256\tstatus\telapsed_ms\tbytes_per_second\tdetail\n' > "$RUN_DIR/results.tsv"
snapshot_udp_counters start

monitor() {
  while :; do
    printf '%s\t' "$(date +%s)" >> "$RUN_DIR/resource.tsv"
    all_pids=$(IFS=,; printf '%s' "${server_pids[*]},${client_pids[*]}")
    ps -o pid=,rss=,vsz=,pcpu=,etime=,comm= -p "$all_pids" 2>/dev/null | tr '\n' ';' >> "$RUN_DIR/resource.tsv" || true
    printf '\n' >> "$RUN_DIR/resource.tsv"
    {
      printf 'epoch=%s\n' "$(date +%s)"
      ss -u -a -m -n -p 2>&1 || true
    } >> "$RUN_DIR/udp-sockets.log"
    sleep 30
  done
}
monitor & monitor_pid=$!

printf 'started_epoch=%s\n' "$(date +%s)" >> "$RUN_DIR/metadata.env"
start_epoch=$(date +%s)
deadline=$((start_epoch + DURATION_SECONDS))
worker() {
  local client=$1 port=$2 expected=$3 worker_id=$4 request_no=0
  while (( $(date +%s) < deadline )); do
    request_no=$((request_no + 1))
    if ! request_one "$client" "$port" "$expected" "${worker_id}-${request_no}"; then
      : > "$RUN_DIR/failures/${worker_id}-${request_no}"
    fi
    sleep "$REQUEST_INTERVAL_SECONDS"
  done
  : > "$RUN_DIR/state/worker-$worker_id.done"
}

worker_id=0
for client in 1 2 3; do
  case $client in
    1) worker_port=$CLIENT_BASE_PORT; worker_expected=$expected1 ;;
    2) worker_port=$((CLIENT_BASE_PORT + 1)); worker_expected=$expected1 ;;
    3) worker_port=$((CLIENT_BASE_PORT + 2)); worker_expected=$expected2 ;;
  esac
  for _ in $(seq 1 "$REQUEST_CONCURRENCY"); do
    worker_id=$((worker_id + 1))
    worker "$client" "$worker_port" "$worker_expected" "$worker_id" &
    load_pids+=("$!")
    printf 'load-worker\t%s\t%s\n' "$worker_id" "${load_pids[-1]}" >> "$RUN_DIR/pids.tsv"
  done
done
worker_wait_failures=0
for pid in "${load_pids[@]}"; do
  if ! wait "$pid"; then
    worker_wait_failures=$((worker_wait_failures + 1))
    : > "$RUN_DIR/failures/worker-process-$pid"
  fi
done
for pid in "${server_pids[@]}" "${client_pids[@]}"; do
  kill -0 "$pid" 2>/dev/null || : > "$RUN_DIR/failures/process-$pid"
done
snapshot_udp_counters end
finished_epoch=$(date +%s)
elapsed_seconds=$((finished_epoch - start_epoch))
request_no=$(awk -F '\t' 'NR>1 {n++} END {print n+0}' "$RUN_DIR/results.tsv")
failures=$(find "$RUN_DIR/failures" -type f -print | wc -l | tr -d '[:space:]')
completed_workers=$(find "$RUN_DIR/state" -maxdepth 1 -type f -name 'worker-*.done' -print | wc -l | tr -d '[:space:]')
expected_workers=$((3 * REQUEST_CONCURRENCY))
printf 'finished_epoch=%s\nelapsed_seconds=%s\nrequest_rounds=%s\nfailures=%s\nworker_wait_failures=%s\ncompleted_workers=%s\nexpected_workers=%s\n' \
  "$finished_epoch" "$elapsed_seconds" "$request_no" "$failures" "$worker_wait_failures" "$completed_workers" "$expected_workers" >> "$RUN_DIR/metadata.env"
pass_count=$(awk -F '\t' 'NR>1 && $7=="PASS" {n++} END {print n+0}' "$RUN_DIR/results.tsv")
fail_count=$(awk -F '\t' 'NR>1 && $7=="FAIL" {n++} END {print n+0}' "$RUN_DIR/results.tsv")
printf 'pass_count=%s\nfail_count=%s\n' "$pass_count" "$fail_count" >> "$RUN_DIR/metadata.env"
total_received_bytes=$(awk -F '\t' 'NR>1 && $7=="PASS" {bytes+=$5} END {printf "%.0f", bytes+0}' "$RUN_DIR/results.tsv")
((elapsed_seconds > 0)) || elapsed_seconds=1
aggregate_bytes_per_second=$((total_received_bytes / elapsed_seconds))
printf 'total_received_bytes=%s\naggregate_bytes_per_second=%s\n' \
  "$total_received_bytes" "$aggregate_bytes_per_second" >> "$RUN_DIR/metadata.env"
throughput_failure=0
for client in 1 2 3; do
  client_bytes=$(awk -F '\t' -v client="$client" 'NR>1 && $2==client && $7=="PASS" {bytes+=$5} END {printf "%.0f", bytes+0}' "$RUN_DIR/results.tsv")
  client_bytes_per_second=$((client_bytes / elapsed_seconds))
  printf 'client%s_received_bytes=%s\nclient%s_bytes_per_second=%s\n' \
    "$client" "$client_bytes" "$client" "$client_bytes_per_second" >> "$RUN_DIR/metadata.env"
  if ((client_bytes_per_second < MIN_CLIENT_BYTES_PER_SECOND)); then
    throughput_failure=1
  fi
done
if ((aggregate_bytes_per_second < MIN_AGGREGATE_BYTES_PER_SECOND)); then
  throughput_failure=1
fi

# Request artifacts are only headers/hashes/counters. Any large file here is a
# hard failure because it would indicate that an HTTP payload reached storage.
if find "$RUN_DIR/requests" -type f -size +1M -print -quit | grep -q .; then
  printf 'payload_file_detected=1\n' >> "$RUN_DIR/metadata.env"
  exit 1
fi
if [[ $ALLOW_SHORT_PREFLIGHT != 1 ]] && ((elapsed_seconds < DURATION_SECONDS)); then
  printf 'duration_gate_failed=1\n' >> "$RUN_DIR/metadata.env"
  exit 1
fi
if ((failures != 0 || fail_count != 0 || request_no == 0 || worker_wait_failures != 0 || completed_workers != expected_workers || throughput_failure != 0)); then exit 1; fi
printf 'status=PASS\n' >> "$RUN_DIR/metadata.env"
  printf '[local-3h-http] PASS run=%s rounds=%s requests=%s throughput_Bps=%s evidence=%s\n' \
  "$RUN_ID" "$request_no" "$pass_count" "$aggregate_bytes_per_second" "$RUN_DIR"
