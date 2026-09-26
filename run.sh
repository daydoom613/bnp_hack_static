#!/usr/bin/env bash
# One file to run the whole project. Easiest: double-click START.bat / STOP.bat (Windows).
#
#   bash run.sh           = up + live demo, then offers to tear down   (START.bat)
#   bash run.sh up        checks, Grafana, plan + budget guard, deploy, wait until healthy
#   bash run.sh demo      15-min live demo (load generated inside AWS)
#   bash run.sh tests     the test cases that work from a laptop (~40 min)
#   bash run.sh status    what is running right now (read-only)
#   bash run.sh check     tools + AWS login only (read-only)
#   bash run.sh down      tear the stack down, stop Grafana         (STOP.bat)
#
# Uses the AWS CLI profile "finops" unless AWS_PROFILE is set.
set -euo pipefail
cd "$(dirname "$0")"

export AWS_PROFILE="${AWS_PROFILE:-finops}"
export AWS_REGION=eu-west-1 AWS_DEFAULT_REGION=eu-west-1 AWS_PAGER=""
# Tools installed with winget / into ~/bin are not always on PATH in a non-login shell.
for dir in "$HOME/bin" "/c/Program Files/Amazon/AWSCLIV2" "$HOME"/AppData/Local/Microsoft/WinGet/Packages/Hashicorp.Terraform_*; do
  [ -d "$dir" ] && PATH="$dir:$PATH"
done
export PATH

ENV_DIR=terraform/environments/dev
GRAFANA_URL="http://localhost:3000/d/finops-cloudscale"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '    \033[32mOK\033[0m  %s\n' "$*"; }
die() {
  printf '\n\033[1;31mSTOPPED: %s\033[0m\n' "$*" >&2
  exit 1
}
confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}
open_url() { cmd.exe //c start "" "$1" >/dev/null 2>&1 || true; }
tf_out() { terraform -chdir="$ENV_DIR" output -raw "$1" 2>/dev/null; }

check() {
  say "Checking tools and AWS login"
  command -v aws >/dev/null || die "AWS CLI not found. Install it: winget install Amazon.AWSCLI"
  command -v terraform >/dev/null || die "Terraform not found. Install it: winget install Hashicorp.Terraform"
  command -v opa >/dev/null || die "OPA not found in ~/bin"
  if ! python -c "import boto3, httpx, pandas, openpyxl" 2>/dev/null; then
    echo "    installing Python packages..."
    python -m pip install -q -r finops-app/requirements.txt || die "pip install failed"
  fi
  ok "tools: aws, terraform $(terraform version | head -1 | awk '{print $2}'), opa, python packages"
  local account
  account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) ||
    die "AWS login failed for profile '$AWS_PROFILE'. Run: aws configure --profile $AWS_PROFILE"
  ok "AWS account $account (profile $AWS_PROFILE)"
  local quota
  quota=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query Quota.Value --output text 2>/dev/null || echo "?")
  ok "EC2 On-Demand vCPU quota: $quota (8 = demo scales to ~3 web instances; 20 = full scaling)"
}

grafana() {
  say "Grafana"
  if curl -s -o /dev/null --max-time 3 http://localhost:3000/api/health; then
    ok "already running"
  else
    powershell.exe -ExecutionPolicy Bypass -File observability/grafana-windows.ps1 -Profile "$AWS_PROFILE" >/dev/null
    for _ in $(seq 1 30); do
      curl -s -o /dev/null --max-time 3 http://localhost:3000/api/health && break
      sleep 2
    done
    curl -s -o /dev/null --max-time 3 http://localhost:3000/api/health || die "Grafana did not start (see ~/grafana/grafana-v11.3.0/data/log)"
    ok "started"
  fi
  ok "$GRAFANA_URL"
  open_url "$GRAFANA_URL"
}

up() {
  check
  grafana

  say "Plan + OPA budget guard"
  bash scripts/plan_and_check.sh dev | tail -4 || die "the budget guard blocked the plan (see the lines above)"

  say "Deploy"
  echo "    This creates the AWS stack. Billing runs at about \$0.17/hour until you run STOP.bat (bash run.sh down)."
  confirm "    Deploy now?" || die "cancelled, nothing was deployed"
  mkdir -p .cache
  local rc=0
  terraform -chdir="$ENV_DIR" apply -input=false -no-color tfplan >.cache/apply.log 2>&1 || rc=$?
  grep -E "Apply complete" .cache/apply.log || true
  if [ "$rc" -ne 0 ]; then
    grep -A8 "^Error" .cache/apply.log | head -30
    die "deploy failed (full log: .cache/apply.log). Paste the error to Claude; run 'bash run.sh up' again after a fix."
  fi

  say "Waiting for the app to answer (instances boot in ~2-3 min)"
  local url code=000
  url="$(tf_out health_url)"
  for i in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)
    [ "$code" = "200" ] && break
    printf '    not yet (HTTP %s), %s/40\r' "$code" "$i"
    sleep 15
  done
  echo
  [ "$code" = "200" ] || die "the app did not become healthy; run: bash run.sh status"
  ok "LIVE: $url"
  curl -s "$url"
  echo
}

demo() {
  say "Live demo (~16 min). Watch Grafana: $GRAFANA_URL"
  bash scripts/live_demo.sh
}

tests() {
  say "Test cases (~40 min)"
  bash scripts/run_tests.sh B1 B2 B4 B5 A2 A3 A4
}

status() {
  say "Status"
  local web worker
  web=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names finops-cloudscale-dev-web-asg \
    --query 'AutoScalingGroups[0].[DesiredCapacity, length(Instances)]' --output text 2>/dev/null || true)
  worker=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names finops-cloudscale-dev-worker-asg \
    --query 'AutoScalingGroups[0].[DesiredCapacity, length(Instances)]' --output text 2>/dev/null || true)
  if [ -z "$web" ] || [ "$web" = "None" ]; then
    ok "stack is DOWN (nothing billing except ~\$1/month for state, image and evidence)"
  else
    ok "stack is UP: web desired/running = ${web//$'\t'//}, worker = ${worker//$'\t'//}"
    ok "app: $(tf_out health_url)"
  fi
  curl -s -o /dev/null --max-time 3 http://localhost:3000/api/health && ok "Grafana: $GRAFANA_URL" || ok "Grafana: not running"
}

down() {
  check
  say "Tear down"
  confirm "    Destroy the AWS stack now (stops billing)?" || die "cancelled, the stack is still running"
  TF_VAR_budget_cap="$(grep -v '^[[:space:]]*#' data/budget_cap.txt | tr -d '[:space:]')" \
    terraform -chdir="$ENV_DIR" destroy -input=false -auto-approve | grep -E "Destroy complete|Error" || true

  # The evidence bucket is kept on purpose, so destroy reports it as an error. What
  # matters is that nothing billable is left:
  local instances nat alb rds
  instances=$(aws ec2 describe-instances --filters Name=tag:Project,Values=finops-cloudscale Name=instance-state-name,Values=pending,running \
    --query 'length(Reservations[].Instances[])' --output text)
  nat=$(aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'length(NatGateways)' --output text)
  alb=$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?starts_with(LoadBalancerName, 'finops-cloudscale')])" --output text)
  rds=$(aws rds describe-db-instances --query "length(DBInstances[?starts_with(DBInstanceIdentifier, 'finops-cloudscale')])" --output text)
  if [ "$instances$nat$alb$rds" = "0000" ]; then
    ok "stack destroyed: no instances, NAT, load balancer or database left. Billing stopped."
  else
    die "still running: instances=$instances nat=$nat alb=$alb rds=$rds. Run STOP.bat again in a few minutes."
  fi
  powershell.exe -Command "Stop-Process -Name grafana -ErrorAction SilentlyContinue" || true
  ok "Grafana stopped (the frozen session dashboard stays saved)"
}

case "${1:-all}" in
  all)
    up
    demo
    say "Demo finished"
    if confirm "    Tear the stack down now (stops billing)?"; then
      down
    else
      echo "    The stack is still running. Double-click STOP.bat (or: bash run.sh down) when you are done."
    fi
    ;;
  up | demo | tests | status | check | down) "$1" ;;
  *)
    echo "usage: bash run.sh [all|up|demo|tests|status|check|down]" >&2
    exit 2
    ;;
esac
