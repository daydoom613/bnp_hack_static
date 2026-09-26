#!/usr/bin/env bash
# The problem statement's test cases, run against the deployed stack, with a PASS/FAIL
# table at the end. Evidence per test: evidence/tests-<ts>/<ID>/ and S3.
#
# Usage:  AWS_PROFILE=<profile> scripts/run_tests.sh [basic | advanced | all | ID ...]
#
#   Basic                                          Advanced
#   B1 stack deployed, resources live              A1 full traffic profile: web and worker scaling,
#   B2 /health 200 within 100 ms (in-region)          Spot workers when queue_length > 50
#   B3 50 RPS for 5 min: <= 5 % errors, < 200 ms   A2 30 % critical, never processed on Spot
#   B4 CPU > 70 % scales web to >= 2               A3 lower budget_cap: OPA blocks, RI pricing fits
#   B5 OPA passes the baseline plan                A4 queue_length spike to 120: +1 (Spot) worker
#   B6 CI pipeline green                           A5 CI pipeline with the advanced load green
#
#   FULL_PROFILE=1  A1 replays data/traffic_profiles.csv (4.7 h) instead of the 75-min profile.
#   B3_PROFILE, B4_PROFILE, A1_PROFILE override the traffic profiles (e.g. for a quick smoke run).
#
# Run it where latency is measured fairly: AWS CloudShell in eu-west-1, or CI
# (Actions -> deploy -> Run workflow, tests = basic/advanced). From a laptop far from
# eu-west-1 the internet round trip alone can exceed the 200 ms latency limit of B3.
# B5 and A3 need terraform + opa; B6 and A5 need the GitHub CLI (gh) outside CI.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

RUN="tests-$(stamp)"
RUN_DIR="$ROOT/evidence/$RUN"
RESULTS="$RUN_DIR/results.tsv"
mkdir -p "$RUN_DIR"
: >"$RESULTS"

BASIC=(B1 B2 B3 B4 B5 B6)
ADVANCED=(A3 A4 A1 A2 A5) # A1 before A2: A2 reuses A1's traffic report

record() { # record <ID> <PASS|FAIL|SKIP> <detail>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RESULTS"
  log "$1 $2: $3"
}

ms() { awk -v s="$1" 'BEGIN { printf "%d", s * 1000 }'; }

report_value() { # report_value <traffic_report.csv> <column> <sum|avg|wavg>
  "$PY" - "$@" <<'EOF'
import csv, sys
path, column, how = sys.argv[1:4]
rows = list(csv.DictReader(open(path)))
if how == "sum":
    print(sum(float(r[column]) for r in rows))
else:  # request-weighted average over slices
    total = sum(float(r["successful_requests"]) for r in rows) or 1
    print(round(sum(float(r[column]) * float(r["successful_requests"]) for r in rows) / total, 2))
EOF
}

# ---------------------------------------------------------------------------
# Basic
# ---------------------------------------------------------------------------
t_B1() { # Deploy the Terraform stack: terraform apply completed, resources live
  local d="$RUN_DIR/B1" stack alb db web worker fn1 fn2
  mkdir -p "$d"
  stack="$(out stack_name)"
  "$TF" -chdir="$ENV_DIR" output -json >"$d/terraform_outputs.json" 2>/dev/null || true
  alb=$(aws elbv2 describe-load-balancers --names "$stack-alb" --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null)
  db=$(aws rds describe-db-instances --db-instance-identifier "$stack-db" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
  web=$(asg_in_service "$(out web_asg_name)")
  worker=$(asg_in_service "$(out worker_asg_name)")
  fn1=$(aws lambda get-function --function-name "$(out metrics_function)" --query 'Configuration.State' --output text 2>/dev/null)
  fn2=$(aws lambda get-function --function-name "$(out drain_function)" --query 'Configuration.State' --output text 2>/dev/null)
  aws fis get-experiment-template --id "$(out fis_spot_template_id)" --output json >"$d/fis_template.json" 2>/dev/null
  aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=finops-cloudscale" "Key=Stack,Values=dynamic" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' >"$d/tagged_resources.txt" 2>/dev/null
  local detail
  detail="ALB $alb, RDS $db, web $web / worker $worker InService, Lambdas $fn1/$fn2, $(wc -l <"$d/tagged_resources.txt" | tr -d ' ') tagged resources"
  if [ "$alb" = "active" ] && [ "$db" = "available" ] && [ "$web" -ge 1 ] && [ "$worker" -ge 1 ] &&
    [ "$fn1" = "Active" ] && [ "$fn2" = "Active" ]; then
    record B1 PASS "$detail"
  else
    record B1 FAIL "$detail"
  fi
}

t_B2() { # /health returns 200 OK within 100 ms
  local d="$RUN_DIR/B2" url code local_s instance inregion median
  mkdir -p "$d"
  url="$(out health_url)"
  code=$(curl -s -o "$d/health.json" -w '%{http_code}' --max-time 5 "$url")
  local_s=$(curl -s -o /dev/null -w '%{time_total}' --max-time 5 "$url")
  # In-region measurement: curl the ALB from a web instance (through the NAT, like any client in eu-west-1).
  instance=$(asg_in_service_ids "$(out web_asg_name)" | awk '{print $1}')
  inregion=$(ssm_run "$instance" "for i in \$(seq 1 11); do curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 2 $url; done")
  echo "$inregion" >"$d/in_region_curl.txt"
  median=$(echo "$inregion" | awk '$1 == 200 { print $2 }' | sort -n | awk '{ a[NR] = $1 } END { if (NR) print a[int((NR + 1) / 2)]; else print 9 }')
  local detail
  detail="HTTP $code; in-region median $(ms "$median") ms (from $instance); from this machine $(ms "$local_s") ms"
  if [ "$code" = "200" ] && [ "$(ms "$median")" -lt 100 ]; then
    record B2 PASS "$detail"
  else
    record B2 FAIL "$detail"
  fi
}

t_B3() { # Constant 50 RPS for 5 min: traffic_report.csv <= 5 % errors, avg latency < 200 ms, stored in S3
  local d="$RUN_DIR/B3" bucket rc err avg
  mkdir -p "$d"
  bucket="$(out artifacts_bucket)"
  simulate "${B3_PROFILE:-$ROOT/finops-app/data/traffic_profile_constant.csv}" "$d" \
    MAX_ERROR_RATE=5 MAX_AVG_LATENCY_MS=200 \
    AWS_ENABLED=true S3_BUCKET="$bucket" S3_PREFIX="reports/$RUN/B3/" >"$d/simulator.log" 2>&1
  rc=$?
  err=$(report_value "$d/traffic_report.csv" error_rate_percent wavg 2>/dev/null || echo "?")
  avg=$(report_value "$d/traffic_report.csv" avg_latency_ms wavg 2>/dev/null || echo "?")
  local s3="missing"
  aws s3 ls "s3://$bucket/reports/$RUN/B3/traffic_report.csv" >/dev/null 2>&1 && s3="s3://$bucket/reports/$RUN/B3/traffic_report.csv"
  local detail
  detail="error rate ${err} %, avg latency ${avg} ms, report $s3"
  if [ "$rc" -eq 0 ] && [ "$s3" != "missing" ]; then
    record B3 PASS "$detail"
  else
    record B3 FAIL "$detail (simulator exit $rc, see $d/simulator.log)"
  fi
}

t_B4() { # CPU > 70 % for two periods scales the Web ASG out to >= 2 instances
  local d="$RUN_DIR/B4" asg start_iso before peak=0 now_n cpu launched
  mkdir -p "$d"
  asg="$(out web_asg_name)"
  # Start from a single web instance so the scale-out is this test's doing.
  if [ "$(asg_desired "$asg")" -gt 1 ]; then
    log "B4: resetting $asg to 1 instance first"
    aws autoscaling set-desired-capacity --auto-scaling-group-name "$asg" --desired-capacity 1 --no-honor-cooldown
    for _ in $(seq 1 30); do
      [ "$(asg_in_service "$asg")" -le 1 ] && break
      sleep 10
    done
  fi
  start_iso="$(now)"
  before="$(asg_in_service "$asg")"
  log "B4: 150 RPS of critical (CPU-heavy) requests for up to 8 min; web InService now $before"
  simulate "${B4_PROFILE:-$ROOT/finops-app/data/traffic_profile_cpu.csv}" "$d" CRITICAL_SHARE=1.0 >"$d/simulator.log" 2>&1 &
  local load_pid=$!
  for _ in $(seq 1 44); do # up to 11 min
    sleep 15
    now_n="$(asg_in_service "$asg")"
    [ "$now_n" -gt "$peak" ] && peak="$now_n"
    echo "$(date -u +%H:%M:%S) desired=$(asg_desired "$asg") in_service=$now_n" >>"$d/timeline.txt"
    [ "$peak" -ge 2 ] && [ "$peak" -gt "$before" ] && break
  done
  # Let the load finish so it never overlaps the next test.
  wait "$load_pid" 2>/dev/null
  cpu=$(aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
    --dimensions "Name=AutoScalingGroupName,Value=$asg" --start-time "$start_iso" --end-time "$(now)" \
    --period 60 --statistics Maximum --query 'max(Datapoints[].Maximum)' --output text 2>/dev/null)
  aws autoscaling describe-scaling-activities --auto-scaling-group-name "$asg" --max-items 20 \
    --output json >"$d/scaling_activities.json"
  # Keep only this test's activities (JMESPath cannot compare timestamps).
  "$PY" - "$d/scaling_activities.json" "$start_iso" >"$d/scaling_activities.txt" <<'EOF'
import json, sys
from datetime import datetime
since = datetime.fromisoformat(sys.argv[2].replace("Z", "+00:00"))
for a in json.load(open(sys.argv[1]))["Activities"]:
    if datetime.fromisoformat(a["StartTime"].replace("Z", "+00:00")) >= since:
        print(a["StartTime"], a["StatusCode"], a["Description"], "|", a.get("Cause", ""))
EOF
  aws cloudwatch describe-alarm-history --alarm-name "$(out stack_name)-web-cpu-high" --start-date "$start_iso" \
    --history-item-type StateUpdate --query 'AlarmHistoryItems[].[Timestamp, HistorySummary]' --output text >"$d/cpu_alarm_history.txt"
  launched=$(grep -c 'Launching a new EC2 instance' "$d/scaling_activities.txt")
  local detail
  detail="web InService $before -> $peak, CPU max ${cpu} %, $launched launch activities, cpu-high alarm: $(grep -c 'to ALARM' "$d/cpu_alarm_history.txt") transitions"
  if [ "$peak" -ge 2 ] && [ "$launched" -ge 1 ]; then
    record B4 PASS "$detail"
  else
    record B4 FAIL "$detail"
  fi
}

t_B5() { # OPA passes a baseline plan (cost <= budget)
  local d="$RUN_DIR/B5"
  mkdir -p "$d"
  if bash "$ROOT/scripts/plan_and_check.sh" baseline >"$d/plan_and_check.log" 2>&1 && grep -q '^allow = true' "$d/plan_and_check.log"; then
    record B5 PASS "$(grep 'Projected monthly compute cost' "$d/plan_and_check.log" | tail -1); opa eval data.finops.allow = true"
  else
    record B5 FAIL "see $d/plan_and_check.log"
  fi
}

latest_run() { # latest_run <text in the run name, e.g. 'tests=advanced'>: "<conclusion> <url>"
  gh run list --workflow deploy.yml --status completed --limit 30 --json displayTitle,conclusion,url \
    --jq "[.[] | select(.displayTitle | contains(\"$1\"))][0] | select(. != null) | \"\\(.conclusion) \\(.url)\""
}

t_B6() { # CI pipeline runs to completion and applies the plan
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    record B6 PASS "this workflow run: validate, load-test, image, plan + OPA and apply all succeeded before these tests"
  elif command -v gh >/dev/null 2>&1; then
    local result
    result="$(latest_run "deploy:")"
    case "$result" in
      success*) record B6 PASS "latest deploy run: $result" ;;
      *) record B6 FAIL "latest deploy run: ${result:-none found}" ;;
    esac
  else
    record B6 SKIP "install the GitHub CLI (gh auth login) or check Actions -> deploy on GitHub"
  fi
}

# ---------------------------------------------------------------------------
# Advanced
# ---------------------------------------------------------------------------
A1_REPORT=""

t_A1() { # Full traffic profile: Web ASG scales (<= 8 at peak), Worker ASG adds Spot when queue_length > 50
  local profile="$ROOT/finops-app/data/traffic_profile_short.csv" run="$RUN-A1" summary
  [ "${FULL_PROFILE:-0}" = "1" ] && profile="$ROOT/data/traffic_profiles.csv"
  profile="${A1_PROFILE:-$profile}"
  bash "$ROOT/scripts/run_load_test.sh" "$profile" "$run" >"$RUN_DIR/A1.log" 2>&1
  summary="$ROOT/reports/$run/scaling_summary.json"
  A1_REPORT="$ROOT/reports/$run/traffic_report.csv"
  if [ ! -s "$summary" ]; then
    record A1 FAIL "no scaling summary; see $RUN_DIR/A1.log"
    return
  fi
  mkdir -p "$RUN_DIR/A1" && cp "$ROOT/reports/$run/"*.json "$ROOT/reports/$run/"*.csv "$RUN_DIR/A1/" 2>/dev/null
  local verdict
  verdict=$("$PY" - "$summary" "$ROOT/reports/$run/cost_savings.csv" <<'EOF'
import csv, json, sys
s = json.load(open(sys.argv[1]))
savings = next(csv.DictReader(open(sys.argv[2])), {})
web, spot, queue = s["web_in_service"]["max"] or 0, s["worker_spot"]["max"] or 0, s["queue_length"]["max"] or 0
ok = 2 <= web <= 8 and queue > 50 and spot >= 1
print(("PASS" if ok else "FAIL") + f" web max {web:g} (1 -> {web:g}, limit 8), queue_length max {queue:g}, "
      f"Spot workers max {spot:g}, workers On-Demand max {s['worker_on_demand']['max'] or 0:g}; "
      f"optimized {savings.get('optimized_monthly_cost')} vs baseline {savings.get('baseline_monthly_cost')} "
      f"= {savings.get('savings_pct')} % saved")
EOF
)
  record A1 "${verdict%% *}" "${verdict#* }"
}

t_A2() { # 30 % of requests critical (priority sheet weights); never processed on Spot hosts
  local d="$RUN_DIR/A2" report="$A1_REPORT" share on_spot guard
  mkdir -p "$d"
  if [ -z "$report" ] || [ ! -s "$report" ]; then
    report="$d/traffic_report.csv"
    simulate "${B3_PROFILE:-$ROOT/finops-app/data/traffic_profile_constant.csv}" "$d" \
      SERVICE_PRIORITY_FILE="$ROOT/data/service_priority_30pct.xlsx" >"$d/simulator.log" 2>&1
  fi
  share=$("$PY" -c "import csv,sys; r=list(csv.DictReader(open(sys.argv[1]))); t=sum(int(x['total_requests']) for x in r); print(round(100*sum(int(x['critical_requests']) for x in r)/max(t,1),1))" "$report")
  on_spot=$(report_value "$report" critical_on_spot sum)
  bash "$ROOT/scripts/test_spot_guard.sh" >"$d/spot_guard.log" 2>&1
  guard=$?
  local detail
  detail="critical share ${share} % (sheet weights 15/15/70), critical processed on Spot: ${on_spot%.*}; spot guard: $(grep -E '^(PASS|FAIL)' "$d/spot_guard.log" | tr '\n' ';')"
  if [ "$guard" -eq 0 ] && [ "${on_spot%.*}" = "0" ] && awk -v s="$share" 'BEGIN { exit !(s >= 25 && s <= 35) }'; then
    record A2 PASS "$detail"
  else
    record A2 FAIL "$detail"
  fi
}

t_A3() { # Cheaper Reserved-Instance option + new budget_cap: OPA blocks the over-cap plan with a clear message
  local d="$RUN_DIR/A3" cap=80 blocked=no fits=no msg
  mkdir -p "$d"
  printf '# A3 test cap: below the On-Demand projection (85.85), above the Reserved one (47.30)\n%s\n' "$cap" >"$d/budget_cap.txt"
  if BUDGET_CAP_FILE="$d/budget_cap.txt" PLAN_FILE=tfplan-a3 bash "$ROOT/scripts/plan_and_check.sh" dev >"$d/on_demand.log" 2>&1; then
    blocked=no
  else
    grep -q "allow = false" "$d/on_demand.log" && blocked=yes
  fi
  msg="$(grep -m1 'exceeds budget_cap' "$d/on_demand.log" | sed 's/^ *- //')"
  if BUDGET_CAP_FILE="$d/budget_cap.txt" PLAN_FILE=tfplan-a3 ON_DEMAND_RATE=reserved bash "$ROOT/scripts/plan_and_check.sh" dev >"$d/reserved.log" 2>&1; then
    fits=yes
  fi
  rm -f "$ENV_DIR/tfplan-a3"
  local detail
  detail="budget_cap $cap: On-Demand plan blocked=$blocked (\"$msg\"); Reserved-Instance pricing $(grep 'Projected monthly compute cost' "$d/reserved.log" | tail -1 | sed 's/.*: //') allowed=$fits"
  if [ "$blocked" = "yes" ] && [ -n "$msg" ] && [ "$fits" = "yes" ]; then
    record A3 PASS "$detail"
  else
    record A3 FAIL "$detail"
  fi
}

t_A4() { # queue_length spike to 120: Lambda-driven step scaling adds a Spot worker (desired +1)
  if bash "$ROOT/scripts/test_queue_spike.sh" >"$RUN_DIR/A4.log" 2>&1; then
    record A4 PASS "$(grep -E 'PASS' "$RUN_DIR/A4.log" | tail -1 | sed -e 's/^\[[^]]*\] //' -e 's/^PASS: //')"
  else
    record A4 FAIL "$(grep -E 'FAIL|before=' "$RUN_DIR/A4.log" | tail -1 | sed 's/^\[[^]]*\] //')"
  fi
}

t_A5() { # Full CI pipeline with the advanced load, no manual intervention
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    if [ "${CI_TESTS:-}" = "advanced" ]; then
      record A5 PASS "this workflow run: every stage passed and it is running the advanced tests unattended"
    else
      record A5 SKIP "run the workflow with tests=advanced"
    fi
  elif command -v gh >/dev/null 2>&1; then
    local result
    result="$(latest_run "tests=advanced")"
    case "$result" in
      success*) record A5 PASS "latest advanced run: $result" ;;
      "") record A5 SKIP "no advanced run yet: gh workflow run deploy.yml -f action=apply -f tests=advanced" ;;
      *) record A5 FAIL "latest advanced run: $result" ;;
    esac
  else
    record A5 SKIP "install the GitHub CLI or run Actions -> deploy -> tests=advanced"
  fi
}

# ---------------------------------------------------------------------------
# Which tests
# ---------------------------------------------------------------------------
SELECTED=()
for arg in "${@:-basic}"; do
  case "$arg" in
    basic) SELECTED+=("${BASIC[@]}") ;;
    advanced) SELECTED+=("${ADVANCED[@]}") ;;
    all) SELECTED+=("${BASIC[@]}" "${ADVANCED[@]}") ;;
    [BA][1-6]) SELECTED+=("$arg") ;;
    *)
      echo "unknown test '$arg' (basic | advanced | all | B1..B6 | A1..A5)" >&2
      exit 2
      ;;
  esac
done

log "Run $RUN against $(out app_url): ${SELECTED[*]}"
for id in "${SELECTED[@]}"; do
  log "---- $id"
  "t_$id"
done

echo
printf '%-4s %-5s %s\n' ID RESULT DETAIL | tee "$RUN_DIR/summary.txt"
while IFS=$'\t' read -r id status detail; do
  printf '%-4s %-5s %s\n' "$id" "$status" "$detail"
done <"$RESULTS" | tee -a "$RUN_DIR/summary.txt"

"$PY" - "$RESULTS" "$RUN_DIR/results.json" <<'EOF'
import json, sys
rows = [line.rstrip("\n").split("\t", 2) for line in open(sys.argv[1]) if line.strip()]
json.dump([{"id": i, "result": r, "detail": d} for i, r, d in rows], open(sys.argv[2], "w"), indent=2)
EOF

upload_dir "$RUN_DIR" evidence >/dev/null 2>&1 && log "Evidence: s3://$(out artifacts_bucket)/evidence/$RUN/"
if grep -q $'\tFAIL\t' "$RESULTS"; then
  exit 1
fi
