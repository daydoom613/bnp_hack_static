"""FinOps CloudScale REST API.

    GET    /health            200 without touching the DB (ALB health check); 503 while draining
    GET    /metrics           Prometheus text format
    GET    /items             list catalog items          GetCatalog  (non-critical)
    GET    /items/{id}        one item                    GetCatalog  (non-critical)
    POST   /items             create an item              CreateItem  (not in the sheet -> critical)
    PUT    /items/{id}        update an item              UpdateItem  (critical)
    DELETE /items/{id}        delete an item              DeleteItem  (not in the sheet -> critical)
    GET    /catalog           same as GET /items          GetCatalog
    POST   /orders            place an order              CreateOrder (critical)
    POST   /process           traffic-simulator entry point: {"request_type": ..., "critical": ...}

Criticality comes from data/service_priority.xlsx. The Spot guard answers 503 to any
critical request that reaches a Spot host. Non-critical /process work is queued to SQS
for the Worker ASG instead of being done on the web tier.
"""
import logging
import random
import threading
import time
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import config, instance, jobs, metrics, priority
from .store import STORE, NotReady, random_item_id

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("cloudscale")


class State:
    draining = False
    consumer = None


def start_draining(reason):
    """Stop taking work: /health turns 503 (the ALB stops routing here) and the consumer stops polling."""
    if State.draining:
        return
    State.draining = True
    metrics.DRAINING.set(1)
    log.warning("DRAIN instance=%s life_cycle=%s role=%s reason=%s",
                instance.INSTANCE_ID, instance.LIFE_CYCLE, config.ROLE, reason)
    if State.consumer:
        threading.Thread(target=State.consumer.stop, name="consumer-stop", daemon=True).start()


def _watch_spot_notice():
    while not State.draining:
        if instance.spot_interruption_pending():
            start_draining("spot interruption notice")
            return
        time.sleep(5)


@asynccontextmanager
async def lifespan(_app):
    STORE.start()
    if config.ROLE == "worker" and config.QUEUE_URL:
        State.consumer = jobs.Consumer()
        State.consumer.start()
    if instance.IS_SPOT:
        threading.Thread(target=_watch_spot_notice, name="spot-notice", daemon=True).start()
    log.info("started role=%s instance=%s life_cycle=%s store=%s queue=%s",
             config.ROLE, instance.INSTANCE_ID, instance.LIFE_CYCLE, STORE.kind, config.QUEUE_URL or "-")
    yield
    # uvicorn got SIGTERM (scale-in, drain Lambda's `docker stop`, deploy): finish and leave.
    start_draining("SIGTERM")
    if State.consumer:
        State.consumer.stop()


app = FastAPI(title="FinOps CloudScale API", lifespan=lifespan)


@app.middleware("http")
async def instance_headers_and_metrics(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    # The simulator records these to prove critical requests never succeed on Spot.
    response.headers["X-Instance-Id"] = instance.INSTANCE_ID
    response.headers["X-Instance-Lifecycle"] = instance.LIFE_CYCLE
    response.headers["X-Role"] = config.ROLE
    request_type = getattr(request.state, "request_type", None)
    if request_type:
        critical = str(request.state.critical).lower()
        metrics.REQUESTS.labels(request_type, critical, str(response.status_code)).inc()
        metrics.LATENCY.labels(request_type).observe(time.perf_counter() - start)
    return response


@app.exception_handler(NotReady)
async def database_not_ready(_request, _exc):
    return JSONResponse({"error": "database not ready"}, status_code=503)


def guard(request: Request, request_type, declared_critical=False):
    """Classify the request and apply the Spot fallback rule. Returns whether it is critical."""
    critical = priority.is_critical(request_type) or bool(declared_critical)
    request.state.request_type = request_type
    request.state.critical = critical
    if critical and instance.IS_SPOT:
        metrics.SPOT_REJECTIONS.inc()
        raise HTTPException(503, detail=f"{request_type} is critical and this host is Spot: rejected")
    return critical


def served(body):
    return {**body, "instance_id": instance.INSTANCE_ID, "instance_life_cycle": instance.LIFE_CYCLE,
            "role": config.ROLE}


# ---------------------------------------------------------------------------
# Health and metrics
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    body = served({"status": "draining" if State.draining else "ok", "db": STORE.kind, "db_ready": STORE.ready})
    return JSONResponse(body, status_code=503 if State.draining else 200)


@app.get("/metrics")
def prometheus_metrics():
    data, content_type = metrics.render()
    return Response(data, media_type=content_type)


@app.get("/")
def index():
    return served({"service": "finops-cloudscale-api", "docs": "/docs"})


# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------
class ItemIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    price: float = Field(default=0, ge=0)
    stock: int = Field(default=0, ge=0)


class ItemPatch(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=200)
    price: Optional[float] = Field(default=None, ge=0)
    stock: Optional[int] = Field(default=None, ge=0)


class OrderIn(BaseModel):
    item_id: Optional[int] = None
    quantity: int = Field(default=1, ge=1, le=100)


@app.get("/items")
def list_items(request: Request, limit: int = 20, offset: int = 0):
    guard(request, "GetCatalog")
    return {"items": STORE.list_items(max(1, min(limit, 100)), max(0, offset))}


@app.get("/catalog")
def catalog(request: Request, limit: int = 20, offset: int = 0):
    return list_items(request, limit, offset)


@app.get("/items/{item_id}")
def get_item(request: Request, item_id: int):
    guard(request, "GetCatalog")
    item = STORE.get_item(item_id)
    if item is None:
        raise HTTPException(404, detail="item not found")
    return item


@app.post("/items", status_code=201)
def create_item(request: Request, item: ItemIn):
    guard(request, "CreateItem")
    return STORE.create_item(item.name, item.price, item.stock)


@app.put("/items/{item_id}")
def update_item(request: Request, item_id: int, patch: ItemPatch):
    guard(request, "UpdateItem")
    item = STORE.update_item(item_id, patch.name, patch.price, patch.stock)
    if item is None:
        raise HTTPException(404, detail="item not found")
    return item


@app.delete("/items/{item_id}", status_code=204)
def delete_item(request: Request, item_id: int):
    guard(request, "DeleteItem")
    if not STORE.delete_item(item_id):
        raise HTTPException(404, detail="item not found")
    return Response(status_code=204)


@app.post("/orders", status_code=201)
def create_order(request: Request, order: OrderIn):
    guard(request, "CreateOrder")
    jobs.burn(config.CRITICAL_WORK_MS)
    return STORE.create_order(order.item_id or random_item_id(), order.quantity, "CreateOrder")


# ---------------------------------------------------------------------------
# Traffic-simulator entry point
# ---------------------------------------------------------------------------
class WorkloadIn(BaseModel):
    request_type: Optional[str] = None
    priority: Optional[int] = None
    critical: bool = False


@app.post("/process")
def process(request: Request, workload: WorkloadIn):
    request_type = workload.request_type or request.headers.get("X-Request-Type") or "GetCatalog"
    critical = guard(request, request_type, workload.critical)

    if request_type == "CreateOrder":
        jobs.burn(config.CRITICAL_WORK_MS)
        order = STORE.create_order(random_item_id(), 1, request_type)
        return served({"status": "processed", "request_type": request_type, "critical": critical,
                       "order_id": order["id"]})

    if request_type == "UpdateItem":
        jobs.burn(config.CRITICAL_WORK_MS)
        item = STORE.update_item(random_item_id(), stock=random.randint(0, 500))
        return served({"status": "processed", "request_type": request_type, "critical": critical,
                       "item_id": item["id"] if item else None})

    if not critical:
        # Non-critical: answer from the catalog now, hand the heavy part to the Spot-heavy workers.
        jobs.burn(config.NONCRITICAL_WORK_MS)
        items = STORE.list_items(10, random.randint(0, 90))
        job_id = jobs.enqueue({"request_type": request_type, "enqueued_at": time.time()})
        return JSONResponse(served({"status": "accepted", "request_type": request_type, "critical": critical,
                                    "items": len(items), "job_id": job_id}), status_code=202)

    jobs.burn(config.CRITICAL_WORK_MS)
    return served({"status": "processed", "request_type": request_type, "critical": critical})
