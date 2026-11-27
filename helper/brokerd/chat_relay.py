"""Assistant chat for viewer Macs (no helper of their own), relayed through Firestore.

The viewer can't reach this helper directly (different network, 127.0.0.1 only), so both sides poll
documents under users/{uid}/ (same security rules as cloud.py):

  chat/index            conversations + memories list (JSON), uploaded when it changes
  chatConv/{cid}        one conversation's messages (JSON), uploaded when it changes
  chatReq/presence      viewer heartbeat {until: epoch}; while fresh we poll fast (1.5 s), else every 15 s
  chatReq/{reqId}       viewer → helper: {op: send|cancel|delete|memory_delete, ...}; deleted once taken
  chatResp/{reqId}      helper → viewer: the reply as it streams {status, text, tools, conversationId, title,
                        error}; flushed ~every 0.7 s; the viewer deletes it when done

Answers run through the same Chat (Claude Code CLI) as the local app, so conversations are shared.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import time
from datetime import datetime, timezone

import httpx

from .cloud import _dumps, load_session

log = logging.getLogger("brokerd.chat_relay")

IDLE_POLL = 15.0
ACTIVE_POLL = 1.5
FLUSH_EVERY = 0.7
SYNC_EVERY = 10.0
STALE_REQUEST = 600  # ignore requests older than this (helper was off)


def _val(f: dict | None):
    if not f:
        return None
    for k in ("stringValue", "doubleValue", "integerValue", "booleanValue", "timestampValue"):
        if k in f:
            return float(f[k]) if k == "integerValue" else f[k]
    return None


class ChatRelay:
    def __init__(self, engine, chat):
        self.engine = engine
        self.chat = chat
        self.store = engine.store
        self._hash: dict[str, str] = {}
        self._tasks: dict[str, asyncio.Task] = {}
        self._active_until = 0.0
        self._last_error: str | None = None
        self._session_uid: str | None = None

    # ---- Firestore REST ----------------------------------------------------
    def _url(self, s: dict, path: str) -> str:
        return (f"https://firestore.googleapis.com/v1/projects/{s['projectId']}/databases/(default)/documents/"
                f"users/{s['uid']}/{path}")

    async def _auth(self, http, s) -> dict:
        return {"Authorization": f"Bearer {await self.engine.cloud._id_token(http, s)}"}

    async def _put(self, http, s, path: str, fields: dict) -> None:
        await self.engine.cloud._put(http, s, await self.engine.cloud._id_token(http, s), path,
                                     {**fields, "updated": datetime.now(timezone.utc)})

    async def _delete(self, http, s, path: str) -> None:
        r = await http.delete(self._url(s, path), headers=await self._auth(http, s))
        if r.status_code not in (200, 404):
            r.raise_for_status()

    async def _list(self, http, s, collection: str) -> list[tuple[str, dict]]:
        r = await http.get(self._url(s, collection), params={"pageSize": 50}, headers=await self._auth(http, s))
        if r.status_code == 404:
            return []
        r.raise_for_status()
        return [(d["name"].rsplit("/", 1)[-1], {k: _val(v) for k, v in (d.get("fields") or {}).items()})
                for d in r.json().get("documents") or []]

    # ---- loop --------------------------------------------------------------
    async def run(self) -> None:
        last_sync = 0.0
        async with httpx.AsyncClient(timeout=30) as http:
            while True:
                s = load_session()
                if s:
                    if s["uid"] != self._session_uid:
                        self._session_uid, self._hash = s["uid"], {}
                    try:
                        await self._poll(http, s)
                        if time.time() - last_sync >= SYNC_EVERY:
                            await self._sync(http, s)
                            last_sync = time.time()
                        self._last_error = None
                    except Exception as e:  # noqa: BLE001
                        msg = f"{type(e).__name__}: {e}"
                        if msg != self._last_error:
                            log.warning("chat relay: %s", msg)
                        self._last_error = msg
                fast = self._tasks or time.time() < self._active_until
                await asyncio.sleep(ACTIVE_POLL if fast else IDLE_POLL)

    async def _poll(self, http, s) -> None:
        now = time.time()
        for rid, f in await self._list(http, s, "chatReq"):
            if rid == "presence":
                self._active_until = max(self._active_until, float(f.get("until") or 0))
                continue
            await self._delete(http, s, f"chatReq/{rid}")  # take it, so it runs once
            self._active_until = max(self._active_until, now + 300)
            if now - float(f.get("created") or now) > STALE_REQUEST:
                continue
            op = f.get("op")
            if op == "send" and rid not in self._tasks:
                self._tasks[rid] = asyncio.create_task(self._answer(http, s, rid, f))
            elif op == "cancel":
                if (t := self._tasks.get(f.get("target") or "")):
                    t.cancel()
            elif op == "delete" and f.get("conversationId"):
                self.store.conversation_delete(f["conversationId"])
                await self._sync(http, s)
            elif op == "memory_delete" and f.get("memoryId") is not None:
                self.store.memory_delete(int(f["memoryId"]))
                await self._sync(http, s)

    async def _answer(self, http, s, rid: str, f: dict) -> None:
        st = {"status": "streaming", "text": "", "tools": [], "conversationId": "", "title": "", "error": ""}
        last = 0.0

        async def flush(force=False):
            nonlocal last
            if not force and time.time() - last < FLUSH_EVERY:
                return
            last = time.time()
            try:
                await self._put(http, s, f"chatResp/{rid}", {**st, "tools": _dumps(st["tools"])})
            except Exception as e:  # noqa: BLE001 — a dropped flush is fine, the next one catches up
                log.info("chat relay flush failed: %r", e)

        try:
            goal = json.loads(f["goal"]) if f.get("goal") else None
        except ValueError:
            goal = None
        await flush(True)  # tells the viewer the helper picked it up
        try:
            async for ev in self.chat.send(f.get("conversationId") or None, (f.get("message") or "").strip(),
                                           goal, f.get("model")):
                t = ev.get("type")
                if t == "start":
                    st["conversationId"], st["title"] = ev.get("conversationId") or "", ev.get("title") or ""
                    await flush(True)
                elif t == "text":
                    st["text"] += ev.get("delta") or ""
                    await flush()
                elif t == "tool":
                    st["tools"].append(ev.get("label") or ev.get("name") or "")
                    await flush(True)
                elif t == "error":
                    st["status"], st["error"] = "error", ev.get("message") or "오류"
            if st["status"] != "error":
                st["status"] = "done"
        except asyncio.CancelledError:
            st["status"] = "done"  # stopped by the viewer; the partial reply is kept
        except Exception as e:  # noqa: BLE001
            st["status"], st["error"] = "error", str(e)[:300]
        finally:
            self._tasks.pop(rid, None)
            await flush(True)
            try:
                await self._sync(http, s)
            except Exception:  # noqa: BLE001
                pass

    # ---- conversation mirror ----------------------------------------------
    def _dirty(self, key: str, payload: str) -> str | None:
        h = hashlib.sha1(payload.encode()).hexdigest()
        return None if self._hash.get(key) == h else h

    async def _sync(self, http, s) -> None:
        convs = self.store.conversations()
        index = _dumps({"conversations": convs, "memories": self.store.memories(),
                        "claude": self.chat.available()["claude"]})
        if (h := self._dirty("index", index)):
            await self._put(http, s, "chat/index", {"data": index})
            self._hash["index"] = h
        ids = {c["id"] for c in convs}
        for c in convs:
            msgs = _dumps(self.store.messages(c["id"]))
            if (h := self._dirty(f"conv:{c['id']}", msgs)):
                await self._put(http, s, f"chatConv/{c['id']}", {"messages": msgs})
                self._hash[f"conv:{c['id']}"] = h
        for key in [k for k in self._hash if k.startswith("conv:") and k[5:] not in ids]:
            await self._delete(http, s, f"chatConv/{key[5:]}")
            del self._hash[key]
