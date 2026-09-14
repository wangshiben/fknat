#!/usr/bin/env bash

set -uo pipefail
umask 077

: "${RESULTS_ROOT:?}"
: "${UNIT_INDEX:?}"
: "${UNIT_RELAY_CLIENT:?}"
: "${UNIT_RELAY_SERVER:?}"
: "${SERVER_RELAY_SSH_TARGET:=root@198.2.237.123}"
: "${SERVER_RELAY_SSH_PORT:=30811}"

output=$RESULTS_ROOT/relay-resources.tsv
printf 'epoch\tnode\tunit\tmemory_current_bytes\tmemory_peak_bytes\tcpu_usage_ns\tstatus\n' > "$output"

sample_unit() {
  local node=$1 unit=$2 sample current peak cpu status
  shift 2
  sample=$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$@" \
    "control_group=\$(systemctl show '$unit' -p ControlGroup --value); \
     current=\$(cat \"/sys/fs/cgroup\${control_group}/memory.current\" 2>/dev/null || printf 0); \
     peak=\$(cat \"/sys/fs/cgroup\${control_group}/memory.peak\" 2>/dev/null || printf 0); \
     cpu=\$(systemctl show '$unit' -p CPUUsageNSec --value 2>/dev/null || printf 0); \
     printf '%s\\t%s\\t%s\\n' \"\$current\" \"\$peak\" \"\$cpu\"" 2>/dev/null)
  IFS=$'\t' read -r current peak cpu <<< "$sample"
  if [[ $current =~ ^[0-9]+$ && $peak =~ ^[0-9]+$ && $cpu =~ ^[0-9]+$ ]]; then
    status=PASS
  else
    current=0
    peak=0
    cpu=0
    status=UNAVAILABLE
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "$node" "$unit" "$current" "$peak" "$cpu" "$status" >> "$output"
}

while :; do
  sample_unit relay-client-index "$UNIT_INDEX" server4
  sample_unit relay-client "$UNIT_RELAY_CLIENT" -p "${CLIENT_RELAY_SSH_PORT:-22}" "${CLIENT_RELAY_SSH_TARGET:-root@160.202.47.24}"
  sample_unit relay-server "$UNIT_RELAY_SERVER" -p "$SERVER_RELAY_SSH_PORT" "$SERVER_RELAY_SSH_TARGET"
  [[ -f $RESULTS_ROOT/control/workload.done ]] && break
  sleep 30
done
