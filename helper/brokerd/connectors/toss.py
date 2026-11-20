"""토스증권 Open API (read-only usage). Spec: openapi.tossinvest.com v1.2.x.

Only GET endpoints plus the OAuth token call are used. Order endpoints are
intentionally not implemented.
"""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo

import httpx

from ..models import BrokerSnapshot, Leg, Quote, norm_symbol

log = logging.getLogger("brokerd.toss")
BASE = "https://openapi.tossinvest.com"


class TossError(Exception):
    def __init__(self, status: int, code: str, message: str = ""):
        super().__init__(f"{status} {code} {message}".strip())
        self.status, self.code, self.message = status, code, message


def _f(v) -> float | None:
    if v is None or v == "":
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _dt(v) -> datetime | None:
    if not v:
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None


class _Limiter:
    """Simple per-group min-interval limiter (Toss limits are per second)."""

    def __init__(self, per_sec: float):
        self.interval = 1.0 / per_sec
        self.lock = asyncio.Lock()
        self.last = 0.0

    async def wait(self):
        async with self.lock:
            delta = time.monotonic() - self.last
            if delta < self.interval:
                await asyncio.sleep(self.interval - delta)
            self.last = time.monotonic()


class TossClient:
    def __init__(self, client_id: str, client_secret: str):
        self.client_id = client_id
        self.client_secret = client_secret
        self.http = httpx.AsyncClient(base_url=BASE, timeout=15)
        self._token: str | None = None
        self._token_exp = 0.0
        self._token_lock = asyncio.Lock()
        self.account_seq: int | None = None
        # Rate-limit groups (kept a bit under the documented limits)
        self.lim = {
            "AUTH": _Limiter(2),
            "ACCOUNT": _Limiter(0.9),
            "ASSET": _Limiter(4),
            "TRANSACTION": _Limiter(4),
            "MARKET_INFO": _Limiter(2),
            "MARKET_DATA": _Limiter(10),
            "MARKET_DATA_CHART": _Limiter(15),
            "ORDER_INFO": _Limiter(2),
        }

    async def close(self):
        await self.http.aclose()

    async def _ensure_token(self) -> str:
        async with self._token_lock:
            if self._token and time.time() < self._token_exp:
                return self._token
            await self.lim["AUTH"].wait()
            r = await self.http.post(
                "/oauth2/token",
                data={
                    "grant_type": "client_credentials",
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                },
            )
            if r.status_code != 200:
                try:
                    j = r.json()
                    code = j.get("error") or "token-error"
                    msg = j.get("error_description") or ""
                except Exception:
                    code, msg = "token-error", r.text[:200]
                if r.status_code == 403 or code == "access_denied":
                    code = "ip-not-allowed"
                raise TossError(r.status_code, code, msg)
            j = r.json()
            self._token = j["access_token"]
            self._token_exp = time.time() + max(60, int(j.get("expires_in", 3600)) - 120)
            log.info("toss token issued (expires_in=%s)", j.get("expires_in"))
            return self._token

    async def _get(self, path: str, group: str, params: dict | None = None, account: bool = False):
        for attempt in range(2):
            token = await self._ensure_token()
            headers = {"Authorization": f"Bearer {token}"}
            if account:
                if self.account_seq is None:
                    await self._load_account()
                headers["X-Tossinvest-Account"] = str(self.account_seq)
            await self.lim[group].wait()
            r = await self.http.get(path, params=params, headers=headers)
            if r.status_code == 200:
                return r.json().get("result")
            try:
                err = r.json().get("error", {})
                code, msg = err.get("code", "unknown"), err.get("message", "")
            except Exception:
                code, msg = "unknown", r.text[:200]
            if r.status_code == 401 and attempt == 0:
                self._token = None  # expired/revoked -> reissue once
                continue
            if r.status_code == 429 and attempt == 0:
                await asyncio.sleep(1.2)
                continue
            raise TossError(r.status_code, code, msg)

    async def _load_account(self):
        token = await self._ensure_token()
        await self.lim["ACCOUNT"].wait()
        r = await self.http.get("/api/v1/accounts", headers={"Authorization": f"Bearer {token}"})
        if r.status_code != 200:
            err = (r.json() or {}).get("error", {}) if r.headers.get("content-type", "").startswith("application/json") else {}
            raise TossError(r.status_code, err.get("code", "account-error"), err.get("message", ""))
        accts = r.json().get("result") or []
        brokerage = [a for a in accts if a.get("accountType") == "BROKERAGE"] or accts
        if not brokerage:
            raise TossError(404, "account-not-found", "종합매매 계좌가 없습니다")
        self.account_seq = int(brokerage[0]["accountSeq"])

    # ---- endpoints -----------------------------------------------------
    async def holdings(self) -> dict:
        return await self._get("/api/v1/holdings", "ASSET", account=True)

    async def buying_power(self, currency: str) -> float | None:
        res = await self._get("/api/v1/buying-power", "ORDER_INFO", {"currency": currency}, account=True)
        return _f((res or {}).get("cashBuyingPower"))

    async def prices(self, symbols: list[str]) -> list[dict]:
        out: list[dict] = []
        for i in range(0, len(symbols), 200):
            chunk = symbols[i : i + 200]
            res = await self._get("/api/v1/prices", "MARKET_DATA", {"symbols": ",".join(chunk)})
            out.extend(res or [])
        return out

    async def usd_krw(self) -> float | None:
        res = await self._get(
            "/api/v1/exchange-rate", "MARKET_INFO", {"baseCurrency": "USD", "quoteCurrency": "KRW"}
        )
        return _f((res or {}).get("midRate")) or _f((res or {}).get("rate"))

    async def daily_candles(self, symbol: str, count: int = 200, before: str | None = None) -> dict:
        params = {"symbol": symbol, "interval": "1d", "count": count, "adjusted": "true"}
        if before:
            params["before"] = before
        return await self._get("/api/v1/candles", "MARKET_DATA_CHART", params) or {}

    async def transactions(self, types: list[str], since: date | None = None) -> list[dict]:
        out, cursor = [], None
        while True:
            params: dict = {"transactionTypes": ",".join(types), "limit": 100}
            if since:
                params["from"] = since.isoformat()
            if cursor:
                params["cursor"] = cursor
            res = await self._get("/api/v1/transactions", "TRANSACTION", params, account=True) or {}
            out.extend(res.get("transactions") or [])
            cursor = res.get("nextCursor")
            if not res.get("hasNext") or not cursor:
                return out


class TossConnector:
    """Keeps a fresh BrokerSnapshot for 토스증권 and serves live quotes."""

    NAME = "토스증권"

    def __init__(self, client: TossClient):
        self.client = client
        self.snapshot = BrokerSnapshot(broker="toss", name=self.NAME, status="connecting", source="api")
        self.usd_krw: float | None = None
        self.last_error: TossError | None = None
        self._cash_at = 0.0

    def _fail(self, e: Exception):
        self.snapshot.status = "error" if not self.snapshot.legs else "stale"
        if isinstance(e, TossError):
            self.last_error = e
            if e.code == "ip-not-allowed":
                self.snapshot.message = "허용 IP가 아닙니다 — 토스 WTS > 설정 > Open API > 허용 IP 관리에 현재 IP를 등록하세요"
            elif e.code in ("invalid_client", "token-error"):
                self.snapshot.message = "client_id / client_secret 을 확인하세요"
            else:
                self.snapshot.message = f"토스 API 오류: {e.code} {e.message}".strip()
        else:
            self.snapshot.message = f"토스 연결 실패: {type(e).__name__}"
        log.warning("toss refresh failed: %r", e)

    async def refresh_holdings(self) -> None:
        try:
            res = await self.client.holdings()
            legs = []
            for it in (res or {}).get("items") or []:
                qty = _f(it.get("quantity")) or 0.0
                if qty == 0:
                    continue
                last = _f(it.get("lastPrice"))
                dpl = _f((it.get("dailyProfitLoss") or {}).get("amount"))
                prev = (last - dpl / qty) if (last is not None and dpl is not None and qty) else None
                legs.append(
                    Leg(
                        broker="toss",
                        symbol=norm_symbol(it.get("symbol", "")),
                        name=it.get("name") or it.get("symbol", ""),
                        market=it.get("marketCountry") or "US",
                        currency=it.get("currency") or "USD",
                        quantity=qty,
                        avg_cost=_f(it.get("averagePurchasePrice")) or 0.0,
                        last_price=last,
                        prev_close=prev,
                    )
                )
            if time.time() - self._cash_at > 60:
                cash = {}
                for ccy in ("USD", "KRW"):
                    v = await self.client.buying_power(ccy)
                    if v:
                        cash[ccy] = v
                self.snapshot.cash = cash
                self._cash_at = time.time()
            self.snapshot.legs = legs
            self.snapshot.status = "ok"
            self.snapshot.message = None
            self.snapshot.as_of = datetime.now(timezone.utc)
            self.last_error = None
        except Exception as e:  # noqa: BLE001
            self._fail(e)

    async def refresh_fx(self) -> None:
        try:
            v = await self.client.usd_krw()
            if v:
                self.usd_krw = v
                self.snapshot.fx_to_usd = {"KRW": 1.0 / v}
        except Exception as e:  # noqa: BLE001
            log.warning("toss fx failed: %s", e)

    async def quotes(self, symbols: list[str]) -> dict[str, Quote]:
        if not symbols:
            return {}
        out: dict[str, Quote] = {}
        try:
            for p in await self.client.prices(symbols):
                price = _f(p.get("lastPrice"))
                if price is None:
                    continue
                out[norm_symbol(p["symbol"])] = Quote(
                    price=price, currency=p.get("currency") or "USD", ts=_dt(p.get("timestamp"))
                )
        except TossError as e:
            if e.code == "stock-not-found" and len(symbols) > 1:
                # One unknown ticker (e.g. SGX listing) fails the batch; retry singly.
                for s in symbols:
                    try:
                        out.update(await self.quotes([s]))
                    except Exception:  # noqa: BLE001
                        pass
            else:
                log.warning("toss quotes failed: %s", e)
        except Exception as e:  # noqa: BLE001
            log.warning("toss quotes failed: %s", e)
        return out

    async def prev_close(self, symbol: str, market: str, quote_ts: datetime | None) -> float | None:
        """Previous session close from daily candles.

        Candles are newest-first. If the newest candle is the same session as the
        latest trade, the previous close is the second candle.
        """
        try:
            res = await self.client.daily_candles(symbol, count=3)
        except Exception as e:  # noqa: BLE001
            log.info("candles failed for %s: %s", symbol, e)
            return None
        candles = res.get("candles") or []
        if not candles:
            return None
        newest = candles[0]
        newest_day = (newest.get("timestamp") or "")[:10]
        tz = ZoneInfo("Asia/Seoul" if market == "KR" else "America/New_York")
        q_day = quote_ts.astimezone(tz).date().isoformat() if quote_ts else None
        if q_day and newest_day == q_day and len(candles) > 1:
            return _f(candles[1].get("closePrice"))
        if q_day and newest_day != q_day:
            return _f(newest.get("closePrice"))
        return _f(candles[1].get("closePrice")) if len(candles) > 1 else None
