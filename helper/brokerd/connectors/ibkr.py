"""Interactive Brokers: IB Gateway (live, read-only) + Flex Web Service (daily fallback)."""
from __future__ import annotations

import asyncio
import time
import logging
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

import httpx

from ..config import FLEX_CACHE_PATH
from ..models import BrokerSnapshot, Leg, norm_symbol

log = logging.getLogger("brokerd.ibkr")
NAME = "IBKR"


def _f(v) -> float | None:
    try:
        return float(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


def _market(currency: str, exchange: str) -> str:
    if currency == "USD":
        return "US"
    if currency == "KRW":
        return "KR"
    return exchange or currency


# --------------------------------------------------------------------------
# IB Gateway (TWS API) via ib_async
# --------------------------------------------------------------------------
class GatewayConnector:
    def __init__(self, host: str, port: int, client_id: int):
        from ib_async import IB  # imported lazily: heavy

        self.ib = IB()
        self.host, self.port, self.client_id = host, port, client_id
        self.message: str | None = "IB Gateway 연결 대기 중"
        self._stop = False
        self._wake = asyncio.Event()
        self._attempts = 0

    async def _nap(self, seconds: float) -> bool:
        """Sleep, but return early (True) when retry() wakes us."""
        try:
            await asyncio.wait_for(self._wake.wait(), timeout=seconds)
            return True
        except asyncio.TimeoutError:
            return False
        finally:
            self._wake.clear()

    async def retry(self, wait: float = 15) -> bool:
        """Drop the current session and reconnect now (e.g. after switching networks).
        Returns True once account data has arrived again."""
        if self.ib.isConnected():
            try:
                self.ib.disconnect()
            except Exception:  # noqa: BLE001
                pass
        self.message = "IB Gateway 다시 연결 중…"
        start = self._attempts
        self._wake.set()
        end = time.monotonic() + wait
        while time.monotonic() < end:
            await asyncio.sleep(0.5)
            if self.snapshot():
                return True
            if self._attempts > start and not self.ib.isConnected():
                return False  # connect attempt failed — no point waiting longer
        return False

    @property
    def connected(self) -> bool:
        return self.ib.isConnected()

    async def run(self):
        """Connect and keep reconnecting. readonly=True: no order capability."""
        backoff = 5
        while not self._stop:
            if not self.ib.isConnected():
                try:
                    await self.ib.connectAsync(
                        self.host, self.port, clientId=self.client_id, readonly=True, timeout=10
                    )
                    self.ib.reqMarketDataType(3)  # delayed is fine; Toss provides live prices
                    self.message = None
                    backoff = 5
                    log.info("IB Gateway connected %s:%s", self.host, self.port)
                    self._attempts += 1
                except Exception as e:  # noqa: BLE001
                    self.message = (
                        "IB Gateway에 연결할 수 없습니다 — Gateway가 실행·로그인 상태인지, "
                        f"API 포트({self.port})가 열려 있는지 확인하세요"
                    )
                    log.info("gateway connect failed: %s", e)
                    self._attempts += 1
                    try:
                        self.ib.disconnect()
                    except Exception:  # noqa: BLE001
                        pass
                    if await self._nap(backoff):
                        backoff = 5
                    else:
                        backoff = min(backoff * 2, 60)
                    continue
            await self._nap(5)

    def stop(self):
        self._stop = True
        try:
            self.ib.disconnect()
        except Exception:  # noqa: BLE001
            pass

    def snapshot(self) -> BrokerSnapshot | None:
        if not self.ib.isConnected():
            return None
        legs: list[Leg] = []
        for p in self.ib.portfolio():
            c = p.contract
            if c.secType != "STK" or not p.position:
                continue
            legs.append(
                Leg(
                    broker="ibkr",
                    symbol=norm_symbol(c.localSymbol or c.symbol) if c.currency != "USD" else norm_symbol(c.symbol),
                    name=c.symbol,
                    market=_market(c.currency, c.primaryExchange or c.exchange),
                    currency=c.currency,
                    quantity=float(p.position),
                    avg_cost=float(p.averageCost),
                    last_price=_f(p.marketPrice) if p.marketPrice and p.marketPrice > 0 else None,
                )
            )
        cash: dict[str, float] = {}
        rate_to_base: dict[str, float] = {}
        for v in self.ib.accountValues():
            # some accounts report per-currency ledger rows as "$LEDGER-CashBalance" etc.
            tag = v.tag.removeprefix("$LEDGER-")
            if v.currency in ("BASE", ""):
                continue
            if tag == "CashBalance":
                cash[v.currency] = _f(v.value) or 0.0  # same row may arrive with and without prefix
            elif tag == "ExchangeRate":
                r = _f(v.value)
                if r:
                    rate_to_base[v.currency] = r
        fx_to_usd = {}
        if "USD" in rate_to_base:
            usd = rate_to_base["USD"]
            fx_to_usd = {ccy: r / usd for ccy, r in rate_to_base.items()}
        if not legs and not cash and not self.ib.accountValues():
            return None  # connected but account data not loaded yet
        return BrokerSnapshot(
            broker="ibkr",
            name=NAME,
            status="ok",
            source="gateway",
            as_of=datetime.now(timezone.utc),
            legs=legs,
            cash={k: v for k, v in cash.items() if abs(v) > 0.005},
            fx_to_usd=fx_to_usd,
        )


# --------------------------------------------------------------------------
# Flex Web Service
# --------------------------------------------------------------------------
FLEX_BASE = "https://ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService"


class FlexError(Exception):
    pass


def _flex_date(s: str | None) -> str | None:
    """Flex dates are yyyyMMdd by default; also accept yyyy-MM-dd."""
    if not s:
        return None
    s = s.split(";")[0].split(",")[0].strip()
    if len(s) == 8 and s.isdigit():
        return f"{s[:4]}-{s[4:6]}-{s[6:]}"
    return s[:10]


class FlexConnector:
    def __init__(self, token: str, query_id: str):
        self.token, self.query_id = token, query_id
        self.xml: ET.Element | None = None
        self.message: str | None = None
        self.fetching = False
        self.fetched_at: datetime | None = None
        self._load_cache()

    def _load_cache(self):
        if FLEX_CACHE_PATH.exists():
            try:
                self.xml = ET.fromstring(FLEX_CACHE_PATH.read_bytes())
                self.fetched_at = datetime.fromtimestamp(FLEX_CACHE_PATH.stat().st_mtime, timezone.utc)
            except ET.ParseError:
                self.xml = None

    async def fetch(self) -> None:
        async with httpx.AsyncClient(timeout=60, headers={"User-Agent": "brokers-dashboard/1.0"}) as http:
            r = await http.get(f"{FLEX_BASE}/SendRequest", params={"t": self.token, "q": self.query_id, "v": 3})
            root = ET.fromstring(r.content)
            if root.findtext("Status") != "Success":
                raise FlexError(f"{root.findtext('ErrorCode')}: {root.findtext('ErrorMessage')}")
            ref = root.findtext("ReferenceCode")
            url = root.findtext("Url") or f"{FLEX_BASE}/GetStatement"
            for _ in range(20):
                await asyncio.sleep(5)
                try:
                    r = await http.get(url, params={"t": self.token, "q": ref, "v": 3})
                except httpx.ConnectError:
                    if url == f"{FLEX_BASE}/GetStatement":
                        raise
                    # the returned host (e.g. gdcdyn.…) may not resolve on some networks
                    log.info("flex url %s unreachable; using %s", url, FLEX_BASE)
                    url = f"{FLEX_BASE}/GetStatement"
                    r = await http.get(url, params={"t": self.token, "q": ref, "v": 3})
                if b"<FlexQueryResponse" in r.content[:500]:
                    FLEX_CACHE_PATH.write_bytes(r.content)
                    self.xml = ET.fromstring(r.content)
                    self.fetched_at = datetime.now(timezone.utc)
                    self.message = None
                    log.info("flex statement fetched (%d bytes)", len(r.content))
                    return
                root = ET.fromstring(r.content)
                code = root.findtext("ErrorCode")
                if code not in ("1019", "1018", "1021"):  # in progress / too many / retry
                    raise FlexError(f"{code}: {root.findtext('ErrorMessage')}")
            raise FlexError("statement generation timed out")

    def _statements(self):
        return [] if self.xml is None else self.xml.iter("FlexStatement")

    def snapshot(self) -> BrokerSnapshot | None:
        if self.xml is None:
            return None
        legs: list[Leg] = []
        cash: dict[str, float] = {}
        fx_base: dict[str, float] = {}
        as_of = None
        for st in self._statements():
            as_of = _flex_date(st.get("toDate")) or as_of
            rows = list(st.iter("OpenPosition"))
            has_summary = any(r.get("levelOfDetail") == "SUMMARY" for r in rows)
            for r in rows:
                if has_summary and r.get("levelOfDetail") != "SUMMARY":
                    continue
                if r.get("assetCategory") not in (None, "STK"):
                    continue
                qty = _f(r.get("position")) or 0.0
                if not qty:
                    continue
                ccy = r.get("currency") or "USD"
                if (fx := _f(r.get("fxRateToBase"))):
                    fx_base[ccy] = fx
                legs.append(
                    Leg(
                        broker="ibkr",
                        symbol=norm_symbol(r.get("symbol", "")),
                        name=(r.get("description") or r.get("symbol") or "").title(),
                        market=_market(ccy, r.get("listingExchange") or ""),
                        currency=ccy,
                        quantity=qty,
                        avg_cost=_f(r.get("costBasisPrice")) or _f(r.get("openPrice")) or 0.0,
                        last_price=_f(r.get("markPrice")),
                    )
                )
            for c in st.iter("CashReportCurrency"):
                ccy = c.get("currency")
                if ccy and ccy != "BASE_SUMMARY":
                    v = _f(c.get("endingCash")) or 0.0
                    if abs(v) > 0.005:
                        cash[ccy] = cash.get(ccy, 0.0) + v
            for c in st.iter("ConversionRate"):
                if (rate := _f(c.get("rate"))) and c.get("fromCurrency"):
                    fx_base[c.get("fromCurrency")] = rate
        fx_to_usd = {}
        if "USD" in fx_base:
            fx_to_usd = {k: v / fx_base["USD"] for k, v in fx_base.items()}
        snap_time = self.fetched_at
        if as_of:
            try:
                snap_time = datetime.fromisoformat(as_of).replace(tzinfo=timezone.utc)
            except ValueError:
                pass
        return BrokerSnapshot(
            broker="ibkr",
            name=NAME,
            status="stale",
            source="flex",
            as_of=snap_time,
            legs=legs,
            cash=cash,
            fx_to_usd=fx_to_usd,
        )

    def trades(self) -> list[dict]:
        """Stock trades from the cached statement, normalized."""
        out = []
        for st in self._statements():
            rows = [r for r in st.iter("Trade") if r.get("assetCategory") in (None, "STK")]
            levels = {r.get("levelOfDetail") for r in rows}
            want = "EXECUTION" if "EXECUTION" in levels else ("ORDER" if "ORDER" in levels else None)
            for r in rows:
                if want and r.get("levelOfDetail") != want:
                    continue
                qty = _f(r.get("quantity"))
                d = _flex_date(r.get("tradeDate") or r.get("dateTime"))
                if not qty or not d:
                    continue
                out.append(
                    {
                        "id": "ibkr:" + (r.get("tradeID") or r.get("ibExecID") or f"{d}:{r.get('symbol')}:{qty}:{r.get('tradePrice')}"),
                        "broker": "ibkr",
                        "symbol": norm_symbol(r.get("symbol", "")),
                        "currency": r.get("currency") or "USD",
                        "qty": qty,  # signed: negative = sell
                        "price": _f(r.get("tradePrice")),
                        "date": d,
                    }
                )
        return out
