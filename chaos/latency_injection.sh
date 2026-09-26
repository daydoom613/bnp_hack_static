#!/usr/bin/env bash
# Expert test: network-latency injection.
#
# tc netem adds DELAY_MS latency and LOSS_PERCENT packet loss for DURATION seconds on
# the web instances' traffic to the ALB (the SSM document reverts it on its own).
# Background traffic runs throughout; the report compares latency before / during /
# after the fault. Expected: latency increase <= 300 ms, error rate <= 2 %.
#
# Usage: AWS_PROFILE=<profile> chaos/latency_injection.sh
#   DELAY_MS=200 LOSS_PERCENT=5 DURATION=60   (defaults: the problem statement's values)
#   TARGETS=all|one                           (all web instances, or just one)
#
# Measure from AWS CloudShell in eu-west-1: from a laptop far away, the internet round
# trip alone can exceed 300 ms and hide what the fault does.
set -euo pipefail
source "$(dirname "$0")/../scripts/lib.sh"

DELAY_MS="${DELAY_MS:-200}"
LOSS_PERCENT="${LOSS_PERCENT:-5}"
DURATION="${DURATION:-60}"
TARGETS="${TARGETS:-all}"

OUT="$ROOT/evidence/latency-$(stamp)"
mkdir -p "$OUT"
START_MS="$(now_ms)"

INSTANCES=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$(out web_asg_name)" \
  --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" --output text)
[ "$TARGETS" = "one" ] && INSTANCES="$(echo "$INSTANCES" | awk '{print $1}')"
log "Targets: $INSTANCES"

log "Starting background traffic (20 RPS for 7 min)"
simulate "$ROOT/finops-app/data/traffic_profile_chaos.csv" "$OUT/traffic" >"$OUT/traffic.log" 2>&1 &
LOAD_PID=$!
sleep 90

FAULT_START="$(now)"
# shellcheck disable=SC2086
COMMAND=$(aws ssm send-command --document-name "$(out latency_document)" --instance-ids $INSTANCES \
  --comment "finops-cloudscale latency chaos" \
  --parameters "DelayMs=$DELAY_MS,LossPercent=$LOSS_PERCENT,DurationSeconds=$DURATION,TargetCidrs=$(out alb_subnet_cidrs)" \
  --query 'Command.CommandId' --output text)
log "netem +${DELAY_MS}ms / ${LOSS_PERCENT}% loss for ${DURATION}s on the ALB path (SSM command $COMMAND)"
sleep $((DURATION + 10))
FAULT_END="$(now)"

wait "$LOAD_PID" || true
aws ssm list-command-invocations --command-id "$COMMAND" --details --output json >"$OUT/ssm_command.json"
aws cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name TargetResponseTime \
  --dimensions "Name=LoadBalancer,Value=$(aws elbv2 describe-load-balancers --names "$(out stack_name)-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text | sed 's#.*:loadbalancer/##')" \
  --start-time "$(date -u -d "@$((START_MS / 1000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$FAULT_START")" \
  --end-time "$(now)" --period 60 --statistics Average Maximum --output json >"$OUT/alb_target_response_time.json" || true
collect_common "$OUT" "$START_MS"

"$PY" - "$OUT" "$FAULT_START" "$FAULT_END" <<'EOF'
import csv, json, sys
from datetime import datetime

out, fault_start, fault_end = sys.argv[1:4]
start = datetime.fromisoformat(fault_start.replace("Z", "+00:00"))
end = datetime.fromisoformat(fault_end.replace("Z", "+00:00"))
phases = {"before": [], "during": [], "after": []}
errors = {"before": 0, "during": 0, "after": 0}
for r in csv.DictReader(open(f"{out}/traffic/traffic_requests.csv")):
    t = datetime.fromisoformat(r["timestamp"])
    phase = "before" if t < start else "during" if t <= end else "after"
    if r["success"] == "True":
        phases[phase].append(float(r["latency_ms"]))
    else:
        errors[phase] += 1

def stats(values, errs):
    values = sorted(values)
    n = len(values) + errs
    return {"requests": n,
            "avg_ms": round(sum(values) / len(values), 1) if values else None,
            "p95_ms": values[int(0.95 * (len(values) - 1))] if values else None,
            "error_rate_percent": round(100 * errs / n, 2) if n else None}

summary = {p: stats(v, errors[p]) for p, v in phases.items()}
b, d = summary["before"], summary["during"]
if b["avg_ms"] is not None and d["avg_ms"] is not None:
    summary["avg_increase_ms"] = round(d["avg_ms"] - b["avg_ms"], 1)
    summary["p95_increase_ms"] = round(d["p95_ms"] - b["p95_ms"], 1)
    summary["pass_latency_increase_le_300ms"] = summary["p95_increase_ms"] <= 300
    summary["pass_error_rate_le_2pct"] = (d["error_rate_percent"] or 0) <= 2
json.dump(summary, open(f"{out}/latency_summary.json", "w"), indent=2)
print(json.dumps(summary, indent=2))
EOF

upload_dir "$OUT" evidence
