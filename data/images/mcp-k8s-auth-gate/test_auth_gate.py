"""Unit tests for mcp-k8s-auth-gate auth_gate.py.

Drives the AuthMiddleware and the proxy handler directly. Upstream HTTP
calls are mocked via httpx.MockTransport so no real network is touched.
Run with:

  uv run --with pytest --with httpx --with starlette --with uvicorn \
         pytest test_auth_gate.py
"""
import asyncio
import logging
import os

os.environ["MCP_API_KEYS"] = "key-a,key-b"
os.environ["UPSTREAM_URL"] = "http://upstream.invalid:8080"
os.environ.setdefault("LOG_LEVEL", "error")

import httpx  # noqa: E402
import pytest  # noqa: E402
from starlette.requests import Request  # noqa: E402

import auth_gate  # noqa: E402


# --- helpers --------------------------------------------------------------


def _call(coro):
    return asyncio.run(coro)


def _make_request(
    method: str = "GET",
    path: str = "/mcp",
    query: str = "",
    headers: dict[str, str] | None = None,
    body: bytes = b"",
) -> Request:
    """Build a Starlette Request without spinning up the full ASGI app."""
    scope = {
        "type": "http",
        "method": method,
        "path": path,
        "raw_path": path.encode(),
        "query_string": query.encode(),
        "headers": [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()],
        "client": ("1.2.3.4", 1234),
        "scheme": "http",
        "server": ("test", 8000),
    }

    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}

    return Request(scope, receive)


async def _drain(resp):
    """Concatenate a StreamingResponse body for assertion."""
    chunks = []
    async for chunk in resp.body_iterator:
        if isinstance(chunk, str):
            chunk = chunk.encode()
        chunks.append(chunk)
    return b"".join(chunks)


def _set_upstream(handler):
    """Swap auth_gate.client to one backed by MockTransport for the test."""
    transport = httpx.MockTransport(handler)
    auth_gate.client = httpx.AsyncClient(transport=transport, timeout=5.0)


def _run_auth(scope, inner=None):
    """Drive AuthMiddleware once and return sent ASGI messages. Mirrors the
    helper from mcp-time/test_server.py so the auth tests stay parallel."""
    sent: list[dict] = []

    async def _send(msg):
        sent.append(msg)

    async def _recv():
        return {"type": "http.request", "body": b"", "more_body": False}

    if inner is None:
        async def inner(scope, receive, send):
            await send({"type": "http.response.start", "status": 200, "headers": []})
            await send({"type": "http.response.body", "body": b"ok"})

    mw = auth_gate.AuthMiddleware(inner)
    asyncio.run(mw(scope, _recv, _send))
    return sent


# --- auth middleware ------------------------------------------------------


def test_auth_rejects_missing_bearer():
    sent = _run_auth({
        "type": "http",
        "method": "POST",
        "path": "/mcp",
        "query_string": b"",
        "headers": [],
        "client": ("1.2.3.4", 1234),
    })
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 401


def test_auth_rejects_wrong_bearer():
    sent = _run_auth({
        "type": "http",
        "method": "POST",
        "path": "/mcp",
        "query_string": b"",
        "headers": [(b"authorization", b"Bearer not-a-real-key")],
        "client": ("1.2.3.4", 1234),
    })
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 401


def test_auth_accepts_valid_bearer():
    sent = _run_auth({
        "type": "http",
        "method": "POST",
        "path": "/mcp",
        "query_string": b"",
        "headers": [(b"authorization", b"Bearer key-a")],
        "client": ("1.2.3.4", 1234),
    })
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 200


def test_auth_accepts_query_param_key():
    sent = _run_auth({
        "type": "http",
        "method": "POST",
        "path": "/mcp",
        "query_string": b"api_key=key-b",
        "headers": [],
        "client": ("1.2.3.4", 1234),
    })
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 200


def test_auth_allows_options_unauthenticated():
    # CORS preflights must bypass auth or browsers can't even probe the server.
    sent = _run_auth({
        "type": "http",
        "method": "OPTIONS",
        "path": "/mcp",
        "query_string": b"",
        "headers": [],
        "client": ("1.2.3.4", 1234),
    })
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 200


def test_auth_closes_websocket():
    sent: list[dict] = []

    async def _send(msg):
        sent.append(msg)

    async def _recv():
        return {"type": "websocket.connect"}

    mw = auth_gate.AuthMiddleware(lambda *a, **kw: None)
    asyncio.run(mw({"type": "websocket"}, _recv, _send))
    assert sent == [{"type": "websocket.close", "code": 1008}]


def test_auth_constant_time_comparison_used():
    # Sanity check: the AuthMiddleware uses secrets.compare_digest, which
    # rejects wrong-length tokens without ValueError. A pre-rewrite version
    # used == and would short-circuit on length differences.
    sent = _run_auth({
        "type": "http",
        "method": "POST",
        "path": "/mcp",
        "query_string": b"",
        "headers": [(b"authorization", b"Bearer x")],  # wrong length
        "client": ("1.2.3.4", 1234),
    })
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 401


# --- proxy handler --------------------------------------------------------


def test_proxy_options_returns_204_without_upstream():
    # Proxy short-circuits OPTIONS so the upstream binary never sees CORS
    # preflights. AuthMiddleware also passes OPTIONS through unauth'd, so
    # this is the second half of the preflight contract.
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(method="OPTIONS", path="/mcp")
    resp = _call(auth_gate.proxy(req))

    assert resp.status_code == 204
    assert captured == []  # upstream not called


def test_proxy_forwards_method_path_and_body():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200, content=b"ok")

    _set_upstream(handler)
    req = _make_request(
        method="POST",
        path="/mcp",
        body=b'{"jsonrpc":"2.0"}',
        headers={"content-type": "application/json"},
    )
    resp = _call(auth_gate.proxy(req))

    assert resp.status_code == 200
    assert len(captured) == 1
    assert captured[0].method == "POST"
    assert str(captured[0].url) == "http://upstream.invalid:8080/mcp"
    assert captured[0].content == b'{"jsonrpc":"2.0"}'
    assert captured[0].headers["content-type"] == "application/json"


def test_proxy_forwards_query_string():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(method="GET", path="/sse", query="last_event_id=42")
    _call(auth_gate.proxy(req))

    assert str(captured[0].url) == "http://upstream.invalid:8080/sse?last_event_id=42"


def test_proxy_strips_api_key_from_outbound_query():
    # Caller's `?api_key=` is for auth-gate only. Forwarding it leaks the
    # token into any downstream log that records URLs (httpx INFO, upstream
    # access log, SSE event ids).
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(
        method="POST",
        path="/mcp",
        query="api_key=key-a&foo=bar",
        headers={"authorization": "Bearer key-a"},
    )
    _call(auth_gate.proxy(req))

    url = str(captured[0].url)
    assert "api_key" not in url
    assert "foo=bar" in url


def test_proxy_drops_query_entirely_when_only_api_key():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(method="POST", path="/mcp", query="api_key=key-a")
    _call(auth_gate.proxy(req))

    assert str(captured[0].url) == "http://upstream.invalid:8080/mcp"


def test_httpx_logger_muted_to_warning():
    # Regression guard: httpx INFO emits the request URL incl. query string.
    # Demoting to WARNING keeps `?api_key=` out of pod logs.
    assert logging.getLogger("httpx").level == logging.WARNING


def test_proxy_strips_authorization_header_outbound():
    # The caller's Bearer is for *this* gate. The upstream binary uses its
    # in-cluster ServiceAccount to talk to the K8s API; forwarding the
    # caller's token would be both useless and a credential leak.
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(
        method="POST",
        path="/mcp",
        headers={"authorization": "Bearer key-a", "x-custom": "preserved"},
    )
    _call(auth_gate.proxy(req))

    assert "authorization" not in {k.lower() for k in captured[0].headers}
    assert captured[0].headers["x-custom"] == "preserved"


def test_proxy_strips_hop_by_hop_headers_outbound():
    # `connection` is not asserted: httpx always sets its own (per-hop by
    # definition) on outbound requests, so what matters is that the
    # caller's value isn't propagated. `te` and `upgrade` httpx never sets,
    # so absence proves we stripped the caller's.
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(
        method="POST",
        path="/mcp",
        headers={
            "connection": "close",
            "te": "trailers",
            "upgrade": "h2c",
            "x-mcp-session-id": "abc",
        },
    )
    _call(auth_gate.proxy(req))

    seen = {k.lower() for k in captured[0].headers}
    assert "te" not in seen
    assert "upgrade" not in seen
    # Caller's `connection: close` must not be forwarded; httpx's default
    # keep-alive should appear instead.
    assert captured[0].headers.get("connection", "").lower() != "close"
    # Non-hop-by-hop headers must survive.
    assert captured[0].headers["x-mcp-session-id"] == "abc"


def test_proxy_strips_hop_by_hop_headers_inbound():
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={
                "connection": "close",
                "transfer-encoding": "chunked",
                "x-mcp-session-id": "from-upstream",
            },
            content=b"ok",
        )

    _set_upstream(handler)
    req = _make_request(method="POST", path="/mcp")
    resp = _call(auth_gate.proxy(req))

    seen = {k.lower() for k in resp.headers}
    assert "connection" not in seen
    assert "transfer-encoding" not in seen
    assert resp.headers["x-mcp-session-id"] == "from-upstream"


def test_proxy_passes_status_code_through():
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(418, content=b"teapot")

    _set_upstream(handler)
    req = _make_request(method="POST", path="/mcp")
    resp = _call(auth_gate.proxy(req))
    assert resp.status_code == 418


def test_proxy_streams_body():
    # MockTransport with `content=b"..."` pre-consumes the stream, so use
    # ByteStream to keep aiter_raw() readable — matches a real upstream.
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            headers={"content-type": "text/event-stream"},
            stream=httpx.ByteStream(b"data: a\n\ndata: b\n\n"),
        )

    _set_upstream(handler)
    req = _make_request(method="GET", path="/sse")
    resp = _call(auth_gate.proxy(req))
    body = _call(_drain(resp))
    assert body == b"data: a\n\ndata: b\n\n"


def test_proxy_upstream_timeout_returns_504():
    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("upstream too slow", request=req)

    _set_upstream(handler)
    req = _make_request(method="POST", path="/mcp")
    resp = _call(auth_gate.proxy(req))
    assert resp.status_code == 504
    assert b'"error_type":"timeout"' in resp.body


def test_proxy_upstream_connect_error_returns_502():
    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=req)

    _set_upstream(handler)
    req = _make_request(method="POST", path="/mcp")
    resp = _call(auth_gate.proxy(req))
    assert resp.status_code == 502
    assert b'"error_type":"upstream_http"' in resp.body


def test_proxy_rejects_oversized_body_before_upstream():
    """Body > MCP_MAX_BODY_BYTES gets 413 at the gate; upstream never called."""
    upstream_called = {"n": 0}

    def handler(req: httpx.Request) -> httpx.Response:
        upstream_called["n"] += 1
        return httpx.Response(200)

    _set_upstream(handler)
    # Squeeze to 64 bytes so the test stays tiny.
    prior = auth_gate.MCP_MAX_BODY_BYTES
    auth_gate.MCP_MAX_BODY_BYTES = 64
    try:
        req = _make_request(method="POST", path="/mcp", body=b"x" * 128)
        resp = _call(auth_gate.proxy(req))
    finally:
        auth_gate.MCP_MAX_BODY_BYTES = prior
    assert resp.status_code == 413
    assert b'"error_type":"payload_too_large"' in resp.body
    assert upstream_called["n"] == 0


def test_proxy_accepts_body_at_exactly_cap():
    """Body of exactly MCP_MAX_BODY_BYTES passes through."""
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=req.content)

    _set_upstream(handler)
    prior = auth_gate.MCP_MAX_BODY_BYTES
    auth_gate.MCP_MAX_BODY_BYTES = 64
    try:
        req = _make_request(method="POST", path="/mcp", body=b"x" * 64)
        resp = _call(auth_gate.proxy(req))
    finally:
        auth_gate.MCP_MAX_BODY_BYTES = prior
    assert resp.status_code == 200


def test_proxy_error_text_does_not_leak_upstream_url():
    """After the M1 scrub, 502/504 JSON bodies must not embed the upstream
    URL — str(httpx exception) would otherwise include 'upstream.invalid:8080'."""
    def handler(req: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("Name or service not known: upstream.invalid", request=req)

    _set_upstream(handler)
    req = _make_request(method="POST", path="/mcp")
    resp = _call(auth_gate.proxy(req))
    assert resp.status_code == 502
    assert b"upstream.invalid" not in resp.body
    assert b'"error_type":"upstream_http"' in resp.body


def test_healthz_bypasses_auth():
    """Health route answers 200 without any bearer."""
    sent = _run_auth({
        "type": "http",
        "method": "GET",
        "path": "/healthz",
        "query_string": b"",
        "headers": [],  # no Authorization, no api_key
    }, inner=None)  # _run_auth default inner returns 200 ok
    statuses = [m["status"] for m in sent if m["type"] == "http.response.start"]
    assert statuses == [200]


def test_proxy_rewrites_root_to_upstream_mcp():
    # Client hits bare `/mcp-k8s/`; nginx strips the location prefix so the
    # gate sees path `/`. Must rewrite to upstream `/mcp` (Streamable HTTP).
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(method="POST", path="/")
    _call(auth_gate.proxy(req))
    assert str(captured[0].url) == "http://upstream.invalid:8080/mcp"


def test_proxy_rewrites_empty_path_to_upstream_mcp():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(method="POST", path="")
    _call(auth_gate.proxy(req))
    assert str(captured[0].url) == "http://upstream.invalid:8080/mcp"


def test_proxy_preserves_sse_path():
    # `/sse` is a real upstream route — rewrite must only fire for bare root.
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(method="GET", path="/sse")
    _call(auth_gate.proxy(req))
    assert str(captured[0].url) == "http://upstream.invalid:8080/sse"


def test_proxy_passes_4xx_from_upstream_unchanged():
    # Upstream RBAC-forbidden responses (e.g. tool call against an
    # unallowed namespace) should propagate as-is, not be reshaped into
    # the auth-gate's own error envelope.
    def handler(req: httpx.Request) -> httpx.Response:
        return httpx.Response(
            403,
            headers={"content-type": "application/json"},
            stream=httpx.ByteStream(
                b'{"error":"forbidden","reason":"namespaces \\"prod\\" is forbidden"}',
            ),
        )

    _set_upstream(handler)
    req = _make_request(method="POST", path="/mcp")
    resp = _call(auth_gate.proxy(req))
    body = _call(_drain(resp))
    assert resp.status_code == 403
    assert b'"error_type"' not in body  # not our envelope
    assert b'forbidden' in body


# --- env validation -------------------------------------------------------


def test_env_int_rejects_bad_value(monkeypatch):
    monkeypatch.setenv("BOGUS_INT", "not-a-number")
    with pytest.raises(SystemExit) as ei:
        auth_gate._env_int("BOGUS_INT", "0")
    assert "BOGUS_INT" in str(ei.value)


def test_env_float_rejects_bad_value(monkeypatch):
    monkeypatch.setenv("BOGUS_FLOAT", "five")
    with pytest.raises(SystemExit) as ei:
        auth_gate._env_float("BOGUS_FLOAT", "0")
    assert "BOGUS_FLOAT" in str(ei.value)


def test_env_int_accepts_good_value(monkeypatch):
    monkeypatch.setenv("OK_INT", "42")
    assert auth_gate._env_int("OK_INT", "0") == 42


def test_env_int_falls_back_to_default(monkeypatch):
    monkeypatch.delenv("MISSING_INT", raising=False)
    assert auth_gate._env_int("MISSING_INT", "7") == 7


# --- module-level state ---------------------------------------------------


def test_api_keys_parsed_from_env():
    # Empty-string entries and whitespace are dropped; module-level set is
    # populated from MCP_API_KEYS at import time.
    assert auth_gate.API_KEYS == {"key-a", "key-b"}


def test_hop_by_hop_includes_authorization():
    # Regression guard: don't accidentally start forwarding the caller's
    # bearer to the upstream.
    assert "authorization" in auth_gate._HOP_BY_HOP


def test_hop_by_hop_strips_browser_context_headers():
    # Regression guard: upstream binary has DNS-rebinding/CSRF protection
    # keyed on Origin AND Sec-Fetch-Site. Forwarding any of these gets the
    # browser caller a 403 "cross-origin request detected".
    for h in ("origin", "referer", "sec-fetch-site", "sec-fetch-mode",
              "sec-fetch-dest", "sec-fetch-user"):
        assert h in auth_gate._HOP_BY_HOP, h


def test_proxy_strips_browser_context_headers_outbound():
    captured: list[httpx.Request] = []

    def handler(req: httpx.Request) -> httpx.Response:
        captured.append(req)
        return httpx.Response(200)

    _set_upstream(handler)
    req = _make_request(
        method="POST",
        path="/mcp",
        headers={
            "origin": "https://thunderbolt.hs.fgsci.com",
            "referer": "https://thunderbolt.hs.fgsci.com/chat",
            "sec-fetch-site": "cross-site",
            "sec-fetch-mode": "cors",
            "sec-fetch-dest": "empty",
            "sec-fetch-user": "?1",
            "content-type": "application/json",
        },
    )
    _call(auth_gate.proxy(req))

    seen = {k.lower() for k in captured[0].headers}
    for stripped in ("origin", "referer", "sec-fetch-site", "sec-fetch-mode",
                     "sec-fetch-dest", "sec-fetch-user"):
        assert stripped not in seen, stripped
    assert captured[0].headers["content-type"] == "application/json"


def test_hop_by_hop_includes_rfc7230_set():
    expected = {
        "connection", "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te", "trailer",
        "transfer-encoding", "upgrade",
    }
    assert expected.issubset(auth_gate._HOP_BY_HOP)
