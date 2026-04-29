"""Shared logging configuration for every mcp-<name> server.

Reads `LOG_LEVEL` from env (default `info`); falls back to INFO on garbage
values rather than a level that hides nothing or everything. Optional
`mute=` parameter raises a noisy upstream library to WARNING — used to
suppress full-URL access logs from `httpx` (per-tenant identifiers in
query strings) and `urllib3` (kubernetes client chatter).
"""

from __future__ import annotations

import logging
import os
from collections.abc import Iterable


def setup_logging(name: str, *, mute: Iterable[str] = ()) -> logging.Logger:
    log_level = os.environ.get("LOG_LEVEL", "info").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    for n in mute:
        logging.getLogger(n).setLevel(logging.WARNING)
    return logging.getLogger(name)
