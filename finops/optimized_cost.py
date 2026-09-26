#!/usr/bin/env python3
"""Optimized (dynamic stack) monthly cost, measured over a load-test window.

    python finops/optimized_cost.py --stack finops-cloudscale-dev \
        --start 2026-09-26T10:00:00Z --end 2026-09-26T11:15:00Z --out optimized_cost.json

The metrics Lambda publishes FinOps/Cost HourlyCost every minute: every instance the
two ASGs hold, priced from data/pricing_matrix.csv at its real market (On-Demand or
Spot). The time-weighted average over the window, x 730 h, is the monthly cost the
stack runs at under that traffic profile, so there is no need to wait a month.
It uses the same prices and the same 730 h as data/baseline_cost.json, so the two
numbers compare like for like in finops/cost_report.py.

Writes the same JSON shape as data/baseline_cost.json (TotalMonthlyCost + Projects).
"""
import argparse
import json
import sys
from datetime import datetime, timedelta, timezone

HOURS_PER_MONTH = 730
NAMESPACE = "FinOps/Cost"


def parse_time(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)


def minutes(cloudwatch, stack, metric, start, end, dimensions=()):
    """One value per minute, oldest first. GetMetricData pages past the 1440-point limit."""
    query = {
        "Id": "m",
        "MetricStat": {
            "Metric": {"Namespace": NAMESPACE, "MetricName": metric,
                       "Dimensions": [{"Name": "Stack", "Value": stack}, *dimensions]},
            "Period": 60,
            "Stat": "Average",
        },
    }
    points, token = {}, None
    while True:
        kwargs = {"MetricDataQueries": [query], "StartTime": start, "EndTime": end, "ScanBy": "TimestampAscending"}
        if token:
            kwargs["NextToken"] = token
        page = cloudwatch.get_metric_data(**kwargs)
        for result in page["MetricDataResults"]:
            points.update(zip(result["Timestamps"], result["Values"]))
        token = page.get("NextToken")
        if not token:
            return [points[t] for t in sorted(points)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stack", required=True, help="terraform output stack_name")
    ap.add_argument("--start", required=True, help="ISO-8601 UTC, e.g. 2026-09-26T10:00:00Z")
    ap.add_argument("--end", required=True)
    ap.add_argument("--region", default="eu-west-1")
    ap.add_argument("--profile", help="AWS profile (default: the usual credential chain)")
    ap.add_argument("--out", default="-")
    args = ap.parse_args()

    import boto3

    start, end = parse_time(args.start), parse_time(args.end)
    if end - start < timedelta(minutes=1):
        sys.exit("the window must be at least 1 minute (the metrics Lambda publishes once a minute)")

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    cloudwatch = session.client("cloudwatch")

    hourly = minutes(cloudwatch, args.stack, "HourlyCost", start, end)
    if not hourly:
        sys.exit(f"no {NAMESPACE} HourlyCost data for Stack={args.stack} between {args.start} and {args.end}; "
                 "is the metrics Lambda running?")

    counts = {}
    for tier in ("web", "worker"):
        for market in ("on-demand", "spot"):
            series = minutes(cloudwatch, args.stack, "InstanceCount", start, end,
                             [{"Name": "Tier", "Value": tier}, {"Name": "Market", "Value": market}])
            counts[f"{tier}_{market}"] = {
                "avg": round(sum(series) / len(series), 2) if series else 0,
                "max": max(series) if series else 0,
            }

    window_minutes = (end - start).total_seconds() / 60
    avg_hourly = sum(hourly) / len(hourly)
    monthly = round(avg_hourly * HOURS_PER_MONTH, 2)
    result = {
        "Version": "0.1",
        "Source": "finops/optimized_cost.py (FinOps/Cost HourlyCost, measured)",
        "Region": args.region,
        "HoursPerMonth": HOURS_PER_MONTH,
        "TotalMonthlyCost": monthly,
        "Projects": [{"Name": "optimized-dynamic-infra", "TotalMonthlyCost": monthly}],
        "Window": {
            "start": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "end": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "minutes": round(window_minutes, 1),
            "samples": len(hourly),
            "coverage_percent": round(100 * len(hourly) / max(window_minutes, 1), 1),
        },
        "AverageHourlyCost": round(avg_hourly, 5),
        "PeakHourlyCost": round(max(hourly), 5),
        "MinHourlyCost": round(min(hourly), 5),
        "InstanceCounts": counts,
        "Notes": [
            "EC2 compute only, priced from data/pricing_matrix.csv, same scope as data/baseline_cost.json.",
            "Monthly = time-weighted average hourly cost over the window x 730 h: "
            "the traffic profile is treated as a representative, compressed day.",
        ],
    }

    text = json.dumps(result, indent=2)
    if args.out == "-":
        print(text)
    else:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text + "\n")
    print(f"Optimized monthly cost: {monthly:.2f} (avg {avg_hourly:.4f}/h over {len(hourly)} min, "
          f"peak {max(hourly):.4f}/h)", file=sys.stderr)


if __name__ == "__main__":
    main()
