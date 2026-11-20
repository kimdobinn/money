"""Paths and persisted (non-secret) settings for the helper."""
from __future__ import annotations

import copy
import json
import os
import secrets as _secrets
from pathlib import Path
from typing import Any

APP_DIR = Path.home() / "Library" / "Application Support" / "Brokers"
LOG_DIR = Path.home() / "Library" / "Logs" / "Brokers"
DB_PATH = APP_DIR / "brokers.sqlite3"
SETTINGS_PATH = APP_DIR / "settings.json"
TOKEN_PATH = APP_DIR / "api-token"
FLEX_CACHE_PATH = APP_DIR / "ibkr-flex-latest.xml"

HOST = "127.0.0.1"
PORT = 8765

DEFAULT_SETTINGS: dict[str, Any] = {
    # auto: demo data until any real connector is configured
    "demoMode": "auto",  # auto | on | off
    "displayCurrency": "SGD",  # USD | SGD | KRW
    "menuBarStyle": "both",  # total | day | both
    "colorStyle": "kr",  # kr: 상승=빨강 / us: 상승=초록
    "toss": {"enabled": True},
    "ibkr": {
        "gatewayEnabled": True,
        "host": "127.0.0.1",
        "port": 4001,  # IB Gateway live default
        "clientId": 77,
        "flexEnabled": True,
        "flexQueryId": "",
    },
}


def ensure_dirs() -> None:
    APP_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)


def api_token() -> str:
    """Shared secret the app sends for write calls. Created once, 0600."""
    ensure_dirs()
    if TOKEN_PATH.exists():
        return TOKEN_PATH.read_text().strip()
    tok = _secrets.token_urlsafe(32)
    TOKEN_PATH.write_text(tok)
    os.chmod(TOKEN_PATH, 0o600)
    return tok


def _merge(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


class Settings:
    def __init__(self) -> None:
        ensure_dirs()
        self.data = copy.deepcopy(DEFAULT_SETTINGS)
        if SETTINGS_PATH.exists():
            try:
                self.data = _merge(self.data, json.loads(SETTINGS_PATH.read_text()))
            except Exception:
                pass

    def update(self, patch: dict) -> None:
        self.data = _merge(self.data, patch)
        SETTINGS_PATH.write_text(json.dumps(self.data, indent=2, ensure_ascii=False))

    def __getitem__(self, key: str) -> Any:
        return self.data[key]
