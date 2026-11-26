from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class Leg:
    """One broker's holding of one instrument."""

    broker: str  # "toss" | "ibkr"
    symbol: str  # normalized, e.g. "BRK.B", "005930"
    name: str
    market: str  # "US" | "KR" | exchange code for others
    currency: str  # trading currency
    quantity: float
    avg_cost: float  # per share, trading currency
    last_price: float | None = None  # broker-reported (may be delayed)
    prev_close: float | None = None


@dataclass
class BrokerSnapshot:
    broker: str
    name: str
    status: str = "disabled"  # ok | stale | error | disabled | connecting
    source: str = ""  # api | gateway | flex | demo
    as_of: datetime | None = None
    legs: list[Leg] = field(default_factory=list)
    cash: dict[str, float] = field(default_factory=dict)  # currency -> amount
    message: str | None = None
    fx_to_usd: dict[str, float] = field(default_factory=dict)  # 1 unit ccy = x USD
    cached: bool = False  # restored from the last good snapshot on disk
    busy: str | None = None  # background work in progress, e.g. "Flex 리포트 받는 중"


@dataclass
class Quote:
    price: float
    currency: str
    ts: datetime | None = None
    prev_close: float | None = None
    source: str = "toss"


def norm_symbol(sym: str) -> str:
    return sym.strip().upper().replace(" ", ".").replace("/", ".")
