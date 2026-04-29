"""Env-var parsing helpers used by every mcp-<name> server."""

from __future__ import annotations

import os


def env_int(name: str, default: str) -> int:
    raw = os.environ.get(name, default)
    try:
        return int(raw)
    except ValueError as e:
        raise SystemExit(f"{name} must be an int, got {raw!r}") from e


def env_float(name: str, default: str) -> float:
    raw = os.environ.get(name, default)
    try:
        return float(raw)
    except ValueError as e:
        raise SystemExit(f"{name} must be a float, got {raw!r}") from e


def env_bool(name: str, default: str = "") -> bool:
    raw = os.environ.get(name, default).strip().lower()
    return raw in ("1", "true", "yes")


def env_csv_set(name: str) -> set[str]:
    return {k.strip() for k in os.environ.get(name, "").split(",") if k.strip()}


def env_required(name: str) -> str:
    raw = os.environ.get(name, "")
    if not raw:
        raise SystemExit(f"{name} must be set")
    return raw
