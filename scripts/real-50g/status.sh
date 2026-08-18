#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
run_id=${1:?usage: status.sh RUN_ID}
results=$ROOT_DIR/test-results/$run_id
[[ -d $results ]] || {
  printf 'run not found: %s\n' "$run_id" >&2
  exit 1
}
printf 'phase=%s\n' "$(cat "$results/phase" 2>/dev/null || printf unknown)"
for client in "$results"/client-*; do
  [[ -d $client ]] || continue
  name=$(basename "$client")
  mib=$(awk -F= '$1 == "successful_mib" {print $2}' "$client/progress.env" 2>/dev/null)
  printf '%s=%s MiB\n' "$name" "${mib:-0}"
done
printf 'total_mib='
total_mib=$(awk -F= '$1 == "successful_mib" {sum += $2} END {print sum + 0}' "$results"/client-*/progress.env 2>/dev/null || true)
printf '%s\n' "${total_mib:-0}"
outage_count=0
if [[ -f $results/ca-outages.tsv ]]; then
  outage_count=$(( $(wc -l < "$results/ca-outages.tsv") - 1 ))
fi
printf 'outages=%s\n' "$outage_count"
