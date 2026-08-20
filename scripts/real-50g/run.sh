#!/usr/bin/env bash

set -uo pipefail
umask 077

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT_DIR=$ROOT_DIR/scripts/real-50g
NATP2P_DIR=/root/natP2p
RUN_ID=${1:-real-50g-$(date -u +%Y%m%dT%H%M%SZ)}
[[ $RUN_ID =~ ^real-50g-[A-Za-z0-9_-]+$ ]] || {
  printf 'invalid run id\n' >&2
  exit 2
}

RESULTS_ROOT=$ROOT_DIR/test-results/$RUN_ID
PRIVATE_ROOT=$ROOT_DIR/.private-real-50g/$RUN_ID
KCP_BUFFER_STATE_FILE=$PRIVATE_ROOT/kcp-socket-buffers-before.env
BIN_DIR=$ROOT_DIR/bin/real-50g
RUN_LABEL=$RUN_ID
SHORT_ID=${RUN_ID#real-50g-}
CONTAINER_PREFIX=fkr50-${SHORT_ID,,}
NETWORK_NAME=$CONTAINER_PREFIX
CA_CONTAINER=$CONTAINER_PREFIX-ca
CA_LOCAL_URL=http://127.0.0.1:18088
CA_PUBLIC_URL=http://129.28.42.247:4006
INDEX_ADDRESS=193.112.62.9:9000
SERVER_RELAY_ADDRESS=198.2.237.123:8820
CLIENT_RELAY_ADDRESS=193.112.62.9:9000
DOCKER_SUBNET=10.230.65.0/24
LOCAL_TUNNEL_ADDRESS=10.230.65.1:18820
REMOTE_TUNNEL_ADDRESS=127.0.0.1:18820
REMOTE_DIR=/root/fknat-real50g-$SHORT_ID
UNIT_INDEX=fknat-real50g-${SHORT_ID}-client-index.service
UNIT_RELAY_SERVER=fknat-real50g-${SHORT_ID}-relay-server.service
UNIT_RELAY_TUNNEL=fknat-real50g-${SHORT_ID}-relay-tunnel.service
UNIT_LOCAL_TUNNEL=fknat-real50g-${SHORT_ID}-local-tunnel.service
BASE_IMAGE=bnfs-local-chaos:latest
MAIN_CA_CONTAINER=ca_web-backend-1
POSTGRES_CONTAINER=ca_web-postgres-1
NFT_SUFFIX=${SHORT_ID,,}
NFT_SUFFIX=${NFT_SUFFIX//-/_}
NFT_SUFFIX=${NFT_SUFFIX//[^a-z0-9_]/_}
NFT_TABLE=fknat_real50g_${NFT_SUFFIX:0:32}
SSH_KEY_COMMENT=fknat-real50g-$SHORT_ID
RELAY_TCP_PATH=${RELAY_TCP_PATH:-direct}
CONTAINER_PLACEMENT=${CONTAINER_PLACEMENT:-local}
ENDPOINT_TRANSPORT=${ENDPOINT_TRANSPORT:-dual}
ENDPOINT_SINGLE_TCP=${ENDPOINT_SINGLE_TCP:-0}
ENDPOINT_RUNTIME_TCP_WIDTH=${ENDPOINT_RUNTIME_TCP_WIDTH:-4}
RELAY_DISABLE_KCP=${RELAY_DISABLE_KCP:-0}
RELAY_BRIDGE_KCP=${RELAY_BRIDGE_KCP:-}
RELAY_BRIDGE_WIDTH=${RELAY_BRIDGE_WIDTH:-0}
REAL50G_PREFLIGHT_ONLY=${REAL50G_PREFLIGHT_ONLY:-0}
KCP_SOCKET_BUFFER_MAX=${KCP_SOCKET_BUFFER_MAX:-16777216}
outage_pid=""
monitor_pid=""
relay_resource_pid=""
cleaned=0
kcp_buffers_tuned=0
local_rmem_max_before=""
local_wmem_max_before=""
relay193_rmem_max_before=""
relay193_wmem_max_before=""
relay198_rmem_max_before=""
relay198_wmem_max_before=""
REMOTE_DOCKER_SOCKET=/run/fkr50-${SHORT_ID:0:24}.sock
REMOTE_DOCKER_HOST=unix://$REMOTE_DOCKER_SOCKET
REMOTE_SWAP_FILE=$REMOTE_DIR/real50g.swap
REMOTE_SWAP_BYTES=${REMOTE_SWAP_BYTES:-1073741824}
UNIT_DOCKER_193=fknat-real50g-${SHORT_ID}-docker.service
UNIT_DOCKER_198=fknat-real50g-${SHORT_ID}-docker.service
KCP_COPY_PORT=${KCP_COPY_PORT:-8899}
WORKLOAD_DEADLINE_SECONDS=${WORKLOAD_DEADLINE_SECONDS:-18000}
SERVER_RATE_MIBPS=${SERVER_RATE_MIBPS:-4}
SERVER_RATE_KIBPS=${SERVER_RATE_KIBPS:-0}
PREFLIGHT_SIZE_MIB=${PREFLIGHT_SIZE_MIB:-16}
PREFLIGHT_MAX_TIME_SECONDS=${PREFLIGHT_MAX_TIME_SECONDS:-300}
CLIENT_READY_TIMEOUT_SECONDS=${CLIENT_READY_TIMEOUT_SECONDS:-$((PREFLIGHT_MAX_TIME_SECONDS + 300))}
FILE_MAX_TIME_SECONDS=${FILE_MAX_TIME_SECONDS:-900}
UNIT_KCP_COPY_198=fknat-real50g-${SHORT_ID}-kcp-copy.service
DOCKER_RUNTIME_ARCHIVE=$BIN_DIR/docker-runtime.tar.gz
BASE_IMAGE_ARCHIVE=$BIN_DIR/bnfs-local-chaos.tar.gz
KCP_COPY_BINARY=$BIN_DIR/kcpcopy
KCP_COPY_ARCHIVE=$BIN_DIR/kcpcopy.gz

case $RELAY_TCP_PATH in
  direct|ssh) ;;
  *)
    printf 'invalid RELAY_TCP_PATH: %s (expected direct or ssh)\n' "$RELAY_TCP_PATH" >&2
    exit 2
    ;;
esac
case $CONTAINER_PLACEMENT in
  local|relay-hosts) ;;
  *)
    printf 'invalid CONTAINER_PLACEMENT: %s (expected local or relay-hosts)\n' "$CONTAINER_PLACEMENT" >&2
    exit 2
    ;;
esac
case $ENDPOINT_TRANSPORT in
  dual|tcp-only) ;;
  *)
    printf 'invalid ENDPOINT_TRANSPORT: %s (expected dual or tcp-only)\n' "$ENDPOINT_TRANSPORT" >&2
    exit 2
    ;;
esac
case $REAL50G_PREFLIGHT_ONLY in
  0|1) ;;
  *)
    printf 'invalid REAL50G_PREFLIGHT_ONLY: %s (expected 0 or 1)\n' "$REAL50G_PREFLIGHT_ONLY" >&2
    exit 2
    ;;
esac
case $ENDPOINT_SINGLE_TCP in
  0|1) ;;
  *)
    printf 'invalid ENDPOINT_SINGLE_TCP: %s (expected 0 or 1)\n' "$ENDPOINT_SINGLE_TCP" >&2
    exit 2
    ;;
esac
[[ $ENDPOINT_RUNTIME_TCP_WIDTH =~ ^[2-8]$ ]] || {
  printf 'invalid ENDPOINT_RUNTIME_TCP_WIDTH: %s (expected 2-8)\n' "$ENDPOINT_RUNTIME_TCP_WIDTH" >&2
  exit 2
}
[[ $KCP_SOCKET_BUFFER_MAX =~ ^[0-9]+$ ]] && ((KCP_SOCKET_BUFFER_MAX >= 1048576)) || {
  printf 'invalid KCP_SOCKET_BUFFER_MAX: %s (expected integer >= 1048576)\n' "$KCP_SOCKET_BUFFER_MAX" >&2
  exit 2
}
[[ $KCP_COPY_PORT =~ ^[0-9]+$ ]] && ((KCP_COPY_PORT >= 8000 && KCP_COPY_PORT <= 9000)) || {
  printf 'invalid KCP_COPY_PORT: %s (expected 8000-9000)\n' "$KCP_COPY_PORT" >&2
  exit 2
}
[[ $WORKLOAD_DEADLINE_SECONDS =~ ^[0-9]+$ ]] && ((WORKLOAD_DEADLINE_SECONDS >= 10800)) || {
  printf 'invalid WORKLOAD_DEADLINE_SECONDS: %s (expected integer >= 10800)\n' "$WORKLOAD_DEADLINE_SECONDS" >&2
  exit 2
}
[[ $SERVER_RATE_MIBPS =~ ^[0-9]+$ ]] && ((SERVER_RATE_MIBPS <= 1024)) || {
  printf 'invalid SERVER_RATE_MIBPS: %s (expected integer 0-1024)\n' "$SERVER_RATE_MIBPS" >&2
  exit 2
}
[[ $SERVER_RATE_KIBPS =~ ^[0-9]+$ ]] && ((SERVER_RATE_KIBPS <= 1048576)) || {
  printf 'invalid SERVER_RATE_KIBPS: %s (expected integer 0-1048576)\n' "$SERVER_RATE_KIBPS" >&2
  exit 2
}
[[ $PREFLIGHT_SIZE_MIB =~ ^[0-9]+$ ]] && ((PREFLIGHT_SIZE_MIB >= 1 && PREFLIGHT_SIZE_MIB <= 200)) || {
  printf 'invalid PREFLIGHT_SIZE_MIB: %s (expected integer 1-200)\n' "$PREFLIGHT_SIZE_MIB" >&2
  exit 2
}
[[ $PREFLIGHT_MAX_TIME_SECONDS =~ ^[0-9]+$ ]] && ((PREFLIGHT_MAX_TIME_SECONDS >= 60 && PREFLIGHT_MAX_TIME_SECONDS <= 21600)) || {
  printf 'invalid PREFLIGHT_MAX_TIME_SECONDS: %s (expected integer 60-21600)\n' "$PREFLIGHT_MAX_TIME_SECONDS" >&2
  exit 2
}
[[ $CLIENT_READY_TIMEOUT_SECONDS =~ ^[0-9]+$ ]] && ((CLIENT_READY_TIMEOUT_SECONDS >= PREFLIGHT_MAX_TIME_SECONDS)) || {
  printf 'invalid CLIENT_READY_TIMEOUT_SECONDS: %s (expected integer >= PREFLIGHT_MAX_TIME_SECONDS)\n' "$CLIENT_READY_TIMEOUT_SECONDS" >&2
  exit 2
}
[[ $FILE_MAX_TIME_SECONDS =~ ^[0-9]+$ ]] && ((FILE_MAX_TIME_SECONDS >= 900 && FILE_MAX_TIME_SECONDS <= 86400)) || {
  printf 'invalid FILE_MAX_TIME_SECONDS: %s (expected integer 900-86400)\n' "$FILE_MAX_TIME_SECONDS" >&2
  exit 2
}
[[ $REMOTE_SWAP_BYTES =~ ^[0-9]+$ ]] && ((REMOTE_SWAP_BYTES >= 536870912)) || {
  printf 'invalid REMOTE_SWAP_BYTES: %s (expected integer >= 536870912)\n' "$REMOTE_SWAP_BYTES" >&2
  exit 2
}
case $RELAY_DISABLE_KCP in
  0|1) ;;
  *)
    printf 'invalid RELAY_DISABLE_KCP: %s (expected 0 or 1)\n' "$RELAY_DISABLE_KCP" >&2
    exit 2
    ;;
esac
if [[ -z $RELAY_BRIDGE_KCP ]]; then
  if [[ $RELAY_DISABLE_KCP == 1 ]]; then
    RELAY_BRIDGE_KCP=0
  else
    RELAY_BRIDGE_KCP=1
  fi
fi
case $RELAY_BRIDGE_KCP in
  0|1) ;;
  *)
    printf 'invalid RELAY_BRIDGE_KCP: %s (expected 0 or 1)\n' "$RELAY_BRIDGE_KCP" >&2
    exit 2
    ;;
esac
if [[ $RELAY_DISABLE_KCP == 1 && $RELAY_BRIDGE_KCP == 1 ]]; then
  printf 'RELAY_BRIDGE_KCP=1 requires RELAY_DISABLE_KCP=0\n' >&2
  exit 2
fi
[[ $RELAY_BRIDGE_WIDTH =~ ^[0-8]$ ]] || {
  printf 'invalid RELAY_BRIDGE_WIDTH: %s (expected 0-8; 0=auto)\n' "$RELAY_BRIDGE_WIDTH" >&2
  exit 2
}

TUNNEL_PUMP_BUF=${TUNNEL_PUMP_BUF:-1048576}
TUNNEL_COALESCE_MS=${TUNNEL_COALESCE_MS:-250}
TUNNEL_MAX_CHUNK=${TUNNEL_MAX_CHUNK:-65536}
TUNNEL_STREAM_SEND_WINDOW=${TUNNEL_STREAM_SEND_WINDOW:-32}
TUNNEL_SEND_WINDOW=${TUNNEL_SEND_WINDOW:-128}
BNFS_MAX_PENDING_BILLING_DATA_SENDS=${BNFS_MAX_PENDING_BILLING_DATA_SENDS:-16}

if [[ -e $RESULTS_ROOT || -e $PRIVATE_ROOT ]]; then
  printf 'run path already exists: %s\n' "$RUN_ID" >&2
  exit 2
fi
mkdir -p "$RESULTS_ROOT" "$PRIVATE_ROOT" "$BIN_DIR"
chmod 700 "$PRIVATE_ROOT"
printf 'initializing\n' > "$RESULTS_ROOT/phase"

log() {
  printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$RESULTS_ROOT/orchestrator.log"
}

phase() {
  printf '%s\n' "$1" > "$RESULTS_ROOT/phase"
  log "phase=$1"
}

metadata() {
  printf '%s=%s\n' "$1" "$2" >> "$RESULTS_ROOT/metadata.env"
}

json_number() {
  local key=$1 fallback=$2 value
  value=$(sed -n "s/.*\"$key\":\([0-9][0-9]*\).*/\\1/p" | head -n 1)
  if [[ $value =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

ssh198() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 -p 30811 root@198.2.237.123 "$@"
}

ssh193() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 server4 "$@"
}

docker193() {
  local quoted
  printf -v quoted '%q ' "$@"
  ssh193 "DOCKER_HOST='$REMOTE_DOCKER_HOST' '$REMOTE_DIR/docker-bin/docker' $quoted"
}

docker198() {
  local quoted
  printf -v quoted '%q ' "$@"
  ssh198 "DOCKER_HOST='$REMOTE_DOCKER_HOST' '$REMOTE_DIR/docker-bin/docker' $quoted"
}

wait_tcp() {
  local host=$1 port=$2 timeout_seconds=$3 start
  start=$(date +%s)
  while (( $(date +%s) - start < timeout_seconds )); do
    if timeout 3 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_http() {
  local url=$1 timeout_seconds=$2 start
  start=$(date +%s)
  while (( $(date +%s) - start < timeout_seconds )); do
    curl -fsS --max-time 5 "$url/readyz" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

stop_background() {
  if [[ -z $outage_pid && -f $RESULTS_ROOT/control/outage.pid ]]; then
    outage_pid=$(cat "$RESULTS_ROOT/control/outage.pid" 2>/dev/null || true)
  fi
  if [[ -z $monitor_pid && -f $RESULTS_ROOT/control/monitor.pid ]]; then
    monitor_pid=$(cat "$RESULTS_ROOT/control/monitor.pid" 2>/dev/null || true)
  fi
  if [[ -z $relay_resource_pid && -f $RESULTS_ROOT/control/relay-resource-monitor.pid ]]; then
    relay_resource_pid=$(cat "$RESULTS_ROOT/control/relay-resource-monitor.pid" 2>/dev/null || true)
  fi
  if [[ -n $outage_pid ]]; then
    kill "$outage_pid" 2>/dev/null || true
    wait "$outage_pid" 2>/dev/null || true
    outage_pid=""
  fi
  if [[ -n $monitor_pid ]]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    monitor_pid=""
  fi
  if [[ -n $relay_resource_pid ]]; then
    kill "$relay_resource_pid" 2>/dev/null || true
    wait "$relay_resource_pid" 2>/dev/null || true
    relay_resource_pid=""
  fi
}

tune_kcp_socket_buffers() {
  if [[ $ENDPOINT_TRANSPORT != dual && $RELAY_BRIDGE_KCP != 1 ]]; then
    return 0
  fi
  local_rmem_max_before=$(sysctl -n net.core.rmem_max)
  local_wmem_max_before=$(sysctl -n net.core.wmem_max)
  relay193_rmem_max_before=$(ssh193 "sysctl -n net.core.rmem_max")
  relay193_wmem_max_before=$(ssh193 "sysctl -n net.core.wmem_max")
  relay198_rmem_max_before=$(ssh198 "sysctl -n net.core.rmem_max")
  relay198_wmem_max_before=$(ssh198 "sysctl -n net.core.wmem_max")
  printf '%s\n' \
    "local_rmem_max_before=$local_rmem_max_before" \
    "local_wmem_max_before=$local_wmem_max_before" \
    "relay193_rmem_max_before=$relay193_rmem_max_before" \
    "relay193_wmem_max_before=$relay193_wmem_max_before" \
    "relay198_rmem_max_before=$relay198_rmem_max_before" \
    "relay198_wmem_max_before=$relay198_wmem_max_before" \
    > "$KCP_BUFFER_STATE_FILE"
  chmod 600 "$KCP_BUFFER_STATE_FILE"
  kcp_buffers_tuned=1

  sysctl -w "net.core.rmem_max=$KCP_SOCKET_BUFFER_MAX" >/dev/null
  sysctl -w "net.core.wmem_max=$KCP_SOCKET_BUFFER_MAX" >/dev/null
  ssh193 "sysctl -w 'net.core.rmem_max=$KCP_SOCKET_BUFFER_MAX' >/dev/null; sysctl -w 'net.core.wmem_max=$KCP_SOCKET_BUFFER_MAX' >/dev/null"
  ssh198 "sysctl -w 'net.core.rmem_max=$KCP_SOCKET_BUFFER_MAX' >/dev/null; sysctl -w 'net.core.wmem_max=$KCP_SOCKET_BUFFER_MAX' >/dev/null"

  metadata kcp_socket_buffer_max "$KCP_SOCKET_BUFFER_MAX"
  metadata local_rmem_max_before "$local_rmem_max_before"
  metadata local_wmem_max_before "$local_wmem_max_before"
  metadata relay193_rmem_max_before "$relay193_rmem_max_before"
  metadata relay193_wmem_max_before "$relay193_wmem_max_before"
  metadata relay198_rmem_max_before "$relay198_rmem_max_before"
  metadata relay198_wmem_max_before "$relay198_wmem_max_before"
  log "KCP socket buffer maxima tuned local/193/198 target=$KCP_SOCKET_BUFFER_MAX"
}

restore_kcp_socket_buffers() {
  if ((kcp_buffers_tuned == 0)) && [[ -f $KCP_BUFFER_STATE_FILE ]]; then
    while IFS='=' read -r key value; do
      case $key in
        local_rmem_max_before) local_rmem_max_before=$value ;;
        local_wmem_max_before) local_wmem_max_before=$value ;;
        relay193_rmem_max_before) relay193_rmem_max_before=$value ;;
        relay193_wmem_max_before) relay193_wmem_max_before=$value ;;
        relay198_rmem_max_before) relay198_rmem_max_before=$value ;;
        relay198_wmem_max_before) relay198_wmem_max_before=$value ;;
      esac
    done < "$KCP_BUFFER_STATE_FILE"
    kcp_buffers_tuned=1
  fi
  ((kcp_buffers_tuned == 1)) || return 0
  if [[ $local_rmem_max_before =~ ^[0-9]+$ ]]; then
    sysctl -w "net.core.rmem_max=$local_rmem_max_before" >/dev/null 2>&1 || true
  fi
  if [[ $local_wmem_max_before =~ ^[0-9]+$ ]]; then
    sysctl -w "net.core.wmem_max=$local_wmem_max_before" >/dev/null 2>&1 || true
  fi
  if [[ $relay193_rmem_max_before =~ ^[0-9]+$ && $relay193_wmem_max_before =~ ^[0-9]+$ ]]; then
    ssh193 "sysctl -w 'net.core.rmem_max=$relay193_rmem_max_before' >/dev/null 2>&1 || true; sysctl -w 'net.core.wmem_max=$relay193_wmem_max_before' >/dev/null 2>&1 || true" || true
  fi
  if [[ $relay198_rmem_max_before =~ ^[0-9]+$ && $relay198_wmem_max_before =~ ^[0-9]+$ ]]; then
    ssh198 "sysctl -w 'net.core.rmem_max=$relay198_rmem_max_before' >/dev/null 2>&1 || true; sysctl -w 'net.core.wmem_max=$relay198_wmem_max_before' >/dev/null 2>&1 || true" || true
  fi
  kcp_buffers_tuned=0
}

collect_artifacts() {
  sync_remote_container_results
  collect_remote_container_logs
  mkdir -p "$RESULTS_ROOT/remote"
  ssh193 "journalctl -u '$UNIT_INDEX' --no-pager -o short-iso" > "$RESULTS_ROOT/remote/relay-client-index.log" 2>&1 || true
  ssh198 "journalctl -u '$UNIT_RELAY_SERVER' --no-pager -o short-iso" > "$RESULTS_ROOT/remote/relay-server.log" 2>&1 || true
  ssh198 "journalctl -u '$UNIT_KCP_COPY_198' --no-pager -o short-iso" > "$RESULTS_ROOT/remote/kcp-copy-deployment.log" 2>&1 || true
  if [[ $RELAY_TCP_PATH == ssh ]]; then
    nft list table ip "$NFT_TABLE" > "$RESULTS_ROOT/protocol-routing-local.nft" 2>&1 || true
    ssh193 "nft list table ip '$NFT_TABLE'" > "$RESULTS_ROOT/remote/protocol-routing-193.nft" 2>&1 || true
    ssh193 "journalctl -u '$UNIT_RELAY_TUNNEL' --no-pager -o short-iso" > "$RESULTS_ROOT/remote/relay-tunnel.log" 2>&1 || true
    journalctl -u "$UNIT_LOCAL_TUNNEL" --no-pager -o short-iso > "$RESULTS_ROOT/local-tunnel.log" 2>&1 || true
  fi
  ssh193 "'$REMOTE_DIR/billingqueue-inspect' -path '$REMOTE_DIR/relay-client-index.waitsubmit'" > "$RESULTS_ROOT/remote/relay-client-index-queue-final.json" 2>/dev/null || true
  ssh198 "'$REMOTE_DIR/billingqueue-inspect' -path '$REMOTE_DIR/relay-server.waitsubmit'" > "$RESULTS_ROOT/remote/relay-server-queue-final.json" 2>/dev/null || true
  if [[ $CONTAINER_PLACEMENT == local ]]; then
    local name
    for name in $(docker ps -a --filter "label=fknat.real50g.run=$RUN_LABEL" --format '{{.Names}}'); do
      docker logs "$name" > "$RESULTS_ROOT/${name}.docker.log" 2>&1 || true
    done
  fi
}

cleanup() {
  ((cleaned == 0)) || return 0
  cleaned=1
  phase cleanup
  stop_background
  sync_remote_container_results
  collect_remote_container_logs
  stop_remote_container_runtime
  docker start "$CA_CONTAINER" >/dev/null 2>&1 || true
  local containers
  containers=$(docker ps -aq --filter "label=fknat.real50g.run=$RUN_LABEL")
  if [[ -n $containers ]]; then
    docker rm -f $containers >/dev/null 2>&1 || true
  fi
  docker rm -f "$CA_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  ssh193 "systemctl stop '$UNIT_INDEX' >/dev/null 2>&1 || true; systemctl reset-failed '$UNIT_INDEX' >/dev/null 2>&1 || true" || true
  ssh198 "systemctl stop '$UNIT_RELAY_SERVER' >/dev/null 2>&1 || true; systemctl reset-failed '$UNIT_RELAY_SERVER' >/dev/null 2>&1 || true" || true
  ssh198 "systemctl stop '$UNIT_KCP_COPY_198' >/dev/null 2>&1 || true; systemctl reset-failed '$UNIT_KCP_COPY_198' >/dev/null 2>&1 || true" || true
  ssh198 "if swapon --show=NAME --noheadings | grep -Fxq '$REMOTE_SWAP_FILE'; then swapoff '$REMOTE_SWAP_FILE' || true; fi" || true
  restore_kcp_socket_buffers
  if [[ $RELAY_TCP_PATH == ssh ]]; then
    systemctl stop "$UNIT_LOCAL_TUNNEL" >/dev/null 2>&1 || true
    systemctl reset-failed "$UNIT_LOCAL_TUNNEL" >/dev/null 2>&1 || true
    ssh193 "systemctl stop '$UNIT_RELAY_TUNNEL' >/dev/null 2>&1 || true; systemctl reset-failed '$UNIT_RELAY_TUNNEL' >/dev/null 2>&1 || true; nft delete table ip '$NFT_TABLE' >/dev/null 2>&1 || true" || true
    ssh198 "if test -f /root/.ssh/authorized_keys; then sed -i '\| $SSH_KEY_COMMENT$|d' /root/.ssh/authorized_keys; fi" || true
    nft delete table ip "$NFT_TABLE" >/dev/null 2>&1 || true
  fi
  if [[ $REMOTE_DIR == /root/fknat-real50g-* ]]; then
    ssh198 "rm -rf -- '$REMOTE_DIR'" || true
    ssh193 "rm -rf -- '$REMOTE_DIR'" || true
  fi
  if [[ $PRIVATE_ROOT == "$ROOT_DIR/.private-real-50g/"* && $PRIVATE_ROOT != "$ROOT_DIR/.private-real-50g/" ]]; then
    rm -rf -- "$PRIVATE_ROOT"
  fi
  printf 'cleaned\n' > "$RESULTS_ROOT/cleanup.status"
}

# 主流程可能在长时间传输、CA 故障窗口或远端命令中被中断。无论正常退出还是收到
# INT/TERM/HUP，都必须经过同一个幂等清理入口，避免遗留容器、Relay、swap 和 sysctl。
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

configure_protocol_routing() {
  phase protocol-routing
  if [[ $RELAY_TCP_PATH == direct ]]; then
    log "protocol routing uses public direct TCP/UDP server_relay=$SERVER_RELAY_ADDRESS"
    return 0
  fi
  if nft list table ip "$NFT_TABLE" >/dev/null 2>&1; then
    log "refusing to replace existing local nft table=$NFT_TABLE"
    return 1
  fi
  if ssh193 "nft list table ip '$NFT_TABLE' >/dev/null 2>&1"; then
    log "refusing to replace existing 193 nft table=$NFT_TABLE"
    return 1
  fi

  nft add table ip "$NFT_TABLE"
  nft "add chain ip $NFT_TABLE prerouting { type nat hook prerouting priority -110; policy accept; }"
  nft add rule ip "$NFT_TABLE" prerouting \
    ip saddr "$DOCKER_SUBNET" ip daddr 198.2.237.123 tcp dport 8820 \
    counter dnat to "$LOCAL_TUNNEL_ADDRESS"

  ssh193 \
    "nft add table ip '$NFT_TABLE'; nft 'add chain ip $NFT_TABLE output { type nat hook output priority -110; policy accept; }'; nft add rule ip '$NFT_TABLE' output ip daddr 198.2.237.123 tcp dport 8820 counter dnat to '$REMOTE_TUNNEL_ADDRESS'"
  log "protocol split installed udp=198.2.237.123:8820 local_tcp=$LOCAL_TUNNEL_ADDRESS remote_tcp=$REMOTE_TUNNEL_ADDRESS subnet=$DOCKER_SUBNET"
}

build_artifacts() {
  phase build
  log "running fknat unit tests"
  (cd "$ROOT_DIR" && go test ./...)
  log "running focused natP2p helper tests"
  (cd "$NATP2P_DIR" && go test ./test/testCode/tunnel/httpfileserver ./billingqueue)
  (cd "$ROOT_DIR" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$RUN_ID" -o "$ROOT_DIR/bin/fknat" .)
  (cd "$NATP2P_DIR" && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o "$BIN_DIR/nodeserver" ./test/testCode/tunnel/nodeserver)
  (cd "$NATP2P_DIR" && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o "$BIN_DIR/httpfileserver" ./test/testCode/tunnel/httpfileserver)
  (cd "$NATP2P_DIR" && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o "$BIN_DIR/billingqueue-inspect" ./test/testCode/billingqueue-inspect)
  (cd "$ROOT_DIR" && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o "$KCP_COPY_BINARY" ./cmd/kcpcopy)
  chmod 755 "$ROOT_DIR/bin/fknat" "$BIN_DIR/nodeserver" "$BIN_DIR/httpfileserver" "$BIN_DIR/billingqueue-inspect" "$KCP_COPY_BINARY"
  gzip -9 -c "$BIN_DIR/nodeserver" > "$BIN_DIR/nodeserver.gz"
  gzip -9 -c "$BIN_DIR/billingqueue-inspect" > "$BIN_DIR/billingqueue-inspect.gz"
  gzip -9 -c "$KCP_COPY_BINARY" > "$KCP_COPY_ARCHIVE"
  if [[ $CONTAINER_PLACEMENT == relay-hosts ]]; then
    for runtime_binary in docker dockerd containerd containerd-shim-runc-v2 runc; do
      command -v "$runtime_binary" >/dev/null
    done
    tar -C /usr/bin -czf "$DOCKER_RUNTIME_ARCHIVE" \
      docker dockerd containerd containerd-shim-runc-v2 runc
    docker image inspect "$BASE_IMAGE" >/dev/null
    docker save "$BASE_IMAGE" | gzip -1 > "$BASE_IMAGE_ARCHIVE"
    metadata docker_runtime_sha256 "$(sha256sum "$DOCKER_RUNTIME_ARCHIVE" | awk '{print $1}')"
    metadata base_image_archive_sha256 "$(sha256sum "$BASE_IMAGE_ARCHIVE" | awk '{print $1}')"
    metadata kcp_copy_sha256 "$(sha256sum "$KCP_COPY_BINARY" | awk '{print $1}')"
  fi
  metadata fknat_sha256 "$(sha256sum "$ROOT_DIR/bin/fknat" | awk '{print $1}')"
  metadata nodeserver_sha256 "$(sha256sum "$BIN_DIR/nodeserver" | awk '{print $1}')"
  metadata httpfileserver_sha256 "$(sha256sum "$BIN_DIR/httpfileserver" | awk '{print $1}')"
}

prepare_remote_container_runtime() {
  [[ $CONTAINER_PLACEMENT == relay-hosts ]] || return 0
  log "preparing temporary Docker daemons on relay hosts"
  ssh193 "mkdir -p '$REMOTE_DIR/docker-bin' '$REMOTE_DIR/docker-data' '$REMOTE_DIR/docker-exec' '$REMOTE_DIR/containers' '$REMOTE_DIR/state' '$REMOTE_DIR/results' '$REMOTE_DIR/plans' '$REMOTE_DIR/control'"
  ssh198 "mkdir -p '$REMOTE_DIR/docker-bin' '$REMOTE_DIR/docker-data' '$REMOTE_DIR/docker-exec' '$REMOTE_DIR/containers' '$REMOTE_DIR/state' '$REMOTE_DIR/results' '$REMOTE_DIR/control'"
  ssh198 "fallocate -l '$REMOTE_SWAP_BYTES' '$REMOTE_SWAP_FILE'; chmod 600 '$REMOTE_SWAP_FILE'; mkswap '$REMOTE_SWAP_FILE' >/dev/null; swapon '$REMOTE_SWAP_FILE'"

  scp -q "$DOCKER_RUNTIME_ARCHIVE" "$BASE_IMAGE_ARCHIVE" "$KCP_COPY_ARCHIVE" \
    "$ROOT_DIR/bin/fknat" "$BIN_DIR/httpfileserver" \
    "$SCRIPT_DIR/client-entrypoint.sh" "$SCRIPT_DIR/client-worker.sh" "$SCRIPT_DIR/server-entrypoint.sh" \
    "server4:$REMOTE_DIR/containers/"
  scp -q -P 30811 "$KCP_COPY_ARCHIVE" "root@198.2.237.123:$REMOTE_DIR/containers/"
  ssh193 "gzip -df '$REMOTE_DIR/containers/$(basename "$KCP_COPY_ARCHIVE")'; chmod 700 '$REMOTE_DIR/containers/$(basename "$KCP_COPY_BINARY")'"
  ssh198 "gzip -df '$REMOTE_DIR/containers/$(basename "$KCP_COPY_ARCHIVE")'; chmod 700 '$REMOTE_DIR/containers/$(basename "$KCP_COPY_BINARY")'"

  local deploy_key copy_ready=0 copy_result filename expected actual
  deploy_key=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  [[ $deploy_key =~ ^[0-9a-f]{64}$ ]]
  ssh198 systemd-run --unit="$UNIT_KCP_COPY_198" --property=KillMode=mixed --property=TimeoutStopSec=10s \
    "$REMOTE_DIR/containers/$(basename "$KCP_COPY_BINARY")" -mode receive \
    -address ":$KCP_COPY_PORT" -destination "$REMOTE_DIR/containers" -key-hex "$deploy_key" >/dev/null
  for _ in $(seq 1 30); do
    if ssh198 "ss -lun | grep -q ':$KCP_COPY_PORT '"; then
      copy_ready=1
      break
    fi
    sleep 1
  done
  [[ $copy_ready == 1 ]]
  ssh193 "'$REMOTE_DIR/containers/$(basename "$KCP_COPY_BINARY")' -mode send -address '198.2.237.123:$KCP_COPY_PORT' -key-hex '$deploy_key' \
    '$REMOTE_DIR/containers/$(basename "$DOCKER_RUNTIME_ARCHIVE")' \
    '$REMOTE_DIR/containers/$(basename "$BASE_IMAGE_ARCHIVE")' \
    '$REMOTE_DIR/containers/fknat' '$REMOTE_DIR/containers/httpfileserver' \
    '$REMOTE_DIR/containers/server-entrypoint.sh'"
  copy_result=$(ssh198 "systemctl show '$UNIT_KCP_COPY_198' -p Result --value")
  [[ $copy_result == success ]]
  for filename in "$(basename "$DOCKER_RUNTIME_ARCHIVE")" "$(basename "$BASE_IMAGE_ARCHIVE")" fknat httpfileserver server-entrypoint.sh; do
    expected=$(ssh193 "sha256sum '$REMOTE_DIR/containers/$filename'" | awk '{print $1}')
    actual=$(ssh198 "sha256sum '$REMOTE_DIR/containers/$filename'" | awk '{print $1}')
    [[ $expected =~ ^[0-9a-f]{64}$ && $actual == "$expected" ]]
  done
  log "temporary runtime payload copied 193->198 over authenticated KCP port=$KCP_COPY_PORT"

  scp -q -r "$PRIVATE_ROOT"/client-* "server4:$REMOTE_DIR/state/"
  scp -q -P 30811 -r "$PRIVATE_ROOT"/server-* "root@198.2.237.123:$REMOTE_DIR/state/"
  scp -q "$RESULTS_ROOT"/plans/client-*.tsv "server4:$REMOTE_DIR/plans/"

  ssh193 "tar -xzf '$REMOTE_DIR/containers/$(basename "$DOCKER_RUNTIME_ARCHIVE")' -C '$REMOTE_DIR/docker-bin'; chmod 700 '$REMOTE_DIR/docker-bin/'* '$REMOTE_DIR/containers/fknat'; chmod 600 '$REMOTE_DIR/state/'*/billing-key.json"
  ssh198 "tar -xzf '$REMOTE_DIR/containers/$(basename "$DOCKER_RUNTIME_ARCHIVE")' -C '$REMOTE_DIR/docker-bin'; chmod 700 '$REMOTE_DIR/docker-bin/'* '$REMOTE_DIR/containers/fknat' '$REMOTE_DIR/containers/httpfileserver'; chmod 600 '$REMOTE_DIR/state/'*/billing-key.json"

  ssh193 systemd-run --unit="$UNIT_DOCKER_193" --property=KillMode=mixed --property=TimeoutStopSec=20s \
    --setenv=PATH="$REMOTE_DIR/docker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$REMOTE_DIR/docker-bin/dockerd" --host="$REMOTE_DOCKER_HOST" \
    --data-root="$REMOTE_DIR/docker-data" --exec-root="$REMOTE_DIR/docker-exec" \
    --pidfile="$REMOTE_DIR/docker.pid" --bridge=none --iptables=false --ip-forward=false \
    --ip-masq=false --userland-proxy=false --log-level=error >/dev/null
  ssh198 systemd-run --unit="$UNIT_DOCKER_198" --property=KillMode=mixed --property=TimeoutStopSec=20s \
    --setenv=PATH="$REMOTE_DIR/docker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$REMOTE_DIR/docker-bin/dockerd" --host="$REMOTE_DOCKER_HOST" \
    --data-root="$REMOTE_DIR/docker-data" --exec-root="$REMOTE_DIR/docker-exec" \
    --pidfile="$REMOTE_DIR/docker.pid" --bridge=none --iptables=false --ip-forward=false \
    --ip-masq=false --userland-proxy=false --log-level=error >/dev/null

  local ready193=0 ready198=0
  for _ in $(seq 1 90); do
    docker193 info >/dev/null 2>&1 && ready193=1
    docker198 info >/dev/null 2>&1 && ready198=1
    [[ $ready193 == 1 && $ready198 == 1 ]] && break
    sleep 1
  done
  [[ $ready193 == 1 && $ready198 == 1 ]]
  docker193 load -i "$REMOTE_DIR/containers/$(basename "$BASE_IMAGE_ARCHIVE")" >/dev/null
  docker198 load -i "$REMOTE_DIR/containers/$(basename "$BASE_IMAGE_ARCHIVE")" >/dev/null
  docker193 image inspect "$BASE_IMAGE" >/dev/null
  docker198 image inspect "$BASE_IMAGE" >/dev/null
  log "temporary Docker daemons ready on 193 and 198"
}

sync_remote_container_results() {
  [[ $CONTAINER_PLACEMENT == relay-hosts ]] || return 0
  mkdir -p "$RESULTS_ROOT"
  ssh193 "tar -C '$REMOTE_DIR/results' --ignore-failed-read --exclude='*/current.bin' --exclude='*/current.metrics' --exclude='*/current.error' -czf - ." 2>/dev/null | tar -C "$RESULTS_ROOT" -xzf - 2>/dev/null || true
  ssh198 "tar -C '$REMOTE_DIR/results' --ignore-failed-read --exclude='*/current.bin' --exclude='*/current.metrics' --exclude='*/current.error' -czf - ." 2>/dev/null | tar -C "$RESULTS_ROOT" -xzf - 2>/dev/null || true
}

collect_remote_container_logs() {
  [[ $CONTAINER_PLACEMENT == relay-hosts ]] || return 0
  local name
  for name in $(docker193 ps -a --filter "label=fknat.real50g.run=$RUN_LABEL" --format '{{.Names}}' 2>/dev/null); do
    docker193 logs "$name" > "$RESULTS_ROOT/${name}.docker.log" 2>&1 || true
  done
  for name in $(docker198 ps -a --filter "label=fknat.real50g.run=$RUN_LABEL" --format '{{.Names}}' 2>/dev/null); do
    docker198 logs "$name" > "$RESULTS_ROOT/${name}.docker.log" 2>&1 || true
  done
}

stop_remote_container_runtime() {
  [[ $CONTAINER_PLACEMENT == relay-hosts ]] || return 0
  local containers
  containers=$(docker193 ps -aq --filter "label=fknat.real50g.run=$RUN_LABEL" 2>/dev/null || true)
  [[ -z $containers ]] || docker193 rm -f $containers >/dev/null 2>&1 || true
  containers=$(docker198 ps -aq --filter "label=fknat.real50g.run=$RUN_LABEL" 2>/dev/null || true)
  [[ -z $containers ]] || docker198 rm -f $containers >/dev/null 2>&1 || true
  ssh193 "systemctl stop '$UNIT_DOCKER_193' >/dev/null 2>&1 || true; systemctl reset-failed '$UNIT_DOCKER_193' >/dev/null 2>&1 || true; find /run -maxdepth 1 -type s -name '$(basename "$REMOTE_DOCKER_SOCKET")' -delete 2>/dev/null || true; if mountpoint -q '$REMOTE_DIR/docker-exec/netns/default'; then umount '$REMOTE_DIR/docker-exec/netns/default' || true; fi" || true
  ssh198 "systemctl stop '$UNIT_DOCKER_198' >/dev/null 2>&1 || true; systemctl reset-failed '$UNIT_DOCKER_198' >/dev/null 2>&1 || true; find /run -maxdepth 1 -type s -name '$(basename "$REMOTE_DOCKER_SOCKET")' -delete 2>/dev/null || true; if mountpoint -q '$REMOTE_DIR/docker-exec/netns/default'; then umount '$REMOTE_DIR/docker-exec/netns/default' || true; fi" || true
}

prepare_fixture_and_ca() {
  phase ca-bootstrap
  node "$SCRIPT_DIR/generate-fixture.mjs" "$PRIVATE_ROOT" "$RESULTS_ROOT" "$MAIN_CA_CONTAINER"
  if [[ $RELAY_TCP_PATH == ssh ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "$SSH_KEY_COMMENT" -f "$PRIVATE_ROOT/relay-tunnel.key"
    ssh-keyscan -T 10 -p 30811 198.2.237.123 > "$PRIVATE_ROOT/relay-tunnel.known_hosts" 2>/dev/null
    chmod 600 "$PRIVATE_ROOT/relay-tunnel.key" "$PRIVATE_ROOT/relay-tunnel.known_hosts"
  fi
  docker cp "$MAIN_CA_CONTAINER:/data/admin.token" "$PRIVATE_ROOT/ca/admin.token"
  chmod 600 "$PRIVATE_ROOT/ca/admin.token"
  docker run -d \
    --name "$CA_CONTAINER" \
    --network ca_web_default \
    --volumes-from "$MAIN_CA_CONTAINER" \
    --env-file "$PRIVATE_ROOT/ca/backend.env" \
    -e "CA_LOG_DIRECTORY=/data/logs/real50g-$SHORT_ID" \
    -p 127.0.0.1:18088:8090 \
    ca_web-backend:latest >/dev/null
  wait_http "$CA_LOCAL_URL" 90
  wait_http "$CA_PUBLIC_URL" 90
  PRIVATE_RUNTIME_DIR=$PRIVATE_ROOT \
    CA_BASE_URL=$CA_LOCAL_URL \
    CA_ADMIN_TOKEN_FILE=$PRIVATE_ROOT/ca/admin.token \
    BNFS_CHAOS_EXTERNAL_CA_POSTGRES_CONTAINER=$POSTGRES_CONTAINER \
    bash "$NATP2P_DIR/test/runtimeScript/local-chaos/bootstrap-external-ca.sh"
  node "$SCRIPT_DIR/capture-billing.mjs" "$PRIVATE_ROOT/ca/billing-key-bootstrap.json" \
    "$RESULTS_ROOT/billing-before.tsv" "$POSTGRES_CONTAINER"
}

deploy_remote_nodes() {
  phase remote-deploy
  ssh198 "mkdir -p '$REMOTE_DIR/logs'; chmod 700 '$REMOTE_DIR'"
  ssh193 "mkdir -p '$REMOTE_DIR/logs'; chmod 700 '$REMOTE_DIR'"
  scp -q -P 30811 "$BIN_DIR/nodeserver.gz" "$BIN_DIR/billingqueue-inspect.gz" \
    "$PRIVATE_ROOT/index/billing-key.json" "root@198.2.237.123:$REMOTE_DIR/"
  scp -q "$BIN_DIR/nodeserver.gz" "$BIN_DIR/billingqueue-inspect.gz" \
    "$PRIVATE_ROOT/index/billing-key.json" "server4:$REMOTE_DIR/"
  if [[ $RELAY_TCP_PATH == ssh ]]; then
    scp -q -P 30811 "$PRIVATE_ROOT/relay-tunnel.key.pub" "root@198.2.237.123:$REMOTE_DIR/"
    scp -q "$PRIVATE_ROOT/relay-tunnel.key" "$PRIVATE_ROOT/relay-tunnel.known_hosts" "server4:$REMOTE_DIR/"
  fi
  ssh198 "gzip -df '$REMOTE_DIR/nodeserver.gz' '$REMOTE_DIR/billingqueue-inspect.gz'"
  ssh193 "gzip -df '$REMOTE_DIR/nodeserver.gz' '$REMOTE_DIR/billingqueue-inspect.gz'"
  ssh198 "chmod 700 '$REMOTE_DIR/nodeserver' '$REMOTE_DIR/billingqueue-inspect'; chmod 600 '$REMOTE_DIR/billing-key.json'"
  ssh193 "chmod 700 '$REMOTE_DIR/nodeserver' '$REMOTE_DIR/billingqueue-inspect'; chmod 600 '$REMOTE_DIR/billing-key.json'"
  if [[ $RELAY_TCP_PATH == ssh ]]; then
    ssh198 "install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; if ! grep -Fq ' $SSH_KEY_COMMENT' /root/.ssh/authorized_keys; then printf '%s ' 'no-agent-forwarding,no-X11-forwarding,no-pty,permitopen=\"127.0.0.1:8820\"' >> /root/.ssh/authorized_keys; cat '$REMOTE_DIR/relay-tunnel.key.pub' >> /root/.ssh/authorized_keys; fi"
    ssh193 "chmod 600 '$REMOTE_DIR/relay-tunnel.key' '$REMOTE_DIR/relay-tunnel.known_hosts'"
  fi
  ssh198 "curl -fsS --max-time 15 '$CA_PUBLIC_URL/readyz' >/dev/null"
  ssh193 "curl -fsS --max-time 15 '$CA_PUBLIC_URL/readyz' >/dev/null"

  ssh193 systemd-run --unit="$UNIT_INDEX" --property=Restart=on-failure --property=RestartSec=3s \
    --setenv=BNFS_BILLING_KEY_FILE="$REMOTE_DIR/billing-key.json" \
    --setenv=BNFS_SECURITY_PROFILE=production --setenv=BNFS_LOG_LEVEL=info \
    --setenv=BNFS_REVOCATION_STATE_FILE="$REMOTE_DIR/relay-client-index.revocations.json" \
    --setenv=BNFS_LOG_CONSOLE=true --setenv=BNFS_LOG_DIRECTORY="$REMOTE_DIR/logs/relay-client-index" \
    --setenv=BNFS_DISABLE_KCP="$RELAY_DISABLE_KCP" \
    --setenv=BNFS_BRIDGE_KCP="$RELAY_BRIDGE_KCP" \
    --setenv=BNFS_KCP_SEND_WINDOW=1536 --setenv=BNFS_KCP_RECEIVE_WINDOW=6144 \
    --setenv=BNFS_KCP_SESSION_BUFFER_BYTES=16777216 \
    "$REMOTE_DIR/nodeserver" -mode relay -listen :9000 -public 193.112.62.9:9000 \
    -peer "$SERVER_RELAY_ADDRESS" -ca "$CA_PUBLIC_URL" \
    -bridge-width "$RELAY_BRIDGE_WIDTH" \
    -admission enforce -key "$REMOTE_DIR/relay-client-index.identity" \
    -billing-queue "$REMOTE_DIR/relay-client-index.waitsubmit" >/dev/null
  wait_tcp 193.112.62.9 9000 90

  ssh198 systemd-run --unit="$UNIT_RELAY_SERVER" --property=Restart=on-failure --property=RestartSec=3s \
    --setenv=BNFS_BILLING_KEY_FILE="$REMOTE_DIR/billing-key.json" \
    --setenv=BNFS_SECURITY_PROFILE=production --setenv=BNFS_LOG_LEVEL=info \
    --setenv=BNFS_REVOCATION_STATE_FILE="$REMOTE_DIR/relay-server.revocations.json" \
    --setenv=BNFS_LOG_CONSOLE=true --setenv=BNFS_LOG_DIRECTORY="$REMOTE_DIR/logs/relay-server" \
    --setenv=BNFS_DISABLE_KCP="$RELAY_DISABLE_KCP" \
    --setenv=BNFS_BRIDGE_KCP="$RELAY_BRIDGE_KCP" \
    --setenv=BNFS_KCP_SEND_WINDOW=1536 --setenv=BNFS_KCP_RECEIVE_WINDOW=6144 \
    --setenv=BNFS_KCP_SESSION_BUFFER_BYTES=16777216 \
    "$REMOTE_DIR/nodeserver" -mode relay -listen :8820 -public "$SERVER_RELAY_ADDRESS" \
    -index "$INDEX_ADDRESS" -ca "$CA_PUBLIC_URL" -admission enforce \
    -bridge-width "$RELAY_BRIDGE_WIDTH" \
    -key "$REMOTE_DIR/relay-server.identity" -billing-queue "$REMOTE_DIR/relay-server.waitsubmit" >/dev/null
  sleep 3
  if [[ $RELAY_TCP_PATH == ssh ]]; then
    ssh193 systemd-run --unit="$UNIT_RELAY_TUNNEL" --property=Restart=on-failure --property=RestartSec=3s \
      /usr/bin/ssh -NT -p 30811 -i "$REMOTE_DIR/relay-tunnel.key" \
      -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$REMOTE_DIR/relay-tunnel.known_hosts" \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -L "$REMOTE_TUNNEL_ADDRESS":127.0.0.1:8820 root@198.2.237.123 >/dev/null
    ssh193 "for _ in \$(seq 1 30); do timeout 2 bash -c '</dev/tcp/${REMOTE_TUNNEL_ADDRESS%:*}/${REMOTE_TUNNEL_ADDRESS##*:}' 2>/dev/null && exit 0; sleep 1; done; exit 1"
  else
    wait_tcp 198.2.237.123 8820 90
    ssh193 "for _ in \$(seq 1 30); do timeout 2 bash -c '</dev/tcp/198.2.237.123/8820' 2>/dev/null && exit 0; sleep 1; done; exit 1"
  fi
  peer_ready=0
  for _ in $(seq 1 60); do
    if ssh193 "journalctl -u '$UNIT_INDEX' --no-pager | grep -q '控制链路已建立(主动).*198.2.237.123:8820'"; then
      peer_ready=1
      break
    fi
    sleep 2
  done
  [[ $peer_ready == 1 ]]
  sleep 3
  ssh193 "systemctl is-active '$UNIT_INDEX'"
  ssh198 "systemctl is-active '$UNIT_RELAY_SERVER'; ss -lun | grep -q ':8820 '; ss -lnt | grep -q ':8820 '"
  if [[ $RELAY_TCP_PATH == ssh ]]; then
    ssh193 "systemctl is-active '$UNIT_RELAY_TUNNEL'; ss -lnt | grep -q ':18820 '"
  fi
}

docker_common_arguments() {
  local disable_kcp=0
  [[ $ENDPOINT_TRANSPORT == tcp-only ]] && disable_kcp=1
  printf '%s\n' \
    --network "$NETWORK_NAME" \
    --label "fknat.real50g.run=$RUN_LABEL" \
    -e BNFS_SECURITY_PROFILE=production \
    -e BNFS_LOG_LEVEL=info \
    -e BNFS_LOG_CONSOLE=true \
    -e BNFS_LOG_DIRECTORY=/results/sdk-logs \
    -e "TUNNEL_PUMP_BUF=$TUNNEL_PUMP_BUF" \
    -e "TUNNEL_COALESCE_MS=$TUNNEL_COALESCE_MS" \
    -e "TUNNEL_MAX_CHUNK=$TUNNEL_MAX_CHUNK" \
    -e "TUNNEL_STREAM_SEND_WINDOW=$TUNNEL_STREAM_SEND_WINDOW" \
    -e "TUNNEL_SEND_WINDOW=$TUNNEL_SEND_WINDOW" \
    -e "BNFS_SINGLE_TCP=$ENDPOINT_SINGLE_TCP" \
    -e "BNFS_RUNTIME_TCP_WIDTH=$ENDPOINT_RUNTIME_TCP_WIDTH" \
    -e BNFS_KCP_SEND_WINDOW=1536 \
    -e BNFS_KCP_RECEIVE_WINDOW=6144 \
    -e BNFS_KCP_SESSION_BUFFER_BYTES=16777216 \
    -e "BNFS_MAX_PENDING_BILLING_DATA_SENDS=$BNFS_MAX_PENDING_BILLING_DATA_SENDS" \
    -e "BNFS_DISABLE_KCP=$disable_kcp" \
    -e "FKNAT_INDEX=$INDEX_ADDRESS" \
    -e "FKNAT_CA_URL=$CA_PUBLIC_URL"
}

remote_docker_common_arguments() {
  local disable_kcp=0
  [[ $ENDPOINT_TRANSPORT == tcp-only ]] && disable_kcp=1
  printf '%s\n' \
    --network host \
    --label "fknat.real50g.run=$RUN_LABEL" \
    -e BNFS_SECURITY_PROFILE=production \
    -e BNFS_LOG_LEVEL=info \
    -e BNFS_LOG_CONSOLE=true \
    -e BNFS_LOG_DIRECTORY=/results/sdk-logs \
    -e "TUNNEL_PUMP_BUF=$TUNNEL_PUMP_BUF" \
    -e "TUNNEL_COALESCE_MS=$TUNNEL_COALESCE_MS" \
    -e "TUNNEL_MAX_CHUNK=$TUNNEL_MAX_CHUNK" \
    -e "TUNNEL_STREAM_SEND_WINDOW=$TUNNEL_STREAM_SEND_WINDOW" \
    -e "TUNNEL_SEND_WINDOW=$TUNNEL_SEND_WINDOW" \
    -e "BNFS_SINGLE_TCP=$ENDPOINT_SINGLE_TCP" \
    -e "BNFS_RUNTIME_TCP_WIDTH=$ENDPOINT_RUNTIME_TCP_WIDTH" \
    -e BNFS_KCP_SEND_WINDOW=1536 \
    -e BNFS_KCP_RECEIVE_WINDOW=6144 \
    -e BNFS_KCP_SESSION_BUFFER_BYTES=16777216 \
    -e "BNFS_MAX_PENDING_BILLING_DATA_SENDS=$BNFS_MAX_PENDING_BILLING_DATA_SENDS" \
    -e "BNFS_DISABLE_KCP=$disable_kcp" \
    -e "FKNAT_CA_URL=$CA_PUBLIC_URL"
}

start_remote_servers() {
  printf 'server\tnode_id\tcontainer\n' > "$RESULTS_ROOT/server-nodes.tsv"
  local index name container node_id app_port ready
  for index in $(seq 1 5); do
    name=server-$(printf '%02d' "$index")
    container=$CONTAINER_PREFIX-$name
    app_port=$((15172 + index))
    ssh198 "mkdir -p '$REMOTE_DIR/results/$name/sdk-logs'"
    mapfile -t common < <(remote_docker_common_arguments)
    docker198 run -d --name "$container" "${common[@]}" \
      -e "SERVER_NAME=$name" -e FKNAT_INDEX="$INDEX_ADDRESS" -e FKNAT_RELAY=127.0.0.1:8820 \
      -e "SERVER_RATE_MIBPS=$SERVER_RATE_MIBPS" -e "SERVER_RATE_KIBPS=$SERVER_RATE_KIBPS" \
      -e "SERVER_APP_PORT=$app_port" \
      --mount "type=bind,src=$REMOTE_DIR/containers/fknat,dst=/opt/fknat,readonly" \
      --mount "type=bind,src=$REMOTE_DIR/containers/httpfileserver,dst=/opt/httpfileserver,readonly" \
      --mount "type=bind,src=$REMOTE_DIR/containers/server-entrypoint.sh,dst=/opt/server-entrypoint.sh,readonly" \
      --mount "type=bind,src=$REMOTE_DIR/state/$name,dst=/state" \
      --mount "type=bind,src=$REMOTE_DIR/results/$name,dst=/results" \
      "$BASE_IMAGE" bash /opt/server-entrypoint.sh >/dev/null
  done

  for index in $(seq 1 5); do
    name=server-$(printf '%02d' "$index")
    container=$CONTAINER_PREFIX-$name
    ready=0
    for _ in $(seq 1 240); do
      if ssh198 "grep -q 'Server 已就绪' '$REMOTE_DIR/results/$name/fknat.log' 2>/dev/null"; then
        ready=1
        break
      fi
      [[ $(docker198 inspect --format '{{.State.Running}}' "$container" 2>/dev/null) == true ]] || break
      sleep 1
    done
    [[ $ready == 1 ]] || return 1
    node_id=$(ssh198 "grep -oE '[0-9a-f]{64}' '$REMOTE_DIR/results/$name/fknat.log' | head -n 1")
    [[ $node_id =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\t%s\t%s\n' "$name" "$node_id" "$container" >> "$RESULTS_ROOT/server-nodes.tsv"
  done
  sync_remote_container_results
}

start_servers() {
  phase local-servers
  if [[ $CONTAINER_PLACEMENT == relay-hosts ]]; then
    start_remote_servers
    return
  fi
  docker network create --subnet "$DOCKER_SUBNET" "$NETWORK_NAME" >/dev/null
  if [[ $RELAY_TCP_PATH == ssh ]]; then
    systemd-run --unit="$UNIT_LOCAL_TUNNEL" --property=Restart=on-failure --property=RestartSec=3s \
      /usr/bin/ssh -NT -p 30811 -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -L "$LOCAL_TUNNEL_ADDRESS":127.0.0.1:8820 root@198.2.237.123 >/dev/null
    wait_tcp "${LOCAL_TUNNEL_ADDRESS%:*}" "${LOCAL_TUNNEL_ADDRESS##*:}" 90
  else
    wait_tcp 198.2.237.123 8820 90
  fi
  printf 'server\tnode_id\tcontainer\n' > "$RESULTS_ROOT/server-nodes.tsv"
  local index name container node_id
  for index in $(seq 1 5); do
    name=server-$(printf '%02d' "$index")
    container=$CONTAINER_PREFIX-$name
    mkdir -p "$RESULTS_ROOT/$name"
    mapfile -t common < <(docker_common_arguments)
    docker run -d --name "$container" "${common[@]}" \
      -e "SERVER_NAME=$name" -e "FKNAT_RELAY=$SERVER_RELAY_ADDRESS" \
      -e "SERVER_RATE_MIBPS=$SERVER_RATE_MIBPS" -e "SERVER_RATE_KIBPS=$SERVER_RATE_KIBPS" \
      --mount "type=bind,src=$ROOT_DIR/bin/fknat,dst=/opt/fknat,readonly" \
      --mount "type=bind,src=$BIN_DIR/httpfileserver,dst=/opt/httpfileserver,readonly" \
      --mount "type=bind,src=$SCRIPT_DIR/server-entrypoint.sh,dst=/opt/server-entrypoint.sh,readonly" \
      --mount "type=bind,src=$PRIVATE_ROOT/$name,dst=/state" \
      --mount "type=bind,src=$RESULTS_ROOT/$name,dst=/results" \
      "$BASE_IMAGE" bash /opt/server-entrypoint.sh >/dev/null
  done

  for index in $(seq 1 5); do
    name=server-$(printf '%02d' "$index")
    container=$CONTAINER_PREFIX-$name
    ready=0
    for _ in $(seq 1 240); do
      if grep -q 'Server 已就绪' "$RESULTS_ROOT/$name/fknat.log" 2>/dev/null; then
        ready=1
        break
      fi
      [[ $(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null) == true ]] || break
      sleep 1
    done
    [[ $ready == 1 ]] || return 1
    node_id=$(grep -oE '[0-9a-f]{64}' "$RESULTS_ROOT/$name/fknat.log" | head -n 1)
    [[ $node_id =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\t%s\t%s\n' "$name" "$node_id" "$container" >> "$RESULTS_ROOT/server-nodes.tsv"
  done
}

start_clients_and_preflight() {
  phase client-preflight
  if [[ $CONTAINER_PLACEMENT == relay-hosts ]]; then
    start_remote_clients_and_preflight
    return
  fi
  local index name container server_number server_name server_id
  for index in $(seq 1 10); do
    name=client-$(printf '%02d' "$index")
    container=$CONTAINER_PREFIX-$name
    server_number=$(( (index + 1) / 2 ))
    server_name=server-$(printf '%02d' "$server_number")
    server_id=$(awk -F '\t' -v target="$server_name" '$1 == target {print $2}' "$RESULTS_ROOT/server-nodes.tsv")
    [[ $server_id =~ ^[0-9a-f]{64}$ ]] || return 1
    mkdir -p "$RESULTS_ROOT/$name"
    mapfile -t common < <(docker_common_arguments)
    docker run -d --name "$container" "${common[@]}" \
      -e "CLIENT_NAME=$name" -e "FKNAT_RELAY=$CLIENT_RELAY_ADDRESS" -e "SERVER_NODE_ID=$server_id" \
      -e "PREFLIGHT_SIZE_MIB=$PREFLIGHT_SIZE_MIB" \
      -e "PREFLIGHT_MAX_TIME_SECONDS=$PREFLIGHT_MAX_TIME_SECONDS" \
      -e "FILE_MAX_TIME_SECONDS=$FILE_MAX_TIME_SECONDS" \
      --mount "type=bind,src=$ROOT_DIR/bin/fknat,dst=/opt/fknat,readonly" \
      --mount "type=bind,src=$SCRIPT_DIR/client-entrypoint.sh,dst=/opt/client-entrypoint.sh,readonly" \
      --mount "type=bind,src=$SCRIPT_DIR/client-worker.sh,dst=/opt/client-worker.sh,readonly" \
      --mount "type=bind,src=$PRIVATE_ROOT/$name,dst=/state" \
      --mount "type=bind,src=$RESULTS_ROOT/$name,dst=/results" \
      --mount "type=bind,src=$RESULTS_ROOT/plans/$name.tsv,dst=/plan/plan.tsv,readonly" \
      --mount "type=bind,src=$RESULTS_ROOT/control,dst=/control,readonly" \
      "$BASE_IMAGE" bash /opt/client-entrypoint.sh >/dev/null
  done

  for index in $(seq 1 10); do
    name=client-$(printf '%02d' "$index")
    container=$CONTAINER_PREFIX-$name
    ready=0
    for _ in $(seq 1 "$CLIENT_READY_TIMEOUT_SECONDS"); do
      if [[ -f $RESULTS_ROOT/$name/ready ]]; then
        ready=1
        break
      fi
      [[ $(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null) == true ]] || break
      sleep 1
    done
    [[ $ready == 1 ]] || return 1
  done
}

start_remote_clients_and_preflight() {
  local index name container server_number server_name server_id listen_port ready
  for index in $(seq 1 10); do
    name=client-$(printf '%02d' "$index")
    container=$CONTAINER_PREFIX-$name
    server_number=$(( (index + 1) / 2 ))
    server_name=server-$(printf '%02d' "$server_number")
    server_id=$(awk -F '\t' -v target="$server_name" '$1 == target {print $2}' "$RESULTS_ROOT/server-nodes.tsv")
    [[ $server_id =~ ^[0-9a-f]{64}$ ]] || return 1
    listen_port=$((18080 + index))
    ssh193 "mkdir -p '$REMOTE_DIR/results/$name/sdk-logs'"
    mapfile -t common < <(remote_docker_common_arguments)
    docker193 run -d --name "$container" "${common[@]}" \
      -e "CLIENT_NAME=$name" -e FKNAT_INDEX=127.0.0.1:9000 -e FKNAT_RELAY=127.0.0.1:9000 \
      -e "SERVER_NODE_ID=$server_id" -e "CLIENT_LISTEN_PORT=$listen_port" \
      -e "PREFLIGHT_SIZE_MIB=$PREFLIGHT_SIZE_MIB" \
      -e "PREFLIGHT_MAX_TIME_SECONDS=$PREFLIGHT_MAX_TIME_SECONDS" \
      -e "FILE_MAX_TIME_SECONDS=$FILE_MAX_TIME_SECONDS" \
      --mount "type=bind,src=$REMOTE_DIR/containers/fknat,dst=/opt/fknat,readonly" \
      --mount "type=bind,src=$REMOTE_DIR/containers/client-entrypoint.sh,dst=/opt/client-entrypoint.sh,readonly" \
      --mount "type=bind,src=$REMOTE_DIR/containers/client-worker.sh,dst=/opt/client-worker.sh,readonly" \
      --mount "type=bind,src=$REMOTE_DIR/state/$name,dst=/state" \
      --mount "type=bind,src=$REMOTE_DIR/results/$name,dst=/results" \
      --mount "type=bind,src=$REMOTE_DIR/plans/$name.tsv,dst=/plan/plan.tsv,readonly" \
      --mount "type=bind,src=$REMOTE_DIR/control,dst=/control,readonly" \
      "$BASE_IMAGE" bash /opt/client-entrypoint.sh >/dev/null
  done

  for index in $(seq 1 10); do
    name=client-$(printf '%02d' "$index")
    container=$CONTAINER_PREFIX-$name
    ready=0
    for _ in $(seq 1 "$CLIENT_READY_TIMEOUT_SECONDS"); do
      if ssh193 "test -f '$REMOTE_DIR/results/$name/ready'"; then
        ready=1
        break
      fi
      [[ $(docker193 inspect --format '{{.State.Running}}' "$container" 2>/dev/null) == true ]] || break
      sleep 1
    done
    [[ $ready == 1 ]] || {
      sync_remote_container_results
      return 1
    }
  done
  sync_remote_container_results
}

run_workload() {
  phase workload
  local workload_start deadline all_done index name container state exit_code workload_status
  workload_start=$(date +%s)
  metadata workload_start_epoch "$workload_start"
  if [[ $CONTAINER_PLACEMENT == relay-hosts ]]; then
    ssh193 "touch '$REMOTE_DIR/control/start'"
  else
    touch "$RESULTS_ROOT/control/start"
  fi
  RESULTS_ROOT=$RESULTS_ROOT CA_CONTAINER=$CA_CONTAINER CA_PUBLIC_URL=$CA_PUBLIC_URL \
    WORKLOAD_START_EPOCH=$workload_start bash "$SCRIPT_DIR/ca-outage-controller.sh" &
  outage_pid=$!
  printf '%s\n' "$outage_pid" > "$RESULTS_ROOT/control/outage.pid"
  RESULTS_ROOT=$RESULTS_ROOT RUN_LABEL=$RUN_LABEL REMOTE_DIR=$REMOTE_DIR \
    UNIT_INDEX=$UNIT_INDEX UNIT_RELAY_SERVER=$UNIT_RELAY_SERVER UNIT_RELAY_TUNNEL=$UNIT_RELAY_TUNNEL \
    UNIT_LOCAL_TUNNEL=$UNIT_LOCAL_TUNNEL \
    RELAY_TCP_PATH=$RELAY_TCP_PATH \
    CONTAINER_PLACEMENT=$CONTAINER_PLACEMENT REMOTE_DOCKER_HOST=$REMOTE_DOCKER_HOST \
    CA_PUBLIC_URL=$CA_PUBLIC_URL CA_LOCAL_URL=$CA_LOCAL_URL bash "$SCRIPT_DIR/monitor.sh" &
  monitor_pid=$!
  printf '%s\n' "$monitor_pid" > "$RESULTS_ROOT/control/monitor.pid"
  RESULTS_ROOT=$RESULTS_ROOT UNIT_INDEX=$UNIT_INDEX UNIT_RELAY_SERVER=$UNIT_RELAY_SERVER \
    bash "$SCRIPT_DIR/relay-resource-monitor.sh" &
  relay_resource_pid=$!
  printf '%s\n' "$relay_resource_pid" > "$RESULTS_ROOT/control/relay-resource-monitor.pid"

  deadline=$((workload_start + WORKLOAD_DEADLINE_SECONDS))
  workload_status=0
  while :; do
    all_done=1
    for index in $(seq 1 10); do
      name=client-$(printf '%02d' "$index")
      container=$CONTAINER_PREFIX-$name
      if [[ $CONTAINER_PLACEMENT == relay-hosts ]]; then
        state=$(docker193 inspect --format '{{.State.Status}}' "$container" 2>/dev/null || printf missing)
      else
        state=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || printf missing)
      fi
      [[ $state == exited || $state == dead ]] || all_done=0
    done
    ((all_done == 1)) && break
    if (( $(date +%s) >= deadline )); then
      workload_status=124
      log "workload deadline exceeded"
      break
    fi
    sync_remote_container_results
    completed=$(find "$RESULTS_ROOT" -mindepth 2 -maxdepth 2 -name complete -type f | wc -l)
    total_mib=$(awk -F= '$1 == "successful_mib" {sum += $2} END {print sum + 0}' "$RESULTS_ROOT"/client-*/progress.env 2>/dev/null || true)
    total_mib=${total_mib:-0}
    log "workload progress completed_clients=$completed successful_mib=$total_mib/51200"
    sleep 30
  done

  printf 'client\texit_code\n' > "$RESULTS_ROOT/client-exits.tsv"
  sync_remote_container_results
  for index in $(seq 1 10); do
    name=client-$(printf '%02d' "$index")
    container=$CONTAINER_PREFIX-$name
    if [[ $CONTAINER_PLACEMENT == relay-hosts ]]; then
      exit_code=$(docker193 inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || printf 255)
    else
      exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || printf 255)
    fi
    printf '%s\t%s\n' "$name" "$exit_code" >> "$RESULTS_ROOT/client-exits.tsv"
    [[ $exit_code == 0 ]] || workload_status=1
  done
  metadata workload_finished_epoch "$(date +%s)"
  metadata workload_exit_code "$workload_status"
  touch "$RESULTS_ROOT/control/workload.done"
  if [[ $CONTAINER_PLACEMENT == relay-hosts ]]; then
    ssh193 "touch '$REMOTE_DIR/control/workload.done'" || true
  fi
  [[ -n $outage_pid ]] && wait "$outage_pid" || true
  outage_pid=""
  [[ -n $monitor_pid ]] && wait "$monitor_pid" || true
  monitor_pid=""
  [[ -n $relay_resource_pid ]] && wait "$relay_resource_pid" || true
  relay_resource_pid=""
  return "$workload_status"
}

drain_queues() {
  phase billing-drain
  docker start "$CA_CONTAINER" >/dev/null 2>&1 || true
  wait_http "$CA_PUBLIC_URL" 120 || true
  printf 'epoch\telapsed_seconds\trelay_client_index_depth\trelay_server_depth\ttotal_depth\n' > "$RESULTS_ROOT/queue-drain.tsv"
  local started index_json server_json index_depth server_depth total elapsed
  started=$(date +%s)
  while :; do
    if index_json=$(ssh193 "'$REMOTE_DIR/billingqueue-inspect' -path '$REMOTE_DIR/relay-client-index.waitsubmit'" 2>/dev/null); then
      index_depth=$(printf '%s' "$index_json" | json_number depth -1)
    else
      index_depth=-1
    fi
    if server_json=$(ssh198 "'$REMOTE_DIR/billingqueue-inspect' -path '$REMOTE_DIR/relay-server.waitsubmit'" 2>/dev/null); then
      server_depth=$(printf '%s' "$server_json" | json_number depth -1)
    else
      server_depth=-1
    fi
    if [[ $index_depth =~ ^[0-9]+$ && $server_depth =~ ^[0-9]+$ ]]; then
      total=$((index_depth + server_depth))
    else
      total=-1
    fi
    elapsed=$(( $(date +%s) - started ))
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$elapsed" "$index_depth" "$server_depth" "$total" >> "$RESULTS_ROOT/queue-drain.tsv"
    ((total == 0)) && break
    ((elapsed >= 600)) && break
    sleep 10
  done
  node "$SCRIPT_DIR/capture-billing.mjs" "$PRIVATE_ROOT/ca/billing-key-bootstrap.json" \
    "$RESULTS_ROOT/billing-after.tsv" "$POSTGRES_CONTAINER"
}

generate_report() {
  phase report
  collect_artifacts
  node "$SCRIPT_DIR/generate-report.mjs" "$RESULTS_ROOT"
}

main() {
  : > "$RESULTS_ROOT/metadata.env"
  metadata run_id "$RUN_ID"
  metadata created_epoch "$(date +%s)"
  metadata ca_public_url "$CA_PUBLIC_URL"
  metadata index_address "$INDEX_ADDRESS"
  metadata server_relay_address "$SERVER_RELAY_ADDRESS"
  metadata local_tunnel_address "$LOCAL_TUNNEL_ADDRESS"
  metadata remote_tunnel_address "$REMOTE_TUNNEL_ADDRESS"
  metadata client_relay_address "$CLIENT_RELAY_ADDRESS"
  metadata docker_subnet "$DOCKER_SUBNET"
  metadata relay_tcp_path "$RELAY_TCP_PATH"
  metadata container_placement "$CONTAINER_PLACEMENT"
  if [[ $RELAY_TCP_PATH == direct ]]; then
    metadata protocol_split "direct-tcp-udp"
  else
    metadata protocol_split "udp-direct-tcp-reverse-ssh"
  fi
  metadata total_bytes "$((50 * 1024 * 1024 * 1024))"
  metadata client_count 10
  metadata server_count 5
  metadata server_rate_mibps "$SERVER_RATE_MIBPS"
  metadata server_rate_kibps "$SERVER_RATE_KIBPS"
  metadata preflight_size_mib "$PREFLIGHT_SIZE_MIB"
  metadata preflight_max_time_seconds "$PREFLIGHT_MAX_TIME_SECONDS"
  metadata client_ready_timeout_seconds "$CLIENT_READY_TIMEOUT_SECONDS"
  metadata file_max_time_seconds "$FILE_MAX_TIME_SECONDS"
  metadata tunnel_pump_buffer "$TUNNEL_PUMP_BUF"
  metadata tunnel_coalesce_ms "$TUNNEL_COALESCE_MS"
  metadata tunnel_max_chunk "$TUNNEL_MAX_CHUNK"
  metadata tunnel_stream_send_window "$TUNNEL_STREAM_SEND_WINDOW"
  metadata tunnel_send_window "$TUNNEL_SEND_WINDOW"
  metadata max_pending_billing_data_sends "$BNFS_MAX_PENDING_BILLING_DATA_SENDS"
  metadata endpoint_transport "$ENDPOINT_TRANSPORT"
  metadata endpoint_single_tcp "$ENDPOINT_SINGLE_TCP"
  metadata endpoint_runtime_tcp_width "$ENDPOINT_RUNTIME_TCP_WIDTH"
  metadata relay_disable_kcp "$RELAY_DISABLE_KCP"
  metadata relay_bridge_kcp "$RELAY_BRIDGE_KCP"
  metadata relay_bridge_width "$RELAY_BRIDGE_WIDTH"
  metadata deployment_kcp_copy_port "$KCP_COPY_PORT"
  metadata workload_deadline_seconds "$WORKLOAD_DEADLINE_SECONDS"
  metadata remote_swap_bytes "$REMOTE_SWAP_BYTES"
  metadata preflight_only "$REAL50G_PREFLIGHT_ONLY"
  build_artifacts
  prepare_fixture_and_ca
  configure_protocol_routing
  tune_kcp_socket_buffers
  deploy_remote_nodes
  prepare_remote_container_runtime
  start_servers
  start_clients_and_preflight
  if [[ $REAL50G_PREFLIGHT_ONLY == 1 ]]; then
    now=$(date +%s)
    metadata workload_start_epoch "$now"
    metadata workload_finished_epoch "$now"
    metadata workload_exit_code 0
    generate_report
    return 0
  fi
  workload_result=0
  run_workload || workload_result=$?
  drain_queues
  generate_report
  return "$workload_result"
}

main_status=0
set +e
(
  set -e
  main
)
main_status=$?
if [[ ! -f $RESULTS_ROOT/report.md ]]; then
  metadata workload_exit_code "$main_status"
  collect_artifacts || true
  node "$SCRIPT_DIR/capture-billing.mjs" "$PRIVATE_ROOT/ca/billing-key-bootstrap.json" \
    "$RESULTS_ROOT/billing-after.tsv" "$POSTGRES_CONTAINER" 2>/dev/null || true
  node "$SCRIPT_DIR/generate-report.mjs" "$RESULTS_ROOT" 2>>"$RESULTS_ROOT/orchestrator.log" || true
fi
cleanup
if [[ $REAL50G_PREFLIGHT_ONLY == 1 ]]; then
  preflight_passes=$(awk -F '\t' 'FNR == 2 && $1 == "PASS" { count++ } END { print count + 0 }' \
    "$RESULTS_ROOT"/client-*/preflight.tsv 2>/dev/null)
  printf 'result=%s\npasses=%s\nexpected=10\n' \
    "$([[ $preflight_passes == 10 ]] && printf PASS || printf FAIL)" "$preflight_passes" \
    > "$RESULTS_ROOT/preflight-status.env"
  [[ $preflight_passes == 10 ]] || main_status=1
elif [[ -f $RESULTS_ROOT/report-status.env ]]; then
  report_result=$(awk -F= '$1 == "result" {print $2}' "$RESULTS_ROOT/report-status.env")
  [[ $report_result == PASS ]] || main_status=1
else
  main_status=1
fi
printf 'complete\n' > "$RESULTS_ROOT/phase"
log "run complete status=$main_status results=$RESULTS_ROOT"
exit "$main_status"
