"""관심 종목: watchlist storage, symbol search and price charts (토스 market data)."""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .connectors.toss import TossClient, _dt, _f
from .models import norm_symbol
from .store import Store

log = logging.getLogger("brokerd.watchlist")

EXCHANGES = ["NASDAQ", "NYSE", "AMEX", "US_ETC", "KOSPI", "KOSDAQ", "KR_ETC"]
KR_EXCHANGES = {"KOSPI", "KOSDAQ", "KR_ETC"}
ETF_TYPES = {"ETF", "FOREIGN_ETF", "ETN"}
RANGES = ["1D", "1W", "1M", "3M", "YTD", "1Y", "5Y", "ALL"]


def country(exchange: str | None) -> str:
    return "KR" if exchange in KR_EXCHANGES else "US"


def market_tz(exchange: str | None) -> ZoneInfo:
    return ZoneInfo("Asia/Seoul" if country(exchange) == "KR" else "America/New_York")


def _thin(points: list[dict], limit: int) -> list[dict]:
    """Keep at most `limit` points (evenly spaced, always keeping the last one)."""
    if len(points) <= limit:
        return points
    step = len(points) / limit
    out = [points[int(i * step)] for i in range(limit)]
    if out[-1] is not points[-1]:
        out[-1] = points[-1]
    return out


class Watchlist:
    def __init__(self, store: Store):
        self.store = store
        self._locks: dict[str, asyncio.Lock] = {}
        self._intraday: dict[tuple[str, int], tuple[float, list[dict]]] = {}
        self.universe_busy = False

    # ---- watchlist rows ------------------------------------------------
    def entries(self) -> list[dict]:
        rows = self.store._x(
            "SELECT symbol, name, english_name, exchange, security_type, currency, starred, added_at "
            "FROM watchlist ORDER BY starred DESC, COALESCE(position, 1e9), added_at"
        )
        return [
            {
                "symbol": r[0], "name": r[1], "englishName": r[2], "exchange": r[3],
                "market": country(r[3]), "securityType": r[4], "isETF": r[4] in ETF_TYPES,
                "currency": r[5], "starred": bool(r[6]), "addedAt": r[7],
            }
            for r in rows
        ]

    def symbols(self) -> dict[str, str]:
        """symbol -> market country (US/KR) for the quote loop."""
        return {r[0]: country(r[1]) for r in self.store._x("SELECT symbol, exchange FROM watchlist")}

    async def add(self, client: TossClient, symbol: str) -> dict:
        sym = norm_symbol(symbol)
        try:
            info = await client.stocks([sym])
        except Exception as e:  # noqa: BLE001
            raise ValueError(f"종목 정보를 가져오지 못했어요 ({e})") from e
        if not info:
            raise ValueError(f"'{sym}' 종목을 찾을 수 없어요")
        it = info[0]
        sym = norm_symbol(it["symbol"])
        self.store._x(
            "INSERT INTO watchlist(symbol, name, english_name, exchange, security_type, currency, starred, added_at, position) "
            "VALUES(?,?,?,?,?,?,0,?,(SELECT COALESCE(MAX(position), -1) + 1 FROM watchlist)) ON CONFLICT(symbol) DO UPDATE SET name=excluded.name, "
            "english_name=excluded.english_name, exchange=excluded.exchange, "
            "security_type=excluded.security_type, currency=excluded.currency",
            (sym, it.get("name"), it.get("englishName"), it.get("market"), it.get("securityType"),
             it.get("currency") or ("KRW" if it.get("market") in KR_EXCHANGES else "USD"), int(time.time())),
        )
        asyncio.create_task(self._warm(client, sym))
        return {"symbol": sym}

    async def _warm(self, client: TossClient, sym: str):
        try:
            await self.daily(client, sym, date.today() - timedelta(days=40))
        except Exception as e:  # noqa: BLE001
            log.info("warm %s failed: %r", sym, e)

    def remove(self, symbol: str):
        self.store._x("DELETE FROM watchlist WHERE symbol=?", (norm_symbol(symbol),))

    def set_order(self, symbols: list[str]):
        """Persist the user's drag-and-drop order (full list, top to bottom)."""
        with self.store.lock:
            self.store.db.executemany(
                "UPDATE watchlist SET position=? WHERE symbol=?",
                [(i, norm_symbol(s)) for i, s in enumerate(symbols)],
            )
            self.store.db.commit()

    def set_starred(self, symbol: str, starred: bool):
        self.store._x("UPDATE watchlist SET starred=? WHERE symbol=?", (int(starred), norm_symbol(symbol)))

    def spark(self, symbol: str, n: int = 30) -> list[float]:
        rows = self.store._x(
            "SELECT close FROM candles_d WHERE symbol=? ORDER BY date DESC LIMIT ?", (symbol, n)
        )
        return [r[0] for r in reversed(rows)]

    # ---- search --------------------------------------------------------
    async def ensure_universe(self, client: TossClient, force: bool = False):
        """Refresh the tradable-symbol list once a day (7 calls) and fill English names."""
        if self.universe_busy:
            return
        at = float(self.store.meta_get("universe_at") or 0)
        if not force and time.time() - at < 24 * 3600:
            return
        self.universe_busy = True
        try:
            rows = []
            for ex in EXCHANGES:
                for it in await client.stocks_all(ex):
                    rows.append((norm_symbol(it["symbol"]), it.get("name"), ex, it.get("securityType")))
            with self.store.lock:
                self.store.db.executemany(
                    "INSERT INTO universe(symbol, name, exchange, security_type) VALUES(?,?,?,?) "
                    "ON CONFLICT(symbol) DO UPDATE SET name=excluded.name, exchange=excluded.exchange, "
                    "security_type=excluded.security_type",
                    rows,
                )
                self.store.db.commit()
            self.store.meta_set("universe_at", time.time())
            log.info("universe: %d symbols", len(rows))
            # English names (for searching "apple", "nasdaq 100" …): /stocks, 200 per call
            missing = [r[0] for r in self.store._x("SELECT symbol FROM universe WHERE english_name IS NULL")]
            for i in range(0, len(missing), 200):
                info = await client.stocks(missing[i : i + 200])
                with self.store.lock:
                    self.store.db.executemany(
                        "UPDATE universe SET english_name=? WHERE symbol=?",
                        [(it.get("englishName") or "", norm_symbol(it["symbol"])) for it in info],
                    )
                    self.store.db.commit()
        except Exception as e:  # noqa: BLE001
            log.warning("universe refresh failed: %r", e)
        finally:
            self.universe_busy = False

    def search(self, q: str, limit: int = 25) -> list[dict]:
        q = q.strip()
        if not q:
            return []
        u = q.upper()
        rows = self.store._x(
            """
            SELECT symbol, name, english_name, exchange, security_type,
              CASE WHEN symbol = ? THEN 0
                   WHEN symbol LIKE ? || '%' THEN 1
                   WHEN name LIKE ? || '%' OR english_name LIKE ? || '%' THEN 2
                   ELSE 3 END AS rk
            FROM universe
            WHERE symbol LIKE ? || '%' OR name LIKE '%' || ? || '%' OR english_name LIKE '%' || ? || '%'
            ORDER BY rk, length(symbol), symbol
            LIMIT ?
            """,
            (u, u, q, q, u, q, q, limit),
        )
        watched = set(self.symbols())
        return [
            {
                "symbol": r[0], "name": r[1], "englishName": r[2] or None, "exchange": r[3],
                "market": country(r[3]), "securityType": r[4], "isETF": r[4] in ETF_TYPES,
                "watched": r[0] in watched,
            }
            for r in rows
        ]

    # ---- price history -------------------------------------------------
    def _lock(self, sym: str) -> asyncio.Lock:
        return self._locks.setdefault(sym, asyncio.Lock())

    def _put_candles(self, sym: str, candles: list[dict]):
        rows = [
            (sym, (c.get("timestamp") or "")[:10], _f(c.get("closePrice")))
            for c in candles
            if c.get("timestamp") and _f(c.get("closePrice")) is not None
        ]
        with self.store.lock:
            self.store.db.executemany("INSERT OR REPLACE INTO candles_d VALUES(?,?,?)", rows)
            self.store.db.commit()

    async def daily(self, client: TossClient, sym: str, since: date | None) -> list[tuple[str, float]]:
        """Daily closes since `since` (None = full history), cached in SQLite."""
        meta = self.store
        async with self._lock(sym):
            epoch = float(meta.meta_get(f"cd_epoch:{sym}") or 0)
            if time.time() - epoch > 7 * 86400:
                # adjusted prices change after splits/dividends: rebuild weekly
                meta._x("DELETE FROM candles_d WHERE symbol=?", (sym,))
                meta.meta_set(f"cd_epoch:{sym}", time.time())
                meta.meta_set(f"cd_next:{sym}", "")
                meta.meta_set(f"cd_upd:{sym}", 0)
            have = meta._x("SELECT min(date), count(*) FROM candles_d WHERE symbol=?", (sym,))[0]
            if not have[1]:
                res = await client.candles(sym, "1d", 200)
                self._put_candles(sym, res.get("candles") or [])
                meta.meta_set(f"cd_next:{sym}", res.get("nextBefore") or "-")
                meta.meta_set(f"cd_upd:{sym}", time.time())
            elif time.time() - float(meta.meta_get(f"cd_upd:{sym}") or 0) > 600:
                res = await client.candles(sym, "1d", 5)
                self._put_candles(sym, res.get("candles") or [])
                meta.meta_set(f"cd_upd:{sym}", time.time())
            for _ in range(40):  # walk back ≤ 8000 sessions
                first = meta._x("SELECT min(date) FROM candles_d WHERE symbol=?", (sym,))[0][0]
                nxt = meta.meta_get(f"cd_next:{sym}") or "-"
                if nxt == "-" or (since and first and first <= since.isoformat()):
                    break
                res = await client.candles(sym, "1d", 200, before=nxt)
                cs = res.get("candles") or []
                self._put_candles(sym, cs)
                meta.meta_set(f"cd_next:{sym}", res.get("nextBefore") or "-")
                if not cs:
                    break
            q = "SELECT date, close FROM candles_d WHERE symbol=?"
            args: tuple = (sym,)
            if since:
                q += " AND date >= ?"
                args = (sym, since.isoformat())
            return meta._x(q + " ORDER BY date", args)

    async def intraday(self, client: TossClient, sym: str, exchange: str | None, sessions: int) -> list[dict]:
        """1-minute closes for the latest `sessions` trading days (cached briefly)."""
        key = (sym, sessions)
        ttl = 45 if sessions == 1 else 300
        hit = self._intraday.get(key)
        if hit and time.time() - hit[0] < ttl:
            return hit[1]
        tz = market_tz(exchange)
        pts: list[dict] = []
        days: list[date] = []
        before = None
        async with self._lock(sym):
            for _ in range(8 * sessions):
                res = await client.candles(sym, "1m", 200, before=before)
                stop = False
                for c in res.get("candles") or []:
                    ts = _dt(c.get("timestamp"))
                    px = _f(c.get("closePrice"))
                    if ts is None or px is None:
                        continue
                    d = ts.astimezone(tz).date()
                    if d not in days:
                        if len(days) == sessions:
                            stop = True
                            break
                        days.append(d)
                    pts.append({"t": ts.astimezone(timezone.utc).isoformat(), "price": px})
                before = res.get("nextBefore")
                if stop or not before:
                    break
        pts.reverse()
        if sessions > 1:
            pts = _thin(pts, 800)
        self._intraday[key] = (time.time(), pts)
        return pts

    async def chart(self, client: TossClient, sym: str, rng: str) -> dict:
        sym = norm_symbol(sym)
        rng = rng.upper() if rng.upper() in RANGES else "1Y"
        ex = (self.store._x("SELECT exchange FROM watchlist WHERE symbol=?", (sym,)) or
              self.store._x("SELECT exchange FROM universe WHERE symbol=?", (sym,)) or [[None]])[0][0]
        intraday = rng in ("1D", "1W")
        if intraday:
            pts = await self.intraday(client, sym, ex, 1 if rng == "1D" else 5)
        else:
            today = datetime.now(market_tz(ex)).date()
            since = {
                "1M": today - timedelta(days=31),
                "3M": today - timedelta(days=92),
                "YTD": today.replace(month=1, day=1),
                "1Y": today - timedelta(days=366),
                "5Y": today - timedelta(days=366 * 5),
                "ALL": None,
            }[rng]
            rows = await self.daily(client, sym, since)
            pts = _thin([{"t": f"{d}T12:00:00+00:00", "price": c} for d, c in rows], 1500)
        # previous session close (baseline for 1D)
        prev = None
        if rng == "1D" and pts:
            day0 = (_dt(pts[0]["t"]) or datetime.now(timezone.utc)).astimezone(market_tz(ex)).date()
            closes = await self.daily(client, sym, day0 - timedelta(days=10))
            older = [c for d, c in closes if d < day0.isoformat()]
            prev = older[-1] if older else None
        return {
            "symbol": sym, "range": rng, "intraday": intraday, "market": country(ex),
            "prevClose": prev, "points": pts,
        }
