"""MCP server (stdio) that the chat's Claude Code process uses to read the portfolio
and to keep long-term memory. Talks to the local helper over HTTP; read-only except memory."""
from __future__ import annotations

import json

import httpx
from mcp.server.mcpserver import MCPServer

from .chat_tools import chart_brief, history_brief, portfolio_brief, watchlist_brief
from .config import api_token

BASE = "http://127.0.0.1:8765"
TOKEN = api_token()

server = MCPServer(
    "money",
    instructions="Live data from the user's money app (Toss Securities + IBKR) and the assistant's long-term memory.",
)


def _get(path: str, **params) -> dict | list:
    r = httpx.get(BASE + path, params={k: v for k, v in params.items() if v is not None}, timeout=30)
    r.raise_for_status()
    return r.json()


def _send(method: str, path: str, body: dict | None = None) -> dict:
    r = httpx.request(method, BASE + path, json=body, headers={"X-Brokers-Token": TOKEN}, timeout=30)
    r.raise_for_status()
    return r.json()


def _j(v) -> str:
    return json.dumps(v, ensure_ascii=False, default=str)


@server.tool()
def get_portfolio() -> str:
    """Current holdings across Toss and IBKR: totals, per-broker cash and status, and every position
    with quantity, average cost, live price, P/L, weight and per-broker legs (incl. KRW cost basis for Toss)."""
    return _j(portfolio_brief(_get("/v1/portfolio")))


@server.tool()
def get_portfolio_history(range: str = "1M") -> str:  # noqa: A002
    """Portfolio value and net-invested amount over time, downsampled to ~80 points.
    range: one of 1D, 1W, 1M, 3M, 1Y, ALL."""
    return _j(history_brief(_get("/v1/history", range=range)))


@server.tool()
def get_trades(symbol: str | None = None, broker: str | None = None, since: str | None = None, limit: int = 200) -> str:
    """Executed trades (buys positive qty, sells negative). Filter by symbol (e.g. QLD), broker ('toss' or 'ibkr'),
    and since (YYYY-MM-DD). Newest first. Splits/transfers have price null."""
    return _j(_get("/v1/trades", symbol=symbol, broker=broker, since=since, limit=limit))


@server.tool()
def get_price_chart(symbol: str, range: str = "1Y") -> str:  # noqa: A002
    """Price history for any US or KR symbol (held or not). range: 1D, 1W, 1M, 3M, 1Y, 5Y."""
    return _j(chart_brief(_get("/v1/chart", symbol=symbol, range=range)))


@server.tool()
def get_watchlist() -> str:
    """The user's watchlist with live prices and daily change."""
    return _j(watchlist_brief(_get("/v1/watchlist")))


@server.tool()
def search_symbols(query: str) -> str:
    """Find tickers by name or symbol (Korean or English names work)."""
    return _j(_get("/v1/search", q=query))


@server.tool()
def get_connection_status() -> str:
    """Which brokers are connected, data sources, last backfill, public IP."""
    return _j(_get("/v1/status"))


@server.tool()
def memory_list() -> str:
    """All saved long-term memories about the user (id, text, saved date)."""
    return _j(_get("/v1/chat/memory"))


@server.tool()
def memory_save(text: str) -> str:
    """Save one durable fact about the user for future conversations (goals, preferences, risk tolerance,
    plans, context about their life or accounts). One fact per call, written as a short standalone sentence."""
    return _j(_send("POST", "/v1/chat/memory", {"text": text}))


@server.tool()
def memory_update(id: int, text: str) -> str:  # noqa: A002
    """Replace the text of an existing memory (when a fact changed)."""
    return _j(_send("PUT", f"/v1/chat/memory/{id}", {"text": text}))


@server.tool()
def memory_delete(id: int) -> str:  # noqa: A002
    """Delete a memory that is wrong or no longer true."""
    return _j(_send("DELETE", f"/v1/chat/memory/{id}"))


if __name__ == "__main__":
    server.run("stdio")
