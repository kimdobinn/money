"""SQLite persistence: intraday snapshots, daily equity curve, trades."""
from __future__ import annotations

import sqlite3
import threading
import time
from datetime import date

from .config import DB_PATH

_SCHEMA = """
CREATE TABLE IF NOT EXISTS snapshots(
  ts INTEGER PRIMARY KEY, value_usd REAL, cost_usd REAL, cash_usd REAL, day_pl_usd REAL);
CREATE TABLE IF NOT EXISTS daily(
  date TEXT PRIMARY KEY, value_usd REAL, cost_usd REAL, cash_usd REAL, source TEXT);
CREATE TABLE IF NOT EXISTS trades(
  id TEXT PRIMARY KEY, broker TEXT, symbol TEXT, currency TEXT, qty REAL, price REAL, date TEXT);
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS fx_hist(minute TEXT PRIMARY KEY, usdkrw REAL);
CREATE TABLE IF NOT EXISTS watchlist(
  symbol TEXT PRIMARY KEY, name TEXT, english_name TEXT, exchange TEXT, security_type TEXT,
  currency TEXT, starred INTEGER DEFAULT 0, added_at INTEGER);
CREATE TABLE IF NOT EXISTS universe(
  symbol TEXT PRIMARY KEY, name TEXT, english_name TEXT, exchange TEXT, security_type TEXT);
CREATE TABLE IF NOT EXISTS hourly(ts INTEGER PRIMARY KEY, value_usd REAL);
CREATE TABLE IF NOT EXISTS candles_d(symbol TEXT, date TEXT, close REAL, PRIMARY KEY(symbol, date));
CREATE TABLE IF NOT EXISTS chat_memory(id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, created INTEGER, updated INTEGER);
CREATE TABLE IF NOT EXISTS chat_conv(id TEXT PRIMARY KEY, session_id TEXT, title TEXT, created INTEGER, updated INTEGER);
CREATE TABLE IF NOT EXISTS chat_msg(id INTEGER PRIMARY KEY AUTOINCREMENT, conv_id TEXT, role TEXT, text TEXT,
  tools TEXT, ts INTEGER);
"""


class Store:
    def __init__(self, path=DB_PATH):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.executescript(_SCHEMA)
        cols = [r[1] for r in self.db.execute("PRAGMA table_info(watchlist)")]
        if "position" not in cols:  # added after the first release
            self.db.execute("ALTER TABLE watchlist ADD COLUMN position INTEGER")
            self.db.commit()
        self.lock = threading.Lock()

    def _x(self, sql, args=()):
        with self.lock:
            cur = self.db.execute(sql, args)
            rows = cur.fetchall()  # fetch before commit: RETURNING statements stay open until drained
            self.db.commit()
            return rows

    def add_snapshot(self, value, cost, cash, day_pl, day: date):
        now = int(time.time())
        self._x("INSERT OR REPLACE INTO snapshots VALUES(?,?,?,?,?)", (now, value, cost, cash, day_pl))
        self._x(
            "INSERT OR REPLACE INTO daily VALUES(?,?,?,?, 'live')", (day.isoformat(), value, cost, cash)
        )
        # keep ~120 days of 5-minute snapshots
        self._x("DELETE FROM snapshots WHERE ts < ?", (now - 120 * 86400,))

    def snapshots_since(self, ts: int):
        return self._x("SELECT ts, value_usd, cost_usd FROM snapshots WHERE ts >= ? ORDER BY ts", (ts,))

    def hourly_since(self, ts: int):
        return self._x("SELECT ts, value_usd FROM hourly WHERE ts >= ? ORDER BY ts", (ts,))

    def put_hourly(self, rows: list[tuple[int, float]]):
        with self.lock:
            self.db.executemany("INSERT OR REPLACE INTO hourly VALUES(?,?)", rows)
            self.db.commit()

    def daily_since(self, d: str):
        return self._x("SELECT date, value_usd, cost_usd, source FROM daily WHERE date >= ? ORDER BY date", (d,))

    def upsert_backfill(self, rows: list[tuple[str, float]]):
        with self.lock:
            self.db.executemany(
                "INSERT INTO daily(date, value_usd, cost_usd, cash_usd, source) VALUES(?,?,NULL,NULL,'backfill') "
                "ON CONFLICT(date) DO UPDATE SET value_usd=excluded.value_usd WHERE daily.source='backfill'",
                rows,
            )
            self.db.commit()

    def save_trades(self, trades: list[dict]):
        with self.lock:
            self.db.executemany(
                "INSERT OR REPLACE INTO trades VALUES(:id,:broker,:symbol,:currency,:qty,:price,:date)", trades
            )
            self.db.commit()

    def trade_flows(self):
        """(date, currency, qty, price) ordered by date; price is NULL for splits/transfers."""
        return self._x("SELECT date, currency, qty, price FROM trades ORDER BY date")

    def trade_symbols(self):
        return self._x("SELECT broker, symbol, currency, qty, price FROM trades ORDER BY date")

    def all_trades(self):
        return self._x("SELECT broker, symbol, currency, qty, date FROM trades ORDER BY date")

    def trades(self, symbol=None, broker=None, since=None, limit=200):
        q, args = "SELECT broker, symbol, currency, qty, price, date FROM trades WHERE 1=1", []
        if symbol:
            q += " AND symbol=?"; args.append(symbol.upper())
        if broker:
            q += " AND broker=?"; args.append(broker)
        if since:
            q += " AND date>=?"; args.append(since)
        q += " ORDER BY date DESC LIMIT ?"; args.append(int(limit))
        return [dict(zip(("broker", "symbol", "currency", "qty", "price", "date"), r)) for r in self._x(q, args)]

    # ---- chat -----------------------------------------------------------------
    def memories(self):
        rows = self._x("SELECT id, text, created, updated FROM chat_memory ORDER BY id")
        return [{"id": r[0], "text": r[1], "created": r[2], "updated": r[3]} for r in rows]

    def memory_add(self, text):
        now = int(time.time())
        with self.lock:
            cur = self.db.execute("INSERT INTO chat_memory(text, created, updated) VALUES(?,?,?)", (text, now, now))
            self.db.commit()
            return cur.lastrowid

    def memory_update(self, mid, text):
        return self._x("UPDATE chat_memory SET text=?, updated=? WHERE id=? RETURNING id", (text, int(time.time()), mid))

    def memory_delete(self, mid):
        return self._x("DELETE FROM chat_memory WHERE id=? RETURNING id", (mid,))

    def conversations(self):
        rows = self._x("SELECT id, title, created, updated FROM chat_conv ORDER BY updated DESC")
        return [{"id": r[0], "title": r[1], "created": r[2], "updated": r[3]} for r in rows]

    def conversation(self, cid):
        r = self._x("SELECT id, session_id, title FROM chat_conv WHERE id=?", (cid,))
        return {"id": r[0][0], "sessionId": r[0][1], "title": r[0][2]} if r else None

    def conversation_upsert(self, cid, session_id, title):
        now = int(time.time())
        self._x(
            "INSERT INTO chat_conv VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
            "session_id=excluded.session_id, updated=excluded.updated",
            (cid, session_id, title, now, now),
        )

    def conversation_delete(self, cid):
        self._x("DELETE FROM chat_msg WHERE conv_id=?", (cid,))
        self._x("DELETE FROM chat_conv WHERE id=?", (cid,))

    def message_add(self, cid, role, text, tools=None):
        import json as _json
        self._x("INSERT INTO chat_msg(conv_id, role, text, tools, ts) VALUES(?,?,?,?,?)",
                (cid, role, text, _json.dumps(tools or []), int(time.time())))

    def messages(self, cid):
        import json as _json
        rows = self._x("SELECT id, role, text, tools, ts FROM chat_msg WHERE conv_id=? ORDER BY id", (cid,))
        return [{"id": r[0], "role": r[1], "text": r[2], "tools": _json.loads(r[3] or "[]"), "ts": r[4]} for r in rows]

    def meta_get(self, k):
        r = self._x("SELECT v FROM meta WHERE k=?", (k,))
        return r[0][0] if r else None

    def meta_set(self, k, v):
        self._x("INSERT OR REPLACE INTO meta VALUES(?,?)", (k, str(v)))

    def fx_hist_all(self):
        return self._x("SELECT minute, usdkrw FROM fx_hist")

    def fx_hist_put(self, minute: str, rate: float):
        self._x("INSERT OR REPLACE INTO fx_hist VALUES(?,?)", (minute, rate))
