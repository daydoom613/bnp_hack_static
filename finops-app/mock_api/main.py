import asyncio
import random

from fastapi import FastAPI
from pydantic import BaseModel


app = FastAPI(title="FinOps Demo API")


class WorkloadRequest(BaseModel):
    request_type: str = "GetCatalog"
    critical: bool = False


@app.get("/health")
async def health():
    return {
        "status": "healthy"
    }


@app.post("/process")
async def process(payload: WorkloadRequest):

    if payload.critical:
        delay = random.uniform(0.05, 0.15)
    else:
        delay = random.uniform(0.02, 0.08)

    await asyncio.sleep(delay)

    return {
        "status": "processed",
        "request_type": payload.request_type,
        "critical": payload.critical,
        "processing_time": round(delay, 4)
    }