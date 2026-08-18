#!/usr/bin/env bash

set -uo pipefail
umask 077

: "${CLIENT_NAME:?}"
plan=/plan/plan.tsv
results=/results/transfers.tsv
progress=/results/progress.env
payload=/results/current.bin
metrics=/results/current.metrics
errors=/results/current.error
maximum_attempts=${MAX_ATTEMPTS_PER_FILE:-30}

printf 'client\tfile_index\tattempt\tsize_mib\tplanned_bytes\tstarted_epoch\tfinished_epoch\tduration_seconds\treceived_bytes\thttp_code\tcurl_rc\tspeed_bps\texpected_sha\tactual_sha\tstatus\terror\n' > "$results"

successful_files=0
successful_mib=0
attempts=0
worker_started=$(date +%s)

while IFS=$'\t' read -r file_index size_mib variant; do
  [[ $file_index == file_index ]] && continue
  [[ $file_index =~ ^[0-9]+$ && $size_mib =~ ^[0-9]+$ && $variant =~ ^[a-z0-9-]+$ ]] || exit 2
  planned_bytes=$((size_mib * 1024 * 1024))
  file_passed=0
  for ((attempt = 1; attempt <= maximum_attempts; attempt += 1)); do
    attempts=$((attempts + 1))
    started_epoch=$(date +%s)
    rm -f "$payload" "$metrics" "$errors"
    expected_sha=$(curl -fsS --connect-timeout 30 --max-time 60 \
      "http://127.0.0.1:18081/checksum?size_mb=${size_mib}&variant=${variant}" \
      2>"$errors" | tr -d '\r\n')
    if [[ ! $expected_sha =~ ^[0-9a-f]{64}$ ]]; then
      finished_epoch=$(date +%s)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\t0\t000\t1\t0\t%s\t\tCHECKSUM_FAILED\tchecksum_request_failed\n' \
        "$CLIENT_NAME" "$file_index" "$attempt" "$size_mib" "$planned_bytes" \
        "$started_epoch" "$finished_epoch" "$expected_sha" >> "$results"
      sleep 10
      continue
    fi

    curl -fsS --connect-timeout 30 --max-time 900 -o "$payload" \
      -w '%{http_code}\t%{size_download}\t%{time_total}\t%{speed_download}' \
      "http://127.0.0.1:18081/file?size_mb=${size_mib}&variant=${variant}" \
      >"$metrics" 2>>"$errors"
    curl_rc=$?
    IFS=$'\t' read -r http_code received_bytes duration_seconds speed_bps < "$metrics" || true
    http_code=${http_code:-000}
    received_bytes=${received_bytes:-0}
    duration_seconds=${duration_seconds:-0}
    speed_bps=${speed_bps:-0}
    actual_sha=""
    status=TRANSFER_FAILED
    error=curl_error
    if ((curl_rc == 0)); then
      actual_sha=$(sha256sum "$payload" | awk '{print $1}')
      if [[ $actual_sha == "$expected_sha" && $received_bytes == "$planned_bytes" ]]; then
        status=PASS
        error=none
      elif [[ $actual_sha != "$expected_sha" ]]; then
        status=SHA_FAILED
        error=sha256_mismatch
      else
        status=SIZE_FAILED
        error=size_mismatch
      fi
    elif ((curl_rc == 28)); then
      status=TIMEOUT
      error=transfer_timeout
    fi
    finished_epoch=$(date +%s)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$CLIENT_NAME" "$file_index" "$attempt" "$size_mib" "$planned_bytes" \
      "$started_epoch" "$finished_epoch" "$duration_seconds" "$received_bytes" "$http_code" \
      "$curl_rc" "$speed_bps" "$expected_sha" "$actual_sha" "$status" "$error" >> "$results"
    rm -f "$payload" "$metrics" "$errors"
    if [[ $status == PASS ]]; then
      successful_files=$((successful_files + 1))
      successful_mib=$((successful_mib + size_mib))
      printf 'client=%s\nsuccessful_files=%d\nsuccessful_mib=%d\nattempts=%d\nlast_file=%s\nupdated_epoch=%s\n' \
        "$CLIENT_NAME" "$successful_files" "$successful_mib" "$attempts" "$file_index" "$(date +%s)" > "$progress"
      file_passed=1
      break
    fi
    sleep 10
  done
  if [[ $file_passed != 1 ]]; then
    printf 'client=%s\nstatus=FAILED\nfailed_file=%s\nsuccessful_mib=%d\nattempts=%d\n' \
      "$CLIENT_NAME" "$file_index" "$successful_mib" "$attempts" > /results/summary.env
    exit 1
  fi
done < "$plan"

worker_finished=$(date +%s)
printf 'client=%s\nstatus=PASS\nstarted_epoch=%s\nfinished_epoch=%s\nsuccessful_files=%d\nsuccessful_mib=%d\nsuccessful_bytes=%d\nattempts=%d\n' \
  "$CLIENT_NAME" "$worker_started" "$worker_finished" "$successful_files" "$successful_mib" \
  "$((successful_mib * 1024 * 1024))" "$attempts" > /results/summary.env
touch /results/complete
