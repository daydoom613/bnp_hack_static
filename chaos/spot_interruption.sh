#!/usr/bin/env bash
# Expert test: Spot-termination fault.
#
# One running Spot worker is taken away while traffic (and therefore background jobs)
# is flowing:
#   * with AWS FIS (enable_fis = true): a real 2-minute Spot interruption notice
#   * without FIS (accounts that cannot use it): a scripted Spot termination through
#     Auto Scaling (terminate-instance-in-auto-scaling-group, desired capacity kept)
# Expected:
#   * the lifecycle hook fires -> drain Lambda deregisters the worker and `docker stop`s
#     it (the app stops polling SQS and finishes its jobs)
#   * a replacement worker is InService within ~2 minutes (capacity rebalance)
#   * no request gets a 5xx (API traffic is on the On-Demand web tier), no job is lost
#
# Usage: AWS_PROFILE=<profile> chaos/spot_interruption.sh
# Evidence: evidence/spot-interruption-<timestamp>/ and s3://<artifacts>/evidence/
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"

OUT="$ROOT/evidence/spot-interruption-$(stamp)"
mkdir -p "$OUT"
ASG="$(out worker_asg_name)"

ensure_spot_worker
START_MS="$(now_ms)"
worker_instances | tee "$OUT/workers_before.txt"

log "Starting background traffic (20 RPS for 7 min) so jobs are running during the fault"
simulate "$ROOT/finops-app/data/traffic_profile_chaos.csv" "$OUT/traffic" >"$OUT/traffic.log" 2>&1 &
LOAD_PID=$!
sleep 45

TEMPLATE="$(out fis_spot_template_id)"
EXPERIMENT=""
if [ -n "$TEMPLATE" ]; then
  EXPERIMENT=$(aws fis start-experiment --experiment-template-id "$TEMPLATE" \
    --tags "Name=$(out stack_name)-spot-interruption" --query 'experiment.id' --output text)
  log "FIS experiment $EXPERIMENT started"
else
  VICTIM=$(worker_instances | awk '$2 == "spot" && $3 == "running" { print $1; exit }')
  echo "$VICTIM" >"$OUT/terminated_spot_instance.txt"
  aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$VICTIM" \
    --no-should-decrement-desired-capacity --query 'Activity.Description' --output text | tee "$OUT/termination_activity.txt"
  log "Scripted Spot termination of $VICTIM (no FIS in this account)"
fi
FAULT_AT=$(date +%s)

# Timeline: every 10 s, the ASG's view of its instances.
: >"$OUT/timeline.txt"
for _ in $(seq 1 36); do
  {
    state="scripted"
    [ -n "$EXPERIMENT" ] && state="$(aws fis get-experiment --id "$EXPERIMENT" --query 'experiment.state.status' --output text)"
    echo "== $(date -u +%H:%M:%S) (+$(($(date +%s) - FAULT_AT))s) fault=$state"
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
      --query 'AutoScalingGroups[0].Instances[].[InstanceId, LifecycleState, HealthStatus, InstanceType]' --output text
  } | tee -a "$OUT/timeline.txt"
  sleep 10
done

wait "$LOAD_PID" || true
worker_instances | tee "$OUT/workers_after.txt"
if [ -n "$EXPERIMENT" ]; then
  aws fis get-experiment --id "$EXPERIMENT" --output json >"$OUT/fis_experiment.json"
fi
collect_common "$OUT" "$START_MS"

"$PY" - "$OUT" <<'EOF'
import csv, sys
out = sys.argv[1]
before = {l.split()[0] for l in open(f"{out}/workers_before.txt") if l.strip()}
after = {l.split()[0] for l in open(f"{out}/workers_after.txt") if l.strip()}
rows = list(csv.DictReader(open(f"{out}/traffic/traffic_report.csv")))
failed = sum(int(r["failed_requests"]) for r in rows)
total = sum(int(r["total_requests"]) for r in rows)
drained = open(f"{out}/drain_lambda.log").read().count("lifecycle_completed")
print(f"\nreplaced instances : {sorted(before - after)} -> new {sorted(after - before)}")
print(f"drain Lambda runs  : {drained} lifecycle actions completed")
print(f"requests           : {total}, failed {failed} ({100 * failed / max(total, 1):.2f}%)")
print("see timeline.txt for the time from the notice to the replacement being InService")
EOF

upload_dir "$OUT" evidence
