"""ASGI bearer-key auth middleware shared across every mcp-<name> server.

Validates the request's `Authorization: Bearer <token>` header (with a
`?api_key=` query-string fallback for clients that can't send custom
headers) against an in-memory allowlist. Empty allowlist is fail-closed:
every request is rejected.

Stateless servers ignore the bound `current_api_key` ContextVar; servers
with per-tenant state (mcp-filesystem, mcp-memory) read it inside their
tools to scope on-disk paths. Litellm passes `on_auth` to bind its own
`current_allowed_hashes` ContextVar from the matched bearer.
"""

from __future__ import annotations

import contextvars
import logging
import secrets
from collections.abc import Callable

from starlette.datastructures import Headers, QueryParams
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

current_api_key: contextvars.ContextVar[str] = contextvars.ContextVar(
    "current_api_key", default=""
)


class AuthMiddleware:
    def __init__(
        self,
        app: ASGIApp,
        *,
        api_keys: set[str],
        on_auth: Callable[[str], None] | None = None,
        logger: logging.Logger,
    ) -> None:
        self.app = app
        self.api_keys = api_keys
        self.on_auth = on_auth
        self.log = logger

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        # ASGI startup/shutdown events must reach the inner app untouched.
        if scope["type"] == "lifespan":
            await self.app(scope, receive, send)
            return

        # Everything that isn't HTTP is rejected closed — MCP streamable-http
        # does not use websockets, so a ws upgrade here is either a stray route
        # or an attacker probing for an auth bypass.
        if scope["type"] != "http":
            self.log.warning("auth: rejecting non-http scope: %s", scope["type"])
            if scope["type"] == "websocket":
                await receive()
                await send({"type": "websocket.close", "code": 1008})
            return

        method = scope["method"]
        # CORS preflight: no auth, no context.
        if method == "OPTIONS":
            await self.app(scope, receive, send)
            return

        # Unauthenticated health probe — kubelet won't send a bearer, and
        # we don't bind a contextvar here so tools can't run anyway.
        if scope["path"] == "/healthz":
            await self.app(scope, receive, send)
            return

        # Bearer token, falling back to ?api_key= query param.
        headers = Headers(scope=scope)
        header = headers.get("authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        if not token:
            token = QueryParams(scope["query_string"]).get("api_key", "").strip()

        # Empty API_KEYS rejects (fail-closed). compare_digest per candidate
        # avoids per-byte timing leaks on the match.
        ok = bool(token) and any(
            secrets.compare_digest(token, k) for k in self.api_keys
        )
        if not ok:
            client = scope.get("client")
            self.log.warning(
                "auth: rejected %s %r from %s",
                method,
                scope["path"],
                client[0] if client else "?",
            )
            await JSONResponse({"error": "unauthorized"}, status_code=401)(
                scope, receive, send
            )
            return

        if self.on_auth is not None:
            self.on_auth(token)
        ctx_token = current_api_key.set(token)
        self.log.debug("auth: ok %s %r", method, scope["path"])
        try:
            await self.app(scope, receive, send)
        finally:
            current_api_key.reset(ctx_token)
