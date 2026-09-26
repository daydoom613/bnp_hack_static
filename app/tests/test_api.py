"""API contract tests. They run without AWS or Postgres (in-memory store, no queue).

    pip install -r app/requirements-dev.txt
    pytest app/tests
"""
import os
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

APP_DIR = Path(__file__).resolve().parents[1]
REPO = APP_DIR.parent
sys.path.insert(0, str(APP_DIR))


os.environ.update({
    "INSTANCE_LIFECYCLE": "on-demand",
    "PRIORITY_FILE": str(REPO / "data" / "service_priority.xlsx"),
    "CRITICAL_WORK_MS": "0",
    "NONCRITICAL_WORK_MS": "0",
    "JOB_WORK_MS": "0",
})
for name in ("DB_HOST", "QUEUE_URL", "PROMETHEUS_MULTIPROC_DIR"):
    os.environ.pop(name, None)

from cloudscale import instance  # noqa: E402  (after the env above)
from cloudscale.main import app  # noqa: E402


def as_host(monkeypatch, life_cycle):
    monkeypatch.setattr(instance, "LIFE_CYCLE", life_cycle)
    monkeypatch.setattr(instance, "IS_SPOT", life_cycle == "spot")
    return TestClient(app)


@pytest.fixture
def on_demand(monkeypatch):
    with as_host(monkeypatch, "on-demand") as client:
        yield client


@pytest.fixture
def spot(monkeypatch):
    with as_host(monkeypatch, "spot") as client:
        yield client


def test_health_is_fast_and_reports_the_host(on_demand):
    response = on_demand.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert response.headers["X-Instance-Lifecycle"] == "on-demand"


def test_crud_round_trip(on_demand):
    created = on_demand.post("/items", json={"name": "widget", "price": 9.5, "stock": 3})
    assert created.status_code == 201
    item_id = created.json()["id"]

    assert on_demand.get(f"/items/{item_id}").json()["name"] == "widget"
    assert on_demand.put(f"/items/{item_id}", json={"stock": 7}).json()["stock"] == 7
    assert on_demand.delete(f"/items/{item_id}").status_code == 204
    assert on_demand.get(f"/items/{item_id}").status_code == 404
    assert len(on_demand.get("/items", params={"limit": 5}).json()["items"]) == 5


def test_orders_and_process_on_demand(on_demand):
    assert on_demand.post("/orders", json={"quantity": 2}).status_code == 201
    for request_type in ("CreateOrder", "UpdateItem"):
        response = on_demand.post("/process", json={"request_type": request_type, "critical": True})
        assert response.status_code == 200, response.text
        assert response.json()["critical"] is True
    catalog = on_demand.post("/process", json={"request_type": "GetCatalog", "critical": False})
    assert catalog.status_code == 202
    assert catalog.json()["status"] == "accepted"


def test_spot_host_rejects_critical_requests(spot):
    for request_type in ("CreateOrder", "UpdateItem"):
        response = spot.post("/process", json={"request_type": request_type})
        assert response.status_code == 503
        assert response.headers["X-Instance-Lifecycle"] == "spot"
    assert spot.post("/orders", json={}).status_code == 503
    assert spot.put("/items/1", json={"stock": 1}).status_code == 503


def test_spot_host_still_serves_non_critical(spot):
    assert spot.post("/process", json={"request_type": "GetCatalog"}).status_code == 202
    assert spot.get("/items").status_code == 200


def test_unknown_request_types_are_treated_as_critical(spot):
    assert spot.post("/process", json={"request_type": "SomethingNew"}).status_code == 503


def test_declared_critical_wins_over_the_sheet(spot):
    response = spot.post("/process", json={"request_type": "GetCatalog", "critical": True})
    assert response.status_code == 503


def test_metrics_exposes_contract_names(spot):
    spot.post("/process", json={"request_type": "CreateOrder"})
    text = spot.get("/metrics").text
    assert "http_requests_total" in text
    assert "http_request_duration_seconds" in text
    rejected = [line for line in text.splitlines() if line.startswith("spot_rejections_total ")]
    assert rejected and float(rejected[0].split()[1]) >= 1
