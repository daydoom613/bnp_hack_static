#!/usr/bin/env bash
# Demo the red budget alert without spending more: temporarily lower the cap the LIVE
# cost metrics compare against. Grafana's "Budget used" panel and the CloudWatch alarm
# <stack>-budget-90pct turn red within about a minute once projected >= 90% of it.
#
#   scripts/budget_alert_demo.sh 25      # idle fleet runs at ~22.8/month -> 91% -> red
#   scripts/budget_alert_demo.sh reset   # back to data/budget_cap.txt
#
# This only changes the SSM parameter the metrics Lambda reads. The OPA budget guard
# still uses data/budget_cap.txt, and the next terraform apply restores the parameter.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

VALUE="${1:?usage: $0 <cap> | reset}"
if [ "$VALUE" = "reset" ]; then
  VALUE="$(grep -v '^[[:space:]]*#' "$ROOT/data/budget_cap.txt" | tr -d '[:space:]')"
fi

PARAM="$(out budget_parameter)"
aws ssm put-parameter --name "$PARAM" --value "$VALUE" --type String --overwrite >/dev/null
log "$PARAM = $VALUE. Watch Grafana 'Budget used' and alarm $(out stack_name)-budget-90pct."
