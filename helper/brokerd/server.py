"""Local HTTP API on 127.0.0.1 for the SwiftUI app and widget."""
from __future__ import annotations

import asyncio
import hmac
from contextlib import asynccontextmanager

from fastapi import Body, FastAPI, Header, HTTPException

from . import keychain
from .config import api_token
from .engine import Engine

engine = Engine()
TOKEN = api_token()

ALLOWED_SETTINGS = {"demoMode", "displayCurrency", "menuBarStyle", "colorStyle", "toss", "ibkr"}


@asynccontextmanager
async def lifespan(_: FastAPI):
    await engine.start()
    yield
    await engine.stop()


app = FastAPI(title="brokerd", lifespan=lifespan, docs_url=None, redoc_url=None)


def _auth(token: str | None):
    if not token or not hmac.compare_digest(token, TOKEN):
        raise HTTPException(401, "bad token")


@app.get("/v1/portfolio")
def portfolio():
    return engine.portfolio()


@app.get("/v1/history")
def history(range: str = "1M"):  # noqa: A002
    return engine.history(range.upper())


@app.get("/v1/status")
def status():
    return engine.status()


@app.put("/v1/settings")
async def put_settings(patch: dict = Body(...), x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    bad = set(patch) - ALLOWED_SETTINGS
    if bad:
        raise HTTPException(400, f"unknown settings: {sorted(bad)}")
    reconnect = bool({"toss", "ibkr"} & set(patch))
    engine.settings.update(patch)
    if reconnect:
        await engine.reload()
    return engine.status()


@app.put("/v1/secrets")
async def put_secrets(values: dict = Body(...), x_brokers_token: str | None = Header(None)):
    """Write-only: values are stored in the Keychain and never returned."""
    _auth(x_brokers_token)
    for k, v in values.items():
        if k not in keychain.KEYS:
            raise HTTPException(400, f"unknown secret {k}")
        keychain.set(k, v)
    await engine.reload()
    return engine.status()


@app.post("/v1/refresh")
async def refresh(x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    engine._holdings_kick.set()
    if engine.flex:
        engine.flex.fetched_at = None
        engine._flex_kick.set()
    return {"ok": True}


@app.post("/v1/backfill")
async def run_backfill(x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    asyncio.create_task(engine.run_backfill())
    return engine.backfill_state
