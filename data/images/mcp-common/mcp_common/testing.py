"""Test helpers shared by per-server test_server.py.

The 4 test files that exercise auth (filesystem, k8s, memory, time)
historically each carried a near-identical `_run_auth` helper and inline
ASGI scope dicts. These helpers replace the duplication.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable

from .auth import AuthMiddleware


def make_http_scope(
    *,
    method: str,
    path: str,
    headers: list[tuple[bytes, bytes]] | tuple[tuple[bytes, bytes], ...] = (),
    query: bytes = b"",
    client: tuple[str, int] = ("1.2.3.4", 1234),
) -> dict:
    return {
        "type": "http",
        "method": method,
        "path": path,
        "query_string": query,
        "headers": list(headers),
        "client": client,
    }


async def _default_inner(scope, receive, send):
    await send({"type": "http.response.start", "status": 200, "headers": []})
    await send({"type": "http.response.body", "body": b"ok"})


def run_auth(
    scope: dict,
    *,
    api_keys: set[str],
    on_auth: Callable[[str], None] | None = None,
    inner=None,
    body: bytes = b"",
) -> list[dict]:
    """Drive AuthMiddleware once and return the ASGI messages it sent.

    Inner defaults to a 200 stub. `body` lets a caller stage a request
    body for inner apps that read it (none of the auth tests need this
    today).
    """
    sent: list[dict] = []

    async def _send(msg):
        sent.append(msg)

    async def _recv():
        return {"type": "http.request", "body": body, "more_body": False}

    log = logging.getLogger("test-auth")
    mw = AuthMiddleware(
        inner if inner is not None else _default_inner,
        api_keys=api_keys,
        on_auth=on_auth,
        logger=log,
    )
    asyncio.run(mw(scope, _recv, _send))
    return sent


def run_asgi(middleware, scope: dict, *, body: bytes = b"") -> list[dict]:
    """Drive an arbitrary already-constructed middleware once. Used for
    websocket-close tests where the inner app is irrelevant."""
    sent: list[dict] = []

    async def _send(msg):
        sent.append(msg)

    async def _recv():
        if scope.get("type") == "websocket":
            return {"type": "websocket.connect"}
        return {"type": "http.request", "body": body, "more_body": False}

    asyncio.run(middleware(scope, _recv, _send))
    return sent
