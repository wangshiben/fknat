#!/usr/bin/env bash

set -uo pipefail
umask 077

: "${CLIENT_NAME:?}"
CLIENT_LISTEN_PORT=${CLIENT_LISTEN_PORT:-18081}
CLIENT_BASE_URL="http://127.0.0.1:${CLIENT_LISTEN_PORT}"
plan=/plan/plan.tsv
results=/results/transfers.tsv
progress=/results/progress.env
maximum_attempts=${MAX_ATTEMPTS_PER_FILE:-30}
file_max_time_seconds=${FILE_MAX_TIME_SECONDS:-900}
concurrency=${CLIENT_FILE_CONCURRENCY:-1}

[[ $concurrency =~ ^[1-8]$ ]] || { printf 'invalid CLIENT_FILE_CONCURRENCY=%s\n' "$concurrency" >&2; exit 2; }

worker_root=$(mktemp -d /results/.workers.XXXXXX)
cleanup() { rm -rf "$worker_root"; }
trap cleanup EXIT INT TERM

if [[ ! -s $results ]]; then
  printf 'client\tfile_index\tattempt\tsize_mib\tplanned_bytes\tstarted_epoch\tfinished_epoch\tduration_seconds\treceived_bytes\thttp_code\tcurl_rc\tspeed_bps\texpected_sha\tactual_sha\tstatus\terror\n' > "$results"
elif ! head -n 1 "$results" | grep -Fqx $'client\tfile_index\tattempt\tsize_mib\tplanned_bytes\tstarted_epoch\tfinished_epoch\tduration_seconds\treceived_bytes\thttp_code\tcurl_rc\tspeed_bps\texpected_sha\tactual_sha\tstatus\terror'; then
  printf 'invalid existing transfers.tsv header: %s\n' "$results" >&2
  exit 2
fi

update_progress() {
  local lock="$progress.lock" temporary="$progress.tmp.$$"
  if command -v flock >/dev/null 2>&1; then
    {
      flock -x 9
      awk -F '\t' 'NR > 1 && $15 == "PASS" {files++; mib += $4; last = $2} END {printf "client=%s\nsuccessful_files=%d\nsuccessful_mib=%d\nattempts=%d\nlast_file=%s\nupdated_epoch=%s\n", ENVIRON["CLIENT_NAME"], files+0, mib+0, (NR > 1 ? NR - 1 : 0), last+0, systime()}' "$results" > "$temporary"
      mv -f "$temporary" "$progress"
    } 9>"$lock"
  else
    awk -F '\t' 'NR > 1 && $15 == "PASS" {files++; mib += $4; last = $2} END {printf "client=%s\nsuccessful_files=%d\nsuccessful_mib=%d\nattempts=%d\nlast_file=%s\nupdated_epoch=%s\n", ENVIRON["CLIENT_NAME"], files+0, mib+0, (NR > 1 ? NR - 1 : 0), last+0, systime()}' "$results" > "$temporary"
    mv -f "$temporary" "$progress"
  fi
}

run_file() {
  local file_index=$1 size_mib=$2 variant=$3 worker_id=$4
  local planned_bytes=$((size_mib * 1024 * 1024))
  local payload="$worker_root/current-${worker_id}.bin"
  local metrics="$worker_root/current-${worker_id}.metrics"
  local errors="$worker_root/current-${worker_id}.error"
  local attempt started_epoch finished_epoch expected_sha actual_sha
  local curl_rc http_code received_bytes duration_seconds speed_bps status error
  if awk -F '\t' -v target="$file_index" 'NR > 1 && $2 == target && $15 == "PASS" { found = 1 } END { exit found ? 0 : 1 }' "$results"; then
    return 0
  fi
  for ((attempt = 1; attempt <= maximum_attempts; attempt += 1)); do
    started_epoch=$(date +%s)
    rm -f "$payload" "$metrics" "$errors"
    expected_sha=$(curl -fsS --connect-timeout 30 --max-time 60 "${CLIENT_BASE_URL}/checksum?size_mb=${size_mib}&variant=${variant}" 2>"$errors" | tr -d '\r\n')
    if [[ ! $expected_sha =~ ^[0-9a-f]{64}$ ]]; then
      finished_epoch=$(date +%s)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\t0\t000\t1\t0\t%s\t\tCHECKSUM_FAILED\tchecksum_request_failed\n' "$CLIENT_NAME" "$file_index" "$attempt" "$size_mib" "$planned_bytes" "$started_epoch" "$finished_epoch" "$expected_sha" >> "$results"
      sleep 10
      continue
    fi
    curl -fsS --connect-timeout 30 --max-time "$file_max_time_seconds" -o "$payload" -w '%{http_code}\t%{size_download}\t%{time_total}\t%{speed_download}' "${CLIENT_BASE_URL}/file?size_mb=${size_mib}&variant=${variant}" >"$metrics" 2>>"$errors"
    curl_rc=$?
    IFS=$'\t' read -r http_code received_bytes duration_seconds speed_bps < "$metrics" || true
    http_code=${http_code:-000}; received_bytes=${received_bytes:-0}; duration_seconds=${duration_seconds:-0}; speed_bps=${speed_bps:-0}
    actual_sha=""; status=TRANSFER_FAILED; error=curl_error
    if ((curl_rc == 0)); then
      actual_sha=$(sha256sum "$payload" | awk '{print $1}')
      if [[ $actual_sha == "$expected_sha" && $received_bytes == "$planned_bytes" ]]; then status=PASS; error=none
      elif [[ $actual_sha != "$expected_sha" ]]; then status=SHA_FAILED; error=sha256_mismatch
      else status=SIZE_FAILED; error=size_mismatch; fi
    elif ((curl_rc == 28)); then status=TIMEOUT; error=transfer_timeout; fi
    finished_epoch=$(date +%s)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CLIENT_NAME" "$file_index" "$attempt" "$size_mib" "$planned_bytes" "$started_epoch" "$finished_epoch" "$duration_seconds" "$received_bytes" "$http_code" "$curl_rc" "$speed_bps" "$expected_sha" "$actual_sha" "$status" "$error" >> "$results"
    rm -f "$payload" "$metrics" "$errors"
    if [[ $status == PASS ]]; then update_progress; return 0; fi
    sleep 10
  done
  return 1
}

worker_loop() {
  local worker_id=$1 file_index size_mib variant
  while IFS=$'\t' read -r file_index size_mib variant; do
    [[ $file_index == file_index ]] && continue
    [[ $file_index =~ ^[0-9]+$ && $size_mib =~ ^[0-9]+$ && $variant =~ ^[a-z0-9-]+$ ]] || return 2
    (( (file_index - 1) % concurrency == worker_id )) || continue
    if ! run_file "$file_index" "$size_mib" "$variant" "$worker_id"; then
      printf '%s\n' "$file_index" > "$worker_root/failed-${worker_id}"
      return 1
    fi
  done < "$plan"
  return 0
}

pids=()
for ((worker_id = 0; worker_id < concurrency; worker_id += 1)); do
  worker_loop "$worker_id" >"$worker_root/worker-${worker_id}.log" 2>&1 &
  pids+=("$!")
done
worker_status=0
for pid in "${pids[@]}"; do wait "$pid" || worker_status=1; done

summary=$(awk -F '\t' 'NR > 1 && $15 == "PASS" {files++; mib += $4; bytes += $9} NR > 1 {attempts++} END {printf "%d\t%d\t%d\t%d\n", files+0, mib+0, bytes+0, attempts+0}' "$results")
IFS=$'\t' read -r successful_files successful_mib successful_bytes attempts <<< "$summary"
if ((worker_status != 0)); then
  failed_file=$(find "$worker_root" -type f -name 'failed-*' -exec head -n 1 {} \; | tail -n 1)
  printf 'client=%s\nstatus=FAILED\nfailed_file=%s\nsuccessful_mib=%s\nattempts=%s\n' "$CLIENT_NAME" "${failed_file:-unknown}" "$successful_mib" "$attempts" > /results/summary.env
  exit 1
fi
worker_started=$(awk -F '\t' 'NR > 1 && $6 ~ /^[0-9]+$/ {if (!min || $6 < min) min=$6} END {print min+0}' "$results")
worker_finished=$(awk -F '\t' 'NR > 1 && $7 ~ /^[0-9]+$/ {if ($7 > max) max=$7} END {print max+0}' "$results")
printf 'client=%s\nstatus=PASS\nstarted_epoch=%s\nfinished_epoch=%s\nsuccessful_files=%s\nsuccessful_mib=%s\nsuccessful_bytes=%s\nattempts=%s\n' "$CLIENT_NAME" "$worker_started" "$worker_finished" "$successful_files" "$successful_mib" "$successful_bytes" "$attempts" > /results/summary.env
touch /results/complete
