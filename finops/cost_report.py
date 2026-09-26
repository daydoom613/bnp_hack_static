#!/usr/bin/env python3
"""Write cost_savings.csv: baseline cost, optimized cost, avoided cost and %-savings.

    python finops/cost_report.py --baseline data/baseline_cost.json \
        --optimized optimized_cost.json --out cost_savings.csv
    python finops/cost_report.py --baseline data/baseline_cost.json --optimized-cost 151.20

avoided_cost = baseline - optimized (the glossary's definition). Each cost file
may be finops/cost_model.py output, data/baseline_cost.json, or raw Infracost
JSON; --optimized-cost takes a plain number instead (e.g. from the bill).
"""
import argparse
import csv
import json
import sys
from datetime import datetime, timezone

COLUMNS = [
    "generated_at",
    "baseline_monthly_cost",
    "optimized_monthly_cost",
    "avoided_cost",
    "savings_pct",
    "budget_cap",
    "optimized_budget_usage_pct",
    "baseline_source",
    "optimized_source",
]


def monthly_cost(path):
    with open(path, encoding="utf-8-sig") as f:
        doc = json.load(f)
    if doc.get("TotalMonthlyCost") is not None:
        return float(doc["TotalMonthlyCost"])
    if doc.get("Projects"):
        return sum(float(p["TotalMonthlyCost"]) for p in doc["Projects"])
    if doc.get("totalMonthlyCost") is not None:  # raw Infracost output
        return float(doc["totalMonthlyCost"])
    sys.exit(f"{path}: no TotalMonthlyCost, Projects or totalMonthlyCost")


def budget_cap(path):
    """data/budget_cap.txt: one number; lines starting with # are ignored."""
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return float(line)
    sys.exit(f"{path}: no budget number")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", default="data/baseline_cost.json")
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--optimized", help="cost JSON for the optimized stack")
    group.add_argument("--optimized-cost", type=float, help="optimized monthly cost as a number")
    ap.add_argument("--budget-cap-file", default="data/budget_cap.txt")
    ap.add_argument("--out", default="cost_savings.csv")
    args = ap.parse_args()

    baseline = monthly_cost(args.baseline)
    if args.optimized:
        optimized, optimized_source = monthly_cost(args.optimized), args.optimized
    else:
        optimized, optimized_source = args.optimized_cost, "manual"

    avoided = baseline - optimized
    cap = budget_cap(args.budget_cap_file)
    row = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "baseline_monthly_cost": f"{baseline:.2f}",
        "optimized_monthly_cost": f"{optimized:.2f}",
        "avoided_cost": f"{avoided:.2f}",
        "savings_pct": f"{100 * avoided / baseline:.1f}" if baseline else "0.0",
        "budget_cap": f"{cap:.2f}",
        "optimized_budget_usage_pct": f"{100 * optimized / cap:.1f}",
        "baseline_source": args.baseline,
        "optimized_source": optimized_source,
    }

    with open(args.out, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerow(row)

    print(f"baseline {row['baseline_monthly_cost']}  optimized {row['optimized_monthly_cost']}  "
          f"avoided {row['avoided_cost']} ({row['savings_pct']}%)  "
          f"budget {row['optimized_budget_usage_pct']}% of {row['budget_cap']}  -> {args.out}")


if __name__ == "__main__":
    main()
