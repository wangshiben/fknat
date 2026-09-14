#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# Manage one Index and two business Relays across two public hosts. This script
# never starts or stops the local NAT/HTTP workload.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ACTION=${1:-status}
RUN_ID=${RUN_ID:-remote-dual-r7-$(date -u +%Y%m%dT%H%M%SZ)}
NORMAL_CONTROL_HOST=${NORMAL_CONTROL_HOST:-129.28.42.247}
NORMAL_CONTROL_PUBLIC_IP=${NORMAL_CONTROL_PUBLIC_IP:-129.28.42.247}
RESTRICTED_CONTROL_HOST=${RESTRICTED_CONTROL_HOST:-156.225.23.32}
RESTRICTED_CONTROL_PUBLIC_IP=${RESTRICTED_CONTROL_PUBLIC_IP:-156.225.23.32}
SERVER_RELAY_HOST=${SERVER_RELAY_HOST:-193.112.62.9}
SERVER_RELAY_PUBLIC_IP=${SERVER_RELAY_PUBLIC_IP:-193.112.62.9}
INDEX_PORT=${INDEX_PORT:-4010}
CLIENT_RELAY_PORT=${CLIENT_RELAY_PORT:-4011}
SERVER_RELAY_PORT=${SERVER_RELAY_PORT:-4012}
RELAY_BIN=${RELAY_BIN:-$ROOT_DIR/../natP2p/dist/fixed-stale-continuity-r7-20260909T130508Z/relayServer-fixed-stale-continuity-r7-20260909T130508Z-linux-amd64}
BILLING_KEY_FILE=${BILLING_KEY_FILE:-$ROOT_DIR/test-results/public3h-bounded-r6-20260905T230830Z/relay.billing-key.json}
RELEASE_SHA256SUMS=${RELEASE_SHA256SUMS:-$(dirname -- "$RELAY_BIN")/SHA256SUMS}
BRIDGE_WIDTH=${BRIDGE_WIDTH:-4}
BNFS_MAX_PENDING_BILLING_DATA_SENDS=${BNFS_MAX_PENDING_BILLING_DATA_SENDS:-16}
BNFS_DISABLE_KCP=${BNFS_DISABLE_KCP:-0}
TUNNEL_MAX_CHUNK=${TUNNEL_MAX_CHUNK:-262144}
TUNNEL_STREAM_SEND_WINDOW=${TUNNEL_STREAM_SEND_WINDOW:-32}
TUNNEL_SEND_WINDOW=${TUNNEL_SEND_WINDOW:-128}
BNFS_KCP_SEND_WINDOW=${BNFS_KCP_SEND_WINDOW:-1536}
BNFS_KCP_RECEIVE_WINDOW=${BNFS_KCP_RECEIVE_WINDOW:-6144}
BNFS_KCP_SESSION_BUFFER_BYTES=${BNFS_KCP_SESSION_BUFFER_BYTES:-16777216}
STATE_FILE=${STATE_FILE:-$ROOT_DIR/.private-remote-3h-http/$RUN_ID/remote-dual-deployment.env}
deploy_in_progress=0

die() { printf '[remote-dual-relay] FAIL: %s\n' "$*" >&2; exit 1; }
remote() { local host=$1; shift; ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$@"; }

read_remote_socket_buffer_maxima() {
  local host=$1 role=$2 values rmem_max wmem_max
  values=$(remote "$host" "printf '%s %s\\n' \"\$(sysctl -n net.core.rmem_max)\" \"\$(sysctl -n net.core.wmem_max)\"") \
    || die "failed to read KCP socket buffer ceilings from $role host $host"
  read -r rmem_max wmem_max <<< "$values"
  [[ $rmem_max =~ ^[0-9]+$ && $wmem_max =~ ^[0-9]+$ ]] \
    || die "invalid KCP socket buffer ceilings from $role host $host: $values"
  if [[ $role == control ]]; then
    CONTROL_RMEM_MAX=$rmem_max
    CONTROL_WMEM_MAX=$wmem_max
  else
    SERVER_RELAY_RMEM_MAX=$rmem_max
    SERVER_RELAY_WMEM_MAX=$wmem_max
  fi
  if [[ $BNFS_DISABLE_KCP == 0 ]] &&
    ((rmem_max < BNFS_KCP_SESSION_BUFFER_BYTES || wmem_max < BNFS_KCP_SESSION_BUFFER_BYTES)); then
    die "KCP socket buffer ceiling on $role host $host is below BNFS_KCP_SESSION_BUFFER_BYTES=$BNFS_KCP_SESSION_BUFFER_BYTES (net.core.rmem_max=$rmem_max net.core.wmem_max=$wmem_max)"
  fi
}

select_control_host() {
  local weekday hhmm
  weekday=$(TZ=Asia/Shanghai date +%u)
  hhmm=$(TZ=Asia/Shanghai date +%H%M)
  if ((weekday >= 1 && weekday <= 5 && 10#$hhmm >= 1030 && 10#$hhmm <= 1800)); then
    CONTROL_HOST=$RESTRICTED_CONTROL_HOST
    CONTROL_PUBLIC_IP=$RESTRICTED_CONTROL_PUBLIC_IP
    CONTROL_SELECTION=weekday-restricted-window
  else
    CONTROL_HOST=$NORMAL_CONTROL_HOST
    CONTROL_PUBLIC_IP=$NORMAL_CONTROL_PUBLIC_IP
    CONTROL_SELECTION=normal-window
  fi
}

load_state() {
  [[ -f $STATE_FILE ]] || die "state file is missing: $STATE_FILE"
  while IFS='=' read -r name value; do
    case "$name" in
      control_host) CONTROL_HOST=$value ;;
      control_public_ip) CONTROL_PUBLIC_IP=$value ;;
      server_relay_host) SERVER_RELAY_HOST=$value ;;
      server_relay_public_ip) SERVER_RELAY_PUBLIC_IP=$value ;;
      index_port) INDEX_PORT=$value ;;
      client_relay_port) CLIENT_RELAY_PORT=$value ;;
      server_relay_port) SERVER_RELAY_PORT=$value ;;
      index_unit) INDEX_UNIT=$value ;;
      client_relay_unit) CLIENT_RELAY_UNIT=$value ;;
      server_relay_unit) SERVER_RELAY_UNIT=$value ;;
      control_dir) CONTROL_DIR=$value ;;
      server_relay_dir) SERVER_RELAY_DIR=$value ;;
      relay_sha256) RELAY_SHA256=$value ;;
    esac
  done < "$STATE_FILE"
}

cleanup_partial_deploy() {
  local rc=$?
  ((deploy_in_progress == 1)) || return "$rc"
  deploy_in_progress=0
  set +e
  remote "$CONTROL_HOST" "systemctl stop '$INDEX_UNIT' '$CLIENT_RELAY_UNIT' >/dev/null 2>&1 || true; systemctl reset-failed '$INDEX_UNIT' '$CLIENT_RELAY_UNIT' >/dev/null 2>&1 || true"
  remote "$SERVER_RELAY_HOST" "systemctl stop '$SERVER_RELAY_UNIT' >/dev/null 2>&1 || true; systemctl reset-failed '$SERVER_RELAY_UNIT' >/dev/null 2>&1 || true"
  return "$rc"
}
trap cleanup_partial_deploy ERR

port_is_free() {
  local host=$1 port=$2
  remote "$host" "! ss -lntupH | awk '{n=split(\$5,a,\":\"); if (a[n] == \"$port\") found=1} END {exit found ? 0 : 1}'"
}

wait_ready() {
  local host=$1 unit=$2 port=$3
  for _ in $(seq 1 90); do
    if [[ $BNFS_DISABLE_KCP == 1 ]]; then
      remote "$host" "systemctl is-active --quiet '$unit' && ss -lntH | grep -Eq '[:.]$port[[:space:]]'" && return 0
    elif remote "$host" "systemctl is-active --quiet '$unit' && ss -lntH | grep -Eq '[:.]$port[[:space:]]' && ss -lnuH | grep -Eq '[:.]$port[[:space:]]'"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

show_one() {
  local role=$1 host=$2 unit=$3 dir=$4 port=$5
  printf 'role=%s host=%s unit=%s port=%s\n' "$role" "$host" "$unit" "$port"
  remote "$host" "systemctl show '$unit' -p Id -p ActiveState -p SubState -p NRestarts -p MainPID; sha256sum '$dir/relayServer'; ss -lntupH | grep -E '[:.]$port[[:space:]]' || true"
}

deploy() {
  [[ $RUN_ID =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid RUN_ID: $RUN_ID"
  [[ -x $RELAY_BIN ]] || die "Relay binary is not executable: $RELAY_BIN"
  [[ -f $BILLING_KEY_FILE ]] || die "billing key is missing: $BILLING_KEY_FILE"
  [[ -f $RELEASE_SHA256SUMS ]] || die "release manifest is missing: $RELEASE_SHA256SUMS"
  for port in "$INDEX_PORT" "$CLIENT_RELAY_PORT" "$SERVER_RELAY_PORT"; do
    [[ $port =~ ^[0-9]+$ ]] && ((port >= 3999 && port <= 4222)) || die "Relay port must be in 3999..4222: $port"
  done
  [[ $INDEX_PORT != "$CLIENT_RELAY_PORT" ]] || die 'Index and client Relay ports must differ'
  [[ $BNFS_DISABLE_KCP == 0 || $BNFS_DISABLE_KCP == 1 ]] || die "BNFS_DISABLE_KCP must be 0 or 1"
  [[ $BNFS_KCP_SESSION_BUFFER_BYTES =~ ^[0-9]+$ && $BNFS_KCP_SESSION_BUFFER_BYTES -ge 1048576 && $BNFS_KCP_SESSION_BUFFER_BYTES -le 268435456 ]] \
    || die "BNFS_KCP_SESSION_BUFFER_BYTES must be 1MiB..256MiB"
  select_control_host
  [[ $CONTROL_HOST != "$SERVER_RELAY_HOST" ]] || die 'the two business Relays must use different hosts'

  local binary_name expected
  binary_name=$(basename -- "$RELAY_BIN")
  expected=$(awk -v name="$binary_name" '$2==name {print $1; exit}' "$RELEASE_SHA256SUMS")
  RELAY_SHA256=$(sha256sum "$RELAY_BIN" | awk '{print $1}')
  [[ $expected == "$RELAY_SHA256" ]] || die "release manifest mismatch expected=$expected actual=$RELAY_SHA256"

  CONTROL_DIR=/root/fknat-$RUN_ID-control
  SERVER_RELAY_DIR=/root/fknat-$RUN_ID-server-relay
  INDEX_UNIT=fknat-$RUN_ID-index.service
  CLIENT_RELAY_UNIT=fknat-$RUN_ID-client-relay.service
  SERVER_RELAY_UNIT=fknat-$RUN_ID-server-relay.service
  deploy_in_progress=1
  local index_address client_relay_address server_relay_address common_properties
  index_address=$CONTROL_PUBLIC_IP:$INDEX_PORT
  client_relay_address=$CONTROL_PUBLIC_IP:$CLIENT_RELAY_PORT
  server_relay_address=$SERVER_RELAY_PUBLIC_IP:$SERVER_RELAY_PORT

  remote "$CONTROL_HOST" 'true'
  remote "$SERVER_RELAY_HOST" 'true'
  read_remote_socket_buffer_maxima "$CONTROL_HOST" control
  read_remote_socket_buffer_maxima "$SERVER_RELAY_HOST" server-relay
  port_is_free "$CONTROL_HOST" "$INDEX_PORT" || die "$CONTROL_HOST:$INDEX_PORT is occupied"
  port_is_free "$CONTROL_HOST" "$CLIENT_RELAY_PORT" || die "$CONTROL_HOST:$CLIENT_RELAY_PORT is occupied"
  port_is_free "$SERVER_RELAY_HOST" "$SERVER_RELAY_PORT" || die "$SERVER_RELAY_HOST:$SERVER_RELAY_PORT is occupied"
  remote "$CONTROL_HOST" "mkdir -p '$CONTROL_DIR/logs/index' '$CONTROL_DIR/logs/client-relay'; chmod 700 '$CONTROL_DIR' '$CONTROL_DIR/logs' '$CONTROL_DIR/logs/index' '$CONTROL_DIR/logs/client-relay'"
  remote "$SERVER_RELAY_HOST" "mkdir -p '$SERVER_RELAY_DIR/logs/server-relay'; chmod 700 '$SERVER_RELAY_DIR' '$SERVER_RELAY_DIR/logs' '$SERVER_RELAY_DIR/logs/server-relay'"
  scp -q "$RELAY_BIN" "$CONTROL_HOST:$CONTROL_DIR/relayServer"
  scp -q "$RELAY_BIN" "$SERVER_RELAY_HOST:$SERVER_RELAY_DIR/relayServer"
  scp -q "$BILLING_KEY_FILE" "$CONTROL_HOST:$CONTROL_DIR/billing-key.json"
  scp -q "$BILLING_KEY_FILE" "$SERVER_RELAY_HOST:$SERVER_RELAY_DIR/billing-key.json"
  remote "$CONTROL_HOST" "chmod 700 '$CONTROL_DIR/relayServer'; chmod 600 '$CONTROL_DIR/billing-key.json'; test \"\$(sha256sum '$CONTROL_DIR/relayServer' | awk '{print \$1}')\" = '$RELAY_SHA256'"
  remote "$SERVER_RELAY_HOST" "chmod 700 '$SERVER_RELAY_DIR/relayServer'; chmod 600 '$SERVER_RELAY_DIR/billing-key.json'; test \"\$(sha256sum '$SERVER_RELAY_DIR/relayServer' | awk '{print \$1}')\" = '$RELAY_SHA256'"

  common_properties="--property=Restart=on-failure --property=RestartSec=3s --property=KillMode=mixed --property=TimeoutStopSec=20s --setenv=BNFS_LOG_CONSOLE=true --setenv=BNFS_MAX_PENDING_BILLING_DATA_SENDS=$BNFS_MAX_PENDING_BILLING_DATA_SENDS --setenv=BNFS_DISABLE_KCP=$BNFS_DISABLE_KCP --setenv=TUNNEL_MAX_CHUNK=$TUNNEL_MAX_CHUNK --setenv=TUNNEL_STREAM_SEND_WINDOW=$TUNNEL_STREAM_SEND_WINDOW --setenv=TUNNEL_SEND_WINDOW=$TUNNEL_SEND_WINDOW --setenv=BNFS_KCP_SEND_WINDOW=$BNFS_KCP_SEND_WINDOW --setenv=BNFS_KCP_RECEIVE_WINDOW=$BNFS_KCP_RECEIVE_WINDOW --setenv=BNFS_KCP_SESSION_BUFFER_BYTES=$BNFS_KCP_SESSION_BUFFER_BYTES"
  remote "$CONTROL_HOST" "systemd-run --unit='$INDEX_UNIT' $common_properties --setenv=BNFS_LOG_DIRECTORY='$CONTROL_DIR/logs/index' '$CONTROL_DIR/relayServer' -mode index -listen ':$INDEX_PORT' -public '$index_address' -peer '$server_relay_address' -key '$CONTROL_DIR/index.identity' -billing-key '$CONTROL_DIR/billing-key.json' -billing-queue '$CONTROL_DIR/index.waitsubmit' -revocation-state '$CONTROL_DIR/index.revocations.json' -bridge-width '$BRIDGE_WIDTH' >/dev/null"
  remote "$CONTROL_HOST" "systemd-run --unit='$CLIENT_RELAY_UNIT' $common_properties --setenv=BNFS_LOG_DIRECTORY='$CONTROL_DIR/logs/client-relay' '$CONTROL_DIR/relayServer' -mode relay -listen ':$CLIENT_RELAY_PORT' -public '$client_relay_address' -index '$index_address' -peer '$server_relay_address' -key '$CONTROL_DIR/client-relay.identity' -billing-key '$CONTROL_DIR/billing-key.json' -billing-queue '$CONTROL_DIR/client-relay.waitsubmit' -revocation-state '$CONTROL_DIR/client-relay.revocations.json' -bridge-width '$BRIDGE_WIDTH' >/dev/null"
  remote "$SERVER_RELAY_HOST" "systemd-run --unit='$SERVER_RELAY_UNIT' $common_properties --setenv=BNFS_LOG_DIRECTORY='$SERVER_RELAY_DIR/logs/server-relay' '$SERVER_RELAY_DIR/relayServer' -mode relay -listen ':$SERVER_RELAY_PORT' -public '$server_relay_address' -index '$index_address' -key '$SERVER_RELAY_DIR/server-relay.identity' -billing-key '$SERVER_RELAY_DIR/billing-key.json' -billing-queue '$SERVER_RELAY_DIR/server-relay.waitsubmit' -revocation-state='$SERVER_RELAY_DIR/server-relay.revocations.json' -bridge-width '$BRIDGE_WIDTH' >/dev/null"

  wait_ready "$CONTROL_HOST" "$INDEX_UNIT" "$INDEX_PORT" || die 'Index did not become ready'
  wait_ready "$CONTROL_HOST" "$CLIENT_RELAY_UNIT" "$CLIENT_RELAY_PORT" || die 'client Relay did not become ready'
  wait_ready "$SERVER_RELAY_HOST" "$SERVER_RELAY_UNIT" "$SERVER_RELAY_PORT" || die 'server Relay did not become ready'
  mkdir -p "$(dirname -- "$STATE_FILE")"
  chmod 700 "$(dirname -- "$STATE_FILE")"
  {
    printf 'run_id=%s\ndeployed_epoch=%s\ncontrol_selection=%s\n' "$RUN_ID" "$(date +%s)" "$CONTROL_SELECTION"
    printf 'control_host=%s\ncontrol_public_ip=%s\nserver_relay_host=%s\nserver_relay_public_ip=%s\n' "$CONTROL_HOST" "$CONTROL_PUBLIC_IP" "$SERVER_RELAY_HOST" "$SERVER_RELAY_PUBLIC_IP"
    printf 'index_port=%s\nclient_relay_port=%s\nserver_relay_port=%s\n' "$INDEX_PORT" "$CLIENT_RELAY_PORT" "$SERVER_RELAY_PORT"
    printf 'index_unit=%s\nclient_relay_unit=%s\nserver_relay_unit=%s\n' "$INDEX_UNIT" "$CLIENT_RELAY_UNIT" "$SERVER_RELAY_UNIT"
    printf 'control_dir=%s\nserver_relay_dir=%s\n' "$CONTROL_DIR" "$SERVER_RELAY_DIR"
    printf 'index_address=%s\nclient_relay_address=%s\nserver_relay_address=%s\n' "$index_address" "$client_relay_address" "$server_relay_address"
    printf 'business_relay_count=2\nrelay_host_count=2\nrelay_sha256=%s\nrelease_manifest=%s\n' "$RELAY_SHA256" "$RELEASE_SHA256SUMS"
    printf 'bridge_width=%s\nbnfs_disable_kcp=%s\nmax_pending_billing_data_sends=%s\n' "$BRIDGE_WIDTH" "$BNFS_DISABLE_KCP" "$BNFS_MAX_PENDING_BILLING_DATA_SENDS"
    printf 'tunnel_max_chunk=%s\ntunnel_stream_send_window=%s\ntunnel_send_window=%s\n' "$TUNNEL_MAX_CHUNK" "$TUNNEL_STREAM_SEND_WINDOW" "$TUNNEL_SEND_WINDOW"
    printf 'bnfs_kcp_send_window=%s\nbnfs_kcp_receive_window=%s\nbnfs_kcp_session_buffer_bytes=%s\n' "$BNFS_KCP_SEND_WINDOW" "$BNFS_KCP_RECEIVE_WINDOW" "$BNFS_KCP_SESSION_BUFFER_BYTES"
    printf 'control_kernel_rmem_max=%s\ncontrol_kernel_wmem_max=%s\nserver_relay_kernel_rmem_max=%s\nserver_relay_kernel_wmem_max=%s\n' \
      "$CONTROL_RMEM_MAX" "$CONTROL_WMEM_MAX" "$SERVER_RELAY_RMEM_MAX" "$SERVER_RELAY_WMEM_MAX"
  } > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  deploy_in_progress=0
  status
}

status() {
  load_state
  show_one index "$CONTROL_HOST" "$INDEX_UNIT" "$CONTROL_DIR" "$INDEX_PORT"
  show_one client-relay "$CONTROL_HOST" "$CLIENT_RELAY_UNIT" "$CONTROL_DIR" "$CLIENT_RELAY_PORT"
  show_one server-relay "$SERVER_RELAY_HOST" "$SERVER_RELAY_UNIT" "$SERVER_RELAY_DIR" "$SERVER_RELAY_PORT"
}

stop() {
  load_state
  remote "$CONTROL_HOST" "systemctl stop '$INDEX_UNIT' '$CLIENT_RELAY_UNIT' >/dev/null 2>&1 || true; systemctl reset-failed '$INDEX_UNIT' '$CLIENT_RELAY_UNIT' >/dev/null 2>&1 || true"
  remote "$SERVER_RELAY_HOST" "systemctl stop '$SERVER_RELAY_UNIT' >/dev/null 2>&1 || true; systemctl reset-failed '$SERVER_RELAY_UNIT' >/dev/null 2>&1 || true"
  printf 'stopped_epoch=%s\n' "$(date +%s)" >> "$STATE_FILE"
  printf '[remote-dual-relay] stopped run=%s control=%s server-relay=%s\n' "$RUN_ID" "$CONTROL_HOST" "$SERVER_RELAY_HOST"
}

case "$ACTION" in
  deploy) deploy ;;
  status) status ;;
  stop) stop ;;
  *) die 'usage: remote-dual-relay-manage.sh deploy|status|stop' ;;
esac
