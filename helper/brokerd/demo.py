"""Realistic fake data so the app is usable before any account is connected."""
from __future__ import annotations

import math
import random
from datetime import datetime, timedelta, timezone

from .models import BrokerSnapshot, Leg, Quote

# symbol, name, base price, toss (qty, avg), ibkr (qty, avg)
_BOOK = [
    ("NVDA", "NVIDIA", 182.0, (40, 121.4), (65, 98.2)),
    ("AAPL", "Apple", 238.0, (25, 196.1), (30, 182.5)),
    ("MSFT", "Microsoft", 512.0, (8, 401.0), (12, 436.9)),
    ("VOO", "Vanguard S&P 500 ETF", 598.0, None, (45, 489.3)),
    ("QQQ", "Invesco QQQ Trust", 571.0, (10, 455.2), (15, 470.8)),
    ("TSLA", "Tesla", 402.0, (15, 268.9), None),
    ("GOOGL", "Alphabet A", 251.0, (20, 172.4), (10, 160.0)),
    ("AMZN", "Amazon", 223.0, None, (28, 185.6)),
    ("PLTR", "Palantir", 168.0, (50, 61.3), None),
]


class Demo:
    def __init__(self) -> None:
        self.rng = random.Random(42)
        self.prices = {s: p for s, _, p, _, _ in _BOOK}
        self.prev = {s: p * (1 + self.rng.uniform(-0.025, 0.02)) for s, _, p, _, _ in _BOOK}
        self.usd_krw = 1392.4
        self.usd_sgd = 1.3018

    def tick(self) -> None:
        for s in self.prices:
            self.prices[s] *= 1 + self.rng.gauss(0, 0.0006)

    def snapshots(self) -> list[BrokerSnapshot]:
        now = datetime.now(timezone.utc)
        toss = BrokerSnapshot("toss", "토스증권", "ok", "demo", now, cash={"USD": 1240.55, "KRW": 382000})
        ibkr = BrokerSnapshot("ibkr", "IBKR", "ok", "demo", now, cash={"USD": 3120.10, "SGD": 2450.00})
        ibkr.fx_to_usd = {"SGD": 1 / self.usd_sgd}
        toss.fx_to_usd = {"KRW": 1 / self.usd_krw}
        for s, name, _, t, i in _BOOK:
            for snap, pos in ((toss, t), (ibkr, i)):
                if pos:
                    snap.legs.append(Leg(snap.broker, s, name, "US", "USD", pos[0], pos[1]))
        return [toss, ibkr]

    def quotes(self) -> dict[str, Quote]:
        now = datetime.now(timezone.utc)
        return {s: Quote(p, "USD", now, self.prev[s], "demo") for s, p in self.prices.items()}

    def history(self, days: int, intraday: bool) -> list[dict]:
        """Smooth synthetic equity curve ending near the current demo value."""
        end_value = sum(
            (t[0] if t else 0) * p + (i[0] if i else 0) * p
            for s, _, p, t, i in [(b[0], b[1], self.prices[b[0]], b[3], b[4]) for b in _BOOK]
        )
        rng = random.Random(7)
        n = days * (78 if intraday else 1)
        step = timedelta(minutes=5) if intraday else timedelta(days=1)
        now = datetime.now(timezone.utc)
        vals, v = [], 1.0
        for _ in range(n):
            v *= 1 + rng.gauss(0.0006 if not intraday else 0.00002, 0.012 if not intraday else 0.0012)
            vals.append(v)
        scale = end_value / vals[-1]
        cost_end = end_value * 0.72
        pts = []
        for k, val in enumerate(vals):
            frac = k / max(1, n - 1)
            pts.append(
                {
                    "t": (now - step * (n - 1 - k)).isoformat(),
                    "valueUSD": round(val * scale, 2),
                    "costUSD": round(cost_end * (0.55 + 0.45 * math.sqrt(frac)), 2),
                }
            )
        return pts
