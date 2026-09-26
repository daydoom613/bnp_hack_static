#!/usr/bin/env python3
"""Generates observability/grafana/dashboards/finops-cloudscale.json (run after editing).

    python observability/build_dashboard.py
"""
import json
from pathlib import Path

DS = {"type": "cloudwatch", "uid": "cloudwatch"}


def metric(ref, namespace, name, dimensions, stat="Maximum", label=""):
    return {"refId": ref, "datasource": DS, "queryMode": "Metrics", "region": "default",
            "namespace": namespace, "metricName": name, "dimensions": dimensions, "statistic": stat,
            "period": "60", "matchExact": True, "metricQueryType": 0, "metricEditorMode": 0,
            "id": "", "expression": "", "label": label}


def search(ref, expression, label=""):
    # Grafana rejects a CloudWatch query without "statistic", even when the SEARCH
    # expression carries its own.
    return {"refId": ref, "datasource": DS, "queryMode": "Metrics", "region": "default",
            "metricQueryType": 0, "metricEditorMode": 1, "expression": expression,
            "statistic": "Average", "id": "", "label": label, "period": "60"}


def cost(ref, name, label, stat="Maximum"):
    return metric(ref, "FinOps/Cost", name, {"Stack": "$stack"}, stat, label)


def count(ref, tier, market, label):
    return metric(ref, "FinOps/Cost", "InstanceCount",
                  {"Stack": "$stack", "Tier": tier, "Market": market}, "Maximum", label)


def thresholds(*steps):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in steps]}


def stat(pid, title, x, targets, unit="none", steps=(("blue", None),), color_mode="value", decimals=None):
    defaults = {"unit": unit, "thresholds": thresholds(*steps), "color": {"mode": "thresholds"}}
    if decimals is not None:
        defaults["decimals"] = decimals
    return {"id": pid, "type": "stat", "title": title, "datasource": DS,
            "gridPos": {"h": 5, "w": 4, "x": x, "y": 0}, "targets": targets,
            "fieldConfig": {"defaults": defaults, "overrides": []},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                        "colorMode": color_mode, "graphMode": "area", "textMode": "auto", "justifyMode": "center"}}


def series(pid, title, x, y, targets, unit="none", stack=False, line_at=None, w=12):
    custom = {"drawStyle": "line", "lineWidth": 2, "fillOpacity": 25 if stack else 5, "showPoints": "never",
              "spanNulls": True, "stacking": {"mode": "normal" if stack else "none", "group": "A"}}
    steps = (("transparent", None),)
    if line_at is not None:
        custom["thresholdsStyle"] = {"mode": "line"}
        steps = (("transparent", None), ("red", line_at))
    return {"id": pid, "type": "timeseries", "title": title, "datasource": DS,
            "gridPos": {"h": 8, "w": w, "x": x, "y": y}, "targets": targets,
            "fieldConfig": {"defaults": {"unit": unit, "custom": custom, "thresholds": thresholds(*steps),
                                         "color": {"mode": "palette-classic"}}, "overrides": []},
            "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                        "tooltip": {"mode": "multi", "sort": "none"}}}


alb = "{AWS/ApplicationELB,LoadBalancer}"
panels = [
    stat(1, "Web instances (On-Demand)", 0, [metric("A", "AWS/AutoScaling", "GroupInServiceInstances",
                                                    {"AutoScalingGroupName": "$web_asg"})]),
    stat(2, "Worker On-Demand", 4, [count("A", "worker", "on-demand", "on-demand")]),
    stat(3, "Worker Spot", 8, [count("A", "worker", "spot", "spot")], steps=(("purple", None),)),
    stat(4, "Projected monthly cost (run rate)", 12, [cost("A", "ProjectedMonthlyCost", "projected")],
         unit="currencyUSD", decimals=2),
    stat(5, "Avoided vs static baseline / month", 16, [cost("A", "AvoidedMonthlyCost", "avoided")],
         unit="currencyUSD", steps=(("red", None), ("green", 0)), decimals=2),
    stat(6, "Budget used (RED >= 90% of cap)", 20, [cost("A", "BudgetUsagePercent", "budget used")],
         unit="percent", steps=(("green", None), ("orange", 75), ("red", 90)), color_mode="background",
         decimals=1),

    series(7, "Instances: web On-Demand, worker On-Demand, worker Spot", 0, 5, [
        metric("A", "AWS/AutoScaling", "GroupInServiceInstances", {"AutoScalingGroupName": "$web_asg"},
               label="web on-demand"),
        count("B", "worker", "on-demand", "worker on-demand"),
        count("C", "worker", "spot", "worker spot"),
    ], stack=True),
    series(8, "Monthly compute cost: dynamic run rate vs static baseline vs budget cap", 12, 5, [
        cost("A", "ProjectedMonthlyCost", "dynamic (run rate)"),
        cost("B", "BaselineMonthlyCost", "static baseline"),
        cost("C", "BudgetCap", "budget cap"),
    ], unit="currencyUSD"),

    series(9, "queue_length (worker scaling signal, scale out > 50)", 0, 13, [
        metric("A", "FinOps/App", "queue_length", {"QueueName": "$queue"}, label="queue_length")], line_at=50),
    series(10, "Web CPU (target tracking at 50%)", 12, 13, [
        metric("A", "AWS/EC2", "CPUUtilization", {"AutoScalingGroupName": "$web_asg"}, "Average", "web CPU avg")],
        unit="percent", line_at=50),

    series(11, "ALB requests / min and 5xx", 0, 21, [
        search("A", f"SEARCH('{alb} MetricName=\"RequestCount\" $stack', 'Sum', 60)", "requests"),
        search("B", f"SEARCH('{alb} MetricName=\"HTTPCode_Target_5XX_Count\" $stack', 'Sum', 60)", "target 5xx"),
        search("C", f"SEARCH('{alb} MetricName=\"HTTPCode_ELB_5XX_Count\" $stack', 'Sum', 60)", "ALB 5xx"),
    ]),
    series(12, "Latency: ALB target response time (limit 300 ms)", 12, 21, [
        search("A", f"SEARCH('{alb} MetricName=\"TargetResponseTime\" $stack', 'Average', 60)", "avg"),
        search("B", f"SEARCH('{alb} MetricName=\"TargetResponseTime\" $stack', 'p95', 60)", "p95"),
    ], unit="s", line_at=0.3),
]


def textbox(name, default, label):
    return {"name": name, "label": label, "type": "textbox", "query": default, "hide": 0,
            "current": {"text": default, "value": default}, "options": [{"text": default, "value": default,
                                                                           "selected": True}]}


dashboard = {
    "uid": "finops-cloudscale",
    "title": "FinOps CloudScale",
    "description": "Live instance counts, projected vs baseline cost, avoided cost and the 90% budget alert.",
    "tags": ["finops", "cloudscale"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 1,
    "editable": True,
    "refresh": "10s",
    "time": {"from": "now-1h", "to": "now"},
    "templating": {"list": [
        textbox("stack", "finops-cloudscale-dev", "Stack"),
        textbox("web_asg", "finops-cloudscale-dev-web-asg", "Web ASG"),
        textbox("worker_asg", "finops-cloudscale-dev-worker-asg", "Worker ASG"),
        textbox("queue", "finops-cloudscale-dev-jobs", "Queue"),
    ]},
    "annotations": {"list": []},
    "panels": panels,
}

out = Path(__file__).parent / "grafana" / "dashboards" / "finops-cloudscale.json"
out.write_text(json.dumps(dashboard, indent=2) + "\n", encoding="utf-8", newline="\n")
print(f"wrote {out} ({len(panels)} panels)")
