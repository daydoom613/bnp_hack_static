#!/usr/bin/env python3
"""What the stack did during a time window: scaling, Spot share, queue, latency, errors.

    python finops/window_summary.py --stack finops-cloudscale-dev --web-asg <name> \
        --queue <name> --start 2026-09-26T10:00:00Z --end 2026-09-26T11:15:00Z --out scaling_summary.json

Reads CloudWatch only (1-minute data), so it can be run any time within 15 days of the
window. Used by scripts/run_load_test.sh and the Advanced full-profile test.
"""
import argparse
import json
import sys
from datetime import datetime, timezone


def parse_time(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)


def series(cloudwatch, namespace, metric, dimensions, stat, start, end):
    query = {"Id": "m", "MetricStat": {
        "Metric": {"Namespace": namespace, "MetricName": metric,
                   "Dimensions": [{"Name": k, "Value": v} for k, v in dimensions.items()]},
        "Period": 60, "Stat": stat}}
    values, token = [], None
    while True:
        kwargs = {"MetricDataQueries": [query], "StartTime": start, "EndTime": end}
        if token:
            kwargs["NextToken"] = token
        page = cloudwatch.get_metric_data(**kwargs)
        for result in page["MetricDataResults"]:
            values.extend(result["Values"])
        token = page.get("NextToken")
        if not token:
            return values


def alb_dimension(elbv2, stack):
    arn = elbv2.describe_load_balancers(Names=[f"{stack}-alb"])["LoadBalancers"][0]["LoadBalancerArn"]
    return arn.split(":loadbalancer/")[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stack", required=True)
    ap.add_argument("--web-asg", required=True)
    ap.add_argument("--queue", required=True)
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--region", default="eu-west-1")
    ap.add_argument("--out", default="-")
    args = ap.parse_args()

    import boto3

    session = boto3.Session(region_name=args.region)
    cloudwatch = session.client("cloudwatch")
    start, end = parse_time(args.start), parse_time(args.end)

    def stats(values):
        return {"max": max(values) if values else None,
                "avg": round(sum(values) / len(values), 2) if values else None,
                "samples": len(values)}

    cost = {"Stack": args.stack}
    summary = {
        "window": {"start": args.start, "end": args.end},
        "web_in_service": stats(series(cloudwatch, "AWS/AutoScaling", "GroupInServiceInstances",
                                       {"AutoScalingGroupName": args.web_asg}, "Maximum", start, end)),
        "worker_on_demand": stats(series(cloudwatch, "FinOps/Cost", "InstanceCount",
                                         {**cost, "Tier": "worker", "Market": "on-demand"}, "Maximum", start, end)),
        "worker_spot": stats(series(cloudwatch, "FinOps/Cost", "InstanceCount",
                                    {**cost, "Tier": "worker", "Market": "spot"}, "Maximum", start, end)),
        "queue_length": stats(series(cloudwatch, "FinOps/App", "queue_length",
                                     {"QueueName": args.queue}, "Maximum", start, end)),
        "budget_usage_percent": stats(series(cloudwatch, "FinOps/Cost", "BudgetUsagePercent",
                                             cost, "Maximum", start, end)),
    }
    try:
        alb = {"LoadBalancer": alb_dimension(session.client("elbv2"), args.stack)}
        latency = series(cloudwatch, "AWS/ApplicationELB", "TargetResponseTime", alb, "Average", start, end)
        summary["alb_target_response_ms"] = {k: (round(v * 1000, 1) if isinstance(v, float) else v)
                                             for k, v in stats(latency).items()}
        summary["alb_requests"] = int(sum(series(cloudwatch, "AWS/ApplicationELB", "RequestCount",
                                                 alb, "Sum", start, end)))
        summary["alb_target_5xx"] = int(sum(series(cloudwatch, "AWS/ApplicationELB", "HTTPCode_Target_5XX_Count",
                                                   alb, "Sum", start, end)))
    except Exception as exc:  # the scaling numbers are still useful without the ALB ones
        summary["alb_error"] = str(exc)

    text = json.dumps(summary, indent=2)
    if args.out == "-":
        print(text)
    else:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text + "\n")
    print(f"web max {summary['web_in_service']['max']} | worker spot max {summary['worker_spot']['max']} | "
          f"queue max {summary['queue_length']['max']}", file=sys.stderr)


if __name__ == "__main__":
    main()
