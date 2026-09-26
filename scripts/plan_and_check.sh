#!/usr/bin/env bash
# Plan a stack and run the budget guard: the same steps deploy.yml runs.
#
#   terraform plan  ->  plan.json  ->  finops/cost_model.py  ->  opa eval data.finops.allow
#
# Usage:  AWS_PROFILE=<profile> scripts/plan_and_check.sh [dev|baseline]
#   dev       the dynamic stack that gets deployed (default)
#   baseline  the static fleet; PLAN ONLY, never apply it. With UPDATE_BASELINE=1 the
#             priced plan is written to data/baseline_cost.json.
#
# Writes tfplan, plan.json, cost_model.json and opa_input.json into the env folder
# (all git-ignored). Exits 1 if OPA denies the plan, so tfplan is only applied when
# allow = true.
#
# Overrides: TERRAFORM, OPA, PYTHON (binaries); BUDGET_CAP_FILE;
#            ON_DEMAND_RATE=reserved to price On-Demand capacity at Reserved-Instance rates;
#            PLAN_FILE (default tfplan) so what-if plans never replace the one you apply.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STACK="${1:-dev}"
case "$STACK" in
  dev) NAME="optimized-dynamic-infra" ;;
  baseline) NAME="baseline-static-infra" ;;
  *)
    echo "usage: $0 [dev|baseline]" >&2
    exit 2
    ;;
esac

ENV_DIR="terraform/environments/$STACK"
TF="${TERRAFORM:-terraform}"
OPA="${OPA:-opa}"
PY="${PYTHON:-$(command -v python || command -v python3)}"
BUDGET_CAP_FILE="${BUDGET_CAP_FILE:-data/budget_cap.txt}"
ON_DEMAND_RATE="${ON_DEMAND_RATE:-on_demand}"
PLAN_FILE="${PLAN_FILE:-tfplan}"

# budget_cap only ever comes from data/budget_cap.txt (lines starting with # are ignored).
TF_VAR_budget_cap="$(grep -v '^[[:space:]]*#' "$BUDGET_CAP_FILE" | tr -d '[:space:]')"
if ! [[ "$TF_VAR_budget_cap" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "$BUDGET_CAP_FILE must contain one number, got '$TF_VAR_budget_cap'" >&2
  exit 1
fi
export TF_VAR_budget_cap
echo "[$STACK] budget_cap = $TF_VAR_budget_cap (from $BUDGET_CAP_FILE), pricing = $ON_DEMAND_RATE"

if [ ! -d "$ENV_DIR/.terraform" ] && [ -z "${TF_DATA_DIR:-}" ]; then
  if [ "$STACK" = "dev" ]; then
    "$TF" -chdir="$ENV_DIR" init -input=false -backend-config=backend.hcl
  else
    "$TF" -chdir="$ENV_DIR" init -input=false
  fi
fi

"$TF" -chdir="$ENV_DIR" plan -input=false -lock-timeout=5m -out="$PLAN_FILE"
"$TF" -chdir="$ENV_DIR" show -json "$PLAN_FILE" >"$ENV_DIR/plan.json"

"$PY" finops/cost_model.py \
  --plan "$ENV_DIR/plan.json" \
  --pricing data/pricing_matrix.csv \
  --name "$NAME" \
  --on-demand-rate "$ON_DEMAND_RATE" \
  --out "$ENV_DIR/cost_model.json"

"$PY" - "$ENV_DIR/plan.json" "$ENV_DIR/cost_model.json" "$ENV_DIR/opa_input.json" <<'EOF'
import json, sys
plan, cost, out = sys.argv[1:4]
with open(plan, encoding="utf-8") as p, open(cost, encoding="utf-8") as c, open(out, "w", encoding="utf-8") as o:
    json.dump({"plan": json.load(p), "cost": json.load(c)}, o)
EOF

query() { "$OPA" eval --data policies --input "$ENV_DIR/opa_input.json" --format "$1" "$2"; }

echo
echo "OPA budget guard (policies/budget.rego + policies/tags.rego) on $STACK"
warnings="$(query raw 'concat("\n", data.finops.warn)')"
[ -n "$warnings" ] && echo "WARN: $warnings"

if [ "$(query raw 'data.finops.allow')" != "true" ]; then
  echo "allow = false. The plan is BLOCKED:"
  query raw 'concat("\n", [sprintf("  - %s", [m]) | m := data.finops.deny[_]])'
  exit 1
fi
echo "allow = true"

if [ "$STACK" = "baseline" ] && [ "${UPDATE_BASELINE:-0}" = "1" ]; then
  cp "$ENV_DIR/cost_model.json" data/baseline_cost.json
  echo "Updated data/baseline_cost.json. Never apply terraform/environments/baseline."
fi
