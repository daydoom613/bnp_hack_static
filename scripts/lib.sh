# shellcheck shell=bash
# Shared helpers, sourced by scripts/*.sh and chaos/*.sh (not run directly).
#
# Needs: terraform (outputs of terraform/environments/dev), aws CLI v2, python with
# finops-app/requirements.txt installed. Set AWS_PROFILE to the account's profile.
#
# Overrides: TERRAFORM, PYTHON, AWS_REGION, OUTPUTS_FILE (a saved `terraform output -json`,
# for machines without terraform, e.g. CloudShell).

# `pwd -W` gives C:/... under Git Bash, so Windows python and aws.exe get usable paths.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && (pwd -W 2>/dev/null || pwd))"
ENV_DIR="$ROOT/terraform/environments/dev"
TF="${TERRAFORM:-terraform}"
PY="${PYTHON:-$(command -v python || command -v python3)}"
REGION="${AWS_REGION:-eu-west-1}"
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
# Git Bash rewrites arguments that look like POSIX paths (e.g. the log group
# /finops-cloudscale-dev/app) into Windows paths before calling aws.exe. Paths here are
# already Windows-style (pwd -W above), so turn that off. No effect on Linux or CI.
export MSYS_NO_PATHCONV=1

CACHE_DIR="$ROOT/.cache"
mkdir -p "$CACHE_DIR"

# ---------------------------------------------------------------------------
# Cleanup on exit: scripts register commands (restore alarms, stop load) with on_exit.
# ---------------------------------------------------------------------------
_EXIT_CMDS=()
on_exit() { _EXIT_CMDS+=("$1"); }
_run_exit() {
  local rc=$? cmd
  for cmd in ${_EXIT_CMDS[@]+"${_EXIT_CMDS[@]}"}; do
    eval "$cmd" || true
  done
  rm -f "$CACHE_DIR"/*-$$.json
  exit "$rc"
}
trap _run_exit EXIT

# ---------------------------------------------------------------------------
# Terraform outputs of the deployed (dynamic) stack, read once per script run.
# ---------------------------------------------------------------------------
out() {
  local file="${OUTPUTS_FILE:-$CACHE_DIR/outputs-$$.json}"
  if [ ! -s "$file" ]; then
    "$TF" -chdir="$ENV_DIR" output -json >"$file"
  fi
  "$PY" -c 'import json, sys
v = json.load(open(sys.argv[1]))[sys.argv[2]]["value"]
print(v if isinstance(v, str) else json.dumps(v))' "$file" "$1"
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
stamp() { date -u +%Y%m%dT%H%M%SZ; }
now_ms() { echo $(($(date +%s) * 1000)); }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Run the traffic simulator (finops-app/simulator) against the deployed ALB.
#   simulate <profile.csv> <report_dir> [VAR=value ...]
simulate() {
  local profile="$1" report_dir="$2"
  shift 2
  (cd "$ROOT/finops-app" && env \
    TARGET_API_URL="$(out app_url)/process" \
    TRAFFIC_PROFILE="$profile" \
    SERVICE_PRIORITY_FILE="$ROOT/data/service_priority.xlsx" \
    REPORT_DIR="$report_dir" \
    AWS_REGION="$REGION" \
    "$@" "$PY" simulator/traffic_sim.py)
}

# ---------------------------------------------------------------------------
# Auto Scaling helpers
# ---------------------------------------------------------------------------

# "i-0abc spot running" lines for the Worker ASG.
worker_instances() {
  aws ec2 describe-instances \
    --filters "Name=tag:aws:autoscaling:groupName,Values=$(out worker_asg_name)" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].[InstanceId, InstanceLifecycle || `on-demand`, State.Name]' --output text
}

asg_desired() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$1" \
    --query 'AutoScalingGroups[0].DesiredCapacity' --output text
}

asg_in_service() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$1" \
    --query "length(AutoScalingGroups[0].Instances[?LifecycleState=='InService'])" --output text
}

asg_in_service_ids() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$1" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" --output text
}

# Wait until an ASG has at least <n> InService instances (default timeout 10 min).
wait_in_service() {
  local asg="$1" n="$2" tries="${3:-40}"
  for _ in $(seq 1 "$tries"); do
    [ "$(asg_in_service "$asg")" -ge "$n" ] && return 0
    sleep 15
  done
  return 1
}

# Scale-in is a step policy on each tier: web on "ALB requests per target < 20 RPS for
# 10 min", worker on "queue_length < 5 for 10 min". While traffic or the queue is quiet
# those alarms stay in ALARM, and CloudWatch re-runs Auto Scaling actions every minute,
# so any instance a test adds would be removed again. Tests that need a bigger fleet
# pause those alarm actions and always restore them on exit.
hold_scale_in() { # hold_scale_in <web|worker>
  local alarm
  case "$1" in
    web) alarm="$(out stack_name)-web-requests-low" ;;
    worker) alarm="$(out stack_name)-queue-length-low" ;;
  esac
  aws cloudwatch disable-alarm-actions --alarm-names "$alarm"
  on_exit "aws cloudwatch enable-alarm-actions --alarm-names $alarm && echo 'Scale-in re-enabled ($alarm)'"
  log "Paused $1 scale-in ($alarm) for this test; it is restored on exit"
}

hold_worker_scale_in() { hold_scale_in worker; }

# The 70/30 mix rounds the On-Demand share UP, so the first Spot worker appears at
# 4 instances (3 On-Demand + 1 Spot). Chaos and Spot-guard tests need one running.
ensure_spot_worker() {
  local asg max
  asg="$(out worker_asg_name)"
  hold_worker_scale_in
  if worker_instances | grep -q 'spot[[:space:]]*running'; then
    return 0
  fi
  max=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
    --query 'AutoScalingGroups[0].MaxSize' --output text)
  log "No Spot worker running: setting $asg desired capacity to $max (70/30 gives 1 Spot at 4)"
  aws autoscaling set-desired-capacity --auto-scaling-group-name "$asg" --desired-capacity "$max" --no-honor-cooldown
  for _ in $(seq 1 40); do
    if worker_instances | grep -q 'spot[[:space:]]*running'; then
      log "Spot worker running:"
      worker_instances
      return 0
    fi
    sleep 15
  done
  echo "No Spot worker appeared within 10 minutes (no Spot capacity for this type/AZ?)." >&2
  return 1
}

# ---------------------------------------------------------------------------
# Run a shell script on an instance through SSM (in-region measurements) and print
# its stdout. Instances have AmazonSSMManagedInstanceCore; no SSH is involved.
#   ssm_run <instance-id> <script>
# ---------------------------------------------------------------------------
ssm_run() {
  local instance="$1" script="$2" input id status=Pending
  input="$CACHE_DIR/ssm-$$.json"
  "$PY" -c 'import json, sys
json.dump({"DocumentName": "AWS-RunShellScript", "InstanceIds": [sys.argv[1]],
           "Parameters": {"commands": sys.argv[2].splitlines()}, "TimeoutSeconds": 120},
          open(sys.argv[3], "w"))' "$instance" "$script" "$input"
  id=$(aws ssm send-command --cli-input-json "file://$input" --query 'Command.CommandId' --output text)
  for _ in $(seq 1 40); do
    sleep 3
    status=$(aws ssm get-command-invocation --command-id "$id" --instance-id "$instance" \
      --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Success | Failed | Cancelled | TimedOut) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$id" --instance-id "$instance" \
    --query StandardOutputContent --output text
}

# ---------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------

# Common to every test, for the window [start_ms, now]: scaling activities, alarm
# history, drain-Lambda and app DRAIN logs, queue state. Everything lands in <dir>.
collect_common() {
  local dir="$1" start_ms="$2" start_iso
  start_iso="$("$PY" -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])/1000, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$start_ms")"
  mkdir -p "$dir"
  for tier in web worker; do
    aws autoscaling describe-scaling-activities --auto-scaling-group-name "$(out "${tier}_asg_name")" \
      --max-items 50 --output json >"$dir/${tier}_scaling_activities.json" || true
  done
  aws cloudwatch describe-alarm-history --start-date "$start_iso" --history-item-type StateUpdate \
    --output json >"$dir/alarm_history.json" || true
  aws logs filter-log-events --log-group-name "/aws/lambda/$(out drain_function)" --start-time "$start_ms" \
    --query 'events[].message' --output text >"$dir/drain_lambda.log" 2>/dev/null || true
  aws logs filter-log-events --log-group-name "$(out app_log_group)" --start-time "$start_ms" \
    --filter-pattern '"DRAIN"' --query 'events[].[logStreamName, message]' --output text >"$dir/app_drain.log" 2>/dev/null || true
  aws sqs get-queue-attributes --queue-url "$(out queue_url)" --attribute-names All --output json >"$dir/queue_attributes.json" || true
}

# Upload a local evidence/report folder to the artifacts bucket under <prefix>/<name>/.
upload_dir() {
  local dir="$1" prefix="$2"
  aws s3 cp --recursive --only-show-errors "$dir" "s3://$(out artifacts_bucket)/$prefix/$(basename "$dir")/"
  log "Uploaded to s3://$(out artifacts_bucket)/$prefix/$(basename "$dir")/"
}
