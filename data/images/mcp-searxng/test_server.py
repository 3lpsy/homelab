"""
Unit tests for mcp-searxng server.py.

Runs the tool functions directly (bypassing FastMCP dispatch) with a
fake httpx.AsyncClient. Run with:

  uv run --with pytest --with fastmcp --with pydantic --with httpx \
         --with uvicorn --with starlette pytest test_server.py
"""
# Make the sibling `data/images/mcp-common/` package importable for tests
# without polluting `data/images/` with a top-level pyproject.toml + conftest.
import pathlib as _pathlib
import sys as _sys

_sys.path.insert(0, str(_pathlib.Path(__file__).resolve().parent.parent / "mcp-common"))

import asyncio
import os
import socket

os.environ["MCP_API_KEYS"] = "key-a,key-b"
os.environ["MCP_SEARXNG_URL"] = "http://searxng.test"
os.environ.setdefault("LOG_LEVEL", "error")

import httpx  # noqa: E402
import pytest  # noqa: E402

from mcp_common.testing import make_http_scope, run_auth  # noqa: E402

import server  # noqa: E402


def _call(coro):
    return asyncio.run(coro)


# --- httpx.AsyncClient fakes -------------------------------------------------


def _fake_get_client(json_data=None, status=200, raise_exc=None):
    """Fake AsyncClient whose `.get()` returns a canned JSON response."""
    captured: dict = {}

    class _Resp:
        def __init__(self):
            self.status_code = status

        def raise_for_status(self):
            if raise_exc is not None:
                raise raise_exc

        def json(self):
            return json_data or {}

    class _Client:
        def __init__(self, **kwargs):
            captured["kwargs"] = kwargs

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return None

        async def get(self, url, params=None):
            captured["url"] = url
            captured["params"] = params
            return _Resp()

    return _Client, captured


def _fake_stream_seq(responses):
    """Fake AsyncClient whose `.stream()` returns the next canned response.

    Each entry: {"chunks": [b"..."], "headers": {...}, "status": int}.
    Keys in `headers` should be lowercase.
    """
    calls: list[dict] = []

    class _Stream:
        def __init__(self, spec):
            self.status_code = spec["status"]
            self.headers = httpx.Headers(spec.get("headers") or {})
            self.url = spec.get("final_url", "")
            self._chunks = spec.get("chunks") or []

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return None

        async def aiter_bytes(self):
            for c in self._chunks:
                yield c

    class _Client:
        def __init__(self, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return None

        def stream(self, method, url, headers=None):
            idx = min(len(calls), len(responses) - 1)
            calls.append({"method": method, "url": url, "headers": dict(headers or {})})
            return _Stream(responses[idx])

    return _Client, calls


def _fake_stream_client(*, chunks, headers, status, final_url="", raise_exc=None):
    """One-shot stream client. Shim over _fake_stream_seq for existing tests."""
    if raise_exc is not None:
        class _Client:
            def __init__(self, **kwargs):
                raise raise_exc

            async def __aenter__(self):
                return self

            async def __aexit__(self, *a):
                return None
        return _Client, []
    return _fake_stream_seq([{
        "chunks": chunks, "headers": headers, "status": status, "final_url": final_url,
    }])


# Happy-path fetch tests target a public IP literal so SSRF validation passes
# without touching real DNS.
PUBLIC = "1.1.1.1"


# --- search -----------------------------------------------------------------


def test_search_builds_params_omits_none(monkeypatch):
    Client, cap = _fake_get_client(json_data={"results": []})
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.search("hello"))
    assert isinstance(resp, server.SearchResponse)
    assert cap["url"] == "http://searxng.test/search"
    assert cap["params"] == {"q": "hello", "format": "json", "safesearch": "0"}


def test_search_passes_optional_params(monkeypatch):
    Client, cap = _fake_get_client(json_data={"results": []})
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    _call(server.search(
        "cats",
        categories="news",
        language="en",
        time_range="week",
        safesearch=2,
    ))
    assert cap["params"] == {
        "q": "cats",
        "format": "json",
        "safesearch": "2",
        "categories": "news",
        "language": "en",
        "time_range": "week",
    }


def test_search_applies_limit(monkeypatch):
    results = [
        {"title": f"r{i}", "url": f"http://x/{i}", "content": "c"}
        for i in range(10)
    ]
    Client, _ = _fake_get_client(json_data={"results": results})
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.search("q", limit=3))
    assert resp.count == 3
    assert [r.title for r in resp.results] == ["r0", "r1", "r2"]


def test_search_shapes_result_model(monkeypatch):
    upstream = {
        "results": [{
            "title": "T",
            "url": "http://x",
            "content": "snippet",
            "engine": "ddg",
            "score": 1.5,
            "publishedDate": "2026-01-01",
        }],
        "suggestions": ["sug"],
        "infoboxes": [{"infobox": "IB", "content": "body", "urls": [{"url": "u"}]}],
    }
    Client, _ = _fake_get_client(json_data=upstream)
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.search("q"))
    r0 = resp.results[0]
    assert r0.title == "T"
    assert r0.snippet == "snippet"
    assert r0.engine == "ddg"
    assert r0.score == 1.5
    assert r0.published_date == "2026-01-01"
    assert resp.suggestions == ["sug"]
    assert resp.infoboxes[0].title == "IB"
    assert resp.infoboxes[0].urls == [{"url": "u"}]


def test_search_drops_unknown_category_and_reports_it(monkeypatch):
    # SearXNG silently drops unknown categories — an LLM's hallucinated
    # filter would otherwise fall back to default with no signal. We
    # pre-filter against KNOWN_CATEGORIES, strip unknowns from the upstream
    # params, and surface them in `dropped_categories`.
    Client, cap = _fake_get_client(json_data={"results": []})
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.search("q", categories="news,bogus,science"))
    # Kept categories reach upstream; unknown stripped.
    assert cap["params"]["categories"] == "news,science"
    assert resp.dropped_categories == ["bogus"]


def test_search_all_unknown_categories_omits_param(monkeypatch):
    # When every supplied category is unknown, `categories` param must be
    # omitted entirely — otherwise SearXNG would see an empty string.
    Client, cap = _fake_get_client(json_data={"results": []})
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.search("q", categories="bogus1,bogus2"))
    assert "categories" not in cap["params"]
    assert resp.dropped_categories == ["bogus1", "bogus2"]


def test_search_case_insensitive_category_match(monkeypatch):
    # KNOWN_CATEGORIES is lowercase, but SearXNG is case-sensitive on the
    # wire. Caller may send "News" or "GENERAL"; keep the original casing
    # on the way out so the upstream still honors it.
    Client, cap = _fake_get_client(json_data={"results": []})
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.search("q", categories="News,GENERAL"))
    assert cap["params"]["categories"] == "News,GENERAL"
    assert resp.dropped_categories == []


def test_search_social_media_category_allowed(monkeypatch):
    # "social media" contains a space and is a legit SearXNG category —
    # make sure the trim logic doesn't mangle it.
    Client, cap = _fake_get_client(json_data={"results": []})
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.search("q", categories="social media,news"))
    assert cap["params"]["categories"] == "social media,news"
    assert resp.dropped_categories == []


def test_search_http_error_returns_error_payload(monkeypatch):
    err = httpx.ConnectError("boom")
    Client, _ = _fake_get_client(raise_exc=err)
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.search("q"))
    assert resp.results == []
    assert resp.error is not None
    assert "ConnectError" in resp.error


# --- fetch happy paths ------------------------------------------------------


def test_fetch_html_stripped(monkeypatch):
    body = (
        b"<html><head><title>T</title>"
        b"<script>alert('x')</script></head>"
        b"<body><p>hello</p><p>world</p></body></html>"
    )
    Client, _ = _fake_stream_client(
        chunks=[body],
        headers={"content-type": "text/html; charset=utf-8"},
        status=200,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.fetch(f"http://{PUBLIC}/"))
    assert resp.status == 200
    assert "alert" not in resp.text
    assert "hello" in resp.text
    assert "world" in resp.text
    assert resp.truncated is False


def test_fetch_pins_ip_and_sets_host_header(monkeypatch):
    Client, calls = _fake_stream_client(
        chunks=[b"ok"],
        headers={"content-type": "text/plain"},
        status=200,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)
    # Fake DNS: example.test -> 1.1.1.1 (public).
    monkeypatch.setattr(
        server.socket, "getaddrinfo",
        lambda h, p, **kw: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (PUBLIC, p))],
    )

    _call(server.fetch("http://example.test/page"))
    assert calls, "stream was not called"
    sent_url = calls[0]["url"]
    # URL rewritten to use the pre-validated IP.
    assert PUBLIC in sent_url
    assert "example.test" not in sent_url
    # Original hostname travels in the Host header instead.
    assert calls[0]["headers"].get("Host") == "example.test"


def test_fetch_respects_max_chars(monkeypatch):
    body = ("x" * 1000).encode()
    Client, _ = _fake_stream_client(
        chunks=[body],
        headers={"content-type": "text/plain"},
        status=200,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.fetch(f"http://{PUBLIC}/", max_chars=50))
    assert resp.truncated is True
    assert len(resp.text) == 50


def test_fetch_cap_bytes_stops_reading(monkeypatch):
    monkeypatch.setattr(server, "MCP_FETCH_MAX_BYTES", 600)
    chunks = [b"a" * 500, b"b" * 500, b"c" * 500]
    Client, _ = _fake_stream_client(
        chunks=chunks,
        headers={"content-type": "text/plain"},
        status=200,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.fetch(f"http://{PUBLIC}/"))
    assert resp.bytes_read >= 1000
    assert "b" not in resp.text
    assert resp.text.startswith("a")


def test_fetch_http_error_status(monkeypatch):
    Client, _ = _fake_stream_client(
        chunks=[b"<html>oops</html>"],
        headers={"content-type": "text/html"},
        status=500,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.fetch(f"http://{PUBLIC}/"))
    assert resp.status == 500
    assert resp.error == "HTTP 500"
    assert resp.text == ""


def test_fetch_transport_error_returns_error(monkeypatch):
    err = httpx.ConnectError("nope")

    class _Client:
        def __init__(self, **kwargs):
            pass

        async def __aenter__(self):
            raise err

        async def __aexit__(self, *a):
            return None

    monkeypatch.setattr(server.httpx, "AsyncClient", _Client)
    resp = _call(server.fetch(f"http://{PUBLIC}/"))
    assert resp.status is None
    assert "ConnectError" in (resp.error or "")


# --- SSRF blocks ------------------------------------------------------------


@pytest.mark.parametrize("url", [
    "http://127.0.0.1/",
    "http://10.0.0.5/",
    "http://192.168.1.1/",
    "http://169.254.169.254/latest/meta-data/",  # AWS metadata
    "http://[::1]/",                              # IPv6 loopback
    "http://[::ffff:10.0.0.1]/",                  # IPv4-mapped private
    "http://[fe80::1]/",                          # IPv6 link-local
    "http://0.0.0.0/",                            # unspecified
])
def test_fetch_blocks_private_and_reserved_ips(url):
    resp = _call(server.fetch(url))
    assert resp.error and "blocked" in resp.error, f"expected block for {url}, got {resp.error!r}"


@pytest.mark.parametrize("url", [
    "http://localhost/",
    "http://kubernetes.default/",
    "http://metadata.google.internal/",
    "http://foo.cluster.local/",
    "http://bar.svc/",
    "http://baz.internal/",
    "http://anything.local/",
])
def test_fetch_blocks_internal_hostnames(url):
    resp = _call(server.fetch(url))
    assert resp.error and "blocked" in resp.error, f"expected block for {url}, got {resp.error!r}"


@pytest.mark.parametrize("url", [
    "file:///etc/passwd",
    "ftp://example.com/",
    "gopher://example.com/",
])
def test_fetch_blocks_non_http_schemes(url):
    resp = _call(server.fetch(url))
    assert resp.error and "blocked" in resp.error


def test_fetch_blocks_hostname_resolving_to_private(monkeypatch):
    # DNS rebind-ish: a hostname that passes name checks but resolves to RFC1918.
    monkeypatch.setattr(
        server.socket, "getaddrinfo",
        lambda h, p, **kw: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.1.2.3", p))],
    )
    resp = _call(server.fetch("http://evil.example.com/"))
    assert resp.error and "blocked" in resp.error
    assert "10.1.2.3" in resp.error


def test_fetch_rejects_hostname_with_mixed_public_and_private(monkeypatch):
    # If a name resolves to both public and private addresses, reject.
    monkeypatch.setattr(
        server.socket, "getaddrinfo",
        lambda h, p, **kw: [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", (PUBLIC, p)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.0.0.5", p)),
        ],
    )
    resp = _call(server.fetch("http://mixed.example.com/"))
    assert resp.error and "blocked" in resp.error


def test_fetch_blocks_dns_failure(monkeypatch):
    def _fail(*a, **kw):
        raise socket.gaierror(-2, "Name or service not known")
    monkeypatch.setattr(server.socket, "getaddrinfo", _fail)
    resp = _call(server.fetch("http://no-such-host.example/"))
    assert resp.error and "blocked" in resp.error
    assert "dns resolution failed" in resp.error


# --- redirect handling ------------------------------------------------------


def test_fetch_follows_safe_redirect(monkeypatch):
    # 1st hop 302 → public IP; 2nd hop 200.
    responses = [
        {"status": 302, "headers": {"location": f"http://{PUBLIC}/final"}},
        {"status": 200, "headers": {"content-type": "text/plain"}, "chunks": [b"done"]},
    ]
    Client, calls = _fake_stream_seq(responses)
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.fetch(f"http://{PUBLIC}/start"))
    assert resp.status == 200
    assert resp.text == "done"
    assert len(calls) == 2
    assert calls[1]["url"].endswith("/final")


def test_fetch_blocks_redirect_to_private(monkeypatch):
    # 302 Location points at a loopback IP — must be rejected before the 2nd GET.
    responses = [
        {"status": 302, "headers": {"location": "http://127.0.0.1/leak"}},
        # If the validator misses, this would serve — test fails loudly.
        {"status": 200, "headers": {"content-type": "text/plain"}, "chunks": [b"leaked"]},
    ]
    Client, calls = _fake_stream_seq(responses)
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.fetch(f"http://{PUBLIC}/start"))
    assert resp.error and "blocked" in resp.error
    # Only the first hop should have hit the fake.
    assert len(calls) == 1


def test_fetch_max_redirects(monkeypatch):
    monkeypatch.setattr(server, "MCP_FETCH_MAX_REDIRECTS", 2)
    # Infinite redirect loop between two public IPs.
    responses = [{"status": 302, "headers": {"location": f"http://{PUBLIC}/next"}}] * 10
    Client, _ = _fake_stream_seq(responses)
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)

    resp = _call(server.fetch(f"http://{PUBLIC}/"))
    assert resp.error and "too many redirects" in resp.error


def test_fetch_https_does_not_rewrite_url(monkeypatch):
    Client, calls = _fake_stream_client(
        chunks=[b"ok"],
        headers={"content-type": "text/plain"},
        status=200,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)
    monkeypatch.setattr(
        server.socket, "getaddrinfo",
        lambda h, p, **kw: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (PUBLIC, p))],
    )

    _call(server.fetch("https://example.test/p"))
    sent_url = calls[0]["url"]
    # HTTPS keeps hostname in URL (SNI + cert validation does the rest).
    assert sent_url == "https://example.test/p"
    assert "Host" not in calls[0]["headers"]


# --- HTML extractor ---------------------------------------------------------


def test_text_extractor_skips_skip_tags():
    body = (
        "<html><head><style>body{color:red}</style></head>"
        "<body><nav>NAV</nav><script>S</script>"
        "<p>keep</p><aside>ASIDE</aside></body></html>"
    )
    out = server._html_to_text(body)
    assert "keep" in out
    for dropped in ("NAV", "S", "ASIDE", "color:red"):
        assert dropped not in out


# --- validator unit tests ---------------------------------------------------


def test_reject_ip_accepts_public():
    # Does not raise.
    server._reject_ip("1.1.1.1")
    server._reject_ip("8.8.8.8")
    server._reject_ip("2606:4700:4700::1111")  # Cloudflare public v6


@pytest.mark.parametrize("ip", [
    "127.0.0.1", "10.0.0.1", "192.168.5.5", "172.16.0.1",
    "169.254.169.254", "0.0.0.0", "224.0.0.1",
    "::1", "fe80::1", "::ffff:10.0.0.1",
])
def test_reject_ip_blocks_internal(ip):
    with pytest.raises(PermissionError):
        server._reject_ip(ip)


def test_pin_url_http_rewrites_and_adds_host():
    url, hdrs = server._pin_url("http://example.test/x?q=1", "example.test", "1.2.3.4", 80, "http")
    assert url == "http://1.2.3.4/x?q=1"
    assert hdrs == {"Host": "example.test"}


def test_pin_url_http_with_nondefault_port():
    url, hdrs = server._pin_url("http://example.test:8080/x", "example.test", "1.2.3.4", 8080, "http")
    assert url == "http://1.2.3.4:8080/x"
    assert hdrs == {"Host": "example.test:8080"}


def test_pin_url_https_unchanged():
    url, hdrs = server._pin_url("https://example.test/x", "example.test", "1.2.3.4", 443, "https")
    assert url == "https://example.test/x"
    assert hdrs == {}


def test_pin_url_ipv6_bracketed():
    url, hdrs = server._pin_url(
        "http://example.test/x", "example.test", "2001:db8::1", 80, "http",
    )
    assert url == "http://[2001:db8::1]/x"


# --- allowlist (MCP_ALLOWED_PRIVATE_CIDRS) ----------------------------------


import ipaddress as _ipaddr  # noqa: E402


def _set_allowlist(monkeypatch, cidrs):
    nets = [_ipaddr.ip_network(c, strict=False) for c in cidrs]
    monkeypatch.setattr(server, "ALLOWED_PRIVATE_CIDRS", nets)


def test_allowlist_permits_ip_literal(monkeypatch):
    _set_allowlist(monkeypatch, ["10.43.0.0/16"])
    Client, _ = _fake_stream_client(
        chunks=[b"ok"],
        headers={"content-type": "text/plain"},
        status=200,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)
    resp = _call(server.fetch("http://10.43.1.5/"))
    assert resp.status == 200
    assert resp.text == "ok"


def test_allowlist_still_blocks_outside_cidr(monkeypatch):
    _set_allowlist(monkeypatch, ["10.43.0.0/16"])
    resp = _call(server.fetch("http://10.44.0.1/"))  # outside allowed CIDR
    assert resp.error and "blocked" in resp.error


def test_allowlist_skips_hostname_block_when_all_ips_allowed(monkeypatch):
    # *.svc.cluster.local would normally be rejected by the name blocklist,
    # but with its IP range in the allowlist it should fetch.
    _set_allowlist(monkeypatch, ["10.43.0.0/16"])
    monkeypatch.setattr(
        server.socket, "getaddrinfo",
        lambda h, p, **kw: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.43.2.7", p))],
    )
    Client, calls = _fake_stream_client(
        chunks=[b"hi"],
        headers={"content-type": "text/plain"},
        status=200,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)
    resp = _call(server.fetch("http://my-svc.default.svc.cluster.local/"))
    assert resp.status == 200
    assert "10.43.2.7" in calls[0]["url"]


def test_allowlist_enforces_name_block_when_ip_outside(monkeypatch):
    # Hostname resolves to a public IP — hostname block should still apply
    # for suffix-blocked names, so `.cluster.local` with a non-allowed IP
    # is rejected.
    _set_allowlist(monkeypatch, ["10.43.0.0/16"])
    monkeypatch.setattr(
        server.socket, "getaddrinfo",
        lambda h, p, **kw: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (PUBLIC, p))],
    )
    resp = _call(server.fetch("http://foo.cluster.local/"))
    assert resp.error and "blocked" in resp.error


def test_allowlist_partial_is_rejected(monkeypatch):
    # Mixed resolve: one in allowlist, one outside → rejected.
    _set_allowlist(monkeypatch, ["10.43.0.0/16"])
    monkeypatch.setattr(
        server.socket, "getaddrinfo",
        lambda h, p, **kw: [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.43.0.1", p)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.99.0.1", p)),
        ],
    )
    resp = _call(server.fetch("http://mixed.example/"))
    assert resp.error and "blocked" in resp.error


def test_allowlist_ipv6(monkeypatch):
    _set_allowlist(monkeypatch, ["fd00::/8"])
    Client, _ = _fake_stream_client(
        chunks=[b"ok"],
        headers={"content-type": "text/plain"},
        status=200,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)
    resp = _call(server.fetch("http://[fd12:3456::1]/"))
    assert resp.status == 200


def test_allowlist_ipv4_mapped_ipv6(monkeypatch):
    _set_allowlist(monkeypatch, ["10.0.0.0/8"])
    Client, _ = _fake_stream_client(
        chunks=[b"ok"],
        headers={"content-type": "text/plain"},
        status=200,
    )
    monkeypatch.setattr(server.httpx, "AsyncClient", Client)
    resp = _call(server.fetch("http://[::ffff:10.0.0.1]/"))
    assert resp.status == 200


def test_allowlist_empty_default_blocks_private():
    # With no allowlist, private IPs are still blocked (default behavior).
    # (ALLOWED_PRIVATE_CIDRS is empty at import time; this test just
    # guards against accidental allow-all regressions.)
    assert server.ALLOWED_PRIVATE_CIDRS == []
    resp = _call(server.fetch("http://10.0.0.1/"))
    assert resp.error and "blocked" in resp.error


def test_parse_cidrs_accepts_mixed_families_and_host_bits():
    nets = server._parse_cidrs("10.0.0.0/8 , 192.168.1.5/24, fd00::/8, ")
    assert len(nets) == 3
    # strict=False normalized the 192.168.1.5/24 host-bit form.
    assert str(nets[1]) == "192.168.1.0/24"


# --- auth middleware --------------------------------------------------------


def test_auth_rejects_missing_bearer():
    sent = run_auth(make_http_scope(method="POST", path="/mcp/"), api_keys=server.API_KEYS)
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 401


def test_auth_accepts_valid_bearer():
    sent = run_auth(
        make_http_scope(
            method="POST",
            path="/mcp/",
            headers=[(b"authorization", b"Bearer key-a")],
        ),
        api_keys=server.API_KEYS,
    )
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 200


def test_auth_accepts_query_param_key():
    sent = run_auth(
        make_http_scope(method="POST", path="/mcp/", query=b"api_key=key-b"),
        api_keys=server.API_KEYS,
    )
    start = next(m for m in sent if m["type"] == "http.response.start")
    assert start["status"] == 200
