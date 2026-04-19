"""
Minimal SearXNG MCP server.

Exposes `search` and `fetch` tools via the MCP streamable-http transport.

Environment:
  SEARXNG_URL      Base URL of a SearXNG instance (default: http://localhost:8080)
  MCP_API_KEYS     CSV of accepted Bearer tokens; empty/unset disables auth.
  FETCH_MAX_BYTES  Max response size read from `fetch` (default 1 MiB)
  FETCH_TIMEOUT    httpx timeout seconds for `fetch` (default 15)
  SEARCH_TIMEOUT   httpx timeout seconds for `search` (default 15)
  MCP_HOST         Bind host (default 0.0.0.0)
  MCP_PORT         Bind port (default 8000)
"""
import html
import os
from html.parser import HTMLParser
from typing import Optional

import httpx
import uvicorn
from mcp.server.fastmcp import FastMCP
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

SEARXNG_URL = os.environ.get("SEARXNG_URL", "http://localhost:8080").rstrip("/")
API_KEYS = {k.strip() for k in os.environ.get("MCP_API_KEYS", "").split(",") if k.strip()}
FETCH_MAX_BYTES = int(os.environ.get("FETCH_MAX_BYTES", str(1024 * 1024)))
FETCH_TIMEOUT = float(os.environ.get("FETCH_TIMEOUT", "15"))
SEARCH_TIMEOUT = float(os.environ.get("SEARCH_TIMEOUT", "15"))
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = int(os.environ.get("MCP_PORT", "8000"))

mcp = FastMCP("searxng", host=MCP_HOST, port=MCP_PORT)


@mcp.tool()
async def search(
    query: str,
    limit: int = 10,
    categories: Optional[str] = None,
    language: Optional[str] = None,
    time_range: Optional[str] = None,
    safesearch: int = 0,
) -> dict:
    """
    Search the web via SearXNG.

    Args:
      query: search query string
      limit: max results to return (default 10)
      categories: comma-separated SearXNG categories (e.g. "general", "news", "images")
      language: language code (e.g. "en", "de")
      time_range: one of "day", "week", "month", "year"
      safesearch: 0 (off), 1 (moderate), 2 (strict)
    """
    params = {"q": query, "format": "json", "safesearch": str(safesearch)}
    if categories:
        params["categories"] = categories
    if language:
        params["language"] = language
    if time_range:
        params["time_range"] = time_range

    try:
        async with httpx.AsyncClient(timeout=SEARCH_TIMEOUT) as client:
            r = await client.get(f"{SEARXNG_URL}/search", params=params)
            r.raise_for_status()
            data = r.json()
    except httpx.HTTPError as e:
        return {
            "query": query,
            "error": f"{type(e).__name__}: {e}" if str(e) else type(e).__name__,
            "results": [],
        }

    results = [
        {
            "title": item.get("title"),
            "url": item.get("url"),
            "snippet": item.get("content"),
            "engine": item.get("engine"),
            "score": item.get("score"),
            "published_date": item.get("publishedDate"),
        }
        for item in (data.get("results") or [])[:limit]
    ]
    return {
        "query": query,
        "count": len(results),
        "results": results,
        "suggestions": data.get("suggestions", []) or [],
        "infoboxes": [
            {
                "title": b.get("infobox"),
                "content": b.get("content"),
                "urls": b.get("urls"),
            }
            for b in (data.get("infoboxes") or [])
        ],
    }


class _TextExtractor(HTMLParser):
    _SKIP = {"script", "style", "noscript", "head", "nav", "footer", "aside", "svg", "form"}

    def __init__(self):
        super().__init__()
        self._skip = 0
        self.parts: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag in self._SKIP:
            self._skip += 1

    def handle_endtag(self, tag):
        if tag in self._SKIP and self._skip > 0:
            self._skip -= 1

    def handle_data(self, data):
        if self._skip == 0:
            t = data.strip()
            if t:
                self.parts.append(t)


def _html_to_text(body: str) -> str:
    p = _TextExtractor()
    try:
        p.feed(body)
    except Exception:
        return body
    return "\n".join(p.parts)


@mcp.tool()
async def fetch(url: str, max_chars: int = 20000) -> dict:
    """
    Fetch a URL and return its text content. HTML is stripped to plain text.

    Args:
      url: absolute http(s) URL
      max_chars: truncate returned text to this many characters (default 20000)
    """
    try:
        async with httpx.AsyncClient(
            timeout=FETCH_TIMEOUT,
            follow_redirects=True,
            headers={"User-Agent": "searxng-mcp/1.0"},
        ) as client:
            async with client.stream("GET", url) as r:
                ctype = r.headers.get("content-type", "").lower()
                total = 0
                chunks: list[bytes] = []
                async for chunk in r.aiter_bytes():
                    total += len(chunk)
                    if total > FETCH_MAX_BYTES:
                        break
                    chunks.append(chunk)
                final_url = str(r.url)
                status = r.status_code
                if status >= 400:
                    return {
                        "url": final_url,
                        "status": status,
                        "content_type": ctype,
                        "error": f"HTTP {status}",
                        "text": "",
                    }
    except httpx.HTTPError as e:
        return {
            "url": url,
            "error": f"{type(e).__name__}: {e}" if str(e) else type(e).__name__,
            "text": "",
        }

    body = b"".join(chunks)
    text = body.decode(errors="replace")
    if "html" in ctype or (not ctype and "<html" in text[:1024].lower()):
        text = _html_to_text(text)
    text = html.unescape(text)
    text = "\n".join(line for line in (ln.strip() for ln in text.splitlines()) if line)

    truncated = len(text) > max_chars
    if truncated:
        text = text[:max_chars]

    return {
        "url": final_url,
        "status": status,
        "content_type": ctype,
        "bytes_read": total,
        "truncated": truncated,
        "text": text,
    }


class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if API_KEYS and request.method != "OPTIONS":
            header = request.headers.get("authorization", "")
            token = header[7:].strip() if header.lower().startswith("bearer ") else ""
            if not token:
                # Fallback for clients that can't set headers (browser MCP clients).
                token = request.query_params.get("api_key", "").strip()
            if token not in API_KEYS:
                return JSONResponse({"error": "unauthorized"}, status_code=401)
        return await call_next(request)


app = mcp.streamable_http_app()
app.add_middleware(AuthMiddleware)


if __name__ == "__main__":
    uvicorn.run(app, host=MCP_HOST, port=MCP_PORT, log_level="info")
