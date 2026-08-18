#!/usr/bin/env bash

set -uo pipefail
umask 077

: "${RESULTS_ROOT:?}"
: "${CA_CONTAINER:?}"
: "${CA_PUBLIC_URL:?}"
: "${WORKLOAD_START_EPOCH:?}"

outages=$RESULTS_ROOT/ca-outages.tsv
log=$RESULTS_ROOT/ca-outage-controller.log
printf 'sequence\tscheduled_epoch\tdown_epoch\tplanned_seconds\tpublic_unavailable_epoch\trestart_epoch\trecovered_epoch\tstatus\n' > "$outages"

restore_ca() {
  docker start "$CA_CONTAINER" >/dev/null 2>&1 || true
}
trap restore_ca EXIT INT TERM

wait_until() {
  local target=$1 now delay
  while :; do
    [[ -f $RESULTS_ROOT/control/workload.done ]] && return 1
    now=$(date +%s)
    ((now >= target)) && return 0
    delay=$((target - now))
    ((delay > 30)) && delay=30
    sleep "$delay"
  done
}

wait_public_state() {
  local wanted=$1 deadline=$2 now
  while :; do
    now=$(date +%s)
    if curl -fsS --max-time 4 "$CA_PUBLIC_URL/readyz" >/dev/null 2>&1; then
      [[ $wanted == up ]] && return 0
    else
      [[ $wanted == down ]] && return 0
    fi
    ((now >= deadline)) && return 1
    sleep 2
  done
}

sequence=0
while :; do
  sequence=$((sequence + 1))
  scheduled_epoch=$((WORKLOAD_START_EPOCH + sequence * 600))
  if ! wait_until "$scheduled_epoch"; then
    break
  fi
  random_value=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
  planned_seconds=$((180 + random_value % 121))
  down_epoch=$(date +%s)
  printf '%s stopping dedicated CA sequence=%d planned_seconds=%d\n' "$(date -Is)" "$sequence" "$planned_seconds" >> "$log"
  docker stop --time 20 "$CA_CONTAINER" >/dev/null 2>>"$log" || true
  public_unavailable_epoch=$(date +%s)
  status=DOWN_CONFIRMED
  if ! wait_public_state down "$((public_unavailable_epoch + 45))"; then
    status=DOWN_NOT_CONFIRMED
  else
    public_unavailable_epoch=$(date +%s)
  fi

  outage_deadline=$((down_epoch + planned_seconds))
  while (( $(date +%s) < outage_deadline )); do
    remaining=$((outage_deadline - $(date +%s)))
    ((remaining > 15)) && remaining=15
    sleep "$remaining"
  done

  restart_epoch=$(date +%s)
  docker start "$CA_CONTAINER" >/dev/null 2>>"$log" || status=RESTART_FAILED
  recovered_epoch=0
  if [[ $status != RESTART_FAILED ]] && wait_public_state up "$((restart_epoch + 120))"; then
    recovered_epoch=$(date +%s)
    [[ $status == DOWN_CONFIRMED ]] && status=PASS
  else
    status=RECOVERY_FAILED
  fi
  printf '%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n' \
    "$sequence" "$scheduled_epoch" "$down_epoch" "$planned_seconds" "$public_unavailable_epoch" \
    "$restart_epoch" "$recovered_epoch" "$status" >> "$outages"
  printf '%s CA outage complete sequence=%d status=%s recovered_epoch=%d\n' \
    "$(date -Is)" "$sequence" "$status" "$recovered_epoch" >> "$log"
done
