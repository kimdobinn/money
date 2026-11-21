"""Background orchestration: polls brokers, keeps quotes/fx fresh, records history."""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import httpx

from . import aggregate, keychain
from .config import Settings
from .connectors.ibkr import FlexConnector, GatewayConnector
from .connectors.toss import TossClient, TossConnector
from .demo import Demo
from .fxcost import KRWCost
from .models import BrokerSnapshot, Quote
from .store import Store
from .watchlist import Watchlist

log = logging.getLogger("brokerd.engine")
NY = ZoneInfo("America/New_York")


class Engine:
    def __init__(self) -> None:
        self.settings = Settings()
        self.store = Store()
        self.demo = Demo()
        self.toss: TossConnector | None = None
        self.gateway: GatewayConnector | None = None
        self.flex: FlexConnector | None = None
        self.quotes: dict[str, Quote] = {}
        self._prev_cache: dict[tuple[str, str], float | None] = {}
        self.fx_fallback: dict[str, float] = {}
        self.public_ip: str | None = None
        self.backfill_state = {"running": False, "lastRun": None, "message": None}
        self.krw_cost = KRWCost(self.store)
        self.watchlist = Watchlist(self.store)
        self._krw_sig: tuple | None = None
        self._krw_at = 0.0
        self._krw_task: asyncio.Task | None = None
        self._tasks: list[asyncio.Task] = []
        self._gw_task: asyncio.Task | None = None
        self._flex_kick = asyncio.Event()
        self._holdings_kick = asyncio.Event()
        self._quote_kick = asyncio.Event()

    # ---- lifecycle ---------------------------------------------------------
    async def start(self) -> None:
        await self.reload()
        for coro in (
            self._holdings_loop(),
            self._quote_loop(),
            self._fx_loop(),
            self._flex_loop(),
            self._snapshot_loop(),
            self._ip_loop(),
            self._auto_backfill(),
            self._watch_loop(),
        ):
            self._tasks.append(asyncio.create_task(coro))

    async def stop(self) -> None:
        for t in self._tasks:
            t.cancel()
        await self._teardown()

    async def _teardown(self):
        if self._gw_task:
            self._gw_task.cancel()
            self._gw_task = None
        if self.gateway:
            self.gateway.stop()
            self.gateway = None
        if self.toss:
            await self.toss.client.close()
            self.toss = None
        self.flex = None

    async def reload(self) -> None:
        """(Re)build connectors from settings + Keychain."""
        await self._teardown()
        s = self.settings
        cid, secret = keychain.get("tossClientId"), keychain.get("tossClientSecret")
        if s["toss"]["enabled"] and cid and secret:
            self.toss = TossConnector(TossClient(cid, secret))
        ib = s["ibkr"]
        if ib["gatewayEnabled"]:
            self.gateway = GatewayConnector(ib["host"], int(ib["port"]), int(ib["clientId"]))
            self._gw_task = asyncio.create_task(self.gateway.run())
        token = keychain.get("ibkrFlexToken")
        if ib["flexEnabled"] and token and ib.get("flexQueryId"):
            self.flex = FlexConnector(token, str(ib["flexQueryId"]))
            self._flex_kick.set()
        self._holdings_kick.set()
        log.info(
            "connectors: toss=%s gateway=%s flex=%s", bool(self.toss), bool(self.gateway), bool(self.flex)
        )

    # ---- state -------------------------------------------------------------
    def is_demo(self) -> bool:
        mode = self.settings["demoMode"]
        if mode == "on":
            return True
        if mode == "off":
            return False
        gw_live = bool(self.gateway and self.gateway.connected)
        return not (self.toss or self.flex or gw_live)

    def _ibkr_snapshot(self) -> BrokerSnapshot | None:
        gw = self.gateway.snapshot() if self.gateway else None
        if gw:
            return gw
        fl = self.flex.snapshot() if self.flex else None
        if fl:
            if self.gateway:
                fl.message = "Gateway 미연결 — 최근 Flex 리포트(전일 기준) 포지션을 표시 중입니다"
            if self.flex.message:
                fl.message = (fl.message + " · " if fl.message else "") + self.flex.message
            return fl
        if self.gateway or self.flex:
            msg = (self.gateway.message if self.gateway else None) or (self.flex.message if self.flex else None)
            return BrokerSnapshot("ibkr", "IBKR", "error" if not self.gateway else "connecting", "", None, message=msg)
        return None

    def broker_snapshots(self) -> list[BrokerSnapshot]:
        if self.is_demo():
            return self.demo.snapshots()
        out = []
        if self.toss:
            out.append(self.toss.snapshot)
        ib = self._ibkr_snapshot()
        if ib:
            out.append(ib)
        return out

    def fx_to_usd(self) -> dict[str, float]:
        fx = {"USD": 1.0}
        fx.update(self.fx_fallback)
        if self.is_demo():
            for s in self.demo.snapshots():
                fx.update(s.fx_to_usd)
            return fx
        ib = self._ibkr_snapshot()
        if ib:
            fx.update(ib.fx_to_usd)
        if self.toss and self.toss.snapshot.fx_to_usd:
            fx.update(self.toss.snapshot.fx_to_usd)  # Toss is the live KRW source
        return fx

    def portfolio(self) -> dict:
        demo = self.is_demo()
        return aggregate.build(
            self.broker_snapshots(),
            self.demo.quotes() if demo else self.quotes,
            self.fx_to_usd(),
            demo=demo,
            display_currency=self.settings["displayCurrency"],
            menu_bar_style=self.settings["menuBarStyle"],
            color_style=self.settings["colorStyle"],
            krw_cost=None if demo else (self.krw_cost.by_symbol if self.toss else None),
            usd_krw=self.demo.usd_krw if demo else (self.toss.usd_krw if self.toss else None),
        )

    def history(self, rng: str) -> dict:
        days = {"1D": 1, "1W": 7, "1M": 30, "3M": 91, "1Y": 365, "ALL": 365 * 20}.get(rng)
        now = datetime.now(timezone.utc)
        if rng == "YTD":
            days = (now.date() - now.date().replace(month=1, day=1)).days + 1
        days = days or 30
        intraday = days <= 7
        if self.is_demo():
            return {"range": rng, "intraday": intraday, "points": self.demo.history(min(days, 900), intraday)}
        # Densest data available: 5-min live snapshots, then the hourly backfill (last month),
        # then one point per day. Buckets keep long ranges light.
        bucket = {"1D": 300, "1W": 900, "1M": 3600, "3M": 3 * 3600, "YTD": 12 * 3600, "1Y": 12 * 3600}.get(rng)
        since_ts = int(time.time()) - days * 86400
        dense: dict[int, tuple[int, float, float | None]] = {}
        if bucket:
            for ts, v, c in self.store.snapshots_since(since_ts):
                dense[ts // bucket] = (ts, v, c)
            for ts, v in self.store.hourly_since(since_ts):
                dense.setdefault(ts // bucket, (ts, v, None))
        rows = sorted(dense.values())
        pts = [
            {"t": datetime.fromtimestamp(ts, timezone.utc).isoformat(), "valueUSD": v, "costUSD": c}
            for ts, v, c in rows
        ]
        if not intraday:
            covered = {datetime.fromtimestamp(ts, NY).date().isoformat() for ts, _, _ in rows}
            since = (now.date() - timedelta(days=days)).isoformat()
            pts += [
                {"t": f"{d}T21:00:00+00:00", "valueUSD": v, "costUSD": c}
                for d, v, c in self.store.daily_since(since)
                if d not in covered
            ]
            pts.sort(key=lambda p: p["t"])
        intraday = intraday or bool(rows)
        return {"range": rng, "intraday": intraday, "points": pts}

    def watchlist_view(self) -> dict:
        held: dict[str, dict] = {}
        if not self.is_demo():
            for s in self.broker_snapshots():
                for l in s.legs:
                    h = held.setdefault(l.symbol, {"quantity": 0.0, "cost": 0.0})
                    h["quantity"] += l.quantity
                    h["cost"] += l.quantity * l.avg_cost
        items = []
        for e in self.watchlist.entries():
            q = self.quotes.get(e["symbol"])
            price = q.price if q else None
            prev = q.prev_close if q else None
            chg = (price - prev) if (price is not None and prev) else None
            h = held.get(e["symbol"])
            items.append({
                **e,
                "price": price,
                "prevClose": prev,
                "change": chg,
                "changePct": (chg / prev) if (chg is not None and prev) else None,
                "priceTime": q.ts.isoformat() if q and q.ts else None,
                "spark": self.watchlist.spark(e["symbol"]),
                "held": {"quantity": h["quantity"], "avgCost": h["cost"] / h["quantity"]}
                if h and h["quantity"] else None,
            })
        return {
            "available": bool(self.toss),
            "searchReady": bool(self.store.meta_get("universe_at")),
            "items": items,
        }

    def status(self) -> dict:
        ib = self.settings["ibkr"]
        toss_err = self.toss.last_error if self.toss else None
        return {
            "demo": self.is_demo(),
            "publicIP": self.public_ip,
            "secrets": keychain.presence(),
            "settings": self.settings.data,
            "connectors": {
                "toss": {
                    "configured": bool(self.toss),
                    "status": self.toss.snapshot.status if self.toss else "disabled",
                    "message": self.toss.snapshot.message if self.toss else None,
                    "ipBlocked": bool(toss_err and toss_err.code == "ip-not-allowed"),
                },
                "gateway": {
                    "enabled": ib["gatewayEnabled"],
                    "connected": bool(self.gateway and self.gateway.connected),
                    "message": self.gateway.message if self.gateway else None,
                },
                "flex": {
                    "configured": bool(self.flex),
                    "fetchedAt": self.flex.fetched_at.isoformat() if self.flex and self.flex.fetched_at else None,
                    "message": self.flex.message if self.flex else None,
                },
            },
            "backfill": self.backfill_state,
        }

    # ---- loops -------------------------------------------------------------
    async def _sleep_or_kick(self, seconds: float, ev: asyncio.Event):
        try:
            await asyncio.wait_for(ev.wait(), timeout=seconds)
        except asyncio.TimeoutError:
            pass
        ev.clear()

    async def _holdings_loop(self):
        while True:
            if self.toss:
                await self.toss.refresh_holdings()
                self._maybe_recompute_krw()
            await self._sleep_or_kick(15, self._holdings_kick)

    def _maybe_recompute_krw(self):
        """원화 평단: recompute when Toss USD holdings change, else every 6h."""
        t = self.toss
        if not t or t.snapshot.status != "ok" or not t.usd_krw:
            return
        sig = tuple(sorted((l.symbol, l.quantity) for l in t.snapshot.legs if l.currency == "USD"))
        stale = time.time() - self._krw_at > 6 * 3600
        if (sig != self._krw_sig or stale) and not (self._krw_task and not self._krw_task.done()):
            async def run():
                try:
                    await self.krw_cost.compute(t.client, t.usd_krw)
                    self._krw_sig, self._krw_at = sig, time.time()
                except Exception as e:  # noqa: BLE001
                    log.warning("KRW cost basis failed: %r", e)
                    self._krw_at = time.time() - 5 * 3600  # retry in ~1h
            self._krw_task = asyncio.create_task(run())

    async def _quote_loop(self):
        while True:
            try:
                if self.is_demo():
                    self.demo.tick()
                elif self.toss:
                    await self._refresh_quotes()
            except Exception as e:  # noqa: BLE001
                log.warning("quote loop: %s", e)
            await self._sleep_or_kick(3, self._quote_kick)

    async def _refresh_quotes(self):
        snaps = self.broker_snapshots()
        watched = self.watchlist.symbols()
        syms = sorted({l.symbol for s in snaps for l in s.legs if l.market in ("US", "KR")} | set(watched))
        fresh = await self.toss.quotes(syms)
        toss_prev = {l.symbol: l.prev_close for l in self.toss.snapshot.legs if l.prev_close}
        markets = {**watched, **{l.symbol: l.market for s in snaps for l in s.legs}}
        fetched = 0
        for sym, q in fresh.items():
            if sym in toss_prev:
                q.prev_close = toss_prev[sym]
                continue
            tz = ZoneInfo("Asia/Seoul") if markets.get(sym) == "KR" else NY
            day = (q.ts or datetime.now(timezone.utc)).astimezone(tz).date().isoformat()
            key = (sym, day)
            if key not in self._prev_cache and fetched < 5:
                self._prev_cache[key] = await self.toss.prev_close(sym, markets.get(sym, "US"), q.ts)
                fetched += 1
            q.prev_close = self._prev_cache.get(key)
        self.quotes.update(fresh)

    async def _fx_loop(self):
        last_fallback = 0.0
        while True:
            if self.toss:
                await self.toss.refresh_fx()
            if time.time() - last_fallback > 6 * 3600:
                try:
                    async with httpx.AsyncClient(timeout=10) as http:
                        r = await http.get("https://api.frankfurter.dev/v1/latest", params={"base": "USD", "symbols": "SGD,KRW"})
                        rates = r.json()["rates"]
                        self.fx_fallback = {c: 1 / v for c, v in rates.items()}
                        last_fallback = time.time()
                except Exception as e:  # noqa: BLE001
                    log.info("fx fallback failed: %s", e)
            await asyncio.sleep(60)

    async def _flex_loop(self):
        while True:
            await self._sleep_or_kick(3600, self._flex_kick)
            f = self.flex
            if not f:
                continue
            stale = not f.fetched_at or datetime.now(timezone.utc) - f.fetched_at > timedelta(hours=6)
            if stale:
                try:
                    await f.fetch()
                except Exception as e:  # noqa: BLE001
                    f.message = f"Flex 리포트 실패: {e}"
                    log.warning("flex fetch failed: %s", e)

    async def _snapshot_loop(self):
        await asyncio.sleep(60)
        while True:
            try:
                if not self.is_demo():
                    # ignore brokers that never delivered data (e.g. IB Gateway not logged in)
                    snaps = [s for s in self.broker_snapshots() if s.legs or s.status in ("ok", "stale")]
                    if snaps and all(s.status in ("ok", "stale") for s in snaps):
                        p = self.portfolio()["totals"]
                        if p["marketValueUSD"] > 0:
                            self.store.add_snapshot(
                                p["marketValueUSD"], p["costBasisUSD"], p["cashUSD"], p["dayPLUSD"],
                                datetime.now(NY).date(),
                            )
            except Exception as e:  # noqa: BLE001
                log.warning("snapshot failed: %s", e)
            await asyncio.sleep(300)

    async def _ip_loop(self):
        while True:
            try:
                async with httpx.AsyncClient(timeout=10) as http:
                    ip = (await http.get("https://api.ipify.org")).text.strip()
                if self.public_ip and ip != self.public_ip:
                    log.warning("public IP changed %s -> %s", self.public_ip, ip)
                    self._holdings_kick.set()
                self.public_ip = ip
            except Exception:  # noqa: BLE001
                pass
            await asyncio.sleep(600)

    async def _auto_backfill(self):
        """Run the history backfill whenever the set of brokers with data changes
        (e.g. first Toss connection, later again when IBKR is added)."""
        while True:
            await asyncio.sleep(90)
            if self.is_demo():
                continue
            live = ",".join(sorted(s.broker for s in self.broker_snapshots() if s.status in ("ok", "stale")))
            if live and live != self.store.meta_get("backfill_brokers"):
                await self.run_backfill()
                self.store.meta_set("backfill_brokers", live)

    async def _watch_loop(self):
        """Daily symbol-universe refresh + keep watchlist sparklines warm."""
        await asyncio.sleep(5)
        while True:
            t = self.toss
            if t:
                await self.watchlist.ensure_universe(t.client)
                start = datetime.now(NY).date() - timedelta(days=45)
                for sym in list(self.watchlist.symbols()):
                    try:
                        await self.watchlist.daily(t.client, sym, start)
                    except Exception as e:  # noqa: BLE001
                        log.info("watch candles %s: %r", sym, e)
            await asyncio.sleep(600)

    async def run_backfill(self) -> dict:
        from .history import backfill

        if self.backfill_state["running"]:
            return self.backfill_state
        self.backfill_state.update(running=True, message="과거 히스토리 복원 중…")
        try:
            msg = await backfill(self)
            self.store.meta_set("backfill_done", datetime.now(timezone.utc).isoformat())
            self.backfill_state.update(message=msg)
        except Exception as e:  # noqa: BLE001
            log.exception("backfill failed")
            self.backfill_state.update(message=f"히스토리 복원 실패: {e}")
        finally:
            self.backfill_state.update(running=False, lastRun=datetime.now(timezone.utc).isoformat())
        return self.backfill_state
