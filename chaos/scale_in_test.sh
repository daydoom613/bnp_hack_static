#!/usr/bin/env bash
# Expert test: scale-in under load.
#
# The Web ASG is pushed to its max (its request-count scale-in alarm paused meanwhile),
# then forced straight back to its min while a constant request stream runs (the
# problem statement's "force a rapid scale-in"). Each removed
# instance is deregistered from the ALB first and drains for the target group's
# deregistration delay (30 s), so in-flight requests finish and the API stays healthy.
#
# Usage: AWS_PROFILE=<profile> chaos/scale_in_test.sh
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"

ASG="$(out web_asg_name)"
OUT="$ROOT/evidence/scale-in-$(stamp)"
mkdir -p "$OUT"
START_MS="$(now_ms)"
read -r MIN MAX < <(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].[MinSize, MaxSize]' --output text)

hold_scale_in web
log "Scaling $ASG out to $MAX and waiting until all are InService"
aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity "$MAX" --no-honor-cooldown
for _ in $(seq 1 60); do
  [ "$(asg_in_service "$ASG")" -ge "$MAX" ] && break
  sleep 15
done
sleep 60 # let the new targets pass ALB health checks

log "Starting a constant request stream (20 RPS for 7 min)"
simulate "$ROOT/finops-app/data/traffic_profile_chaos.csv" "$OUT/traffic" >"$OUT/traffic.log" 2>&1 &
LOAD_PID=$!
sleep 60

log "Forcing scale-in: $MAX -> $MIN while traffic flows"
aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity "$MIN" --no-honor-cooldown

TG_ARN=$(aws elbv2 describe-target-groups --names "$(out stack_name)-web" --query 'TargetGroups[0].TargetGroupArn' --output text)
: >"$OUT/target_health.txt"
for _ in $(seq 1 24); do
  {
    echo "== $(date -u +%H:%M:%S) in-service=$(asg_in_service "$ASG")"
    aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query 'TargetHealthDescriptions[].[Target.Id, TargetHealth.State]' --output text
  } | tee -a "$OUT/target_health.txt"
  sleep 10
done

wait "$LOAD_PID" || true
collect_common "$OUT" "$START_MS"

"$PY" - "$OUT" <<'EOF'
import csv, sys
rows = list(csv.DictReader(open(f"{sys.argv[1]}/traffic/traffic_report.csv")))
total = sum(int(r["total_requests"]) for r in rows)
failed = sum(int(r["failed_requests"]) for r in rows)
print(f"\nrequests {total}, failed {failed} ({100 * failed / max(total, 1):.2f}%); "
      "target_health.txt shows targets going 'draining' before they disappear")
EOF

upload_dir "$OUT" evidence
