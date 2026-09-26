#!/usr/bin/env bash
# Advanced test: a custom queue_length metric spiking to 120 makes the Lambda-driven step
# scaling add a Spot worker: Worker ASG desired capacity +1.
#
# The worker fleet starts at 3 (70/30 rounds the On-Demand share up, so 3 = 3 On-Demand);
# the +1 takes it to 4 = 3 On-Demand + 1 Spot, so the added capacity is the Spot share.
# queue_length is normally published every minute by the metrics Lambda; this writes one
# extra datapoint of 120, and the alarm uses Maximum, so the spike wins that minute.
#
# Usage: AWS_PROFILE=<profile> scripts/test_queue_spike.sh
#   START_AT=3   worker desired capacity before the spike (must be < max)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ASG="$(out worker_asg_name)"
QUEUE="$(out queue_name)"
START_AT="${START_AT:-3}"
OUT="$ROOT/evidence/queue-spike-$(stamp)"
mkdir -p "$OUT"
START_MS="$(now_ms)"

MAX=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --query 'AutoScalingGroups[0].MaxSize' --output text)
if [ "$START_AT" -ge "$MAX" ]; then
  echo "START_AT ($START_AT) must be below the worker max ($MAX)." >&2
  exit 1
fi

hold_worker_scale_in
log "Setting $ASG to $START_AT workers and waiting until they are InService"
aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity "$START_AT" --no-honor-cooldown
wait_in_service "$ASG" "$START_AT" || log "WARN: not all $START_AT workers InService yet; continuing"
# Let the queue_length-high alarm settle back to OK before the spike.
sleep 90

BEFORE="$(asg_desired "$ASG")"
worker_instances | tee "$OUT/workers_before.txt"
log "$ASG desired capacity before: $BEFORE"

aws cloudwatch put-metric-data --namespace FinOps/App --metric-name queue_length \
  --dimensions "QueueName=$QUEUE" --value 120 --unit Count
log "Published FinOps/App queue_length=120 (QueueName=$QUEUE). Waiting for alarm -> step policy..."

AFTER="$BEFORE"
for _ in $(seq 1 24); do
  sleep 15
  AFTER="$(asg_desired "$ASG")"
  if [ "$AFTER" -gt "$BEFORE" ]; then
    break
  fi
done
log "$ASG desired capacity after: $AFTER"

SPOT="no"
if [ "$AFTER" -gt "$BEFORE" ]; then
  log "Waiting for the new worker to launch..."
  for _ in $(seq 1 24); do
    if worker_instances | grep -q 'spot'; then
      SPOT="yes"
      break
    fi
    sleep 15
  done
fi
worker_instances | tee "$OUT/workers_after.txt"

collect_common "$OUT" "$START_MS"
aws autoscaling describe-scaling-activities --auto-scaling-group-name "$ASG" --max-items 3 \
  --query 'Activities[].[StartTime, StatusCode, Description]' --output table | tee "$OUT/latest_activities.txt"
echo "before=$BEFORE after=$AFTER spot_worker_present=$SPOT" | tee "$OUT/result.txt"
upload_dir "$OUT" evidence

if [ "$AFTER" -eq $((BEFORE + 1)) ] && [ "$SPOT" = "yes" ]; then
  log "PASS: desired capacity $BEFORE -> $AFTER and the added capacity is a Spot worker"
else
  log "FAIL: expected desired $((BEFORE + 1)) with a Spot worker; got desired $AFTER, spot=$SPOT"
  exit 1
fi
