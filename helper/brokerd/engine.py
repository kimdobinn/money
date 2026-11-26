"""Background orchestration: polls brokers, keeps quotes/fx fresh, records history."""
from __future__ import annotations

import asyncio
import json
import logging
import time
from bisect import bisect_right
from dataclasses import asdict, replace
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import httpx

from . import aggregate, keychain
from .config import Settings
from .cloud import CloudSync
from .connectors.ibkr import FlexConnector, GatewayConnector
from .connectors import ibkr_web
from .connectors.ibkr_web import WebApiConnector
from .connectors.toss import TossClient, TossConnector
from .demo import Demo
from .fxcost import KRWCost
from .history import TOSS_TYPES, normalize_toss
from .models import BrokerSnapshot, Leg, Quote
from .store import Store
from .watchlist import Watchlist

log = logging.getLogger("brokerd.engine")


def _dump_snapshot(s: BrokerSnapshot) -> dict:
    d = asdict(s)
    d["as_of"] = s.as_of.isoformat() if s.as_of else None
    d.pop("cached", None)
    d.pop("busy", None)
    return d


def _load_snapshot(d: dict) -> BrokerSnapshot:
    d = dict(d)
    d["legs"] = [Leg(**l) for l in d.get("legs") or []]
    d["as_of"] = datetime.fromisoformat(d["as_of"]) if d.get("as_of") else None
    return BrokerSnapshot(**d)
NY = ZoneInfo("America/New_York")


class Engine:
    def __init__(self) -> None:
        self.settings = Settings()
        self.store = Store()
        self.demo = Demo()
        self.toss: TossConnector | None = None
        self.gateway: GatewayConnector | None = None
        self.flex: FlexConnector | None = None
        # IBKR Web API (Client Portal Gateway): works where IB Gateway's port 4001 is blocked
        self.webapi: WebApiConnector | None = WebApiConnector() if ibkr_web.available() else None
        self.quotes: dict[str, Quote] = {}
        self._prev_cache: dict[tuple[str, str], float | None] = {}
        self.fx_fallback: dict[str, float] = {}
        self._snap_saved: dict[str, float] = {}
        self._snap_cache: dict[str, BrokerSnapshot | None] = {}
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
        self.cloud = CloudSync(self)

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
            self.cloud.run(),
            *([self.webapi.run()] if self.webapi else []),
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
        gw_live = bool((self.gateway and self.gateway.connected) or (self.webapi and self.webapi.connected))
        return not (self.toss or self.flex or gw_live)

    def _ibkr_snapshot(self) -> BrokerSnapshot | None:
        gw = self.gateway.snapshot() if self.gateway else None
        if not gw and self.webapi:
            gw = self.webapi.snapshot()
        if gw:
            if gw.legs and time.time() - self._snap_saved.get("ibkr:gateway", 0) > 60:
                self.store.meta_set("snap:ibkr:gateway", json.dumps(_dump_snapshot(gw)))
                self._snap_saved["ibkr:gateway"] = time.time()
                self._snap_cache.pop("ibkr:gateway", None)
            return gw
        fl = self.flex.snapshot() if self.flex else None
        # Gateway went away: keep its last numbers unless the Flex report is newer. Flex is dated by
        # report day (00:00 UTC) but covers that whole trading day, so count it as of the next day.
        live = self.gateway or self.webapi
        last = self._cached("ibkr:gateway") if live else None
        if last and last.as_of and (not fl or not fl.as_of or last.as_of > fl.as_of + timedelta(days=1)):
            when = last.as_of.astimezone().strftime("%-m/%-d %H:%M")
            msg = f"실시간 연결 끊김 — 마지막 연결({when}) 기준 포지션을 표시 중입니다"
            if (m := self._ibkr_live_message()):
                msg += " · " + m
            return replace(last, status="stale", cached=True, legs=[replace(l) for l in last.legs], message=msg)
        if fl:
            if live:
                fl.message = "실시간 연결 끊김 — 최근 Flex 리포트(전일 기준) 포지션을 표시 중입니다"
            if self.flex.message:
                fl.message = (fl.message + " · " if fl.message else "") + self.flex.message
            return fl
        if live or self.flex:
            msg = self._ibkr_live_message() or (self.flex.message if self.flex else None)
            return BrokerSnapshot("ibkr", "IBKR", "error" if not live else "connecting", "", None, message=msg)
        return None

    def _ibkr_live_message(self) -> str | None:
        if self.webapi and not self.webapi.connected:
            return self.webapi.message
        return self.gateway.message if self.gateway else None

    def broker_snapshots(self) -> list[BrokerSnapshot]:
        if self.is_demo():
            return self.demo.snapshots()
        out = []
        if self.toss:
            out.append(self.toss.snapshot)
        ib = self._ibkr_snapshot()
        if ib:
            out.append(ib)
        out = [self._with_cache(s) for s in out]
        if self.flex and self.flex.fetching:
            out = [replace(s, busy="Flex 리포트 받는 중") if s.broker == "ibkr" else s for s in out]
        return out

    # ---- last-known holdings -------------------------------------------------
    def _with_cache(self, s: BrokerSnapshot) -> BrokerSnapshot:
        """Persist each broker's last good holdings; when a broker can't be reached
        (startup, IP block, Gateway off), show those holdings instead of nothing."""
        if s.legs or s.cash:
            if s.status in ("ok", "stale") and time.time() - self._snap_saved.get(s.broker, 0) > 60:
                self.store.meta_set(f"snap:{s.broker}", json.dumps(_dump_snapshot(s)))
                self._snap_saved[s.broker] = time.time()
                self._snap_cache.pop(s.broker, None)
            return s
        c = self._cached(s.broker)
        if not c:
            return s
        # message = why the live connection failed; the app shows "Last fetched …" from as_of
        return replace(c, status="stale", cached=True, legs=[replace(l) for l in c.legs], message=s.message)

    def _cached(self, key: str) -> BrokerSnapshot | None:
        if key not in self._snap_cache:
            raw = self.store.meta_get(f"snap:{key}")
            try:
                self._snap_cache[key] = _load_snapshot(json.loads(raw)) if raw else None
            except (ValueError, TypeError):
                self._snap_cache[key] = None
        return self._snap_cache[key]

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
        # Live rows recorded before the most recently added broker joined only hold part of the
        # portfolio; the backfill (which now includes that broker) covers that time instead.
        joined = max(
            (int(v) for s in self.broker_snapshots()
             if (v := self.store.meta_get(f"first_seen:{s.broker}")) and v.isdigit()),
            default=0,
        )
        joined_day = datetime.fromtimestamp(joined, NY).date().isoformat() if joined else ""
        dense: dict[int, tuple[int, float, float | None]] = {}
        if bucket:
            for ts, v, c in self.store.snapshots_since(max(since_ts, joined)):
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
                for d, v, c, src in self.store.daily_since(since)
                if d not in covered and not (src == "live" and d < joined_day)
            ]
            pts.sort(key=lambda p: p["t"])
        intraday = intraday or bool(rows)
        self._add_invested(pts)
        return {"range": rng, "intraday": intraday, "points": pts}

    def _add_invested(self, pts: list[dict]) -> None:
        """Net money put into stocks as of each point (buys − sells at fill price), so the app can
        chart 투자수익 = 평가금액 − 순투입액 without the jumps from new deposits. Includes realized gains."""
        fx = self.fx_to_usd()
        dates: list[str] = []
        cum: list[float] = []
        flows = self.store.trade_flows()
        rows = self.store.trade_symbols()
        trade_brokers = {r[0] for r in rows}
        net: dict[tuple[str, str], float] = {}
        first_px: dict[tuple[str, str], float] = {}
        for _, sym, ccy, qty, px in rows:
            net[(sym, ccy)] = net.get((sym, ccy), 0.0) + qty
            if px is not None:
                first_px.setdefault((sym, ccy), px)
        held: dict[tuple[str, str], float] = {}
        avg: dict[tuple[str, str], float] = {}
        late: list[tuple[int, float]] = []  # (from date, USD) for brokers without trade history
        for s in self.broker_snapshots():
            if s.broker in trade_brokers:
                for leg in s.legs:
                    k = (leg.symbol, leg.currency)
                    held[k] = held.get(k, 0.0) + leg.quantity
                    avg.setdefault(k, leg.avg_cost)
            elif s.legs:
                # no trades on record: its holdings count as invested (at avg cost) from the day
                # the app first saw them, matching when they start showing up in the value series
                since = int(self.store.meta_get(f"first_seen:{s.broker}") or time.time())
                late.append((since, sum(l.quantity * l.avg_cost * fx.get(l.currency, 0.0) for l in s.legs)))
        # Shares held before the first recorded trade (current − Σ trades) have no buy in the
        # records; count them as invested at their first known fill price (else avg cost).
        total = 0.0
        for key in set(held) | set(net):
            opening = held.get(key, 0.0) - net.get(key, 0.0)
            px = first_px.get(key, avg.get(key))
            if opening > 1e-9 and px and key[1] in fx:
                total += opening * px * fx[key[1]]
        for d, ccy, qty, px in flows:
            if px is None or ccy not in fx:  # splits / transfers move no money
                continue
            total += qty * px * fx[ccy]
            if dates and dates[-1] == d:
                cum[-1] = total
            else:
                dates.append(d)
                cum.append(total)
        if not dates and not late:
            return
        for p in pts:
            t = datetime.fromisoformat(p["t"])
            d = t.astimezone(NY).date().isoformat()
            i = bisect_right(dates, d) - 1
            v = cum[i] if i >= 0 else 0.0
            v += sum(amt for since, amt in late if t.timestamp() >= since)
            p["investedUSD"] = round(v, 2)

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
                "webapi": {
                    "available": bool(self.webapi),
                    "running": bool(self.webapi and self.webapi.running),
                    "connected": bool(self.webapi and self.webapi.connected),
                    "message": self.webapi.message if self.webapi else None,
                    "loginUrl": ibkr_web.LOGIN_URL,
                },
                "flex": {
                    "configured": bool(self.flex),
                    "fetchedAt": self.flex.fetched_at.isoformat() if self.flex and self.flex.fetched_at else None,
                    "message": self.flex.message if self.flex else None,
                },
            },
            "backfill": self.backfill_state,
            "cloud": self.cloud.state,
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
        await asyncio.sleep(20)
        while True:
            f = self.flex
            if not f:
                await self._sleep_or_kick(3600, self._flex_kick)
                continue
            stale = not f.fetched_at or datetime.now(timezone.utc) - f.fetched_at > timedelta(hours=6)
            if stale:
                f.fetching = True
                try:
                    await f.fetch()
                except Exception as e:  # noqa: BLE001
                    f.message = f"Flex 리포트 실패: {e}"
                    log.warning("flex fetch failed: %s", e)
                finally:
                    f.fetching = False
            await self._sleep_or_kick(3600, self._flex_kick)

    async def _snapshot_loop(self):
        await asyncio.sleep(60)
        while True:
            try:
                if not self.is_demo():
                    # Skip brokers that never delivered data (e.g. IB Gateway never logged in), but
                    # don't record while one that did is down — a partial total would look like a crash.
                    snaps = [
                        s for s in self.broker_snapshots()
                        if s.legs or s.status in ("ok", "stale") or self.store.meta_get(f"first_seen:{s.broker}")
                    ]
                    if snaps and all(s.status in ("ok", "stale") and (s.legs or s.cash) and not s.cached for s in snaps):
                        for s in snaps:
                            if not self.store.meta_get(f"first_seen:{s.broker}"):
                                self.store.meta_set(f"first_seen:{s.broker}", str(int(time.time())))
                        p = self.portfolio()["totals"]
                        if p["marketValueUSD"] > 0:
                            self.store.add_snapshot(
                                p["marketValueUSD"], p["costBasisUSD"], p["cashUSD"], p["dayPLUSD"],
                                datetime.now(NY).date(),
                            )
            except Exception as e:  # noqa: BLE001
                log.warning("snapshot failed: %s", e)
            await asyncio.sleep(300)

    async def _check_ip(self) -> None:
        try:
            async with httpx.AsyncClient(timeout=6) as http:
                ip = (await http.get("https://api.ipify.org")).text.strip()
            if self.public_ip and ip != self.public_ip:
                log.warning("public IP changed %s -> %s", self.public_ip, ip)
                self._holdings_kick.set()
            self.public_ip = ip
        except Exception:  # noqa: BLE001
            pass

    async def retry(self, broker: str, quick: bool = False) -> dict:
        """User-triggered reconnect for one broker (e.g. after switching Wi-Fi).
        quick: only poke the Gateway (used while waiting for the user to log in)."""
        if not quick:
            await self._check_ip()
        if broker == "toss":
            t = self.toss
            if not t:
                return {"ok": False, "message": "토스 API가 설정되지 않았습니다"}
            t._cash_at = 0.0
            await t.refresh_holdings()
            await t.refresh_fx()
            self._quote_kick.set()
            ok = t.snapshot.status == "ok"
            msg = "토스 연결됨" if ok else (t.snapshot.message or "토스 연결 실패")
            if not ok and self.public_ip:
                msg += f" (현재 IP {self.public_ip})"
            return {"ok": ok, "message": msg}
        if broker == "ibkr":
            if not (self.gateway or self.flex or self.webapi):
                return {"ok": False, "message": "IBKR이 설정되지 않았습니다"}
            parts, ok = [], False
            if self.flex and not quick:
                self.flex.fetched_at = None
                self._flex_kick.set()
            if self.webapi and self.webapi.running:
                self.webapi.wake()
                for _ in range(8):
                    await asyncio.sleep(0.5)
                    if self.webapi.connected:
                        break
                if self.webapi.connected:
                    ok = True
                    parts.append("IBKR 웹 연결됨")
            if self.gateway and not ok:
                ok = await self.gateway.retry(wait=4 if quick else 15)
                parts.append("IB Gateway 연결됨" if ok else (self.gateway.message or "IB Gateway 연결 실패"))
            if self.flex and not quick:
                self.flex.fetching = True  # show the spinner right away; the loop picks it up
                if not self.gateway:
                    ok, parts = True, ["Flex 리포트 다시 받는 중"]
            self._quote_kick.set()
            return {"ok": ok, "message": " · ".join(parts)}
        return {"ok": False, "message": f"알 수 없는 증권사: {broker}"}

    async def _ip_loop(self):
        while True:
            await self._check_ip()
            await asyncio.sleep(600)

    async def _auto_backfill(self):
        """Run the history backfill whenever the set of brokers with data changes
        (e.g. first Toss connection, later again when IBKR is added)."""
        while True:
            await asyncio.sleep(90)
            if self.is_demo():
                continue
            live = ",".join(sorted(s.broker for s in self.broker_snapshots() if s.status in ("ok", "stale")))
            if live and self.flex and self.flex.trades():
                live += "+flex"  # re-run once IBKR trade history arrives
            if live and live != self.store.meta_get("backfill_brokers"):
                await self.run_backfill()
                if self.backfill_state.get("ok"):
                    self.store.meta_set("backfill_brokers", live)

    async def _watch_loop(self):
        """Daily symbol-universe refresh + keep watchlist sparklines warm."""
        await asyncio.sleep(5)
        while True:
            t = self.toss
            if t:
                try:  # keep recent trades fresh for the 투자수익 chart
                    since = datetime.now(NY).date() - timedelta(days=10)
                    trades = normalize_toss(await t.client.transactions(TOSS_TYPES, since=since))
                    if trades:
                        self.store.save_trades(trades)
                except Exception as e:  # noqa: BLE001
                    log.info("trade refresh failed: %r", e)
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
            self.backfill_state.update(message=msg, ok=True)
        except Exception as e:  # noqa: BLE001
            log.exception("backfill failed")
            self.backfill_state.update(message=f"히스토리 복원 실패: {e}", ok=False)
        finally:
            self.backfill_state.update(running=False, lastRun=datetime.now(timezone.utc).isoformat())
        return self.backfill_state
