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
"""


class Store:
    def __init__(self, path=DB_PATH):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.executescript(_SCHEMA)
        self.lock = threading.Lock()

    def _x(self, sql, args=()):
        with self.lock:
            cur = self.db.execute(sql, args)
            self.db.commit()
            return cur.fetchall()

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

    def daily_since(self, d: str):
        return self._x("SELECT date, value_usd, cost_usd FROM daily WHERE date >= ? ORDER BY date", (d,))

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

    def all_trades(self):
        return self._x("SELECT broker, symbol, currency, qty, date FROM trades ORDER BY date")

    def meta_get(self, k):
        r = self._x("SELECT v FROM meta WHERE k=?", (k,))
        return r[0][0] if r else None

    def meta_set(self, k, v):
        self._x("INSERT OR REPLACE INTO meta VALUES(?,?)", (k, str(v)))

    def fx_hist_all(self):
        return self._x("SELECT minute, usdkrw FROM fx_hist")

    def fx_hist_put(self, minute: str, rate: float):
        self._x("INSERT OR REPLACE INTO fx_hist VALUES(?,?)", (minute, rate))
