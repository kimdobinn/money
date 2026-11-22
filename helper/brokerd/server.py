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


# ---- 관심 종목 --------------------------------------------------------------
def _toss():
    if not engine.toss:
        raise HTTPException(409, "토스 계정을 연결해야 관심 종목 시세를 볼 수 있어요")
    return engine.toss.client


@app.get("/v1/watchlist")
def watchlist():
    return engine.watchlist_view()


@app.get("/v1/search")
def search(q: str = ""):
    return {"ready": bool(engine.store.meta_get("universe_at")), "results": engine.watchlist.search(q)}


@app.get("/v1/chart")
async def chart(symbol: str, range: str = "1Y"):  # noqa: A002
    client = _toss()
    try:
        return await engine.watchlist.chart(client, symbol, range)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(502, f"차트를 불러오지 못했어요: {e}") from e


@app.post("/v1/watchlist")
async def watch_add(body: dict = Body(...), x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    try:
        await engine.watchlist.add(_toss(), str(body.get("symbol", "")))
    except ValueError as e:
        raise HTTPException(404, str(e)) from e
    engine._quote_kick.set()
    return engine.watchlist_view()


@app.put("/v1/watchlist-order")
def watch_order(body: dict = Body(...), x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    engine.watchlist.set_order([str(s) for s in body.get("symbols") or []])
    return engine.watchlist_view()


@app.put("/v1/watchlist/{symbol}")
def watch_update(symbol: str, body: dict = Body(...), x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    if "starred" in body:
        engine.watchlist.set_starred(symbol, bool(body["starred"]))
    return engine.watchlist_view()


@app.delete("/v1/watchlist/{symbol}")
def watch_remove(symbol: str, x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    engine.watchlist.remove(symbol)
    return engine.watchlist_view()


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
