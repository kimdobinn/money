"""Secrets live in the macOS login Keychain, never on disk."""
from __future__ import annotations

import keyring
from keyring.errors import PasswordDeleteError

SERVICE = "com.brokers.helper"
KEYS = ("tossClientId", "tossClientSecret", "ibkrFlexToken")


def get(key: str) -> str | None:
    try:
        v = keyring.get_password(SERVICE, key)
    except Exception:
        return None
    return v or None


def set(key: str, value: str | None) -> None:  # noqa: A001
    if key not in KEYS:
        raise KeyError(key)
    if value:
        keyring.set_password(SERVICE, key, value.strip())
    else:
        try:
            keyring.delete_password(SERVICE, key)
        except PasswordDeleteError:
            pass


def presence() -> dict[str, bool]:
    return {k: get(k) is not None for k in KEYS}
