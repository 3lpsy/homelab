"""Final wiring: register `/healthz`, attach AuthMiddleware, run uvicorn.

Each server's tail collapses to a single `mcp_common.run(mcp, ...)` call
after defining its tools and instructions.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable

import uvicorn
from fastmcp import FastMCP
from starlette.middleware import Middleware
from starlette.responses import JSONResponse

from .auth import AuthMiddleware


async def _healthz(_request) -> JSONResponse:
    """Liveness + readiness probe target. No auth, no upstream calls."""
    return JSONResponse({"ok": True})


def build_app(
    mcp: FastMCP,
    *,
    api_keys: set[str],
    logger: logging.Logger,
    on_auth: Callable[[str], None] | None = None,
):
    """Register `/healthz` and wrap the FastMCP ASGI app with AuthMiddleware.

    Returned at module load so test_server.py can mount the same app behind
    a uvicorn fixture or hit it via httpx.AsyncClient — `run_app` is the
    main-only counterpart that boots uvicorn for production.
    """
    mcp.custom_route("/healthz", methods=["GET"])(_healthz)
    return mcp.http_app(
        path="/",
        middleware=[
            Middleware(
                AuthMiddleware,
                api_keys=api_keys,
                on_auth=on_auth,
                logger=logger,
            )
        ],
    )


def run_app(app, *, host: str, port: int) -> None:
    log_level = os.environ.get("LOG_LEVEL", "info").lower()
    uvicorn.run(app, host=host, port=port, log_level=log_level, access_log=False)


def run(
    mcp: FastMCP,
    *,
    host: str,
    port: int,
    api_keys: set[str],
    logger: logging.Logger,
    on_auth: Callable[[str], None] | None = None,
) -> None:
    """Convenience: build_app + run_app in one call. Most servers use this;
    tests should use build_app to avoid spawning uvicorn at import time."""
    app = build_app(mcp, api_keys=api_keys, logger=logger, on_auth=on_auth)
    run_app(app, host=host, port=port)
