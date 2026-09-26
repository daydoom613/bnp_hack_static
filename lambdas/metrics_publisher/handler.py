"""Every minute: publish queue_length and the live FinOps cost metrics.

FinOps/App   queue_length {QueueName}              -> Worker ASG step scaling
FinOps/Cost  HourlyCost, ProjectedMonthlyCost,     -> Grafana, the 90% budget alarm,
             BaselineMonthlyCost, AvoidedMonthlyCost,  and finops/optimized_cost.py
             SavingsPercent, BudgetCap, BudgetUsagePercent {Stack}
FinOps/Cost  InstanceCount {Stack, Tier, Market}

Cost = every instance the two ASGs are running, priced from data/pricing_matrix.csv
(On-Demand or Spot rate by the instance's actual market), x 730 h for a monthly
run rate. The baseline is the static fleet's cost from data/baseline_cost.json.
"""
import json
import logging
import os

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

STACK = os.environ["STACK"]
TIERS = {"web": os.environ["WEB_ASG"], "worker": os.environ["WORKER_ASG"]}
QUEUE_URL = os.environ["QUEUE_URL"]
QUEUE_NAME = os.environ["QUEUE_NAME"]
PRICING = json.loads(os.environ["PRICING_JSON"])  # {"t3.small": {"on_demand": .., "spot": ..}, ...}
BASELINE_MONTHLY = float(os.environ["BASELINE_MONTHLY"])
BUDGET_PARAMETER = os.environ["BUDGET_PARAMETER"]
HOURS_PER_MONTH = float(os.environ.get("HOURS_PER_MONTH", "730"))
COST_NAMESPACE = os.environ.get("COST_NAMESPACE", "FinOps/Cost")
APP_NAMESPACE = os.environ.get("APP_NAMESPACE", "FinOps/App")

autoscaling = boto3.client("autoscaling")
ec2 = boto3.client("ec2")
sqs = boto3.client("sqs")
ssm = boto3.client("ssm")
cloudwatch = boto3.client("cloudwatch")


def queue_length():
    attrs = sqs.get_queue_attributes(QueueUrl=QUEUE_URL, AttributeNames=["ApproximateNumberOfMessages"])
    return int(attrs["Attributes"]["ApproximateNumberOfMessages"])


def fleet():
    """[(tier, instance_type, market)] for every instance the ASGs still hold (all are billed)."""
    groups = autoscaling.describe_auto_scaling_groups(AutoScalingGroupNames=list(TIERS.values()))
    tier_of = {name: tier for tier, name in TIERS.items()}
    members = {}
    for group in groups["AutoScalingGroups"]:
        for inst in group["Instances"]:
            members[inst["InstanceId"]] = (tier_of[group["AutoScalingGroupName"]], inst["InstanceType"])

    market = {}
    ids = list(members)
    for start in range(0, len(ids), 100):
        for reservation in ec2.describe_instances(InstanceIds=ids[start:start + 100])["Reservations"]:
            for inst in reservation["Instances"]:
                market[inst["InstanceId"]] = "spot" if inst.get("InstanceLifecycle") == "spot" else "on-demand"
    return [(tier, itype, market.get(iid, "on-demand")) for iid, (tier, itype) in members.items()]


def price(itype, market):
    rates = PRICING.get(itype)
    if rates is None:
        # Unpriced types never get past OPA; if one appears anyway, count it at the dearest rate.
        log.warning("no price for %s, using the highest On-Demand rate", itype)
        return max(r["on_demand"] for r in PRICING.values())
    return rates["spot"] if market == "spot" else rates["on_demand"]


def budget_cap():
    return float(ssm.get_parameter(Name=BUDGET_PARAMETER)["Parameter"]["Value"])


def handler(event, context):
    depth = queue_length()
    instances = fleet()
    hourly = sum(price(itype, market) for _, itype, market in instances)
    projected = hourly * HOURS_PER_MONTH
    cap = budget_cap()
    avoided = BASELINE_MONTHLY - projected
    usage = 100 * projected / cap if cap else 0

    stack = [{"Name": "Stack", "Value": STACK}]
    cost = [
        ("HourlyCost", hourly, "None"),
        ("ProjectedMonthlyCost", projected, "None"),
        ("BaselineMonthlyCost", BASELINE_MONTHLY, "None"),
        ("AvoidedMonthlyCost", avoided, "None"),
        ("SavingsPercent", 100 * avoided / BASELINE_MONTHLY if BASELINE_MONTHLY else 0, "Percent"),
        ("BudgetCap", cap, "None"),
        ("BudgetUsagePercent", usage, "Percent"),
    ]
    data = [{"MetricName": n, "Dimensions": stack, "Value": round(v, 4), "Unit": u} for n, v, u in cost]
    for tier in TIERS:
        for market in ("on-demand", "spot"):
            count = sum(1 for t, _, m in instances if t == tier and m == market)
            data.append({"MetricName": "InstanceCount", "Unit": "Count", "Value": count,
                         "Dimensions": stack + [{"Name": "Tier", "Value": tier}, {"Name": "Market", "Value": market}]})

    cloudwatch.put_metric_data(Namespace=COST_NAMESPACE, MetricData=data)
    cloudwatch.put_metric_data(Namespace=APP_NAMESPACE, MetricData=[{
        "MetricName": "queue_length", "Unit": "Count", "Value": depth,
        "Dimensions": [{"Name": "QueueName", "Value": QUEUE_NAME}]}])

    summary = {"queue_length": depth, "instances": len(instances), "hourly_cost": round(hourly, 4),
               "projected_monthly": round(projected, 2), "avoided_monthly": round(avoided, 2),
               "budget_cap": cap, "budget_usage_percent": round(usage, 1)}
    log.info(json.dumps(summary))
    return summary
