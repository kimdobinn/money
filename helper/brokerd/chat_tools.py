"""Compact, LLM-friendly views of helper data. Pure functions on the JSON the API returns,
shared by the chat context builder (in the helper) and the MCP server (separate process)."""
from __future__ import annotations

from datetime import datetime


def _r(v, n=2):
    return round(v, n) if isinstance(v, (int, float)) else v


def portfolio_brief(p: dict) -> dict:
    t = p.get("totals") or {}
    return {
        "asOf": p.get("asOf"),
        "currencyNote": "All *USD amounts are US dollars. KRW figures are Korean won.",
        "fx": p.get("fx"),
        "totals": {k: _r(v) for k, v in t.items()},
        "brokers": [
            {
                "id": b["id"], "name": b["name"], "status": b["status"], "source": b["source"],
                "cached": b.get("cached"), "asOf": b.get("asOf"), "message": b.get("message"),
                "stocksUSD": _r(b["marketValueUSD"]), "cashUSD": _r(b["cashUSD"]), "cash": b.get("cash"),
                "costBasisUSD": _r(b["costBasisUSD"]),
                "unrealizedPLUSD": _r(b["marketValueUSD"] - b["costBasisUSD"]),
                "dayPLUSD": _r(b["dayPLUSD"]), "positions": b["positions"], "krwView": b.get("krw"),
            }
            for b in p.get("brokers", [])
        ],
        "positions": [
            {
                "symbol": x["symbol"], "name": x["name"], "market": x["market"], "currency": x["currency"],
                "quantity": x["quantity"], "avgCost": _r(x["avgCost"], 4), "lastPrice": x.get("lastPrice"),
                "prevClose": x.get("prevClose"), "marketValueUSD": _r(x.get("marketValueUSD")),
                "unrealizedPL": _r(x.get("unrealizedPL")), "unrealizedPLPct": _r(x.get("unrealizedPLPct"), 4),
                "dayChangePct": _r(x.get("dayChangePct"), 4), "dayPL": _r(x.get("dayPL")),
                "weight": _r(x.get("weight"), 4),
                "byBroker": [
                    {k: _r(v) for k, v in leg.items() if k in (
                        "broker", "quantity", "avgCost", "marketValue", "costBasis", "unrealizedPL",
                        "avgCostKRW", "plKRW", "plKRWPct", "pricePLKRW", "fxPLKRW")}
                    for leg in x.get("legs", [])
                ],
            }
            for x in p.get("positions", [])
        ],
    }


def history_brief(h: dict, max_points: int = 80) -> dict:
    pts = h.get("points") or []
    step = max(1, len(pts) // max_points)
    keep = pts[::step]
    if pts and keep[-1] is not pts[-1]:
        keep.append(pts[-1])
    rows = []
    for p in keep:
        inv = p.get("investedUSD")
        rows.append({
            "t": p["t"], "valueUSD": _r(p["valueUSD"]), "netInvestedUSD": _r(inv),
            "profitUSD": _r(p["valueUSD"] - inv) if inv is not None else None,
        })
    return {
        "range": h.get("range"),
        "note": "valueUSD = stock market value (cash excluded). netInvestedUSD = buys − sells to date. "
                "profitUSD = valueUSD − netInvestedUSD (realized + unrealized).",
        "points": rows,
    }


def chart_brief(c: dict, max_points: int = 80) -> dict:
    pts = c.get("points") or []
    step = max(1, len(pts) // max_points)
    keep = pts[::step]
    if pts and keep[-1] is not pts[-1]:
        keep.append(pts[-1])
    prices = [p["price"] for p in pts if p.get("price") is not None]
    return {
        "symbol": c.get("symbol"), "range": c.get("range"), "market": c.get("market"),
        "first": prices[0] if prices else None, "last": prices[-1] if prices else None,
        "high": max(prices) if prices else None, "low": min(prices) if prices else None,
        "points": [{"t": p["t"], "price": p["price"]} for p in keep],
    }


def watchlist_brief(w: dict) -> list[dict]:
    return [
        {k: (_r(v, 4) if isinstance(v, float) else v) for k, v in it.items() if k != "spark"}
        for it in w.get("items", [])
    ]


def context_block(p: dict, memories: list[dict], goal: dict | None) -> str:
    """Prepended to the first message of a conversation."""
    import json

    t = p.get("totals") or {}
    lines = [
        "<context>",
        f"Now: {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %Z')}",
        f"Net worth ≈ ${t.get('netWorthUSD', 0):,.0f} "
        f"(stocks ${t.get('marketValueUSD', 0):,.0f}, cash ${t.get('cashUSD', 0):,.0f})",
    ]
    if goal:
        lines.append(f"User's goal: {json.dumps(goal, ensure_ascii=False)}")
    if memories:
        lines.append("Saved memories about the user (oldest first):")
        lines += [f"- [{m['id']}] {m['text']}" for m in memories]
    else:
        lines.append("No saved memories yet.")
    lines.append("Holdings:")
    for x in p.get("positions", []):
        lines.append(
            f"- {x['symbol']} {x['quantity']:g}주 · 평단 {x['avgCost']:.2f} {x['currency']} · "
            f"현재 {x.get('lastPrice')} · 비중 {100 * (x.get('weight') or 0):.1f}% · "
            f"손익 {x.get('unrealizedPL', 0):+,.0f} ({100 * (x.get('unrealizedPLPct') or 0):+.1f}%)"
        )
    lines.append("Use the tools for anything more detailed or more current.")
    lines.append("</context>")
    return "\n".join(lines)
