"""Interactive Brokers Web API via IBKR's Client Portal Gateway (live, read-only).

The Client Portal Gateway is IBKR's small Java proxy: it runs on this Mac (localhost:5055 only),
the user logs in once through it in the browser (+ IBKR app approval), and it talks to
api.ibkr.com over ordinary HTTPS (443). That gets through networks that block IB Gateway's
port 4001, e.g. school Wi-Fi. Only portfolio (read) endpoints are used — no order endpoints.

The Java process is started detached (own session) so a helper restart doesn't drop the login.
"""
from __future__ import annotations

import asyncio
import logging
import os
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx

from ..config import APP_DIR
from ..models import BrokerSnapshot, Leg, norm_symbol
from .ibkr import NAME, _f, _market

log = logging.getLogger("brokerd.ibkr_web")

CP_DIR = APP_DIR / "clientportal"
PORT = 5055
BASE = f"http://localhost:{PORT}"
LOGIN_URL = BASE + "/"
API = BASE + "/v1/api"
HEADERS = {"User-Agent": "money/1.0"}  # IBKR's edge rejects requests without one


def available() -> bool:
    return (CP_DIR / "root" / "conf.yaml").exists() and (CP_DIR / "dist").is_dir()


def _java() -> str | None:
    try:
        home = subprocess.run(["/usr/libexec/java_home"], capture_output=True, text=True, timeout=5).stdout.strip()
        if home and os.access(f"{home}/bin/java", os.X_OK):
            return f"{home}/bin/java"
    except Exception:  # noqa: BLE001
        pass
    for p in [shutil.which("java"), *map(str, Path.home().glob("Applications/IB Gateway*/.install4j/jre.bundle/Contents/Home/bin/java"))]:
        if p and os.access(p, os.X_OK):
            return p
    return None


class WebApiConnector:
    def __init__(self):
        self.message: str | None = "IBKR 웹 로그인이 필요해요"
        self.running = False  # Client Portal Gateway answers on localhost
        self.authenticated = False
        self._snap: BrokerSnapshot | None = None
        self._accounts: list[str] = []
        self._wake = asyncio.Event()
        self._tickled = 0.0
        self._invalidated = 0.0
        self._stop = False

    @property
    def connected(self) -> bool:
        return self.authenticated and self._snap is not None

    def snapshot(self) -> BrokerSnapshot | None:
        return self._snap if self.authenticated else None

    # ---- process -----------------------------------------------------------
    async def _alive(self, http: httpx.AsyncClient) -> bool:
        try:
            r = await http.get(BASE + "/", follow_redirects=False, timeout=3)
            return r.status_code < 500
        except httpx.HTTPError:
            return False

    async def ensure_started(self) -> bool:
        """Start the Client Portal Gateway if it isn't running. Returns True once it answers."""
        async with httpx.AsyncClient(headers=HEADERS) as http:
            if await self._alive(http):
                self.running = True
                return True
            java = _java()
            if not java:
                self.message = "Java를 찾을 수 없어요 — IBKR 웹 로그인에 필요해요"
                return False
            cp = ":".join(["root", "dist/ibgroup.web.core.iblink.router.clientportal.gw.jar", "build/lib/runtime/*"])
            logf = open(CP_DIR / "gw.log", "ab")  # noqa: SIM115 — handed to the child
            subprocess.Popen(
                [java, "-server", "-Dvertx.disableDnsResolver=true", "-Djava.net.preferIPv4Stack=true",
                 "-Dvertx.logger-delegate-factory-class-name=io.vertx.core.logging.SLF4JLogDelegateFactory",
                 "-cp", cp, "ibgroup.web.core.clientportal.gw.GatewayStart", "--conf", "../root/conf.yaml"],
                cwd=CP_DIR, stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
            logf.close()
            for _ in range(40):
                await asyncio.sleep(0.5)
                if await self._alive(http):
                    self.running = True
                    log.info("Client Portal Gateway started on :%s", PORT)
                    return True
            self.message = "IBKR 웹 게이트웨이를 시작하지 못했어요"
            return False

    def wake(self) -> None:
        self._wake.set()

    # ---- loop --------------------------------------------------------------
    async def run(self):
        async with httpx.AsyncClient(headers=HEADERS, timeout=15) as http:
            while not self._stop:
                try:
                    await self._tick(http)
                except Exception as e:  # noqa: BLE001
                    log.info("web api tick failed: %r", e)
                    self.message = f"IBKR 웹 API 오류: {type(e).__name__}"
                try:
                    await asyncio.wait_for(self._wake.wait(), timeout=15 if self.authenticated else 5)
                except asyncio.TimeoutError:
                    pass
                self._wake.clear()

    async def _tick(self, http: httpx.AsyncClient):
        self.running = await self._alive(http)
        if not self.running:
            self.authenticated, self._snap = False, None
            self.message = "IBKR 웹 로그인이 필요해요"
            return
        now = time.time()
        if now - self._tickled > 55:  # keeps the session alive (IBKR drops it after ~5 min idle)
            r = await http.post(API + "/tickle", content=b"")
            self._tickled = now
            if r.status_code == 401:
                self._logged_out()
                return
        r = await http.get(API + "/portfolio/accounts")
        if r.status_code == 401:
            self._logged_out()
            return
        r.raise_for_status()
        self._accounts = [a.get("accountId") or a.get("id") for a in r.json() if a.get("accountId") or a.get("id")]
        if not self._accounts:
            return
        if now - self._invalidated > 300:  # positions are cached server-side; refresh every 5 min
            for acct in self._accounts:
                await http.post(f"{API}/portfolio/{acct}/positions/invalidate", content=b"")
            self._invalidated = now
        legs: list[Leg] = []
        cash: dict[str, float] = {}
        rate_to_base: dict[str, float] = {}
        for acct in self._accounts:
            page = 0
            while True:
                r = await http.get(f"{API}/portfolio/{acct}/positions/{page}")
                r.raise_for_status()
                rows = r.json() or []
                for p in rows:
                    if (p.get("assetClass") or "STK") != "STK" or not _f(p.get("position")):
                        continue
                    ccy = p.get("currency") or "USD"
                    sym = p.get("ticker") or p.get("contractDesc") or ""
                    legs.append(Leg(
                        broker="ibkr", symbol=norm_symbol(sym), name=p.get("name") or sym,
                        market=_market(ccy, p.get("listingExchange") or ""), currency=ccy,
                        quantity=float(p["position"]),
                        avg_cost=_f(p.get("avgPrice")) or _f(p.get("avgCost")) or 0.0,
                        last_price=_f(p.get("mktPrice")) or None,
                    ))
                if len(rows) < 100:  # IBKR pages positions by 100
                    break
                page += 1
            r = await http.get(f"{API}/portfolio/{acct}/ledger")
            r.raise_for_status()
            for ccy, row in (r.json() or {}).items():
                if ccy == "BASE" or not isinstance(row, dict):
                    continue
                c = _f(row.get("cashbalance")) or 0.0
                if abs(c) > 0.005:
                    cash[ccy] = cash.get(ccy, 0.0) + c
                if (x := _f(row.get("exchangerate"))):
                    rate_to_base[ccy] = x
        fx_to_usd = {}
        if "USD" in rate_to_base:
            fx_to_usd = {k: v / rate_to_base["USD"] for k, v in rate_to_base.items()}
        if not self.authenticated:
            log.info("IBKR Web API logged in (%d accounts)", len(self._accounts))
        self.authenticated, self.message = True, None
        self._snap = BrokerSnapshot(
            broker="ibkr", name=NAME, status="ok", source="webapi", as_of=datetime.now(timezone.utc),
            legs=legs, cash=cash, fx_to_usd=fx_to_usd,
        )

    def _logged_out(self):
        if self.authenticated:
            log.info("IBKR Web API session ended")
        self.authenticated, self._snap = False, None
        self.message = "IBKR 웹 로그인이 필요해요"

    def stop(self):
        self._stop = True
