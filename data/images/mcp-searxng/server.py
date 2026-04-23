"""SearXNG MCP server.

Thin wrapper around a SearXNG instance exposing `search` and `fetch` tools
over the MCP streamable-http transport. Auth is fail-closed (empty
`MCP_API_KEYS` rejects every request). No per-tenant state on disk.

Environment:
  MCP_API_KEYS         CSV of accepted Bearer tokens. Empty/unset is fail-closed.
  MCP_SEARXNG_URL      Base URL of a SearXNG instance (default http://localhost:8080).
  MCP_FETCH_MAX_BYTES  Max response size read from `fetch` (default 10 MiB).
  MCP_FETCH_TIMEOUT    httpx timeout seconds for `fetch` (default 15).
  MCP_FETCH_MAX_REDIRECTS  Max redirect hops in `fetch` (default 5).
  MCP_ALLOWED_PRIVATE_CIDRS  CSV of CIDRs exempted from the private/internal
                             block (e.g. "10.43.0.0/16,fd00::/8"). Hosts whose
                             resolved addresses *all* fall in these CIDRs
                             bypass both the IP blocklist and the hostname
                             blocklist (so cluster-internal DNS works). Default
                             empty (no exemptions).
  MCP_SEARCH_TIMEOUT   httpx timeout seconds for `search` (default 15).
  MCP_HOST             Bind host (default 0.0.0.0).
  MCP_PORT             Bind port (default 8000).
  LOG_LEVEL            debug / info / warning / error (default info).
"""

import html
import ipaddress
import logging
import os
import secrets
import socket
import urllib.parse
from html.parser import HTMLParser
from typing import Annotated, Any

import httpx
import uvicorn
from fastmcp import FastMCP
from pydantic import BaseModel, ConfigDict, Field
from starlette.datastructures import Headers, QueryParams
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

API_KEYS = {k.strip() for k in os.environ.get("MCP_API_KEYS", "").split(",") if k.strip()}
MCP_SEARXNG_URL = os.environ.get("MCP_SEARXNG_URL", "http://localhost:8080").rstrip("/")
MCP_FETCH_MAX_BYTES = int(os.environ.get("MCP_FETCH_MAX_BYTES", str(10 * 1024 * 1024)))
MCP_FETCH_TIMEOUT = float(os.environ.get("MCP_FETCH_TIMEOUT", "15"))
MCP_FETCH_MAX_REDIRECTS = int(os.environ.get("MCP_FETCH_MAX_REDIRECTS", "5"))
MCP_SEARCH_TIMEOUT = float(os.environ.get("MCP_SEARCH_TIMEOUT", "15"))
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = int(os.environ.get("MCP_PORT", "8000"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()


def _parse_cidrs(raw: str) -> list:
    nets: list = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        nets.append(ipaddress.ip_network(item, strict=False))
    return nets


ALLOWED_PRIVATE_CIDRS = _parse_cidrs(os.environ.get("MCP_ALLOWED_PRIVATE_CIDRS", ""))

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.ERROR),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
# httpx logs full request URLs (including query strings) at INFO. Search
# queries and arbitrary fetch URLs land in those logs; mute to WARNING so
# only failures surface.
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("mcp-searxng")
log.info(
    "startup: searxng=%s api_keys=%d allowed_cidrs=%d log_level=%s",
    MCP_SEARXNG_URL, len(API_KEYS), len(ALLOWED_PRIVATE_CIDRS), LOG_LEVEL,
)


class SearchResultItem(BaseModel):
    title: str | None = None
    url: str | None = None
    snippet: str | None = None
    engine: str | None = None
    score: float | None = None
    published_date: str | None = None


class Infobox(BaseModel):
    title: str | None = None
    content: str | None = None
    urls: list[dict] | None = None


class SearchResponse(BaseModel):
    query: str
    count: int = 0
    results: list[SearchResultItem] = Field(default_factory=list)
    suggestions: list[str] = Field(default_factory=list)
    infoboxes: list[Infobox] = Field(default_factory=list)
    error: str | None = None


class FetchResponse(BaseModel):
    url: str
    status: int | None = None
    content_type: str | None = None
    bytes_read: int | None = None
    truncated: bool = False
    text: str = ""
    error: str | None = None


# FastMCP v2: transport (host/port/path) is configured at http_app()/uvicorn
# time, not on the constructor. Constructor takes only the server name +
# instructions.
mcp = FastMCP(
    "searxng",
    instructions=(
        "Two tools for web access:\n"
        "  1. `search(query, ...)` — web search via SearXNG. Returns title/url/"
        "snippet/engine for each hit plus optional infoboxes. Use when you need "
        "to *find* pages.\n"
        "  2. `fetch(url, max_chars=...)` — retrieve a specific URL and return "
        "its plain-text body. HTML is stripped. Use when you already know the "
        "URL (e.g. from a prior `search` result) and need its content.\n\n"
        "`fetch` blocks private, loopback, link-local, and cluster-internal "
        "addresses (SSRF defense) — expect `error: blocked: ...` for those.\n"
        "For small models: lower `max_chars` (1000-5000) to stay within your "
        "context window."
    ),
)


async def _healthz(_request: Any) -> JSONResponse:
    """Liveness + readiness probe target. No auth, no upstream calls."""
    return JSONResponse({"ok": True})


mcp.custom_route("/healthz", methods=["GET"])(_healthz)


@mcp.tool()
async def search(
    query: Annotated[str, Field(min_length=1, max_length=4096, description="Search query string.")],
    limit: Annotated[int, Field(ge=1, le=100)] = 10,
    categories: Annotated[str | None, Field(max_length=256)] = None,
    language: Annotated[str | None, Field(max_length=16)] = None,
    time_range: str | None = None,
    safesearch: Annotated[int, Field(ge=0, le=2)] = 0,
) -> SearchResponse:
    """Search the web via SearXNG.

    Args:
      query: search query string
      limit: max results to return (default 10)
      categories: comma-separated SearXNG categories (e.g. "general", "news", "images")
      language: language code (e.g. "en", "de")
      time_range: one of "day", "week", "month", "year"
      safesearch: 0 (off), 1 (moderate), 2 (strict)
    """
    params: dict[str, str] = {"q": query, "format": "json", "safesearch": str(safesearch)}
    if categories:
        params["categories"] = categories
    if language:
        params["language"] = language
    if time_range:
        params["time_range"] = time_range

    try:
        async with httpx.AsyncClient(timeout=MCP_SEARCH_TIMEOUT) as client:
            r = await client.get(f"{MCP_SEARXNG_URL}/search", params=params)
            r.raise_for_status()
            data = r.json()
    except httpx.HTTPError as e:
        log.warning("search: query=%r failed (%s)", query, type(e).__name__)
        return SearchResponse(
            query=query,
            error=f"upstream unreachable ({type(e).__name__})",
        )
    except ValueError as e:
        # r.json() on malformed upstream bodies raises ValueError — not an
        # httpx.HTTPError — so it has to be caught separately or it would
        # crash the tool dispatcher.
        log.warning("search: query=%r returned non-JSON (%s)", query, type(e).__name__)
        return SearchResponse(
            query=query,
            error=f"upstream returned non-JSON ({type(e).__name__})",
        )

    items = [
        SearchResultItem(
            title=item.get("title"),
            url=item.get("url"),
            snippet=item.get("content"),
            engine=item.get("engine"),
            score=item.get("score"),
            published_date=item.get("publishedDate"),
        )
        for item in (data.get("results") or [])[:limit]
    ]
    infoboxes = [
        Infobox(
            title=b.get("infobox"),
            content=b.get("content"),
            urls=b.get("urls"),
        )
        for b in (data.get("infoboxes") or [])
    ]
    log.info("search: query=%r hits=%d", query, len(items))
    return SearchResponse(
        query=query,
        count=len(items),
        results=items,
        suggestions=data.get("suggestions") or [],
        infoboxes=infoboxes,
    )


# SSRF defense for `fetch`.
#
# Strategy:
#   1. scheme must be http/https,
#   2. reject obvious internal hostnames by name (localhost, *.cluster.local, …),
#   3. resolve via getaddrinfo, reject if ANY returned address is
#      private / loopback / link-local / multicast / reserved / unspecified
#      (covers RFC1918, 127/8, 169.254/16 metadata, IPv6 equivalents,
#      and IPv4-mapped-IPv6 wrappers like ::ffff:10.0.0.1),
#   4. for HTTP, rewrite the URL to use the pre-validated IP and send the
#      original hostname in the Host header — this closes the TOCTOU /
#      DNS-rebinding window because httpx's own resolution is bypassed,
#   5. for HTTPS, keep the hostname in the URL. TLS cert validation is the
#      natural defense: a rebound internal host can't present a valid cert
#      for the original name, so the handshake fails closed.
#   6. redirects are handled manually with `follow_redirects=False` so every
#      hop goes back through the validator.
_BLOCKED_HOSTS = {
    "localhost",
    "ip6-localhost",
    "ip6-loopback",
    "kubernetes",
    "kubernetes.default",
    "metadata",
    "metadata.google.internal",
}
_BLOCKED_SUFFIXES = (
    ".local",
    ".localhost",
    ".cluster.local",
    ".svc",
    ".internal",
    ".arpa",
)


def _reject_hostname(host: str) -> None:
    h = host.lower().rstrip(".")
    if h in _BLOCKED_HOSTS:
        raise PermissionError(f"blocked hostname: {host!r}")
    for suf in _BLOCKED_SUFFIXES:
        if h.endswith(suf):
            raise PermissionError(f"blocked hostname suffix {suf!r}: {host!r}")


def _in_allowlist(addr) -> bool:
    """True if `addr` is inside any MCP_ALLOWED_PRIVATE_CIDRS entry.

    Drills through IPv4-mapped IPv6 so that `::ffff:10.0.0.1` matches a
    `10.0.0.0/8` allowlist entry. Family-matches: v4 addrs only test v4
    nets, v6 only test v6 nets.
    """
    if not ALLOWED_PRIVATE_CIDRS:
        return False
    mapped = getattr(addr, "ipv4_mapped", None)
    check = mapped if mapped is not None else addr
    return any(
        check.version == net.version and check in net
        for net in ALLOWED_PRIVATE_CIDRS
    )


def _reject_ip(ip: str) -> None:
    addr = ipaddress.ip_address(ip)
    if _in_allowlist(addr):
        return
    # IPv4-mapped IPv6 (::ffff:10.0.0.1) — drill through to the v4 view so
    # a mapped RFC1918 address still trips the private/loopback flags.
    mapped = getattr(addr, "ipv4_mapped", None)
    check = mapped if mapped is not None else addr
    if (
        check.is_private
        or check.is_loopback
        or check.is_link_local
        or check.is_reserved
        or check.is_multicast
        or check.is_unspecified
    ):
        raise PermissionError(f"blocked address: {ip}")


def _resolve_and_validate(url: str) -> tuple[str, list[str], int, str]:
    """Parse, name-check, resolve, IP-check. Returns (host, ips, port, scheme).

    Raises PermissionError on any rejection; ValueError for malformed URLs.
    """
    p = urllib.parse.urlsplit(url)
    if p.scheme not in ("http", "https"):
        raise PermissionError(f"scheme not allowed: {p.scheme!r}")
    host = p.hostname
    if not host:
        raise ValueError("url missing host")
    port = p.port or (443 if p.scheme == "https" else 80)
    # IP literal: no DNS, just the address check.
    try:
        _reject_ip(host)
        return host, [host], port, p.scheme
    except ValueError:
        pass  # not an IP literal, fall through to hostname path
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as e:
        raise PermissionError(f"dns resolution failed for {host!r}: {e}") from None
    ips = sorted({info[4][0] for info in infos})
    if not ips:
        raise PermissionError(f"no addresses resolved for {host!r}")
    # Hostname blocklist is skipped when every resolved IP is explicitly
    # allow-listed via MCP_ALLOWED_PRIVATE_CIDRS — the operator has opted in
    # to those ranges, so cluster-internal DNS names resolving inside them
    # should work (e.g. *.svc.cluster.local -> 10.43.0.0/16).
    all_allowed = bool(ALLOWED_PRIVATE_CIDRS) and all(
        _in_allowlist(ipaddress.ip_address(ip)) for ip in ips
    )
    if not all_allowed:
        _reject_hostname(host)
    # Conservative: ALL resolved addresses must be safe. A hostname that
    # resolves to a mix of public and private IPs is rejected outright.
    for ip in ips:
        _reject_ip(ip)
    return host, ips, port, p.scheme


def _pin_url(
    url: str, host: str, ip: str, port: int, scheme: str,
) -> tuple[str, dict[str, str]]:
    """For HTTP, rewrite URL to use `ip` and return a Host header override.

    For HTTPS, return the URL unchanged — the TLS handshake against the
    original hostname provides its own rebind defense.
    """
    if scheme == "https":
        return url, {}
    p = urllib.parse.urlsplit(url)
    ip_host = f"[{ip}]" if ":" in ip else ip
    netloc = ip_host if port == 80 else f"{ip_host}:{port}"
    rewritten = urllib.parse.urlunsplit(
        (scheme, netloc, p.path or "/", p.query, p.fragment),
    )
    host_header = host if port == 80 else f"{host}:{port}"
    return rewritten, {"Host": host_header}


class _TextExtractor(HTMLParser):
    _SKIP = {"script", "style", "noscript", "head", "nav", "footer", "aside", "svg", "form"}

    def __init__(self) -> None:
        super().__init__()
        self._skip = 0
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in self._SKIP:
            self._skip += 1

    def handle_endtag(self, tag: str) -> None:
        if tag in self._SKIP and self._skip > 0:
            self._skip -= 1

    def handle_data(self, data: str) -> None:
        if self._skip == 0:
            t = data.strip()
            if t:
                self.parts.append(t)


def _html_to_text(body: str) -> str:
    # html.parser is lenient by design and doesn't raise on malformed input,
    # so no try/except. If the stdlib parser ever does raise, let it surface
    # rather than silently returning unstripped HTML.
    p = _TextExtractor()
    p.feed(body)
    return "\n".join(p.parts)


@mcp.tool()
async def fetch(
    url: Annotated[str, Field(min_length=1, max_length=2048, description="Absolute http(s) URL to fetch.")],
    max_chars: Annotated[
        int,
        Field(ge=1, le=200000, description="Truncate returned text to this many characters. Lower (1000-5000) for small-context models."),
    ] = 5000,
) -> FetchResponse:
    """Fetch a URL and return its text content. HTML is stripped to plain text.

    Args:
      url: absolute http(s) URL. Private/loopback/link-local/metadata/cluster
           addresses are rejected (SSRF defense).
      max_chars: truncate returned text to this many characters.
    """
    current = url
    status: int | None = None
    ctype = ""
    chunks: list[bytes] = []
    total = 0
    try:
        for _ in range(MCP_FETCH_MAX_REDIRECTS + 1):
            host, ips, port, scheme = _resolve_and_validate(current)
            request_url, host_override = _pin_url(current, host, ips[0], port, scheme)
            hdrs = {"User-Agent": "mcp-searxng/1.0", **host_override}
            async with httpx.AsyncClient(timeout=MCP_FETCH_TIMEOUT) as client:
                async with client.stream("GET", request_url, headers=hdrs) as r:
                    status = r.status_code
                    ctype = r.headers.get("content-type", "").lower()
                    if 300 <= status < 400 and "location" in r.headers:
                        new_url = urllib.parse.urljoin(current, r.headers["location"])
                        log.debug("fetch: %d redirect %s -> %s", status, current, new_url)
                        current = new_url
                        continue
                    if status >= 400:
                        log.info("fetch: %s -> %d", current, status)
                        return FetchResponse(
                            url=current,
                            status=status,
                            content_type=ctype,
                            error=f"HTTP {status}",
                        )
                    async for chunk in r.aiter_bytes():
                        total += len(chunk)
                        if total > MCP_FETCH_MAX_BYTES:
                            break
                        chunks.append(chunk)
                    break
        else:
            raise PermissionError(
                f"too many redirects (> {MCP_FETCH_MAX_REDIRECTS})",
            )
    except PermissionError as e:
        log.warning("fetch: url=%r blocked: %s", url, e)
        return FetchResponse(url=current, error=f"blocked: {e}")
    except httpx.HTTPError as e:
        # Scrub `str(e)` — httpx exception text can include the upstream
        # hostname/IP. The caller already has the URL; no need to echo it.
        log.warning("fetch: url=%r failed (%s)", current, type(e).__name__)
        return FetchResponse(
            url=current,
            error=f"upstream unreachable ({type(e).__name__})",
        )

    body = b"".join(chunks)
    text = body.decode(errors="replace")
    if "html" in ctype or (not ctype and "<html" in text[:1024].lower()):
        text = _html_to_text(text)
    text = html.unescape(text)
    # Truncate before line-filtering to bound CPU on multi-MiB responses.
    # We overshoot by 2x so trailing-whitespace trimming can't leave us
    # short of max_chars after filtering.
    if len(text) > max_chars * 2:
        text = text[: max_chars * 2]
    text = "\n".join(line for line in (ln.strip() for ln in text.splitlines()) if line)

    truncated = len(text) > max_chars
    if truncated:
        text = text[:max_chars]

    log.info("fetch: %s -> %d bytes=%d truncated=%s", current, status, total, truncated)
    return FetchResponse(
        url=current,
        status=status,
        content_type=ctype,
        bytes_read=total,
        truncated=truncated,
        text=text,
    )


# Pure ASGI middleware (not BaseHTTPMiddleware): keeps the whole request in
# one task so nothing gets dropped across anyio task boundaries. Matches
# mcp-memory / mcp-filesystem shape; this server has no per-tenant state so
# no contextvar is bound — the token is only used to authorize the request.
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

        # Unauthenticated health probe — kubelet sends no bearer.
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
            client = scope.get("client")
            log.warning(
                "auth: rejected %s %r from %s",
                method, scope["path"], client[0] if client else "?",
            )
            await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
            return

        log.debug("auth: ok %s %r", method, scope["path"])
        await self.app(scope, receive, send)


app = mcp.http_app(
    path="/",
    middleware=[Middleware(AuthMiddleware)],
)


if __name__ == "__main__":
    uvicorn.run(app, host=MCP_HOST, port=MCP_PORT, log_level=LOG_LEVEL.lower(), access_log=False)
