"""Prometheus metrics (names are part of the contract in README.md).

uvicorn runs several worker processes, so when PROMETHEUS_MULTIPROC_DIR is set
(the Dockerfile sets it) /metrics aggregates every process's counters.
"""
import os

from prometheus_client import (CONTENT_TYPE_LATEST, CollectorRegistry, Counter, Gauge, Histogram,
                               generate_latest, multiprocess)

REQUESTS = Counter(
    "http_requests_total", "API requests", ["type", "critical", "status"])
LATENCY = Histogram(
    "http_request_duration_seconds", "API request latency", ["type"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2.5, 5))
SPOT_REJECTIONS = Counter(
    "spot_rejections_total", "Critical requests refused because this host is Spot")
JOBS_ENQUEUED = Counter(
    "jobs_enqueued_total", "Background jobs sent to the queue")
JOBS_PROCESSED = Counter(
    "jobs_processed_total", "Background jobs completed by this worker")
DRAINING = Gauge(
    "instance_draining", "1 once the host is draining (Spot notice or SIGTERM)", multiprocess_mode="max")


def render():
    if "PROMETHEUS_MULTIPROC_DIR" in os.environ:
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
        return generate_latest(registry), CONTENT_TYPE_LATEST
    return generate_latest(), CONTENT_TYPE_LATEST
