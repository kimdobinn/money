"""Uploads snapshots to the user's Firestore so other Macs signed in to the same Google account can view them.

The app does the Google sign-in and writes the Firebase session to APP_DIR/cloud.json (0600); this
module only reads it. Layout (security rules restrict users/{uid}/** to that uid):

  users/{uid}/state/live          portfolio + watchlist + status JSON: right away when holdings, cash or
                                  connection status change; price moves are batched every 30 s
  users/{uid}/state/history       all history ranges, every 10 minutes
  users/{uid}/snapshots/{date}    the day's latest portfolio, hourly (one doc per local day)

Secrets (API keys, Flex token, Keychain values) are never uploaded. Demo data is never uploaded.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import time
from datetime import datetime, timezone

import httpx

from .config import APP_DIR

log = logging.getLogger("brokerd.cloud")

SESSION_PATH = APP_DIR / "cloud.json"
LIVE_EVERY = 30  # price-only changes; Firestore free tier is 20k writes/day
HISTORY_EVERY = 600
SNAPSHOT_EVERY = 3600
HISTORY_RANGES = ("1D", "1W", "1M", "3M", "YTD", "1Y", "ALL")


def load_session() -> dict | None:
    try:
        s = json.loads(SESSION_PATH.read_text())
    except (OSError, ValueError):
        return None
    return s if all(s.get(k) for k in ("apiKey", "projectId", "uid", "refreshToken")) else None


def _ts(dt: datetime | None = None) -> str:
    return (dt or datetime.now(timezone.utc)).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _dumps(v) -> str:
    return json.dumps(v, ensure_ascii=False, default=str, separators=(",", ":"))


class CloudSync:
    def __init__(self, engine):
        self.engine = engine
        self._kick = asyncio.Event()
        self._token: tuple[str, float, str] | None = None  # (id_token, expires_at, refresh_token it came from)
        self._last: dict[str, float] = {}
        self._hash: dict[str, str] = {}
        self.state: dict = {"signedIn": False, "email": None, "lastSync": None, "error": None}

    def kick(self) -> None:
        self._last.clear()
        self._hash.clear()
        self._kick.set()

    async def run(self) -> None:
        async with httpx.AsyncClient(timeout=30) as http:
            while True:
                try:
                    await self._tick(http)
                except Exception as e:  # noqa: BLE001
                    msg = str(e) or type(e).__name__
                    if isinstance(e, httpx.HTTPStatusError):
                        msg = f"{e.response.status_code}: {e.response.text[:200]}"
                    if self.state.get("error") != msg:
                        log.warning("cloud sync failed: %s", msg)
                    self.state["error"] = msg
                try:
                    await asyncio.wait_for(self._kick.wait(), timeout=10)
                except asyncio.TimeoutError:
                    pass
                self._kick.clear()

    # ---- auth --------------------------------------------------------------
    async def _id_token(self, http: httpx.AsyncClient, s: dict) -> str:
        if self._token and self._token[2] == s["refreshToken"] and self._token[1] > time.time() + 120:
            return self._token[0]
        r = await http.post(
            "https://securetoken.googleapis.com/v1/token",
            params={"key": s["apiKey"]},
            data={"grant_type": "refresh_token", "refresh_token": s["refreshToken"]},
        )
        if r.status_code == 400:
            raise RuntimeError("Google 로그인이 만료됐어요 — 앱 설정에서 다시 로그인해주세요")
        r.raise_for_status()
        j = r.json()
        self._token = (j["id_token"], time.time() + int(j.get("expires_in", 3600)), s["refreshToken"])
        return j["id_token"]

    # ---- upload ------------------------------------------------------------
    async def _put(self, http, s: dict, token: str, path: str, fields: dict) -> None:
        url = (f"https://firestore.googleapis.com/v1/projects/{s['projectId']}/databases/(default)/documents/"
               f"users/{s['uid']}/{path}")
        body = {"fields": {}}
        for k, v in fields.items():
            if isinstance(v, datetime):
                body["fields"][k] = {"timestampValue": _ts(v)}
            elif isinstance(v, (int, float)) and not isinstance(v, bool):
                body["fields"][k] = {"doubleValue": float(v)}
            else:
                body["fields"][k] = {"stringValue": v}
        r = await http.patch(url, json=body, headers={"Authorization": f"Bearer {token}"})
        r.raise_for_status()

    def _due(self, key: str, every: float) -> bool:
        return time.time() - self._last.get(key, 0) >= every

    def _changed(self, key: str, payload: str) -> bool:
        h = hashlib.sha1(payload.encode()).hexdigest()
        if self._hash.get(key) == h:
            return False
        self._hash[key] = h
        return True

    async def _tick(self, http: httpx.AsyncClient) -> None:
        s = load_session()
        if not s:
            self.state = {"signedIn": False, "email": None, "lastSync": None, "error": None}
            self._token = None
            return
        if s.get("uid") != self.state.get("uid"):
            self._last.clear()
            self._hash.clear()
        self.state.update(signedIn=True, email=s.get("email"), uid=s.get("uid"))
        eng = self.engine
        if eng.is_demo():
            self.state["error"] = "데모 데이터는 올리지 않아요 — 증권사 계정을 연결하면 동기화돼요"
            return
        now = datetime.now(timezone.utc)
        wrote = False

        # Holdings, cash or broker status changed (a trade, a deposit, a reconnect) → upload now.
        sig = _dumps([(b.broker, b.status, sorted((l.symbol, l.quantity) for l in b.legs), b.cash)
                      for b in eng.broker_snapshots()])
        if self._changed("holdings", sig):
            self._last.pop("live", None)

        if self._due("live", LIVE_EVERY):
            portfolio = await asyncio.to_thread(eng.portfolio)
            fields = {
                "portfolio": _dumps(portfolio),
                "watchlist": _dumps(await asyncio.to_thread(eng.watchlist_view)),
                "status": _dumps({**eng.status(), "cloud": None}),
            }
            if self._changed("live", fields["portfolio"] + fields["watchlist"] + sig):
                token = await self._id_token(http, s)
                await self._put(http, s, token, "state/live", {**fields, "updated": now})
                wrote = True
            self._last["live"] = time.time()

            if self._due("snapshot", SNAPSHOT_EVERY):
                token = await self._id_token(http, s)
                day = datetime.now().astimezone().strftime("%Y-%m-%d")
                t = portfolio.get("totals") or {}
                await self._put(http, s, token, f"snapshots/{day}", {
                    "portfolio": fields["portfolio"], "updated": now,
                    "netWorthUSD": t.get("netWorthUSD") or 0, "marketValueUSD": t.get("marketValueUSD") or 0,
                })
                self._last["snapshot"] = time.time()
                wrote = True

        if self._due("history", HISTORY_EVERY):
            ranges = {r: await asyncio.to_thread(eng.history, r) for r in HISTORY_RANGES}
            payload = _dumps(ranges)
            if self._changed("history", payload):
                token = await self._id_token(http, s)
                await self._put(http, s, token, "state/history", {"ranges": payload, "updated": now})
                wrote = True
            self._last["history"] = time.time()

        if wrote or self.state.get("lastSync") is None:
            self.state["lastSync"] = _ts(now)
        self.state["error"] = None
