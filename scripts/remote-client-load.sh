#!/usr/bin/env bash
set -Eeuo pipefail

# Runs on the remote NAT Client host. Response bodies are streamed through
# sha256sum and wc; no HTTP payload is written to disk.
RUN_DIR=${RUN_DIR:?}
DURATION_SECONDS=${DURATION_SECONDS:-10800}
REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS:-600}
SIZE_MB=${SIZE_MB:-4}
PORT1=${PORT1:-29200}
PORT2=${PORT2:-29201}
THREADS=${THREADS:-6}
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"
printf 'started_epoch=%s\nduration_seconds=%s\nsize_mb=%s\nthreads=%s\n' "$(date +%s)" "$DURATION_SECONDS" "$SIZE_MB" "$THREADS" > "$RUN_DIR/metadata.env"
expected1=$(curl -fsS --max-time 30 "http://127.0.0.1:$PORT1/checksum?size_mb=$SIZE_MB")
expected2=$(curl -fsS --max-time 30 "http://127.0.0.1:$PORT2/checksum?size_mb=$SIZE_MB")
printf 'expected_port1=%s\nexpected_port2=%s\n' "$expected1" "$expected2" >> "$RUN_DIR/metadata.env"
printf 'epoch\tthread\tport\tbytes\tsha256\tstatus\telapsed_ms\tdetail\n' > "$RUN_DIR/results.tsv"
deadline=$(( $(date +%s) + DURATION_SECONDS ))
request_one() {
  local thread=$1 port=$2 expected=$3 seq=$4 start end elapsed body_hash bytes status detail hash_file bytes_file status_text
  hash_file=$(mktemp "$RUN_DIR/hash.XXXXXX")
  bytes_file=$(mktemp "$RUN_DIR/bytes.XXXXXX")
  start=$(date +%s%N)
  set +e
  curl --silent --show-error --fail --connect-timeout 15 --max-time "$REQUEST_TIMEOUT_SECONDS" \
    "http://127.0.0.1:$port/file?size_mb=$SIZE_MB" \
    > >(tee >(sha256sum | awk '{print $1}' > "$hash_file") | wc -c > "$bytes_file") 2>"$RUN_DIR/error-$thread.log"
  status=$?
  wait || true
  end=$(date +%s%N)
  elapsed=$(( (end - start) / 1000000 ))
  body_hash=$(tr -d '[:space:]' < "$hash_file" 2>/dev/null || true)
  bytes=$(tr -d '[:space:]' < "$bytes_file" 2>/dev/null || true)
  detail=""
  if [[ $status -ne 0 ]]; then
    detail="curl_exit=$status"
  elif [[ $body_hash != "$expected" ]]; then
    status=2
    detail="sha256_mismatch expected=$expected actual=$body_hash"
  elif [[ $bytes != $((SIZE_MB * 1024 * 1024)) ]]; then
    status=3
    detail="byte_mismatch expected=$((SIZE_MB * 1024 * 1024)) actual=$bytes"
  fi
  if [[ $status -eq 0 ]]; then status_text=PASS; else status_text=FAIL; fi
  {
    flock 9
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$thread" "$port" "${bytes:-0}" "$body_hash" "$status_text" "$elapsed" "$detail"
  } 9>>"$RUN_DIR/results.lock" >>"$RUN_DIR/results.tsv"
  if [[ $status -ne 0 ]]; then return 1; fi
}
worker() {
  local thread=$1 port=$2 expected=$3 seq=0
  while (( $(date +%s) < deadline )); do
    seq=$((seq + 1))
    request_one "$thread" "$port" "$expected" "$seq" || true
  done
}
for index in 1 2 3; do worker "p1-$index" "$PORT1" "$expected1" & done
for index in 1 2 3; do worker "p2-$index" "$PORT2" "$expected2" & done
wait
total=$(awk 'NR>1{total++} END{print total+0}' "$RUN_DIR/results.tsv")
passed=$(awk -F '\t' 'NR>1 && $6=="PASS"{passed++} END{print passed+0}' "$RUN_DIR/results.tsv")
failed=$((total - passed))
success_rate=0
if (( total > 0 )); then success_rate=$((passed * 10000 / total)); fi
printf 'finished_epoch=%s\ntotal=%s\npassed=%s\nfailed=%s\nsuccess_rate_basis_points=%s\n' "$(date +%s)" "$total" "$passed" "$failed" "$success_rate" > "$RUN_DIR/summary.env"
if (( total == 0 || success_rate < 9000 )); then exit 1; fi
