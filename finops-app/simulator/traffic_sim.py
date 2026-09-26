import asyncio
import json
import os
import random
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import boto3
import httpx
import pandas as pd
from dotenv import load_dotenv


# ============================================================
# LOAD ENVIRONMENT VARIABLES
# ============================================================

load_dotenv()


# ============================================================
# CONFIGURATION
# ============================================================

TARGET_API_URL = os.getenv(
    "TARGET_API_URL",
    "http://localhost:8000/process"
)

TRAFFIC_PROFILE = os.getenv(
    "TRAFFIC_PROFILE",
    "data/traffic_profiles_demo.csv"
)

SERVICE_PRIORITY_FILE = os.getenv(
    "SERVICE_PRIORITY_FILE",
    "../data/service_priority.xlsx"
)

AWS_ENABLED = (
    os.getenv("AWS_ENABLED", "false")
    .strip()
    .lower()
    == "true"
)

AWS_REGION = os.getenv(
    "AWS_REGION",
    "eu-west-1"
)

S3_BUCKET = os.getenv(
    "S3_BUCKET",
    ""
)

# Key prefix inside S3_BUCKET, e.g. reports/2026-09-26T10-00-00Z/
S3_PREFIX = os.getenv(
    "S3_PREFIX",
    "reports/"
)

# Share of requests that are Critical (0.0 - 1.0).
# Empty = pick request types uniformly from the Priority sheet.
# The Advanced test uses 0.3: "30 % of requests are marked Critical".
CRITICAL_SHARE = os.getenv(
    "CRITICAL_SHARE",
    ""
).strip()

# Pass / fail gate for CI (empty = no gate).
# The Basic test: error rate <= 5 %, average latency < 200 ms.
MAX_ERROR_RATE = os.getenv(
    "MAX_ERROR_RATE",
    ""
).strip()

MAX_AVG_LATENCY_MS = os.getenv(
    "MAX_AVG_LATENCY_MS",
    ""
).strip()


# ============================================================
# OUTPUT PATHS
# ============================================================

REPORT_DIR = Path(
    os.getenv(
        "REPORT_DIR",
        "reports"
    )
)

REPORT_DIR.mkdir(
    parents=True,
    exist_ok=True
)

TRAFFIC_REPORT_PATH = (
    REPORT_DIR / "traffic_report.csv"
)

REQUEST_REPORT_PATH = (
    REPORT_DIR / "traffic_requests.csv"
)

LIVE_METRICS_PATH = (
    REPORT_DIR / "live_metrics.json"
)


# ============================================================
# LOAD SERVICE PRIORITY DATA
# ============================================================

def load_priority_data():
    """
    Loads workload definitions from:

        data/service_priority.xlsx

    Sheet:
        Priority

    Required columns:
        request_type
        priority
        critical
    """

    path = Path(
        SERVICE_PRIORITY_FILE
    )

    if not path.exists():

        print(
            "service_priority.xlsx not found."
        )

        print(
            "Using fallback request types."
        )

        return [
            {
                "request_type": "CreateOrder",
                "priority": 1,
                "critical": True,
                "weight": 1.0
            },
            {
                "request_type": "GetCatalog",
                "priority": 3,
                "critical": False,
                "weight": 1.0
            },
            {
                "request_type": "UpdateItem",
                "priority": 2,
                "critical": True,
                "weight": 1.0
            }
        ]

    try:

        df = pd.read_excel(
            path,
            sheet_name="Priority"
        )

        required_columns = {
            "request_type",
            "priority",
            "critical"
        }

        missing = (
            required_columns
            - set(df.columns)
        )

        if missing:

            raise ValueError(
                f"Missing columns: {missing}"
            )

        workloads = []

        for _, row in df.iterrows():

            critical_value = (
                row["critical"]
            )

            # Safely handle Excel TRUE/FALSE
            if isinstance(
                critical_value,
                str
            ):

                critical = (
                    critical_value
                    .strip()
                    .lower()
                    in {
                        "true",
                        "1",
                        "yes"
                    }
                )

            else:

                critical = bool(
                    critical_value
                )

            # Optional "weight" column: share of traffic for this
            # request type (e.g. 15 / 15 / 70 for 30 % critical).
            weight = (
                float(row["weight"])
                if "weight" in df.columns
                and pd.notna(row["weight"])
                else 1.0
            )

            workloads.append(
                {
                    "request_type":
                        str(
                            row["request_type"]
                        ).strip(),

                    "priority":
                        int(
                            row["priority"]
                        ),

                    "critical":
                        critical,

                    "weight":
                        weight
                }
            )

        print(
            f"Loaded {len(workloads)} "
            f"workload types from "
            f"{SERVICE_PRIORITY_FILE}"
        )

        for workload in workloads:

            print(
                f"  "
                f"{workload['request_type']} | "
                f"Priority="
                f"{workload['priority']} | "
                f"Critical="
                f"{workload['critical']} | "
                f"Weight="
                f"{workload['weight']}"
            )

        return workloads

    except Exception as exc:

        print(
            "Failed to read "
            "service_priority.xlsx:"
        )

        print(exc)

        print(
            "Using fallback values."
        )

        return [
            {
                "request_type": "CreateOrder",
                "priority": 1,
                "critical": True,
                "weight": 1.0
            },
            {
                "request_type": "GetCatalog",
                "priority": 3,
                "critical": False,
                "weight": 1.0
            },
            {
                "request_type": "UpdateItem",
                "priority": 2,
                "critical": True,
                "weight": 1.0
            }
        ]


WORKLOADS = load_priority_data()


def choose_workload():
    """
    Pick the next request type.

    With CRITICAL_SHARE set, first decide Critical vs
    Non-Critical with that probability, then pick a
    type within the group. Otherwise pick by the sheet's
    "weight" column (uniform when there is none).
    """

    if not CRITICAL_SHARE:
        return random.choices(
            WORKLOADS,
            weights=[
                workload["weight"]
                for workload in WORKLOADS
            ]
        )[0]

    critical = [
        workload
        for workload in WORKLOADS
        if workload["critical"]
    ]

    noncritical = [
        workload
        for workload in WORKLOADS
        if not workload["critical"]
    ]

    want_critical = (
        random.random()
        < float(CRITICAL_SHARE)
    )

    group = (
        critical
        if want_critical
        else noncritical
    )

    return random.choice(
        group or WORKLOADS
    )


# ============================================================
# HELPER FUNCTIONS
# ============================================================

def percentile_95(values):
    """
    Calculate approximate 95th percentile.
    """

    if not values:
        return 0

    values = sorted(values)

    index = int(
        0.95
        * (len(values) - 1)
    )

    return values[index]


def write_live_metrics(data):
    """
    Atomically update live_metrics.json.
    """

    temp_path = (
        LIVE_METRICS_PATH
        .with_suffix(".tmp")
    )

    with open(
        temp_path,
        "w",
        encoding="utf-8"
    ) as file:

        json.dump(
            data,
            file,
            indent=2
        )

    temp_path.replace(
        LIVE_METRICS_PATH
    )


def save_reports(
    all_requests,
    summaries
):
    """
    Save:
      traffic_requests.csv
      traffic_report.csv
    """

    request_df = pd.DataFrame(
        all_requests
    )

    summary_df = pd.DataFrame(
        summaries
    )

    request_df.to_csv(
        REQUEST_REPORT_PATH,
        index=False
    )

    summary_df.to_csv(
        TRAFFIC_REPORT_PATH,
        index=False
    )


# ============================================================
# SINGLE HTTP REQUEST
# ============================================================

async def send_request(
    client,
    semaphore,
    request_number,
    slice_number
):
    """
    Randomly choose one workload from Excel
    and send it to the API.
    """

    # RANDOM SELECTION (weighted by CRITICAL_SHARE when set)
    workload = choose_workload()

    payload = {
        "request_type":
            workload["request_type"],

        "priority":
            workload["priority"],

        "critical":
            workload["critical"]
    }

    # The ALB routes on headers (it cannot read the body):
    # X-Critical=true always goes to the On-Demand web tier.
    headers = {
        "X-Request-Type":
            payload["request_type"],

        "X-Critical":
            str(payload["critical"]).lower()
    }

    async with semaphore:

        start = (
            time.perf_counter()
        )

        try:

            response = await client.post(
                TARGET_API_URL,
                json=payload,
                headers=headers
            )

            latency_ms = (
                time.perf_counter()
                - start
            ) * 1000

            success = (
                200
                <= response.status_code
                < 400
            )

            return {
                "timestamp":
                    datetime.now(
                        timezone.utc
                    ).isoformat(),

                "slice":
                    slice_number,

                "request_number":
                    request_number,

                "request_type":
                    payload["request_type"],

                "priority":
                    payload["priority"],

                "critical":
                    payload["critical"],

                "status_code":
                    response.status_code,

                "latency_ms":
                    round(
                        latency_ms,
                        2
                    ),

                "success":
                    success,

                "error":
                    "",

                # Which host answered (set by the API).
                # Proves Critical requests never succeed on Spot.
                "served_by":
                    response.headers.get(
                        "X-Instance-Id",
                        ""
                    ),

                "served_lifecycle":
                    response.headers.get(
                        "X-Instance-Lifecycle",
                        ""
                    )
            }

        except Exception as exc:

            latency_ms = (
                time.perf_counter()
                - start
            ) * 1000

            return {
                "timestamp":
                    datetime.now(
                        timezone.utc
                    ).isoformat(),

                "slice":
                    slice_number,

                "request_number":
                    request_number,

                "request_type":
                    payload["request_type"],

                "priority":
                    payload["priority"],

                "critical":
                    payload["critical"],

                "status_code":
                    0,

                "latency_ms":
                    round(
                        latency_ms,
                        2
                    ),

                "success":
                    False,

                "error":
                    str(exc),

                "served_by":
                    "",

                "served_lifecycle":
                    ""
            }


# ============================================================
# REQUEST WORKER
# ============================================================

async def request_worker(
    client,
    semaphore,
    request_number,
    slice_number,
    completed_records
):
    """
    Execute one request and store result.
    """

    result = await send_request(
        client=
            client,

        semaphore=
            semaphore,

        request_number=
            request_number,

        slice_number=
            slice_number
    )

    completed_records.append(
        result
    )

    return result


# ============================================================
# LIVE METRICS
# ============================================================

def calculate_live_metrics(
    slice_number,
    target_rps,
    duration_sec,
    concurrency,
    completed_records,
    started_at,
    running=True
):
    """
    Calculate currently completed traffic metrics.
    """

    completed = len(
        completed_records
    )

    successes = sum(
        1
        for record
        in completed_records
        if record["success"]
    )

    failures = (
        completed - successes
    )

    successful_latencies = [
        record["latency_ms"]
        for record
        in completed_records
        if record["success"]
    ]

    if successful_latencies:

        avg_latency = (
            sum(
                successful_latencies
            )
            / len(
                successful_latencies
            )
        )

        p95_latency = percentile_95(
            successful_latencies
        )

    else:

        avg_latency = 0

        p95_latency = 0

    elapsed = max(
        time.perf_counter()
        - started_at,
        0.001
    )

    attempted_rps = (
        completed / elapsed
    )

    successful_rps = (
        successes / elapsed
    )

    error_rate = (
        failures
        / completed
        * 100
        if completed
        else 0
    )

    critical_requests = sum(
        1
        for record
        in completed_records
        if record["critical"]
    )

    noncritical_requests = (
        completed
        - critical_requests
    )

    return {
        "timestamp":
            datetime.now(
                timezone.utc
            ).isoformat(),

        "simulation_running":
            running,

        "slice":
            slice_number,

        "target_rps":
            target_rps,

        "attempted_rps":
            round(
                attempted_rps,
                2
            ),

        "successful_rps":
            round(
                successful_rps,
                2
            ),

        "current_rps":
            round(
                successful_rps,
                2
            ),

        "duration_sec":
            duration_sec,

        "elapsed_sec":
            round(
                elapsed,
                2
            ),

        "concurrency":
            concurrency,

        "completed_requests":
            completed,

        "successful_requests":
            successes,

        "failed_requests":
            failures,

        "critical_requests":
            critical_requests,

        "noncritical_requests":
            noncritical_requests,

        "avg_latency_ms":
            round(
                avg_latency,
                2
            ),

        "p95_latency_ms":
            round(
                p95_latency,
                2
            ),

        "error_rate_percent":
            round(
                error_rate,
                2
            )
    }


# ============================================================
# RUN ONE TRAFFIC SLICE
# ============================================================

async def run_slice(
    client,
    slice_number,
    target_rps,
    duration_sec,
    concurrency
):
    """
    Generate target_rps requests per second
    for duration_sec.
    """

    print()

    print(
        "--------------------------------"
    )

    print(
        f"Target RPS   : "
        f"{target_rps}"
    )

    print(
        f"Duration     : "
        f"{duration_sec}s"
    )

    print(
        f"Concurrency  : "
        f"{concurrency}"
    )

    print(
        "--------------------------------"
    )

    semaphore = asyncio.Semaphore(
        concurrency
    )

    tasks = []

    completed_records = []

    start_time = (
        time.perf_counter()
    )

    end_time = (
        start_time
        + duration_sec
    )

    request_interval = (
        1.0 / target_rps
    )

    next_request_time = (
        start_time
    )

    request_number = 0

    next_metrics_update = (
        start_time + 1
    )


    # ========================================================
    # TRAFFIC GENERATION LOOP
    # ========================================================

    while (
        time.perf_counter()
        < end_time
    ):

        now = (
            time.perf_counter()
        )

        # Schedule request
        if (
            now
            >= next_request_time
        ):

            task = asyncio.create_task(
                request_worker(
                    client=
                        client,

                    semaphore=
                        semaphore,

                    request_number=
                        request_number,

                    slice_number=
                        slice_number,

                    completed_records=
                        completed_records
                )
            )

            tasks.append(
                task
            )

            request_number += 1

            next_request_time += (
                request_interval
            )


        # ====================================================
        # UPDATE LIVE METRICS ONCE PER SECOND
        # ====================================================

        if (
            now
            >= next_metrics_update
        ):

            metrics = (
                calculate_live_metrics(
                    slice_number=
                        slice_number,

                    target_rps=
                        target_rps,

                    duration_sec=
                        duration_sec,

                    concurrency=
                        concurrency,

                    completed_records=
                        completed_records,

                    started_at=
                        start_time,

                    running=
                        True
                )
            )

            write_live_metrics(
                metrics
            )

            print(
                f"["
                f"{int(metrics['elapsed_sec']):3}s"
                f"] "
                f"Target="
                f"{target_rps:4} | "
                f"SuccessRPS="
                f"{metrics['successful_rps']:6.1f} | "
                f"Completed="
                f"{metrics['completed_requests']:5} | "
                f"Failed="
                f"{metrics['failed_requests']:4} | "
                f"Avg="
                f"{metrics['avg_latency_ms']:7.2f} ms"
            )

            next_metrics_update += 1


        # Prevent busy CPU loop
        await asyncio.sleep(
            0.001
        )


    # ========================================================
    # WAIT FOR ALL SCHEDULED REQUESTS
    # ========================================================

    if tasks:

        await asyncio.gather(
            *tasks
        )


    # ========================================================
    # FINAL SLICE METRICS
    # ========================================================

    metrics = (
        calculate_live_metrics(
            slice_number=
                slice_number,

            target_rps=
                target_rps,

            duration_sec=
                duration_sec,

            concurrency=
                concurrency,

            completed_records=
                completed_records,

            started_at=
                start_time,

            running=
                False
        )
    )

    write_live_metrics(
        metrics
    )

    print(
        f"Scheduled "
        f"{len(tasks)} requests"
    )

    print(
        f"Successful: "
        f"{metrics['successful_requests']}"
    )

    print(
        f"Failed: "
        f"{metrics['failed_requests']}"
    )

    return completed_records


# ============================================================
# CREATE SLICE SUMMARY
# ============================================================

def create_summary(
    slice_number,
    target_rps,
    duration_sec,
    concurrency,
    records
):

    total = len(
        records
    )

    successes = sum(
        1
        for record
        in records
        if record["success"]
    )

    failures = (
        total
        - successes
    )

    successful_latencies = [
        record["latency_ms"]
        for record
        in records
        if record["success"]
    ]

    if successful_latencies:

        avg_latency = (
            sum(
                successful_latencies
            )
            / len(
                successful_latencies
            )
        )

        p95_latency = percentile_95(
            successful_latencies
        )

    else:

        avg_latency = 0

        p95_latency = 0


    attempted_rps = (
        total / duration_sec
        if duration_sec
        else 0
    )

    successful_rps = (
        successes / duration_sec
        if duration_sec
        else 0
    )

    error_rate = (
        failures
        / total
        * 100
        if total
        else 0
    )


    # ========================================================
    # REQUEST TYPE COUNTS
    # ========================================================

    create_order_count = sum(
        1
        for record
        in records
        if record[
            "request_type"
        ]
        == "CreateOrder"
    )

    get_catalog_count = sum(
        1
        for record
        in records
        if record[
            "request_type"
        ]
        == "GetCatalog"
    )

    update_item_count = sum(
        1
        for record
        in records
        if record[
            "request_type"
        ]
        == "UpdateItem"
    )


    # ========================================================
    # CRITICAL / NON-CRITICAL COUNTS
    # ========================================================

    critical_requests = sum(
        1
        for record
        in records
        if record["critical"]
    )

    noncritical_requests = (
        total
        - critical_requests
    )


    # ========================================================
    # SPOT RULE EVIDENCE
    # critical_on_spot must stay 0: a Critical request is
    # never processed (2xx) by a Spot host.
    # ========================================================

    critical_on_spot = sum(
        1
        for record
        in records
        if record["critical"]
        and record["success"]
        and record.get("served_lifecycle") == "spot"
    )

    spot_rejections = sum(
        1
        for record
        in records
        if record["status_code"] == 503
        and record.get("served_lifecycle") == "spot"
    )


    return {

        "slice":
            slice_number,

        "target_rps":
            target_rps,

        # Kept for dashboard compatibility
        "actual_rps":
            round(
                successful_rps,
                2
            ),

        "attempted_rps":
            round(
                attempted_rps,
                2
            ),

        "successful_rps":
            round(
                successful_rps,
                2
            ),

        "duration_sec":
            duration_sec,

        "concurrency":
            concurrency,

        "total_requests":
            total,

        "successful_requests":
            successes,

        "failed_requests":
            failures,

        "create_order_requests":
            create_order_count,

        "get_catalog_requests":
            get_catalog_count,

        "update_item_requests":
            update_item_count,

        "critical_requests":
            critical_requests,

        "noncritical_requests":
            noncritical_requests,

        "avg_latency_ms":
            round(
                avg_latency,
                2
            ),

        "p95_latency_ms":
            round(
                p95_latency,
                2
            ),

        "error_rate_percent":
            round(
                error_rate,
                2
            ),

        "critical_on_spot":
            critical_on_spot,

        "spot_rejections":
            spot_rejections
    }


# ============================================================
# OPTIONAL S3 UPLOAD
# ============================================================

def upload_reports_to_s3():

    if not AWS_ENABLED:

        print(
            "AWS upload disabled."
        )

        return


    if not S3_BUCKET:

        print(
            "AWS_ENABLED=true but "
            "S3_BUCKET is empty."
        )

        return


    try:

        s3 = boto3.client(
            "s3",
            region_name=
                AWS_REGION
        )

        files = [
            TRAFFIC_REPORT_PATH,
            REQUEST_REPORT_PATH,
            LIVE_METRICS_PATH
        ]

        for file_path in files:

            if not file_path.exists():

                continue

            object_name = (
                f"{S3_PREFIX}"
                f"{file_path.name}"
            )

            s3.upload_file(
                str(file_path),
                S3_BUCKET,
                object_name
            )

            print(
                f"Uploaded: "
                f"s3://"
                f"{S3_BUCKET}/"
                f"{object_name}"
            )

    except Exception as exc:

        print(
            "S3 upload failed:"
        )

        print(exc)


# ============================================================
# MAIN SIMULATION
# ============================================================

async def main():

    print()

    print(
        "========================================"
    )

    print(
        " Dynamic CloudScale Traffic Simulator"
    )

    print(
        "========================================"
    )

    print(
        f"Target API : "
        f"{TARGET_API_URL}"
    )

    print(
        f"Profile    : "
        f"{TRAFFIC_PROFILE}"
    )

    print(
        f"Workloads  : "
        f"{len(WORKLOADS)}"
    )

    print()


    # ========================================================
    # LOAD TRAFFIC PROFILE
    # ========================================================

    profile_path = Path(
        TRAFFIC_PROFILE
    )

    if not profile_path.exists():

        raise FileNotFoundError(
            f"Traffic profile not found: "
            f"{profile_path}"
        )


    profile = pd.read_csv(
        profile_path
    )

    required_columns = {
        "time_offset_min",
        "rps_target",
        "duration_sec",
        "concurrency"
    }

    missing = (
        required_columns
        - set(
            profile.columns
        )
    )

    if missing:

        raise ValueError(
            f"Traffic profile missing "
            f"columns: {missing}"
        )


    # ========================================================
    # STORAGE
    # ========================================================

    all_requests = []

    summaries = []

    simulation_start = (
        time.time()
    )


    # ========================================================
    # HTTP CLIENT
    # ========================================================

    limits = httpx.Limits(
        max_connections=
            500,

        max_keepalive_connections=
            100
    )

    timeout = httpx.Timeout(
        connect=10.0,
        read=30.0,
        write=10.0,
        pool=30.0
    )


    async with httpx.AsyncClient(
        limits=limits,
        timeout=timeout
    ) as client:


        # ====================================================
        # PROCESS EACH TRAFFIC SLICE
        # ====================================================

        for index, row in profile.iterrows():

            slice_number = (
                index + 1
            )

            time_offset_min = int(
                row[
                    "time_offset_min"
                ]
            )

            target_rps = int(
                row[
                    "rps_target"
                ]
            )

            duration_sec = int(
                row[
                    "duration_sec"
                ]
            )

            concurrency = int(
                row[
                    "concurrency"
                ]
            )


            # =================================================
            # WAIT UNTIL SLICE START TIME
            # =================================================

            target_start = (
                simulation_start
                + (
                    time_offset_min
                    * 60
                )
            )

            wait_time = (
                target_start
                - time.time()
            )

            if wait_time > 0:

                print()

                print(
                    f"Waiting "
                    f"{round(wait_time, 1)}s "
                    f"for next slice..."
                )

                write_live_metrics(
                    {
                        "timestamp":
                            datetime.now(
                                timezone.utc
                            ).isoformat(),

                        "simulation_running":
                            True,

                        "status":
                            "waiting",

                        "next_slice":
                            slice_number,

                        "wait_seconds":
                            round(
                                wait_time,
                                1
                            ),

                        "current_rps":
                            0,

                        "target_rps":
                            0,

                        "successful_requests":
                            0,

                        "failed_requests":
                            0,

                        "avg_latency_ms":
                            0,

                        "p95_latency_ms":
                            0,

                        "error_rate_percent":
                            0
                    }
                )

                await asyncio.sleep(
                    wait_time
                )


            # =================================================
            # RUN TRAFFIC SLICE
            # =================================================

            records = await run_slice(
                client=
                    client,

                slice_number=
                    slice_number,

                target_rps=
                    target_rps,

                duration_sec=
                    duration_sec,

                concurrency=
                    concurrency
            )


            all_requests.extend(
                records
            )


            summary = create_summary(
                slice_number=
                    slice_number,

                target_rps=
                    target_rps,

                duration_sec=
                    duration_sec,

                concurrency=
                    concurrency,

                records=
                    records
            )


            summaries.append(
                summary
            )


            # =================================================
            # SAVE AFTER EVERY SLICE
            # =================================================

            save_reports(
                all_requests=
                    all_requests,

                summaries=
                    summaries
            )

            print(
                "Traffic reports updated."
            )


    # ========================================================
    # FINAL SAVE
    # ========================================================

    save_reports(
        all_requests=
            all_requests,

        summaries=
            summaries
    )


    # ========================================================
    # FINAL SUMMARY
    # ========================================================

    summary_df = pd.DataFrame(
        summaries
    )

    print()

    print(
        "========================================"
    )

    print(
        " SIMULATION COMPLETE"
    )

    print(
        "========================================"
    )

    print()


    if not summary_df.empty:

        print(
            summary_df.to_string(
                index=False
            )
        )


    print()

    print(
        f"Detailed report : "
        f"{REQUEST_REPORT_PATH}"
    )

    print(
        f"Summary report  : "
        f"{TRAFFIC_REPORT_PATH}"
    )

    print(
        f"Live metrics    : "
        f"{LIVE_METRICS_PATH}"
    )


    # ========================================================
    # OPTIONAL AWS UPLOAD
    # ========================================================

    upload_reports_to_s3()

    return check_gate(
        summaries
    )


# ============================================================
# PASS / FAIL GATE (CI)
# ============================================================

def check_gate(summaries):
    """
    Returns the process exit code.

    1 when MAX_ERROR_RATE / MAX_AVG_LATENCY_MS are set and
    the whole run exceeds them, or when any Critical request
    was processed by a Spot host. Otherwise 0.
    """

    records_total = sum(
        summary["total_requests"]
        for summary in summaries
    )

    if not records_total:

        print(
            "GATE: no requests were sent."
        )

        return 1

    failed = sum(
        summary["failed_requests"]
        for summary in summaries
    )

    # Request-weighted average over all slices.
    avg_latency = sum(
        summary["avg_latency_ms"]
        * summary["successful_requests"]
        for summary in summaries
    ) / max(
        sum(
            summary["successful_requests"]
            for summary in summaries
        ),
        1
    )

    error_rate = (
        failed
        / records_total
        * 100
    )

    critical_on_spot = sum(
        summary["critical_on_spot"]
        for summary in summaries
    )

    print()

    print(
        f"GATE: error rate {error_rate:.2f} % | "
        f"avg latency {avg_latency:.1f} ms | "
        f"critical on Spot {critical_on_spot}"
    )

    problems = []

    if (
        MAX_ERROR_RATE
        and error_rate > float(MAX_ERROR_RATE)
    ):
        problems.append(
            f"error rate {error_rate:.2f} % > {MAX_ERROR_RATE} %"
        )

    if (
        MAX_AVG_LATENCY_MS
        and avg_latency > float(MAX_AVG_LATENCY_MS)
    ):
        problems.append(
            f"avg latency {avg_latency:.1f} ms > {MAX_AVG_LATENCY_MS} ms"
        )

    if critical_on_spot:
        problems.append(
            f"{critical_on_spot} critical requests were processed on Spot"
        )

    for problem in problems:

        print(
            f"GATE FAILED: {problem}"
        )

    return 1 if problems else 0


# ============================================================
# ENTRY POINT
# ============================================================

if __name__ == "__main__":

    try:

        sys.exit(
            asyncio.run(
                main()
            )
        )

    except KeyboardInterrupt:

        print()

        print(
            "Traffic simulation "
            "stopped by user."
        )

        sys.exit(130)

    except Exception as exc:

        print()

        print(
            "Traffic simulation failed:"
        )

        print(exc)

        sys.exit(1)
