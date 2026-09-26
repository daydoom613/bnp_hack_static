#!/usr/bin/env bash
# Live demo: hit the deployed stack with a short, sharp traffic profile and print the
# fleet reacting every 15 s, while Grafana (observability/) shows the same thing live.
#
#   AWS_PROFILE=<profile> scripts/live_demo.sh [profile.csv]
#     default profile: finops-app/data/traffic_profile_live_demo.csv
#                      (15 min: 1 min warm-up -> 9 min at 200 RPS -> 5 min lull)
#
#   FROM=region (default)  the load is generated INSIDE eu-west-1: the real traffic
#                          simulator runs in a container on a worker instance (sent over
#                          SSM), so responses come back in ~40 ms like for users near the
#                          region. That instance is protected from scale-in meanwhile.
#   FROM=here              the load is generated from this machine (latency then includes
#                          your internet round trip to eu-west-1).
#
# Ctrl-C stops the load. The priority sheet is data/service_priority_30pct.xlsx (30 % critical).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

abs() { echo "$(cd "$(dirname "$1")" && (pwd -W 2>/dev/null || pwd))/$(basename "$1")"; }

PROFILE="$(abs "${1:-$ROOT/finops-app/data/traffic_profile_live_demo.csv}")"
PRIORITY="$ROOT/data/service_priority_30pct.xlsx"
FROM="${FROM:-region}"
RUN="demo-$(stamp)"
OUT="$ROOT/reports/$RUN"
mkdir -p "$OUT"

WEB="$(out web_asg_name)"
WORKER="$(out worker_asg_name)"
QUEUE_URL="$(out queue_url)"
URL="$(out app_url)"
DURATION=$("$PY" -c 'import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
print(max(int(r["time_offset_min"]) * 60 + int(r["duration_sec"]) for r in rows))' "$PROFILE")

log "Live demo $RUN: $(basename "$PROFILE") (~$((DURATION / 60)) min) against $URL, load from: $FROM"
log "Grafana: http://localhost:3000/d/finops-cloudscale"

if [ "$FROM" = "region" ]; then
  HOST=$(asg_in_service_ids "$WORKER" | awk '{print $1}')
  aws autoscaling set-instance-protection --auto-scaling-group-name "$WORKER" --instance-ids "$HOST" --protected-from-scale-in
  on_exit "aws autoscaling set-instance-protection --auto-scaling-group-name $WORKER --instance-ids $HOST --no-protected-from-scale-in"
  on_exit "ssm_run $HOST 'docker rm -f finops-loadgen >/dev/null 2>&1; echo load generator stopped' || true"

  PACKAGE="$CACHE_DIR/demo-$$"
  mkdir -p "$PACKAGE"
  cp "$ROOT/finops-app/simulator/traffic_sim.py" "$ROOT/finops-app/requirements.txt" "$PACKAGE/"
  cp "$PROFILE" "$PACKAGE/profile.csv"
  cp "$PRIORITY" "$PACKAGE/priority.xlsx"
  B64=$(cd "$PACKAGE" && tar czf - . | base64 -w0)
  rm -rf "$PACKAGE"

  log "Starting the load generator on worker $HOST (protected from scale-in for the demo)"
  ssm_run "$HOST" "set -e
rm -rf /tmp/demo && mkdir -p /tmp/demo && cd /tmp/demo
echo '$B64' | base64 -d | tar xz
docker rm -f finops-loadgen >/dev/null 2>&1 || true
docker run -d --name finops-loadgen -v /tmp/demo:/sim -w /sim python:3.12-slim sh -c 'pip install -q -r requirements.txt >/dev/null 2>&1 && TARGET_API_URL=$URL/process TRAFFIC_PROFILE=profile.csv SERVICE_PRIORITY_FILE=priority.xlsx REPORT_DIR=/sim/out AWS_ENABLED=false python traffic_sim.py > /sim/sim.log 2>&1'
echo load generator container started"
else
  simulate "$PROFILE" "$OUT" SERVICE_PRIORITY_FILE="$PRIORITY" >"$OUT/simulator.log" 2>&1 &
  on_exit "kill $! 2>/dev/null"
fi

# Live view: the same numbers Grafana shows, in the terminal.
queue_depth() {
  aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' --output text
}
echo
printf '%-9s %-7s %-18s %-26s %s\n' TIME ELAPSED "WEB (in svc/want)" "WORKERS (in svc/want, spot)" QUEUE | tee "$OUT/timeline.txt"
START=$(date +%s)
while [ $(($(date +%s) - START)) -le $((DURATION + 45)) ]; do
  elapsed=$(($(date +%s) - START))
  spot=$(worker_instances | grep -c 'spot' || true)
  printf '%-9s %-7s %-18s %-26s %s\n' "$(date -u +%H:%M:%S)" "$((elapsed / 60))m$((elapsed % 60))s" \
    "$(asg_in_service "$WEB")/$(asg_desired "$WEB")" \
    "$(asg_in_service "$WORKER")/$(asg_desired "$WORKER"), $spot spot" \
    "$(queue_depth)" | tee -a "$OUT/timeline.txt"
  sleep 15
done

if [ "$FROM" = "region" ]; then
  ssm_run "$HOST" "grep GATE /tmp/demo/sim.log || tail -5 /tmp/demo/sim.log; cat /tmp/demo/out/traffic_report.csv 2>/dev/null" | tee "$OUT/traffic_report_remote.txt"
else
  grep GATE "$OUT/simulator.log" || true
fi
echo
log "Traffic done. Scale-in follows the lull within ~5 min; keep Grafana open to show it. Timeline: $OUT/timeline.txt"
