#!/usr/bin/env bash
# Collect logs and scaling history for the last N minutes into evidence/manual-<ts>/ and
# upload them to the artifacts bucket. Use it after a demo or a screen recording.
#
# Usage: AWS_PROFILE=<profile> chaos/collect_evidence.sh [minutes]   (default 60)
#
# Also lists the ALB access logs for the window (they are already in the ALB log bucket)
# and recent FIS experiments.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"

MINUTES="${1:-60}"
OUT="$ROOT/evidence/manual-$(stamp)"
START_MS=$(($(now_ms) - MINUTES * 60 * 1000))

collect_common "$OUT" "$START_MS"
aws fis list-experiments --query 'experiments[].[id, experimentTemplateId, state.status, creationTime]' \
  --output text >"$OUT/fis_experiments.txt" || true
aws s3 ls --recursive "s3://$(out alb_logs_bucket)/alb/AWSLogs/" | tail -200 >"$OUT/alb_access_logs_index.txt" || true
aws cloudwatch describe-alarms --alarm-name-prefix "$(out stack_name)" \
  --query 'MetricAlarms[].[AlarmName, StateValue, StateUpdatedTimestamp]' --output text >"$OUT/alarms_now.txt" || true

log "Collected $MINUTES minutes of evidence in $OUT"
upload_dir "$OUT" evidence
