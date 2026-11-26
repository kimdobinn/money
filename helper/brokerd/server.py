"""Local HTTP API on 127.0.0.1 for the SwiftUI app and widget."""
from __future__ import annotations

import asyncio
import hmac
from contextlib import asynccontextmanager

import json

from fastapi import Body, FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse

from . import keychain
from .config import api_token
from .connectors import ibkr_web
from .engine import Engine

engine = Engine()
from .chat import Chat  # noqa: E402

chat = Chat(engine)
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


@app.post("/v1/refresh/{broker}")
async def retry_broker(broker: str, quick: bool = False, x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    return await engine.retry(broker, quick)


@app.get("/v1/trades")
def trades(symbol: str | None = None, broker: str | None = None, since: str | None = None, limit: int = 200):
    return {"trades": engine.store.trades(symbol, broker, since, min(limit, 2000))}


# ---- chat ---------------------------------------------------------------------
@app.get("/v1/chat/status")
def chat_status():
    return chat.available()


@app.post("/v1/chat")
async def chat_send(body: dict = Body(...), x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    text = (body.get("message") or "").strip()
    if not text:
        raise HTTPException(400, "empty message")

    async def gen():
        async for ev in chat.send(body.get("conversationId"), text, body.get("goal"), body.get("model")):
            yield json.dumps(ev, ensure_ascii=False) + "\n"

    return StreamingResponse(gen(), media_type="application/x-ndjson")


@app.get("/v1/chat/conversations")
def chat_conversations():
    return {"conversations": engine.store.conversations()}


@app.get("/v1/chat/conversations/{cid}")
def chat_messages(cid: str):
    conv = engine.store.conversation(cid)
    if not conv:
        raise HTTPException(404, "not found")
    return {"id": cid, "title": conv["title"], "messages": engine.store.messages(cid)}


@app.delete("/v1/chat/conversations/{cid}")
def chat_delete(cid: str, x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    engine.store.conversation_delete(cid)
    return {"ok": True}


@app.get("/v1/chat/memory")
def memory_list():
    return {"memories": engine.store.memories()}


@app.post("/v1/chat/memory")
def memory_add(body: dict = Body(...), x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    text = (body.get("text") or "").strip()
    if not text:
        raise HTTPException(400, "empty")
    return {"ok": True, "id": engine.store.memory_add(text)}


@app.put("/v1/chat/memory/{mid}")
def memory_update(mid: int, body: dict = Body(...), x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    return {"ok": bool(engine.store.memory_update(mid, (body.get("text") or "").strip()))}


@app.delete("/v1/chat/memory/{mid}")
def memory_delete(mid: int, x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    return {"ok": bool(engine.store.memory_delete(mid))}


@app.post("/v1/ibkr/web/login")
async def ibkr_web_login(x_brokers_token: str | None = Header(None)):
    """Start the local Client Portal Gateway (if needed) and return the page to log in on."""
    _auth(x_brokers_token)
    w = engine.webapi
    if not w:
        raise HTTPException(404, "IBKR Client Portal Gateway가 설치되어 있지 않아요")
    ok = await w.ensure_started()
    w.wake()
    return {"ok": ok, "url": ibkr_web.LOGIN_URL, "message": w.message if not ok else None}


@app.post("/v1/cloud/sync")
def cloud_sync(x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    engine.cloud.kick()
    return engine.cloud.state


@app.post("/v1/backfill")
async def run_backfill(x_brokers_token: str | None = Header(None)):
    _auth(x_brokers_token)
    asyncio.create_task(engine.run_backfill())
    return engine.backfill_state
