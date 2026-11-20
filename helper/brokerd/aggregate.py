"""Combine broker snapshots + live quotes into one portfolio view."""
from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone

from .models import BrokerSnapshot, Quote

BROKER_ORDER = {"toss": 0, "ibkr": 1}


def _r(v, n=4):
    return None if v is None else round(v, n)


def build(
    snaps: list[BrokerSnapshot],
    quotes: dict[str, Quote],
    fx_to_usd: dict[str, float],
    *,
    demo: bool,
    display_currency: str,
    menu_bar_style: str,
    color_style: str = "kr",
    krw_cost: dict | None = None,
    usd_krw: float | None = None,
) -> dict:
    def usd(amount: float, ccy: str) -> float:
        rate = fx_to_usd.get(ccy)
        return amount * rate if rate else 0.0

    groups: dict[tuple[str, str], list] = defaultdict(list)
    for s in snaps:
        for leg in s.legs:
            groups[(leg.symbol, leg.currency)].append(leg)

    positions = []
    broker_mv = defaultdict(float)
    broker_cost = defaultdict(float)
    broker_day = defaultdict(float)
    # 원화 기준 (Toss only): cost at historical FX vs value at current FX
    krw = {"cost": 0.0, "value": 0.0, "pricePL": 0.0, "fxPL": 0.0, "complete": True, "any": False}
    for (sym, ccy), legs in groups.items():
        q = quotes.get(sym)
        qty = sum(l.quantity for l in legs)
        cost = sum(l.quantity * l.avg_cost for l in legs)
        last = q.price if q else next((l.last_price for l in legs if l.last_price), None)
        prev = (q.prev_close if q and q.prev_close else None) or next(
            (l.prev_close for l in legs if l.prev_close), None
        )
        name = next((l.name for l in legs if l.broker == "toss"), None) or legs[0].name
        mv = qty * last if last is not None else None
        day_chg = (last - prev) if (last is not None and prev) else None
        leg_out = []
        for l in sorted(legs, key=lambda x: BROKER_ORDER.get(x.broker, 9)):
            lmv = l.quantity * last if last is not None else None
            lcost = l.quantity * l.avg_cost
            if lmv is not None:
                broker_mv[l.broker] += usd(lmv, ccy)
            broker_cost[l.broker] += usd(lcost, ccy)
            if day_chg is not None:
                broker_day[l.broker] += usd(l.quantity * day_chg, ccy)
            k = _krw_leg(l, lmv, lcost, krw_cost, usd_krw, demo)
            if k:
                krw["any"] = True
                krw["cost"] += k["costKRW"]; krw["value"] += k["valueKRW"]
                krw["pricePL"] += k["pricePLKRW"]; krw["fxPL"] += k["fxPLKRW"]
            elif l.broker == "toss" and lmv is not None:
                krw["complete"] = False
            leg_out.append(
                {
                    **(k or {}),
                    "broker": l.broker,
                    "quantity": _r(l.quantity, 6),
                    "avgCost": _r(l.avg_cost),
                    "marketValue": _r(lmv, 2),
                    "costBasis": _r(lcost, 2),
                    "unrealizedPL": _r(lmv - lcost, 2) if lmv is not None else None,
                }
            )
        positions.append(
            {
                "symbol": sym,
                "name": name,
                "market": legs[0].market,
                "currency": ccy,
                "quantity": _r(qty, 6),
                "avgCost": _r(cost / qty) if qty else None,
                "lastPrice": _r(last),
                "prevClose": _r(prev),
                "priceSource": q.source if q else (legs[0].broker if last is not None else None),
                "priceTime": q.ts.isoformat() if q and q.ts else None,
                "marketValue": _r(mv, 2),
                "costBasis": _r(cost, 2),
                "unrealizedPL": _r(mv - cost, 2) if mv is not None else None,
                "unrealizedPLPct": _r((mv - cost) / cost, 6) if (mv is not None and cost) else None,
                "dayChange": _r(day_chg),
                "dayChangePct": _r(day_chg / prev, 6) if (day_chg is not None and prev) else None,
                "dayPL": _r(qty * day_chg, 2) if day_chg is not None else None,
                "marketValueUSD": _r(usd(mv, ccy), 2) if mv is not None else None,
                "legs": leg_out,
            }
        )

    total_mv = sum(p["marketValueUSD"] or 0 for p in positions)
    for p in positions:
        p["weight"] = _r((p["marketValueUSD"] or 0) / total_mv, 6) if total_mv else 0
    positions.sort(key=lambda p: -(p["marketValueUSD"] or 0))

    brokers = []
    total_cash = 0.0
    for s in sorted(snaps, key=lambda x: BROKER_ORDER.get(x.broker, 9)):
        cash_usd = sum(usd(v, c) for c, v in s.cash.items())
        total_cash += cash_usd
        brokers.append(
            {
                "id": s.broker,
                "name": s.name,
                "status": s.status,
                "source": s.source,
                "asOf": s.as_of.isoformat() if s.as_of else None,
                "message": s.message,
                "marketValueUSD": round(broker_mv[s.broker], 2),
                "costBasisUSD": round(broker_cost[s.broker], 2),
                "dayPLUSD": round(broker_day[s.broker], 2),
                "cash": {c: round(v, 2) for c, v in s.cash.items()},
                "cashUSD": round(cash_usd, 2),
                "positions": len(s.legs),
                "krw": _krw_summary(krw) if s.broker == "toss" else None,
            }
        )

    total_cost = sum(broker_cost.values())
    day_pl = sum(broker_day.values())
    prev_mv = total_mv - day_pl
    return {
        "asOf": datetime.now(timezone.utc).isoformat(),
        "demo": demo,
        "displayCurrency": display_currency,
        "menuBarStyle": menu_bar_style,
        "colorStyle": color_style,
        "fx": {
            "USDKRW": _r(1 / fx_to_usd["KRW"], 4) if fx_to_usd.get("KRW") else None,
            "USDSGD": _r(1 / fx_to_usd["SGD"], 6) if fx_to_usd.get("SGD") else None,
        },
        "totals": {
            "marketValueUSD": round(total_mv, 2),
            "costBasisUSD": round(total_cost, 2),
            "unrealizedPLUSD": round(total_mv - total_cost, 2),
            "unrealizedPLPct": _r((total_mv - total_cost) / total_cost, 6) if total_cost else None,
            "dayPLUSD": round(day_pl, 2),
            "dayPLPct": _r(day_pl / prev_mv, 6) if prev_mv else None,
            "cashUSD": round(total_cash, 2),
            "netWorthUSD": round(total_mv + total_cash, 2),
        },
        "brokers": brokers,
        "positions": positions,
    }


def _krw_leg(leg, lmv, lcost, krw_cost, usd_krw, demo) -> dict | None:
    """원화 기준 손익 for one Toss leg. USD legs need a KRW cost basis whose
    quantity matches the live holding; KRW legs are native."""
    if leg.broker != "toss" or lmv is None:
        return None
    if leg.currency == "KRW":
        return {"avgCostKRW": leg.avg_cost, "costKRW": lcost, "valueKRW": lmv, "plKRW": lmv - lcost,
                "plKRWPct": (lmv - lcost) / lcost if lcost else None, "pricePLKRW": lmv - lcost, "fxPLKRW": 0.0}
    if leg.currency != "USD" or not usd_krw:
        return None
    if demo:
        cost_krw = lcost * 1310.0  # demo: bought when USD was cheaper
    else:
        e = (krw_cost or {}).get(leg.symbol)
        if not e or abs(e["qty"] - leg.quantity) > 1e-6:
            return None
        cost_krw = e["costKRW"]
    value = lmv * usd_krw
    return {
        "avgCostKRW": round(cost_krw / leg.quantity, 2),
        "costKRW": round(cost_krw),
        "valueKRW": round(value),
        "plKRW": round(value - cost_krw),
        "plKRWPct": round((value - cost_krw) / cost_krw, 6) if cost_krw else None,
        "pricePLKRW": round((lmv - lcost) * usd_krw),
        "fxPLKRW": round(lcost * usd_krw - cost_krw),
    }


def _krw_summary(k: dict) -> dict | None:
    if not k["any"]:
        return None
    return {
        "costKRW": round(k["cost"]),
        "valueKRW": round(k["value"]),
        "plKRW": round(k["value"] - k["cost"]),
        "plPct": round((k["value"] - k["cost"]) / k["cost"], 6) if k["cost"] else None,
        "pricePLKRW": round(k["pricePL"]),
        "fxPLKRW": round(k["fxPL"]),
        "complete": k["complete"],
    }
