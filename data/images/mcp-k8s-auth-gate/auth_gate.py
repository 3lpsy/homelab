"""Bearer-token reverse proxy in front of containers/kubernetes-mcp-server.

Upstream is a Go binary with no static-token auth mode, so this sidecar
fronts it with the same `Authorization: Bearer <key>` (or `?api_key=`)
contract used by every Python MCP in this repo. Auth-passing requests are
streamed verbatim to UPSTREAM_URL (loopback to the sibling container in the
pod). Auth is fail-closed: empty `MCP_API_KEYS` rejects every request.

Environment:
  MCP_API_KEYS    CSV of accepted Bearer tokens. Empty/unset is fail-closed.
  UPSTREAM_URL    Loopback URL of the upstream MCP binary
                  (default 'http://127.0.0.1:8080').
  MCP_HOST        Bind host (default 0.0.0.0).
  MCP_PORT        Bind port (default 8000).
  UPSTREAM_TIMEOUT  httpx total timeout seconds (default 600 — long-poll SSE).
  LOG_LEVEL       debug / info / warning / error (default info).
"""

import logging
import os
import secrets
from contextlib import asynccontextmanager
from urllib.parse import urlencode, urlparse

import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.datastructures import Headers, QueryParams
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route
from starlette.types import ASGIApp, Receive, Scope, Send


def _env_int(name: str, default: str) -> int:
    raw = os.environ.get(name, default)
    try:
        return int(raw)
    except ValueError as e:
        raise SystemExit(f"{name} must be an int, got {raw!r}") from e


def _env_float(name: str, default: str) -> float:
    raw = os.environ.get(name, default)
    try:
        return float(raw)
    except ValueError as e:
        raise SystemExit(f"{name} must be a float, got {raw!r}") from e


API_KEYS = {k.strip() for k in os.environ.get("MCP_API_KEYS", "").split(",") if k.strip()}
UPSTREAM_URL = os.environ.get("UPSTREAM_URL", "http://127.0.0.1:8080").rstrip("/")
UPSTREAM_TIMEOUT = _env_float("UPSTREAM_TIMEOUT", "600")
# Gate-side body cap. Sits just above the upstream's 1 MiB TOML cap so upstream
# still owns the authoritative limit; the gate rejects early to avoid buffering
# multi-megabyte bodies for an already-doomed request.
MCP_MAX_BODY_BYTES = _env_int("MCP_MAX_BODY_BYTES", str(2 * 1024 * 1024))
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = _env_int("MCP_PORT", "8000")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
# httpx logs full request URLs (including query strings) at INFO. Callers
# that auth via `?api_key=...` would see their key in pod logs. Mute to
# WARNING so only failures surface; loss of per-request observability is
# acceptable since auth-gate logs auth decisions itself.
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("mcp-k8s-auth-gate")

# Validate UPSTREAM_URL at import so a typo fails the pod instead of every
# proxied request.
_parsed = urlparse(UPSTREAM_URL)
if _parsed.scheme not in ("http", "https") or not _parsed.netloc:
    raise SystemExit(f"UPSTREAM_URL must be an http(s) URL, got {UPSTREAM_URL!r}")

log.info(
    "startup: upstream=%s api_keys=%d timeout=%.0f max_body=%d log_level=%s",
    UPSTREAM_URL, len(API_KEYS), UPSTREAM_TIMEOUT, MCP_MAX_BODY_BYTES, LOG_LEVEL,
)


# Hop-by-hop headers (RFC 7230 §6.1) plus headers the proxy must rewrite.
# `authorization` is stripped because the upstream uses its in-cluster
# ServiceAccount token to talk to the K8s API — the caller's Bearer is for
# *this* gate, not for kubernetes. `host`/`content-length` are recomputed by
# httpx on the outgoing request.
#
# `origin`, `referer`, and the `sec-fetch-*` family are stripped to defeat
# the upstream binary's DNS-rebinding/CSRF protection. nginx + auth-gate
# means the caller's Origin/Sec-Fetch-Site never match the upstream's
# loopback bind; without this, browsers get 403 "cross-origin request
# detected from Sec-Fetch-Site header". The request is genuinely
# server-to-server by the time it reaches the upstream, so removing the
# browser-context signals is correct, not just a workaround.
_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "authorization",
    "host",
    "content-length",
    "origin",
    "referer",
    "sec-fetch-site",
    "sec-fetch-mode",
    "sec-fetch-dest",
    "sec-fetch-user",
}


# Module-level singleton — built in lifespan, torn down on shutdown. Mirrors
# the shared httpx.AsyncClient pattern from mcp-prometheus / mcp-searxng (they
# build per-request, but this server is purely a proxy and connection reuse
# matters for SSE long-polls).
client: httpx.AsyncClient | None = None


# --- Proxy handler ---------------------------------------------------------


async def proxy(request: Request) -> Response:
    """Forward an authenticated request to the upstream binary, streaming
    the response back. Auth is enforced upstream of this handler by
    AuthMiddleware so we never see unauthenticated requests."""

    assert client is not None  # set by lifespan

    if request.method == "OPTIONS":
        # nginx in mcp-shared owns CORS preflight; the upstream binary isn't
        # built for browser clients. Short-circuit so a stray OPTIONS that
        # slips past nginx doesn't 405 from the upstream.
        return Response(status_code=204)

    # Strip `api_key` from the outbound query — auth-gate already validated
    # it, the upstream binary doesn't use it, and forwarding leaks the
    # token into anywhere that logs URLs (httpx access logs, upstream
    # request logs, SSE event ids).
    # Bare `/` (or empty) from nginx's `/mcp-k8s/` location is rewritten to
    # the upstream's Streamable HTTP endpoint `/mcp` so every MCP in this
    # repo addresses as `/mcp-<name>/`. `/sse` and other upstream routes
    # still forward verbatim.
    in_path = request.url.path or "/"
    fwd_path = "/mcp" if in_path in ("", "/") else in_path
    target = f"{UPSTREAM_URL}{fwd_path}"
    if request.url.query:
        forwarded_qs = urlencode(
            [(k, v) for k, v in request.query_params.multi_items() if k != "api_key"]
        )
        if forwarded_qs:
            target = f"{target}?{forwarded_qs}"

    fwd_headers = {k: v for k, v in request.headers.items() if k.lower() not in _HOP_BY_HOP}

    # Bounded-size body read — refuse bodies larger than MCP_MAX_BODY_BYTES so
    # a compromised or runaway client can't buffer multi-megabyte uploads in
    # the gate's memory before upstream rejects them.
    body = bytearray()
    async for chunk in request.stream():
        body.extend(chunk)
        if len(body) > MCP_MAX_BODY_BYTES:
            log.warning(
                "proxy %s %r: body exceeded MCP_MAX_BODY_BYTES=%d; rejecting",
                request.method, request.url.path, MCP_MAX_BODY_BYTES,
            )
            return JSONResponse(
                {"error": "request body too large", "error_type": "payload_too_large"},
                status_code=413,
            )

    upstream_req = client.build_request(
        request.method,
        target,
        headers=fwd_headers,
        content=bytes(body),
    )
    try:
        upstream_resp = await client.send(upstream_req, stream=True)
    except httpx.TimeoutException as e:
        # Scrub str(e) — httpx includes the upstream URL, which is loopback
        # today but would carry tenant bits if UPSTREAM_URL ever changes.
        log.warning("proxy %s %r: upstream timeout (%s)", request.method, request.url.path, type(e).__name__)
        return JSONResponse(
            {"error": f"upstream timeout ({type(e).__name__})", "error_type": "timeout"},
            status_code=504,
        )
    except httpx.HTTPError as e:
        log.warning("proxy %s %r: upstream http error (%s)", request.method, request.url.path, type(e).__name__)
        return JSONResponse(
            {"error": f"upstream unreachable ({type(e).__name__})", "error_type": "upstream_http"},
            status_code=502,
        )

    response_headers = {k: v for k, v in upstream_resp.headers.items() if k.lower() not in _HOP_BY_HOP}

    async def body_iter():
        try:
            async for chunk in upstream_resp.aiter_raw():
                yield chunk
        finally:
            await upstream_resp.aclose()

    return StreamingResponse(
        body_iter(),
        status_code=upstream_resp.status_code,
        headers=response_headers,
    )


# --- Auth middleware (verbatim from mcp-time / mcp-searxng) ----------------


class AuthMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "lifespan":
            await self.app(scope, receive, send)
            return

        if scope["type"] != "http":
            log.warning("auth: rejecting non-http scope: %s", scope["type"])
            if scope["type"] == "websocket":
                await receive()
                await send({"type": "websocket.close", "code": 1008})
            return

        method = scope["method"]
        if method == "OPTIONS":
            await self.app(scope, receive, send)
            return

        # Unauthenticated health probe — kubelet won't send a bearer.
        if scope["path"] == "/healthz":
            await self.app(scope, receive, send)
            return

        headers = Headers(scope=scope)
        header = headers.get("authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        if not token:
            token = QueryParams(scope["query_string"]).get("api_key", "").strip()

        ok = bool(token) and any(secrets.compare_digest(token, k) for k in API_KEYS)
        if not ok:
            client_addr = scope.get("client")
            log.warning(
                "auth: rejected %s %r from %s",
                method, scope["path"], client_addr[0] if client_addr else "?",
            )
            await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
            return

        log.debug("auth: ok %s %r", method, scope["path"])
        await self.app(scope, receive, send)


@asynccontextmanager
async def lifespan(_app: Starlette):
    global client
    client = httpx.AsyncClient(
        timeout=httpx.Timeout(UPSTREAM_TIMEOUT, connect=5.0),
        limits=httpx.Limits(max_keepalive_connections=20, max_connections=100),
    )
    try:
        yield
    finally:
        await client.aclose()


async def healthz(_request: Request) -> JSONResponse:
    """Local health probe — no auth, no upstream call. The proxy catch-all
    would otherwise swallow /healthz and forward it to kubernetes-mcp-server,
    which doesn't know the route."""
    return JSONResponse({"ok": True})


app = Starlette(
    lifespan=lifespan,
    middleware=[Middleware(AuthMiddleware)],
    routes=[
        Route("/healthz", healthz, methods=["GET"]),
        Route(
            "/{path:path}",
            proxy,
            methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"],
        ),
    ],
)


if __name__ == "__main__":
    uvicorn.run(app, host=MCP_HOST, port=MCP_PORT, log_level=LOG_LEVEL.lower(), access_log=False)
