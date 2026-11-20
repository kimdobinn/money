"""KRW (원화) cost basis for 토스 USD holdings, matching the Toss app's 원화 평단.

Toss computes the KRW average cost as a moving average where each buy is valued
at the USD→KRW *buy rate* (`rate` of GET /exchange-rate) at the transaction's
processing time. (The transaction's own `exchangeRate` field is a different rate.)
Verified: GOOG 6주 @ $284.65, rate 1342 at 2026-11-10T06:59+09:00 → 382,000원 (Toss app).
"""
from __future__ import annotations

import logging
from collections import defaultdict
from datetime import datetime
from itertools import groupby

from .connectors.toss import TossClient, _f
from .models import norm_symbol

log = logging.getLogger("brokerd.fxcost")
TYPES = ["BUY", "SELL", "SECURITIES_TRANSFER_IN", "SECURITIES_TRANSFER_OUT"]


def _key(t: dict) -> str:
    return t.get("transactionTime") or (t["settlementDate"] + "T23:59:59+09:00")


def _ordered(tx: list[dict]) -> list[dict]:
    """Chronological; settlement timestamps often tie for a same-day sell+buy.
    Within a tie, sells go first (Toss's averages match that), unless holdings
    would go negative — then buys first."""
    out = []
    held: dict[str, float] = defaultdict(float)
    for _, grp in groupby(sorted(tx, key=_key), key=_key):
        grp = list(grp)
        by_sym = defaultdict(list)
        for t in grp:
            by_sym[t["symbol"]].append(t)
        for sym, ts in by_sym.items():
            sells = sum(_f(t["quantity"]) or 0 for t in ts if t["transactionType"] in ("SELL", "SECURITIES_TRANSFER_OUT"))
            sells_first = held[sym] + 1e-9 >= sells
            ts.sort(key=lambda t: (t["transactionType"] in ("BUY", "SECURITIES_TRANSFER_IN")) == sells_first)
            for t in ts:
                q = _f(t["quantity"]) or 0
                held[sym] += q if t["transactionType"] in ("BUY", "SECURITIES_TRANSFER_IN") else -q
                out.append(t)
    return out


def _active_buys(tx: list[dict]) -> list[dict]:
    """Buys that still affect the current average (since each symbol last hit zero)."""
    held: dict[str, float] = defaultdict(float)
    active: dict[str, list[dict]] = defaultdict(list)
    for t in tx:
        s, q, typ = t["symbol"], _f(t["quantity"]) or 0, t["transactionType"]
        if typ in ("BUY", "SECURITIES_TRANSFER_IN"):
            held[s] += q
            if typ == "BUY":
                active[s].append(t)
        else:
            held[s] -= q
            if held[s] <= 1e-9:
                held[s] = 0.0
                active[s] = []
    return [t for ts in active.values() for t in ts]


class KRWCost:
    def __init__(self, store):
        self.store = store
        self.by_symbol: dict[str, dict] = {}
        self.computed_at: datetime | None = None
        self._rates: dict[str, float] = dict(store.fx_hist_all())

    async def _rate_at(self, client: TossClient, ts: str | None, now_rate: float) -> float:
        if not ts:
            return now_rate  # unsettled: no time yet → current rate
        minute = ts[:16]
        if minute not in self._rates:
            res = await client._get(
                "/api/v1/exchange-rate", "MARKET_INFO",
                {"baseCurrency": "USD", "quoteCurrency": "KRW", "dateTime": ts},
            )
            rate = _f((res or {}).get("rate"))
            if not rate:
                return now_rate
            self._rates[minute] = rate
            self.store.fx_hist_put(minute, rate)
        return self._rates[minute]

    async def compute(self, client: TossClient, now_rate: float) -> None:
        raw = await client.transactions(TYPES)
        tx = [
            t for t in raw
            if t.get("currency") == "USD" and t.get("symbol") and t.get("assetClass") in (None, "STOCK")
            and not t.get("isCancellation")
        ]
        for t in tx:
            t["symbol"] = norm_symbol(t["symbol"])
        tx = _ordered(tx)
        need = _active_buys(tx)
        for t in need:  # fills the rate cache (≈3 req/s, cached forever in SQLite)
            await self._rate_at(client, t.get("transactionTime"), now_rate)

        state: dict[str, list[float]] = defaultdict(lambda: [0.0, 0.0, 0.0])  # qty, usd, krw
        for t in tx:
            s, q, typ = t["symbol"], _f(t["quantity"]) or 0, t["transactionType"]
            p = state[s]
            if typ == "BUY":
                amt = _f(t.get("amount")) or (q * (_f(t.get("filledPrice")) or 0))
                ts = t.get("transactionTime")
                rate = self._rates.get(ts[:16]) if ts else now_rate
                rate = rate or _f(t.get("exchangeRate")) or now_rate
                p[0] += q; p[1] += amt; p[2] += amt * rate
            elif typ == "SECURITIES_TRANSFER_IN":
                if p[0] > 0:
                    p[1] += p[1] / p[0] * q; p[2] += p[2] / p[0] * q
                p[0] += q
            else:
                if p[0] > 0:
                    keep = max(0.0, 1 - q / p[0])
                    p[1] *= keep; p[2] *= keep
                p[0] -= q
                if p[0] <= 1e-9:
                    p[:] = [0.0, 0.0, 0.0]
        self.by_symbol = {
            s: {"qty": q, "avgUSD": u / q, "avgKRW": k / q, "costKRW": k}
            for s, (q, u, k) in state.items() if q > 1e-9
        }
        self.computed_at = datetime.now()
        log.info("KRW cost basis computed for %d symbols (%d rate lookups cached)", len(self.by_symbol), len(self._rates))
