"""
Stage 1: FastAPI + Redis
A small API that stores key/value items and counts hits in Redis.
All connection settings come from environment variables, so the same
code runs unchanged on your laptop, in Docker, and in Kubernetes.
"""
import os

import redis
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# ---- Configuration (12-factor style: config lives in the environment) ----
REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_PASSWORD = os.getenv("REDIS_PASSWORD") or None

# The client connects lazily: the app can start even if Redis is down.
r = redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    password=REDIS_PASSWORD,
    decode_responses=True,       # return str instead of bytes
    socket_connect_timeout=2,    # fail fast instead of hanging
    socket_timeout=2,
)

app = FastAPI(title="Redis Lab API")


class Item(BaseModel):
    value: str


def redis_call(fn, *args):
    """Run a Redis command and turn connection problems into HTTP 503."""
    try:
        return fn(*args)
    except redis.RedisError as exc:
        raise HTTPException(status_code=503, detail=f"Redis unavailable: {exc}")


@app.get("/")
def root():
    return {"service": "redis-lab-api", "redis_host": REDIS_HOST}


@app.get("/api/hits")
def hits():
    count = redis_call(r.incr, "hits")
    return {"hits": count}


@app.put("/api/items/{key}")
def set_item(key: str, item: Item):
    redis_call(r.set, f"item:{key}", item.value)
    return {"key": key, "value": item.value}


@app.get("/api/items/{key}")
def get_item(key: str):
    value = redis_call(r.get, f"item:{key}")
    if value is None:
        raise HTTPException(status_code=404, detail="Key not found")
    return {"key": key, "value": value}