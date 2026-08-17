#!/usr/bin/env bash

set -uo pipefail

base_url=${BASE_URL:-http://127.0.0.1:18081}
output_dir=${OUTPUT_DIR:-}
duration_seconds=${DURATION_SECONDS:-1800}
interval_seconds=${INTERVAL_SECONDS:-40}
minimum_size_mib=${MIN_SIZE_MIB:-100}
maximum_size_mib=${MAX_SIZE_MIB:-200}
transfer_timeout_seconds=${TRANSFER_TIMEOUT_SECONDS:-600}

if [[ -z $output_dir || $output_dir == / ]]; then
  echo "OUTPUT_DIR must be a non-root directory" >&2
  exit 2
fi
for value in "$duration_seconds" "$interval_seconds" "$minimum_size_mib" \
  "$maximum_size_mib" "$transfer_timeout_seconds"; do
  if [[ ! $value =~ ^[0-9]+$ || $value -le 0 ]]; then
    echo "duration, interval, sizes and timeout must be positive integers" >&2
    exit 2
  fi
done
if (( minimum_size_mib > maximum_size_mib )); then
  echo "MIN_SIZE_MIB must not exceed MAX_SIZE_MIB" >&2
  exit 2
fi

umask 077
mkdir -p "$output_dir/results" "$output_dir/payloads" "$output_dir/errors"
results_file=$output_dir/transfers.tsv
summary_file=$output_dir/summary.env
start_epoch=$(date +%s)
deadline_epoch=$((start_epoch + duration_seconds))
range=$((maximum_size_mib - minimum_size_mib + 1))

printf 'index\tscheduled_epoch\tstarted_epoch\tfinished_epoch\tsize_mib\tbytes\tcurl_rc\thttp_code\ttime_seconds\tspeed_bps\texpected_sha\tactual_sha\tstatus\terror\n' \
  > "$results_file"

random_size() {
  local random_value
  random_value=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
  printf '%d\n' $((minimum_size_mib + random_value % range))
}

record_result() {
  local index=$1
  shift
  local result_file=$output_dir/results/$(printf '%04d' "$index").tsv
  printf '%s' "$index" > "$result_file"
  for field in "$@"; do
    printf '\t%s' "$field" >> "$result_file"
  done
  printf '\n' >> "$result_file"
}

run_transfer() {
  local index=$1
  local scheduled_epoch=$2
  local size_mib=$3
  local started_epoch finished_epoch timeout
  local expected_sha actual_sha status error_code
  local payload_file metrics_file error_file checksum_url file_url
  local curl_rc http_code bytes time_seconds speed_bps

  started_epoch=$(date +%s)
  payload_file=$output_dir/payloads/$(printf '%04d' "$index").bin
  metrics_file=$output_dir/results/$(printf '%04d' "$index").metrics
  error_file=$output_dir/errors/$(printf '%04d' "$index").log
  checksum_url="$base_url/checksum?size_mb=$size_mib"
  file_url="$base_url/file?size_mb=$size_mib"
  expected_sha=$(curl -fsS --max-time 60 "$checksum_url" 2>"$error_file" | tr -d '\r\n')
  if [[ ! $expected_sha =~ ^[0-9a-f]{64}$ ]]; then
    finished_epoch=$(date +%s)
    record_result "$index" "$scheduled_epoch" "$started_epoch" "$finished_epoch" "$size_mib" \
      0 1 000 0 0 "$expected_sha" "" CHECKSUM_FAILED checksum_request_failed
    return
  fi

  timeout=$transfer_timeout_seconds

  curl -fsS --max-time "$timeout" -o "$payload_file" \
    -w '%{http_code}\t%{size_download}\t%{time_total}\t%{speed_download}' \
    "$file_url" >"$metrics_file" 2>>"$error_file"
  curl_rc=$?
  IFS=$'\t' read -r http_code bytes time_seconds speed_bps < "$metrics_file"
  http_code=${http_code:-000}
  bytes=${bytes:-0}
  time_seconds=${time_seconds:-0}
  speed_bps=${speed_bps:-0}
  actual_sha=""
  status=TRANSFER_FAILED
  error_code=curl_error
  if (( curl_rc == 0 )); then
    actual_sha=$(sha256sum "$payload_file" | awk '{print $1}')
    if [[ $actual_sha == "$expected_sha" ]]; then
      status=PASS
      error_code=none
    else
      status=SHA_FAILED
      error_code=sha256_mismatch
    fi
  elif (( curl_rc == 28 )); then
    status=TIMEOUT
    error_code=transfer_timeout
  fi
  finished_epoch=$(date +%s)
  record_result "$index" "$scheduled_epoch" "$started_epoch" "$finished_epoch" "$size_mib" \
    "$bytes" "$curl_rc" "$http_code" "$time_seconds" "$speed_bps" "$expected_sha" \
    "$actual_sha" "$status" "$error_code"
  if [[ -f $payload_file ]]; then
    unlink "$payload_file"
  fi
}

if ! curl -fsS --max-time 30 "$base_url/health" >/dev/null; then
  echo "fknat health check failed: $base_url/health" >&2
  exit 1
fi

echo "start_epoch=$start_epoch deadline_epoch=$deadline_epoch interval_seconds=$interval_seconds size_mib=$minimum_size_mib..$maximum_size_mib"
pids=()
index=0
for ((offset = 0; offset < duration_seconds; offset += interval_seconds)); do
  target_epoch=$((start_epoch + offset))
  now=$(date +%s)
  if (( now < target_epoch )); then
    sleep $((target_epoch - now))
  fi
  index=$((index + 1))
  size_mib=$(random_size)
  echo "launch index=$index scheduled_epoch=$target_epoch size_mib=$size_mib"
  run_transfer "$index" "$target_epoch" "$size_mib" &
  pids+=("$!")
done

for pid in "${pids[@]}"; do
  wait "$pid" || true
done

for result_file in "$output_dir"/results/*.tsv; do
  [[ $result_file == "$results_file" ]] && continue
  cat "$result_file" >> "$results_file"
done
sort -t $'\t' -k1,1n "$results_file" -o "$results_file"
finished_epoch=$(date +%s)
awk -F '\t' -v started="$start_epoch" -v deadline="$deadline_epoch" -v finished="$finished_epoch" '
  NR == 1 { next }
  {
    transfers++
    requested_mib += $5
    bytes += $6
    status[$13]++
    if (($10 + 0) > 0) {
      speed_sum += $10
      speed_samples++
    }
  }
  END {
    printf "started_epoch=%d\n", started
    printf "deadline_epoch=%d\n", deadline
    printf "finished_epoch=%d\n", finished
    printf "launched_transfers=%d\n", transfers
    printf "requested_mib=%d\n", requested_mib
    printf "received_bytes=%.0f\n", bytes
    printf "pass=%d\n", status["PASS"] + 0
    printf "timeout=%d\n", status["TIMEOUT"] + 0
    printf "deadline=%d\n", status["DEADLINE"] + 0
    printf "checksum_failed=%d\n", status["CHECKSUM_FAILED"] + 0
    printf "sha_failed=%d\n", status["SHA_FAILED"] + 0
    printf "transfer_failed=%d\n", status["TRANSFER_FAILED"] + 0
    printf "average_reported_speed_bps=%.0f\n", speed_samples ? speed_sum / speed_samples : 0
  }
' "$results_file" > "$summary_file"
cat "$summary_file"
