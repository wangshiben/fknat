#!/usr/bin/env bash

set -uo pipefail
umask 077

: "${RESULTS_ROOT:?}"
: "${RUN_LABEL:?}"
: "${REMOTE_DIR:?}"
: "${UNIT_INDEX:?}"
: "${UNIT_RELAY_SERVER:?}"
: "${UNIT_RELAY_TUNNEL:?}"
: "${UNIT_LOCAL_TUNNEL:?}"
: "${CA_PUBLIC_URL:?}"
: "${CA_LOCAL_URL:?}"

resources=$RESULTS_ROOT/resources.tsv
queues=$RESULTS_ROOT/queues.tsv
restarts=$RESULTS_ROOT/restarts.tsv
ca_health=$RESULTS_ROOT/ca-health.tsv
printf 'epoch\tcontainer\tcpu_percent\tmemory_usage\tnet_io\tblock_io\tpids\tstate\trestarts\n' > "$resources"
printf 'epoch\tnode\tdepth\tpayload_bytes\tfile_bytes\tinspect_status\n' > "$queues"
printf 'epoch\tnode\tunit\tnrestarts\tactive_state\n' > "$restarts"
printf 'epoch\tlocal_status\tpublic_status\n' > "$ca_health"

inspect_queue() {
  local node=$1 queue_path=$2 output depth payload file_bytes status
  shift 2
  output=$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$@" \
    "$REMOTE_DIR/billingqueue-inspect -path '$queue_path'; stat -c '%s' '$queue_path' 2>/dev/null || printf 0" 2>/dev/null)
  file_bytes=$(printf '%s\n' "$output" | tail -n 1)
  output=$(printf '%s\n' "$output" | head -n 1)
  depth=$(printf '%s' "$output" | jq -r '.depth // 0' 2>/dev/null)
  payload=$(printf '%s' "$output" | jq -r '.payload_bytes // 0' 2>/dev/null)
  if [[ $depth =~ ^[0-9]+$ && $payload =~ ^[0-9]+$ && $file_bytes =~ ^[0-9]+$ ]]; then
    status=PASS
  else
    depth=0
    payload=0
    file_bytes=0
    status=UNAVAILABLE
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$node" "$depth" "$payload" "$file_bytes" "$status" >> "$queues"
}

inspect_unit() {
  local node=$1 unit=$2 output nrestarts active
  shift 2
  output=$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$@" \
    "systemctl show '$unit' -p NRestarts -p ActiveState" 2>/dev/null)
  nrestarts=$(printf '%s\n' "$output" | awk -F= '$1 == "NRestarts" {print $2}')
  active=$(printf '%s\n' "$output" | awk -F= '$1 == "ActiveState" {print $2}')
  [[ $nrestarts =~ ^[0-9]+$ ]] || nrestarts=-1
  [[ -n $active ]] || active=unavailable
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$node" "$unit" "$nrestarts" "$active" >> "$restarts"
}

inspect_local_unit() {
  local unit=$1 output nrestarts active
  output=$(systemctl show "$unit" -p NRestarts -p ActiveState 2>/dev/null)
  nrestarts=$(printf '%s\n' "$output" | awk -F= '$1 == "NRestarts" {print $2}')
  active=$(printf '%s\n' "$output" | awk -F= '$1 == "ActiveState" {print $2}')
  [[ $nrestarts =~ ^[0-9]+$ ]] || nrestarts=-1
  [[ -n $active ]] || active=unavailable
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" local "$unit" "$nrestarts" "$active" >> "$restarts"
}

sample() {
  local epoch names name state restart local_status public_status
  epoch=$(date +%s)
  names=$(docker ps -a --filter "label=fknat.real50g.run=$RUN_LABEL" --format '{{.Names}}')
  for name in $names; do
    state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || printf unavailable)
    restart=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null || printf -1)
    if [[ $state == running ]]; then
      docker stats --no-stream --format "${epoch}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}\t${state}\t${restart}" "$name" >> "$resources" 2>/dev/null || true
    else
      printf '%s\t%s\t0%%\t0B / 0B\t0B / 0B\t0B / 0B\t0\t%s\t%s\n' "$epoch" "$name" "$state" "$restart" >> "$resources"
    fi
  done

  inspect_queue relay-client-index "$REMOTE_DIR/relay-client-index.waitsubmit" server4
  inspect_queue relay-server "$REMOTE_DIR/relay-server.waitsubmit" -p 30811 root@198.2.237.123
  inspect_unit relay-client-index "$UNIT_INDEX" server4
  inspect_unit relay-server "$UNIT_RELAY_SERVER" -p 30811 root@198.2.237.123
  inspect_unit relay-tunnel "$UNIT_RELAY_TUNNEL" server4
  inspect_local_unit "$UNIT_LOCAL_TUNNEL"

  local_status=DOWN
  public_status=DOWN
  curl -fsS --max-time 4 "$CA_LOCAL_URL/readyz" >/dev/null 2>&1 && local_status=UP
  curl -fsS --max-time 4 "$CA_PUBLIC_URL/readyz" >/dev/null 2>&1 && public_status=UP
  printf '%s\t%s\t%s\n' "$epoch" "$local_status" "$public_status" >> "$ca_health"
}

while :; do
  sample
  [[ -f $RESULTS_ROOT/control/workload.done ]] && break
  sleep 30
done
