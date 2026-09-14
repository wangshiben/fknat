#!/usr/bin/env bash

set -uo pipefail
umask 077

: "${RESULTS_ROOT:?}"
: "${RUN_LABEL:?}"
: "${REMOTE_DIR:?}"
: "${UNIT_INDEX:?}"
: "${UNIT_RELAY_CLIENT:?}"
: "${UNIT_RELAY_SERVER:?}"
: "${SERVER_RELAY_SSH_TARGET:=root@198.2.237.123}"
: "${SERVER_RELAY_SSH_PORT:=30811}"
: "${UNIT_RELAY_TUNNEL:?}"
: "${UNIT_LOCAL_TUNNEL:?}"
: "${RELAY_TCP_PATH:=direct}"
: "${CONTAINER_PLACEMENT:=local}"
: "${REMOTE_DOCKER_HOST:=}"
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

json_number() {
  local key=$1 fallback=$2 value
  value=$(sed -n "s/.*\"$key\":\([0-9][0-9]*\).*/\\1/p" | head -n 1)
  if [[ $value =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

inspect_queue() {
  local node=$1 queue_path=$2 output depth payload file_bytes status
  shift 2
  output=$(timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$@" \
    "$REMOTE_DIR/billingqueue-inspect -path '$queue_path'; stat -c '%s' '$queue_path' 2>/dev/null || printf 0" 2>/dev/null)
  file_bytes=$(printf '%s\n' "$output" | tail -n 1)
  output=$(printf '%s\n' "$output" | head -n 1)
  depth=$(printf '%s' "$output" | json_number depth 0)
  payload=$(printf '%s' "$output" | json_number payload_bytes 0)
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

docker193() {
  local quoted
  printf -v quoted '%q ' "$@"
  ssh -o BatchMode=yes -o ConnectTimeout=8 server4 \
    "DOCKER_HOST='$REMOTE_DOCKER_HOST' '$REMOTE_DIR/docker-bin/docker' $quoted"
}

docker198() {
  local quoted
  printf -v quoted '%q ' "$@"
  ssh -o BatchMode=yes -o ConnectTimeout=8 -p 30811 root@198.2.237.123 \
    "DOCKER_HOST='$REMOTE_DOCKER_HOST' '$REMOTE_DIR/docker-bin/docker' $quoted"
}

sample_docker() {
  local epoch=$1 location=$2 names inspect_rows name state restart
  local -a running=()
  shift 2
  names=$("$@" ps -a --filter "label=fknat.real50g.run=$RUN_LABEL" --format '{{.Names}}' 2>/dev/null || true)
  [[ -n $names ]] || return 0
  inspect_rows=$("$@" inspect --format '{{.Name}}|{{.State.Status}}|{{.RestartCount}}' $names 2>/dev/null || true)
  while IFS='|' read -r name state restart; do
    [[ -n $name ]] || continue
    name=${name#/}
    [[ -n $state ]] || state=unavailable
    [[ $restart =~ ^[0-9]+$ ]] || restart=-1
    if [[ $state == running ]]; then
      running+=("$name")
    else
      printf '%s\t%s/%s\t0%%\t0B / 0B\t0B / 0B\t0B / 0B\t0\t%s\t%s\n' \
        "$epoch" "$location" "$name" "$state" "$restart" >> "$resources"
    fi
  done <<< "$inspect_rows"
  if ((${#running[@]} > 0)); then
    "$@" stats --no-stream \
      --format "${epoch}\t${location}/{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}\trunning\t{{.Container}}" \
      "${running[@]}" | while IFS=$'\t' read -r sample_epoch sample_name cpu memory net block pids sample_state container_id; do
        restart=$(printf '%s\n' "$inspect_rows" | awk -F '|' -v target="/${sample_name#*/}" '$1 == target {print $3; exit}')
        [[ $restart =~ ^[0-9]+$ ]] || restart=-1
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$sample_epoch" "$sample_name" "$cpu" "$memory" "$net" "$block" "$pids" "$sample_state" "$restart"
      done >> "$resources" 2>/dev/null || true
  fi
}

sample() {
  local epoch local_status public_status
  epoch=$(date +%s)
  if [[ $CONTAINER_PLACEMENT == relay-hosts ]]; then
    sample_docker "$epoch" 193 docker193
    sample_docker "$epoch" 198 docker198
  else
    sample_docker "$epoch" local docker
  fi

  inspect_queue relay-client-index "$REMOTE_DIR/relay-client-index.waitsubmit" server4
  inspect_queue relay-client "$REMOTE_DIR/relay-client.waitsubmit" -p "${CLIENT_RELAY_SSH_PORT:-22}" "${CLIENT_RELAY_SSH_TARGET:-root@160.202.47.24}"
  inspect_queue relay-server "$REMOTE_DIR/relay-server.waitsubmit" -p "$SERVER_RELAY_SSH_PORT" "$SERVER_RELAY_SSH_TARGET"
  inspect_unit relay-client-index "$UNIT_INDEX" server4
  inspect_unit relay-client "$UNIT_RELAY_CLIENT" -p "${CLIENT_RELAY_SSH_PORT:-22}" "${CLIENT_RELAY_SSH_TARGET:-root@160.202.47.24}"
  inspect_unit relay-server "$UNIT_RELAY_SERVER" -p "$SERVER_RELAY_SSH_PORT" "$SERVER_RELAY_SSH_TARGET"
  if [[ $RELAY_TCP_PATH == ssh ]]; then
    inspect_unit relay-tunnel "$UNIT_RELAY_TUNNEL" server4
    inspect_local_unit "$UNIT_LOCAL_TUNNEL"
  fi

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
