import json
import os
from pathlib import Path

import boto3
import pandas as pd
from dotenv import load_dotenv

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles


load_dotenv()


app = FastAPI(
    title="Dynamic AutoScale Dashboard"
)


AWS_ENABLED = (
    os.getenv(
        "AWS_ENABLED",
        "false"
    ).lower()
    == "true"
)

AWS_REGION = os.getenv(
    "AWS_REGION",
    "eu-west-1"
)

WEB_ASG_NAME = os.getenv(
    "WEB_ASG_NAME",
    ""
)

WORKER_ASG_NAME = os.getenv(
    "WORKER_ASG_NAME",
    ""
)

BUDGET_FILE = Path(
    os.getenv(
        "BUDGET_FILE",
        "../data/budget_cap.txt"
    )
)

BASELINE_FILE = Path(
    os.getenv(
        "BASELINE_COST_FILE",
        "../data/baseline_cost.json"
    )
)

OPTIMIZED_FILE = Path(
    os.getenv(
        "OPTIMIZED_COST_FILE",
        "../reports/latest/optimized_cost.json"
    )
)

TRAFFIC_REPORT = Path(
    "reports/traffic_report.csv"
)


app.mount(
    "/static",
    StaticFiles(
        directory="dashboard/static"
    ),
    name="static"
)


def read_budget():

    with open(
        BUDGET_FILE,
        "r",
        encoding="utf-8"
    ) as file:

        for line in file:

            line = line.strip()

            if (
                line
                and not line.startswith("#")
            ):
                return float(line)

    return 0


def read_baseline_cost():

    with open(
        BASELINE_FILE,
        encoding="utf-8"
    ) as file:

        data = json.load(file)

    return float(
        data["Projects"][0]
        ["TotalMonthlyCost"]
    )


def read_optimized_cost():

    if not OPTIMIZED_FILE.exists():
        return 0

    with open(
        OPTIMIZED_FILE,
        encoding="utf-8"
    ) as file:

        data = json.load(file)

    return float(
        data.get(
            "TotalMonthlyCost",
            0
        )
    )


def read_traffic():

    if not TRAFFIC_REPORT.exists():

        return {
            "current_rps": 0,
            "avg_latency_ms": 0,
            "error_rate_percent": 0
        }

    df = pd.read_csv(
        TRAFFIC_REPORT
    )

    if df.empty:

        return {
            "current_rps": 0,
            "avg_latency_ms": 0,
            "error_rate_percent": 0
        }

    latest = df.iloc[-1]

    return {
        "current_rps":
            float(
                latest["actual_rps"]
            ),

        "avg_latency_ms":
            float(
                latest[
                    "avg_latency_ms"
                ]
            ),

        "error_rate_percent":
            float(
                latest[
                    "error_rate_percent"
                ]
            )
    }


def get_asg_count(name):

    if not AWS_ENABLED or not name:
        return None

    client = boto3.client(
        "autoscaling",
        region_name=AWS_REGION
    )

    response = (
        client
        .describe_auto_scaling_groups(
            AutoScalingGroupNames=[
                name
            ]
        )
    )

    groups = response[
        "AutoScalingGroups"
    ]

    if not groups:
        return 0

    instances = groups[0][
        "Instances"
    ]

    return len(
        [
            instance
            for instance in instances
            if instance[
                "LifecycleState"
            ]
            == "InService"
        ]
    )


@app.get("/")
async def dashboard():

    return FileResponse(
        "dashboard/static/index.html"
    )


@app.get("/api/summary")
async def summary():

    budget = read_budget()

    baseline = (
        read_baseline_cost()
    )

    optimized = (
        read_optimized_cost()
    )

    avoided = (
        baseline - optimized
    )

    savings = (
        avoided / baseline * 100
        if baseline
        else 0
    )

    budget_usage = (
        optimized / budget * 100
        if budget
        else 0
    )

    traffic = read_traffic()

    web_count = get_asg_count(
        WEB_ASG_NAME
    )

    worker_count = get_asg_count(
        WORKER_ASG_NAME
    )

    # No AWS access: show nothing rather than made-up counts.
    total_instances = (
        None
        if web_count is None or worker_count is None
        else web_count + worker_count
    )

    return {

        "traffic": traffic,

        "infrastructure": {
            "web_instances":
                web_count,

            "worker_instances":
                worker_count,

            "total_instances":
                total_instances
        },

        "cost": {

            "baseline_cost":
                round(
                    baseline,
                    2
                ),

            "optimized_cost":
                round(
                    optimized,
                    2
                ),

            "avoided_cost":
                round(
                    avoided,
                    2
                ),

            "savings_percent":
                round(
                    savings,
                    2
                ),

            "budget_cap":
                round(
                    budget,
                    2
                ),

            "budget_usage_percent":
                round(
                    budget_usage,
                    2
                ),

            "budget_alert":
                budget_usage >= 90
        }
    }


@app.get("/health")
async def health():

    return {
        "status": "healthy"
    }