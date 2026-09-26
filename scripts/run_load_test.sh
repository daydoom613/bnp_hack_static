#!/usr/bin/env bash
# Drive the deployed stack with a traffic profile, then turn the measured cost into
# cost_savings.csv. This is how the optimized monthly cost is measured without
# waiting a month: HourlyCost (published every minute) averaged over the run x 730 h.
#
# Usage:  AWS_PROFILE=<profile> scripts/run_load_test.sh [profile.csv] [run-name]
#   default profile: finops-app/data/traffic_profile_short.csv (75 min, peak -> lull -> mid)
#   full profile:    data/traffic_profiles.csv (4.7 h, the Dataset document's)
#
# Env: PRIORITY_FILE (default data/service_priority_30pct.xlsx: 30 % of traffic critical),
#      CRITICAL_SHARE (overrides the sheet's weights), MAX_ERROR_RATE, MAX_AVG_LATENCY_MS.
# Tip: run it from AWS CloudShell in eu-west-1 so latency is measured in-region.
#
# Writes reports/<run-name>/ (traffic_report.csv, traffic_requests.csv, optimized_cost.json,
# cost_savings.csv, scaling_summary.json, scaling activities) and uploads it to
# s3://<artifacts bucket>/reports/. reports/latest/ gets the newest cost files.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

abs() { echo "$(cd "$(dirname "$1")" && (pwd -W 2>/dev/null || pwd))/$(basename "$1")"; }

PROFILE="$(abs "${1:-$ROOT/finops-app/data/traffic_profile_short.csv}")"
PRIORITY="$(abs "${PRIORITY_FILE:-$ROOT/data/service_priority_30pct.xlsx}")"
RUN="${2:-load-$(stamp)}"
OUT="$ROOT/reports/$RUN"
mkdir -p "$OUT"

BUCKET="$(out artifacts_bucket)"
STACK="$(out stack_name)"
START="$(now)"
START_MS="$(now_ms)"

log "Run $RUN: $(basename "$PROFILE"), priorities $(basename "$PRIORITY"), against $(out app_url)"
set +e
simulate "$PROFILE" "$OUT" \
  SERVICE_PRIORITY_FILE="$PRIORITY" \
  AWS_ENABLED=true S3_BUCKET="$BUCKET" S3_PREFIX="reports/$RUN/" \
  CRITICAL_SHARE="${CRITICAL_SHARE:-}" \
  MAX_ERROR_RATE="${MAX_ERROR_RATE:-}" MAX_AVG_LATENCY_MS="${MAX_AVG_LATENCY_MS:-}"
SIM_EXIT=$?
set -e
END="$(now)"

log "Waiting 2 minutes for the last cost datapoints and scale-in to register..."
sleep 120

# Each step is independent: one failing (e.g. no cost datapoints yet) must not lose the others.
set +e
POST_FAILED=0
step() {
  "$@" || {
    log "WARN: step failed: $*"
    POST_FAILED=1
  }
}
step "$PY" "$ROOT/finops/optimized_cost.py" --stack "$STACK" --start "$START" --end "$END" \
  --region "$REGION" --out "$OUT/optimized_cost.json"
[ -s "$OUT/optimized_cost.json" ] && step "$PY" "$ROOT/finops/cost_report.py" --baseline "$ROOT/data/baseline_cost.json" \
  --optimized "$OUT/optimized_cost.json" --budget-cap-file "$ROOT/data/budget_cap.txt" \
  --out "$OUT/cost_savings.csv"
step "$PY" "$ROOT/finops/window_summary.py" --stack "$STACK" --web-asg "$(out web_asg_name)" \
  --queue "$(out queue_name)" --start "$START" --end "$(now)" --region "$REGION" \
  --out "$OUT/scaling_summary.json"
cp "$ROOT/data/baseline_cost.json" "$OUT/baseline_cost.json"
collect_common "$OUT" "$START_MS"

step upload_dir "$OUT" reports
mkdir -p "$ROOT/reports/latest"
for f in optimized_cost.json cost_savings.csv traffic_report.csv scaling_summary.json; do
  [ -s "$OUT/$f" ] && cp "$OUT/$f" "$ROOT/reports/latest/"
done
[ -s "$OUT/cost_savings.csv" ] && step aws s3 cp --only-show-errors "$OUT/cost_savings.csv" "s3://$BUCKET/reports/latest/cost_savings.csv"

echo
cat "$OUT/cost_savings.csv" 2>/dev/null
echo
log "Simulator exit code: $SIM_EXIT (non-zero = gate failed or errors; see traffic_report.csv)"
[ "$POST_FAILED" -eq 0 ] || log "Some post-processing steps failed (see WARN lines above)"
[ "$SIM_EXIT" -ne 0 ] && exit "$SIM_EXIT"
exit "$POST_FAILED"
