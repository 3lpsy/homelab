"""Shared bootstrap for the per-tenant MCP servers in this repo.

Every `mcp-<name>/server.py` image historically copy-pasted the same ASGI
auth middleware, env helpers, logging setup, /healthz route, and uvicorn
wiring. This package owns those pieces so a behaviour fix lands once.
"""

from .auth import AuthMiddleware, current_api_key
from .bootstrap import run
from .config import env_bool, env_csv_set, env_float, env_int, env_required
from .logging_setup import setup_logging
from .tenant import hash_tenant, init_tenant_root

__all__ = [
    "AuthMiddleware",
    "current_api_key",
    "env_bool",
    "env_csv_set",
    "env_float",
    "env_int",
    "env_required",
    "hash_tenant",
    "init_tenant_root",
    "run",
    "setup_logging",
]
