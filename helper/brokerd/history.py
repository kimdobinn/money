"""Backfill a daily equity curve from past trades + historical closes."""
from __future__ import annotations

import hashlib
import logging
from bisect import bisect_right
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .connectors.toss import TossClient, _f
from .models import norm_symbol

log = logging.getLogger("brokerd.history")
TOSS_TYPES = ["BUY", "SELL", "SECURITIES_TRANSFER_IN", "SECURITIES_TRANSFER_OUT"]
MAX_YEARS = 5


def _minus_business_days(d: date, n: int) -> date:
    while n > 0:
        d -= timedelta(days=1)
        if d.weekday() < 5:
            n -= 1
    return d


def normalize_toss(tx: list[dict]) -> list[dict]:
    out = []
    for t in tx:
        if t.get("assetClass") not in (None, "STOCK") or not t.get("symbol"):
            continue
        qty = _f(t.get("quantity"))
        if not qty:
            continue
        typ = t.get("transactionType")
        sign = 1 if typ in ("BUY", "SECURITIES_TRANSFER_IN") else -1
        if t.get("isCancellation"):
            sign = -sign
        settle = date.fromisoformat(t["settlementDate"])
        market = t.get("marketCountry") or "US"
        trade_day = _minus_business_days(settle, 2 if market == "KR" else 1)
        raw = "|".join(str(t.get(k)) for k in ("transactionType", "symbol", "settlementDate", "quantity", "amount", "transactionTime", "isCancellation", "settled"))
        out.append(
            {
                "id": "toss:" + hashlib.sha1(raw.encode()).hexdigest()[:20],
                "broker": "toss",
                "symbol": norm_symbol(t["symbol"]),
                "currency": t.get("currency") or ("KRW" if market == "KR" else "USD"),
                "qty": sign * qty,
                "price": _f(t.get("filledPrice")),
                "date": trade_day.isoformat(),
            }
        )
    return out


async def daily_closes(client: TossClient, symbol: str, start: date) -> list[tuple[str, float]]:
    rows: list[tuple[str, float]] = []
    before = None
    for _ in range(20):  # 20 * 200 bars ≈ 16 years max
        res = await client.daily_candles(symbol, count=200, before=before)
        candles = res.get("candles") or []
        for c in candles:
            close = _f(c.get("closePrice"))
            if close is not None:
                rows.append(((c.get("timestamp") or "")[:10], close))
        before = res.get("nextBefore")
        if not candles or not before or before[:10] < start.isoformat():
            break
    rows.sort()
    return rows


INTRADAY_DAYS = 31


async def _hourly_closes(client: TossClient, symbol: str, since: datetime) -> dict[int, float]:
    """Last 1-minute close of every hour since `since` (unix hour -> close)."""
    out: dict[int, float] = {}
    before = None
    for _ in range(400):
        res = await client.candles(symbol, "1m", 200, before=before)
        candles = res.get("candles") or []
        oldest = None
        for c in candles:
            ts = c.get("timestamp")
            px = _f(c.get("closePrice"))
            if not ts or px is None:
                continue
            t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            oldest = t
            # candle timestamp = end of minute; bucket into the hour it closes
            hour = int((t.timestamp() - 1) // 3600 * 3600)
            out.setdefault(hour, px)  # candles are newest-first -> first seen = last close of hour
        before = res.get("nextBefore")
        if not candles or not before or (oldest and oldest < since):
            break
    return out


async def backfill_intraday(engine, all_trades, current, trades_by) -> int:
    """Hourly equity curve for the last month from 1-minute candles (denser 1W/1M charts)."""
    client: TossClient = engine.toss.client
    since = datetime.now(timezone.utc) - timedelta(days=INTRADAY_DAYS)
    since_d = since.date().isoformat()
    fx = engine.fx_to_usd()
    syms = [
        k for k in set(current) | {(t[1], t[2]) for t in all_trades}
        if k[1] in fx and (current.get(k, 0) > 1e-9 or any(d >= since_d for d, _ in trades_by.get(k, [])))
    ]
    series: dict[tuple[str, str], dict[int, float]] = {}
    for key in syms:
        try:
            series[key] = await _hourly_closes(client, key[0], since)
        except Exception as e:  # noqa: BLE001
            log.info("no 1m candles for %s: %s", key[0], e)
    hours = sorted({h for s in series.values() for h in s if h >= since.timestamp()})
    ny = ZoneInfo("America/New_York")
    last: dict[tuple[str, str], float] = {}
    # seed carry-forward prices with the newest close before the window
    for key, s in series.items():
        older = [h for h in s if h < since.timestamp()]
        if older:
            last[key] = s[max(older)]
    rows = []
    for h in hours:
        d = datetime.fromtimestamp(h, ny).date().isoformat()
        total = 0.0
        for key, s in series.items():
            if h in s:
                last[key] = s[h]
            qty = current.get(key, 0.0) - sum(q for td, q in trades_by.get(key, []) if td > d)
            if qty > 1e-9 and key in last:
                total += qty * last[key] * fx[key[1]]
        if total > 0:
            rows.append((h, round(total, 2)))
    engine.store.put_hourly(rows)
    return len(rows)


async def backfill(engine) -> str:
    """Returns a human-readable summary. Raises on hard failure."""
    toss: TossClient | None = engine.toss.client if engine.toss else None
    trades: list[dict] = []
    if toss:
        trades += normalize_toss(await toss.transactions(TOSS_TYPES))
    if engine.flex:
        trades += engine.flex.trades()
    if trades:
        engine.store.save_trades(trades)

    all_trades = engine.store.all_trades()  # (broker, symbol, ccy, qty, date)
    current: dict[tuple[str, str], float] = defaultdict(float)
    for s in engine.broker_snapshots():
        for leg in s.legs:
            current[(leg.symbol, leg.currency)] += leg.quantity

    today = date.today()
    floor = today - timedelta(days=365 * MAX_YEARS)
    start = max(floor, min((date.fromisoformat(t[4]) for t in all_trades), default=today - timedelta(days=365)))

    syms = set(current) | {(t[1], t[2]) for t in all_trades}
    trades_by: dict[tuple[str, str], list[tuple[str, float]]] = defaultdict(list)
    for _, sym, ccy, qty, d in all_trades:
        trades_by[(sym, ccy)].append((d, qty))

    if not toss:
        return "토스 API가 없어 과거 시세를 가져올 수 없습니다 (히스토리는 오늘부터 기록됩니다)"

    fx = engine.fx_to_usd()
    closes: dict[tuple[str, str], tuple[list[str], list[float]]] = {}
    skipped = []
    for key in syms:
        sym, ccy = key
        if ccy not in fx:
            skipped.append(sym)
            continue
        try:
            rows = await daily_closes(toss, sym, start)
        except Exception as e:  # noqa: BLE001
            log.info("no candles for %s: %s", sym, e)
            skipped.append(sym)
            continue
        if rows:
            closes[key] = ([r[0] for r in rows], [r[1] for r in rows])

    days = sorted({d for ds, _ in closes.values() for d in ds if d >= start.isoformat()})
    out = []
    for d in days:
        total = 0.0
        for key, (ds, cs) in closes.items():
            qty = current.get(key, 0.0) - sum(q for td, q in trades_by.get(key, []) if td > d)
            if qty <= 1e-9:
                continue
            i = bisect_right(ds, d) - 1
            if i < 0:
                continue
            total += qty * cs[i] * fx[key[1]]
        out.append((d, round(total, 2)))
    engine.store.upsert_backfill(out)
    try:
        n_hours = await backfill_intraday(engine, all_trades, current, trades_by)
    except Exception as e:  # noqa: BLE001
        log.warning("intraday backfill failed: %r", e)
        n_hours = 0
    msg = f"{len(days)}일치 히스토리 복원 완료 (거래 {len(all_trades)}건"
    msg += f", 최근 한 달 시간별 {n_hours}개)" if n_hours else ")"
    if skipped:
        msg += f" · 시세 없음: {', '.join(sorted(set(skipped)))}"
    return msg
