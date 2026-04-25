"""LiteLLM spend MCP server.

Readonly wrapper around LiteLLM proxy spend endpoints. Scopes queries by
LiteLLM virtual-key *hash* (the SHA-256 stored in
LiteLLM_VerificationTokenTable.token, shown as "Hashed Token" in the UI)
rather than forcing each client to hold its own LiteLLM virtual key.

Auth + scope model:
  1. Client authenticates with an MCP bearer (via `Authorization: Bearer ...`
     or `?api_key=`) validated against MCP_API_KEYS.
  2. Each MCP bearer is bound to an allowlist of LiteLLM key hashes
     (MCP_KEY_HASH_MAP, JSON `{<mcp_bearer>: [<hash>, ...]}`). Only hashes
     in that list can be queried by the caller. Tools take `key_hash` as
     an explicit argument and reject any hash outside the allowlist with
     timing-safe comparison.
  3. Upstream calls always use LITELLM_MASTER_KEY as bearer. The master
     key never leaves the pod. The MCP only hits a hardcoded set of GET
     paths — no path/passthrough, no write endpoints.

Environment:
  MCP_API_KEYS          CSV of accepted MCP Bearer tokens. Empty = fail-closed.
  MCP_KEY_HASH_MAP      JSON: {<mcp_bearer>: [<litellm_key_hash>, ...]}.
                        Bearers not present or with [] can't query any spend.
  LITELLM_BASE_URL      LiteLLM proxy base URL (required, reached via tailnet).
  LITELLM_MASTER_KEY    LiteLLM master key (required). Never leaves the pod.
  LITELLM_TLS_SKIP_VERIFY  "true"/"1" to disable TLS verify. Default false.
  MCP_UPSTREAM_TIMEOUT  httpx timeout seconds (default 60).
  MCP_MAX_LOGS          Hard cap on /spend/logs rows returned per tool call
                        (default 2000). Aggregation tools respect it too.
  MCP_HOST              Bind host (default 0.0.0.0).
  MCP_PORT              Bind port (default 8000).
  LOG_LEVEL             debug / info / warning / error (default info).
"""

import asyncio
import calendar
import json
import logging
import os
import re
import secrets
from contextvars import ContextVar
from datetime import date, datetime
from typing import Annotated, Any

import httpx
import uvicorn
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import BaseModel, ConfigDict, Field
from starlette.datastructures import Headers, QueryParams
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send


def _env_float(name: str, default: str) -> float:
    raw = os.environ.get(name, default)
    try:
        return float(raw)
    except ValueError as e:
        raise SystemExit(f"{name} must be a float, got {raw!r}") from e


def _env_int(name: str, default: str) -> int:
    raw = os.environ.get(name, default)
    try:
        return int(raw)
    except ValueError as e:
        raise SystemExit(f"{name} must be an int, got {raw!r}") from e


def _parse_hash_map(raw: str) -> dict[str, frozenset[str]]:
    """Parse MCP_KEY_HASH_MAP JSON into `{bearer: frozenset(hash...)}`.

    Fail-closed on parse errors at startup — a malformed map would otherwise
    silently authorise nothing, which is hard to debug. Empty/unset is ok
    (every bearer gets an empty allowlist)."""
    if not raw.strip():
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as e:
        raise SystemExit(f"MCP_KEY_HASH_MAP must be valid JSON: {e}") from e
    if not isinstance(parsed, dict):
        raise SystemExit("MCP_KEY_HASH_MAP must be a JSON object")
    out: dict[str, frozenset[str]] = {}
    for bearer, hashes in parsed.items():
        if not isinstance(bearer, str):
            raise SystemExit(f"MCP_KEY_HASH_MAP keys must be strings, got {type(bearer).__name__}")
        if not isinstance(hashes, list):
            raise SystemExit(f"MCP_KEY_HASH_MAP[{bearer!r}] must be a list")
        cleaned: list[str] = []
        for h in hashes:
            if not isinstance(h, str) or len(h) != 64 or not all(c in "0123456789abcdef" for c in h):
                raise SystemExit(
                    f"MCP_KEY_HASH_MAP[{bearer!r}] contains non-hash entry: {h!r} "
                    "(expected 64-char lowercase hex)"
                )
            cleaned.append(h)
        out[bearer] = frozenset(cleaned)
    return out


API_KEYS = {k.strip() for k in os.environ.get("MCP_API_KEYS", "").split(",") if k.strip()}
KEY_HASH_MAP = _parse_hash_map(os.environ.get("MCP_KEY_HASH_MAP", ""))
LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "").rstrip("/")
LITELLM_MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "")
LITELLM_TLS_SKIP_VERIFY = os.environ.get("LITELLM_TLS_SKIP_VERIFY", "").lower() in ("1", "true", "yes")
MCP_UPSTREAM_TIMEOUT = _env_float("MCP_UPSTREAM_TIMEOUT", "60")
MCP_MAX_LOGS = _env_int("MCP_MAX_LOGS", "2000")
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = _env_int("MCP_PORT", "8000")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
# httpx logs full request URLs (including query strings) at INFO. URLs may
# carry per-tenant identifiers or future query-string credentials; mute to
# WARNING so only failures surface.
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("mcp-litellm")

if not LITELLM_BASE_URL:
    raise SystemExit("LITELLM_BASE_URL must be set")
if not LITELLM_MASTER_KEY:
    raise SystemExit("LITELLM_MASTER_KEY must be set")

log.info(
    "startup: litellm=%s api_keys=%d hash_map_tenants=%d hash_map_hashes=%d tls_skip_verify=%s timeout=%.1fs max_logs=%d log_level=%s",
    LITELLM_BASE_URL,
    len(API_KEYS),
    len(KEY_HASH_MAP),
    sum(len(v) for v in KEY_HASH_MAP.values()),
    LITELLM_TLS_SKIP_VERIFY,
    MCP_UPSTREAM_TIMEOUT,
    MCP_MAX_LOGS,
    LOG_LEVEL,
)


# Per-request allowed-hash set, bound by AuthMiddleware.
current_allowed_hashes: ContextVar[frozenset[str]] = ContextVar(
    "current_allowed_hashes", default=frozenset()
)


def _allowlist() -> frozenset[str]:
    return current_allowed_hashes.get()


def _validate_hash(key_hash: str) -> str:
    """Reject hashes not in the caller's allowlist.

    Timing-safe comparison — stops a caller who gets 403 on a random hash
    from binary-searching which hashes exist in other tenants' allowlists.
    """
    allow = _allowlist()
    if not allow:
        raise ToolError(
            "No LiteLLM key hashes are bound to this MCP bearer. "
            "Ask your admin to add your key's hash to the MCP key-hash map."
        )
    # Canonicalise then timing-safe check against every entry.
    kh = key_hash.strip().lower()
    if len(kh) != 64 or not all(c in "0123456789abcdef" for c in kh):
        raise ToolError(f"key_hash must be 64-char lowercase hex, got {key_hash!r}")
    if not any(secrets.compare_digest(kh, a) for a in allow):
        raise ToolError("key_hash not in this MCP bearer's allowlist")
    return kh


def _resolve_hash(key_hash: str | None) -> str:
    """Validate an explicit hash, or default to the sole allowlist entry.

    Small OSS models routinely mangle 64-char hex. When the caller's
    allowlist has exactly one entry, let them omit `key_hash` entirely —
    the common single-key tenant case. With multiple entries we require
    an explicit choice so the LLM can't silently query the wrong key."""
    if key_hash is not None:
        return _validate_hash(key_hash)
    allow = _allowlist()
    if not allow:
        raise ToolError(
            "No LiteLLM key hashes are bound to this MCP bearer. "
            "Ask your admin to add your key's hash to the MCP key-hash map."
        )
    if len(allow) > 1:
        raise ToolError(
            f"Multiple key hashes in allowlist ({len(allow)}). "
            "Call `list_my_keys` and pass one as `key_hash`."
        )
    return next(iter(allow))


# --- Pydantic response models --------------------------------------------


class KeyInfo(BaseModel):
    # Whitelist only the fields a caller should ever see. LiteLLM's
    # /key/info row also carries user_id, team_id, metadata blobs,
    # object_permission, etc. — never surface those to an MCP tenant.
    model_config = ConfigDict(extra="ignore")
    key_hash: str
    key_alias: str | None = None
    spend: float | None = None
    max_budget: float | None = None
    models: list[str] | None = None
    tpm_limit: int | None = None
    rpm_limit: int | None = None
    budget_duration: str | None = None
    created_at: str | None = None
    expires: str | None = None


class SpendLogEntry(BaseModel):
    model_config = ConfigDict(extra="allow")


class SpendLogs(BaseModel):
    model_config = ConfigDict(extra="forbid")
    key_hash: str
    start_date: str
    end_date: str
    count: int
    truncated: bool = False
    logs: list[dict[str, Any]]


class DailyRow(BaseModel):
    model_config = ConfigDict(extra="forbid")
    date: str
    spend: float
    total_tokens: int
    prompt_tokens: int
    completion_tokens: int
    request_count: int
    by_model: dict[str, float]


class DailySummary(BaseModel):
    model_config = ConfigDict(extra="forbid")
    key_hash: str
    start_date: str
    end_date: str
    days: list[DailyRow]
    total_spend: float
    total_tokens: int
    total_requests: int
    log_count: int
    # Rows upstream returned that had no parseable startTime — excluded from
    # day buckets. Non-zero here explains `sum(days[*].request_count) <
    # log_count` so a caller isn't confused by the mismatch.
    skipped_rows: int = 0
    truncated: bool = False


class MonthlySummary(BaseModel):
    model_config = ConfigDict(extra="forbid")
    key_hash: str
    month: str
    start_date: str
    end_date: str
    total_spend: float
    total_tokens: int
    prompt_tokens: int
    completion_tokens: int
    total_requests: int
    by_model: dict[str, float]
    by_day: dict[str, float]
    log_count: int
    skipped_rows: int = 0
    truncated: bool = False


class MyKey(BaseModel):
    model_config = ConfigDict(extra="forbid")
    key_hash: str
    key_alias: str | None = None
    spend: float | None = None
    max_budget: float | None = None
    models: list[str] | None = None
    error: str | None = None  # set when /key/info failed for that hash


class MyKeysResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    keys: list[MyKey]


# --- HTTP client -----------------------------------------------------------


# Module-level singleton. Reusing a single AsyncClient keeps the TLS +
# HTTP keepalive pool warm — a fresh client per call would handshake the
# tailnet hop on every /spend/logs/v2 page (~30-80ms each).
_http_singleton = httpx.AsyncClient(
    base_url=LITELLM_BASE_URL,
    headers={
        "User-Agent": "mcp-litellm/2.0",
        "Authorization": f"Bearer {LITELLM_MASTER_KEY}",
    },
    verify=not LITELLM_TLS_SKIP_VERIFY,
    timeout=MCP_UPSTREAM_TIMEOUT,
)


def _client() -> httpx.AsyncClient:
    """Return the singleton httpx client. Kept as a function so tests can
    monkeypatch it to inject a MockTransport-backed client per call.
    Callers must NOT close the returned client — the pool outlives the
    tool invocation by design."""
    return _http_singleton


async def _get(path: str, params: list[tuple[str, Any]] | None = None) -> Any:
    """GET one hardcoded LiteLLM path. Raises ToolError on any failure with a
    short message aimed at the LLM caller. Never leaks raw response bodies."""
    try:
        c = _client()
        r = await c.get(path, params=params or [])
    except httpx.TimeoutException:
        log.warning("upstream timeout GET %s", path)
        raise ToolError(
            f"LiteLLM timed out after {MCP_UPSTREAM_TIMEOUT:.0f}s — proxy may be slow or the tailnet hop is down"
        )
    except httpx.HTTPError as e:
        log.warning("upstream http error GET %s: %s", path, type(e).__name__)
        raise ToolError(f"LiteLLM unreachable ({type(e).__name__}) — check the mcp-litellm pod's tailscale sidecar")

    if r.status_code == 401:
        raise ToolError("LiteLLM returned 401 — master key rejected. The MCP's master key is invalid or rotated.")
    if r.status_code == 403:
        raise ToolError("LiteLLM returned 403 — master key lacks permission for this route (unexpected)")
    if r.status_code == 404:
        raise ToolError(f"LiteLLM returned 404 for {path} — endpoint not available on this proxy version")
    if r.status_code >= 400:
        log.info("upstream %d GET %s", r.status_code, path)
        raise ToolError(f"LiteLLM returned HTTP {r.status_code}")

    try:
        return r.json()
    except (json.JSONDecodeError, ValueError):
        log.warning("upstream non-JSON GET %s", path)
        raise ToolError("LiteLLM returned a non-JSON response")


# --- date helpers ---------------------------------------------------------


def _validate_date_range(start_date: str, end_date: str) -> None:
    # Parse each side separately so the error names the offending arg.
    # Pydantic `pattern=` on the tool signature would surface as
    # "1 validation error for call[...] ... [type=string_pattern_mismatch]
    # https://errors.pydantic.dev/..." — noisy for small OSS LLMs. Catch
    # it here and raise a one-line ToolError instead.
    try:
        s = date.fromisoformat(start_date)
    except ValueError:
        raise ToolError(f"start_date must be YYYY-MM-DD, got {start_date!r}")
    try:
        e = date.fromisoformat(end_date)
    except ValueError:
        raise ToolError(f"end_date must be YYYY-MM-DD, got {end_date!r}")
    if e < s:
        raise ToolError(f"end_date {end_date} precedes start_date {start_date}")


_MONTH_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


def _validate_month(month: str) -> None:
    """Enforce YYYY-MM with a valid month number, in a one-line ToolError
    (same rationale as `_validate_date_range` — avoid pydantic's noisy
    validation URL in the error surface).
    """
    if not _MONTH_RE.match(month):
        raise ToolError(f"month must be YYYY-MM (e.g. '2026-04'), got {month!r}")


def _row_date(row: dict[str, Any]) -> str | None:
    """Extract YYYY-MM-DD from a spend_logs row. LiteLLM exposes `startTime`
    as ISO-8601; some versions use `start_time`. Returns None if absent."""
    raw = row.get("startTime") or row.get("start_time") or row.get("request_time")
    if not isinstance(raw, str) or not raw:
        return None
    # Accept both "2026-04-23T00:01:02.345Z" and date-only strings.
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).date().isoformat()
    except ValueError:
        return raw[:10] if len(raw) >= 10 else None


def _row_spend(row: dict[str, Any]) -> float:
    for key in ("spend", "cost", "response_cost"):
        v = row.get(key)
        if isinstance(v, (int, float)):
            return float(v)
    return 0.0


def _row_tokens(row: dict[str, Any], key: str) -> int:
    v = row.get(key)
    return int(v) if isinstance(v, (int, float)) else 0


def _row_model(row: dict[str, Any]) -> str:
    v = row.get("model") or row.get("model_id") or "unknown"
    return str(v)


def _row_session_id(row: dict[str, Any]) -> str | None:
    """session_id lives at the row top level on /spend/logs/v2 and inside
    metadata.session_id on callers that set it via completion kwargs."""
    sid = row.get("session_id")
    if isinstance(sid, str) and sid:
        return sid
    meta = row.get("metadata")
    if isinstance(meta, dict):
        sid = meta.get("session_id")
        if isinstance(sid, str) and sid:
            return sid
    return None


def _to_key_info(kh: str, info: dict[str, Any]) -> "KeyInfo":
    def pick(k: str, types: type | tuple[type, ...]) -> Any:
        v = info.get(k)
        return v if isinstance(v, types) else None

    return KeyInfo(
        key_hash=kh,
        key_alias=pick("key_alias", str),
        spend=pick("spend", (int, float)),
        max_budget=pick("max_budget", (int, float)),
        models=pick("models", list),
        tpm_limit=pick("tpm_limit", int),
        rpm_limit=pick("rpm_limit", int),
        budget_duration=pick("budget_duration", str),
        created_at=pick("created_at", str),
        expires=pick("expires", str),
    )


def _unwrap_info(data: Any) -> dict[str, Any] | None:
    """LiteLLM sometimes wraps /key/info in {'info': {...}}; sometimes it
    returns the row flat. Returns the inner dict or None if shape is junk."""
    if not isinstance(data, dict):
        return None
    inner = data.get("info")
    if isinstance(inner, dict):
        return inner
    return data


async def _paginate_spend_logs(
    key_hash: str, start_date: str, end_date: str, cap: int
) -> tuple[list[dict[str, Any]], int, bool]:
    """Page through /spend/logs/v2 up to `cap` rows.

    Returns (rows, upstream_total, truncated). `truncated` is True when
    upstream has more rows than the cap. v1 /spend/logs is deprecated
    upstream and unpaginated; v2 caps page_size at 100."""
    rows: list[dict[str, Any]] = []
    page = 1
    page_size = 100
    upstream_total = 0
    while True:
        data = await _get(
            "/spend/logs/v2",
            [
                ("api_key", key_hash),
                ("start_date", start_date),
                ("end_date", end_date),
                ("page", str(page)),
                ("page_size", str(page_size)),
            ],
        )
        if not isinstance(data, dict):
            raise ToolError("LiteLLM /spend/logs/v2 returned unexpected shape")
        batch = data.get("data")
        if not isinstance(batch, list):
            raise ToolError("LiteLLM /spend/logs/v2 returned unexpected shape")
        t = data.get("total")
        if isinstance(t, int):
            upstream_total = t
        rows.extend(batch)
        if not batch:
            break
        if len(rows) >= cap:
            break
        if upstream_total and len(rows) >= upstream_total:
            break
        total_pages = data.get("total_pages")
        if isinstance(total_pages, int) and page >= total_pages:
            break
        page += 1
    if not upstream_total:
        upstream_total = len(rows)
    truncated = upstream_total > cap and len(rows) >= cap
    return rows[:cap], upstream_total, truncated


# --- aggregation ----------------------------------------------------------


def _aggregate_daily(rows: list[dict[str, Any]]) -> tuple[list[DailyRow], int]:
    """Bucket rows by day. Returns (daily_rows, skipped_count) where
    skipped_count is rows whose startTime couldn't be parsed."""
    days: dict[str, dict[str, Any]] = {}
    skipped = 0
    for r in rows:
        d = _row_date(r)
        if d is None:
            skipped += 1
            continue
        bucket = days.setdefault(
            d,
            {
                "spend": 0.0,
                "total_tokens": 0,
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "request_count": 0,
                "by_model": {},
            },
        )
        spend = _row_spend(r)
        bucket["spend"] += spend
        bucket["total_tokens"] += _row_tokens(r, "total_tokens")
        bucket["prompt_tokens"] += _row_tokens(r, "prompt_tokens")
        bucket["completion_tokens"] += _row_tokens(r, "completion_tokens")
        bucket["request_count"] += 1
        model = _row_model(r)
        bucket["by_model"][model] = bucket["by_model"].get(model, 0.0) + spend
    daily_rows = [
        DailyRow(
            date=d,
            spend=round(v["spend"], 6),
            total_tokens=v["total_tokens"],
            prompt_tokens=v["prompt_tokens"],
            completion_tokens=v["completion_tokens"],
            request_count=v["request_count"],
            by_model={m: round(s, 6) for m, s in v["by_model"].items()},
        )
        for d, v in sorted(days.items())
    ]
    return daily_rows, skipped


# --- Tools -----------------------------------------------------------------


async def _healthz(_request: Any) -> JSONResponse:
    """Liveness + readiness probe target. No auth, no upstream calls — just
    proves the ASGI app is alive. Separate from tool dispatch so a wedged
    upstream LiteLLM doesn't flap the pod."""
    return JSONResponse({"ok": True})


mcp = FastMCP(
    "litellm-spend",
    instructions=(
        "Read-only view into LiteLLM virtual-key spend for the keys bound to "
        "this MCP bearer.\n\n"
        "Standard flow:\n"
        "  1. Call `list_my_keys` first to see which keys you can query. "
        "Each entry has a `key_hash` and a human `key_alias`.\n"
        "  2. Use `get_monthly_summary(month='YYYY-MM')` for 'how much did I "
        "spend in X month'. Use `get_daily_summary(start_date, end_date)` for "
        "a custom date range. Use `get_spend_logs` only when per-request rows "
        "are actually needed — it is slower and truncates beyond MCP_MAX_LOGS.\n"
        "  3. If your allowlist has exactly one key, `key_hash` is optional on "
        "every tool; the single key is used automatically. If it has more "
        "than one, pass the `key_hash` from step 1.\n\n"
        "Dates: `YYYY-MM-DD`. Months: `YYYY-MM`. All ranges are inclusive and "
        "interpreted in UTC."
    ),
)


mcp.custom_route("/healthz", methods=["GET"])(_healthz)


async def _fetch_key_info(h: str) -> MyKey:
    """One /key/info call, converted to a MyKey; errors become per-entry
    strings so one bad hash doesn't fail `list_my_keys` for the whole set."""
    try:
        data = await _get("/key/info", [("key", h)])
    except ToolError as e:
        return MyKey(key_hash=h, error=str(e))
    info = _unwrap_info(data)
    if info is None:
        return MyKey(key_hash=h, error="unexpected /key/info shape")
    return MyKey(
        key_hash=h,
        key_alias=info.get("key_alias") if isinstance(info.get("key_alias"), str) else None,
        spend=info.get("spend") if isinstance(info.get("spend"), (int, float)) else None,
        max_budget=info.get("max_budget") if isinstance(info.get("max_budget"), (int, float)) else None,
        models=info.get("models") if isinstance(info.get("models"), list) else None,
    )


@mcp.tool()
async def list_my_keys() -> MyKeysResult:
    """List the LiteLLM virtual keys bound to this MCP bearer. Each entry
    carries a `key_hash` (opaque id to pass to the other tools), a human
    `key_alias`, lifetime `spend`, and `max_budget`. Per-entry `error` is
    set if that specific key failed to fetch (e.g. rotated or deleted)."""
    allow = _allowlist()
    if not allow:
        return MyKeysResult(keys=[])
    # Fan out in parallel — sequential awaits here would multiply timeouts.
    hashes = sorted(allow)
    results = await asyncio.gather(*(_fetch_key_info(h) for h in hashes))
    return MyKeysResult(keys=list(results))


@mcp.tool()
async def get_key_info(
    key_hash: Annotated[
        str | None,
        Field(
            description=(
                "Optional LiteLLM key hash (64-char lowercase hex) from "
                "`list_my_keys`. Omit to auto-select when your allowlist has "
                "exactly one key."
            ),
        ),
    ] = None,
) -> KeyInfo:
    """Metadata + lifetime spend for a single LiteLLM virtual key. Returns
    key_alias, spend, max_budget, models, and rate limits only — never
    user_id, team_id, or admin metadata."""
    kh = _resolve_hash(key_hash)
    data = await _get("/key/info", [("key", kh)])
    info = _unwrap_info(data)
    if info is None:
        raise ToolError("LiteLLM /key/info returned unexpected shape")
    return _to_key_info(kh, info)


@mcp.tool()
async def get_spend_logs(
    start_date: Annotated[str, Field(description="Inclusive start date, YYYY-MM-DD.")],
    end_date: Annotated[str, Field(description="Inclusive end date, YYYY-MM-DD.")],
    key_hash: Annotated[
        str | None,
        Field(description="Optional LiteLLM key hash. Omit if your allowlist has one key."),
    ] = None,
    session_id: Annotated[
        str | None,
        Field(
            description=(
                "Optional: filter to a single LiteLLM session_id. Filtering "
                "happens client-side after pagination, so narrow the date "
                "range when possible."
            ),
            max_length=256,
        ),
    ] = None,
    limit: Annotated[
        int | None,
        Field(ge=1, le=10000, description=f"Max rows to return. Server caps at MCP_MAX_LOGS ({MCP_MAX_LOGS})."),
    ] = None,
) -> SpendLogs:
    """Per-request spend log rows for a key hash. Each row carries
    request_id, call_type, model, spend, tokens, and session metadata.

    The `truncated=true` flag means more rows exist upstream; narrow the
    date range or raise MCP_MAX_LOGS."""
    kh = _resolve_hash(key_hash)
    _validate_date_range(start_date, end_date)
    cap = MCP_MAX_LOGS if limit is None else min(limit, MCP_MAX_LOGS)
    rows, upstream_total, truncated = await _paginate_spend_logs(kh, start_date, end_date, cap)
    if session_id:
        # Upstream doesn't filter by session_id — apply client-side.
        # Keeps the advertised filter honest even if the metadata shape drifts.
        rows = [r for r in rows if _row_session_id(r) == session_id]
    return SpendLogs(
        key_hash=kh,
        start_date=start_date,
        end_date=end_date,
        count=upstream_total,
        truncated=truncated,
        logs=rows,
    )


@mcp.tool()
async def get_daily_summary(
    start_date: Annotated[str, Field(description="Inclusive start date, YYYY-MM-DD.")],
    end_date: Annotated[str, Field(description="Inclusive end date, YYYY-MM-DD.")],
    key_hash: Annotated[
        str | None,
        Field(description="Optional LiteLLM key hash. Omit if your allowlist has one key."),
    ] = None,
) -> DailySummary:
    """Per-day breakdown for a key hash: spend, tokens, requests, plus per-
    model spend each day. Aggregated client-side from paginated spend logs.

    `truncated=true` means the upstream row count exceeded MCP_MAX_LOGS."""
    kh = _resolve_hash(key_hash)
    _validate_date_range(start_date, end_date)
    rows, upstream_total, truncated = await _paginate_spend_logs(kh, start_date, end_date, MCP_MAX_LOGS)
    days, skipped = _aggregate_daily(rows)
    total_spend = round(sum(d.spend for d in days), 6)
    total_tokens = sum(d.total_tokens for d in days)
    total_requests = sum(d.request_count for d in days)
    return DailySummary(
        key_hash=kh,
        start_date=start_date,
        end_date=end_date,
        days=days,
        total_spend=total_spend,
        total_tokens=total_tokens,
        total_requests=total_requests,
        log_count=upstream_total,
        skipped_rows=skipped,
        truncated=truncated,
    )


@mcp.tool()
async def get_monthly_summary(
    month: Annotated[str, Field(description="Month to summarize, YYYY-MM.")],
    key_hash: Annotated[
        str | None,
        Field(description="Optional LiteLLM key hash. Omit if your allowlist has one key."),
    ] = None,
) -> MonthlySummary:
    """Whole-month totals for a key hash: spend, tokens, requests, plus by-
    model and by-day rollups. Aggregated client-side from paginated spend
    logs."""
    _validate_month(month)
    kh = _resolve_hash(key_hash)
    year, mon = int(month[:4]), int(month[5:7])
    start = date(year, mon, 1)
    end = date(year, mon, calendar.monthrange(year, mon)[1])

    rows, upstream_total, truncated = await _paginate_spend_logs(
        kh, start.isoformat(), end.isoformat(), MCP_MAX_LOGS
    )

    total_spend = 0.0
    total_tokens = 0
    prompt_tokens = 0
    completion_tokens = 0
    total_requests = 0
    skipped = 0
    by_model: dict[str, float] = {}
    by_day: dict[str, float] = {}

    for r in rows:
        spend = _row_spend(r)
        total_spend += spend
        total_tokens += _row_tokens(r, "total_tokens")
        prompt_tokens += _row_tokens(r, "prompt_tokens")
        completion_tokens += _row_tokens(r, "completion_tokens")
        total_requests += 1
        model = _row_model(r)
        by_model[model] = by_model.get(model, 0.0) + spend
        d = _row_date(r)
        if d is not None:
            by_day[d] = by_day.get(d, 0.0) + spend
        else:
            skipped += 1

    return MonthlySummary(
        key_hash=kh,
        month=month,
        start_date=start.isoformat(),
        end_date=end.isoformat(),
        total_spend=round(total_spend, 6),
        total_tokens=total_tokens,
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        total_requests=total_requests,
        by_model={m: round(s, 6) for m, s in by_model.items()},
        by_day={d: round(s, 6) for d, s in by_day.items()},
        log_count=upstream_total,
        skipped_rows=skipped,
        truncated=truncated,
    )


# --- Auth middleware -------------------------------------------------------


class AuthMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "lifespan":
            await self.app(scope, receive, send)
            return

        if scope["type"] != "http":
            if scope["type"] == "websocket":
                log.warning("auth: rejecting websocket (unsupported)")
                try:
                    await asyncio.wait_for(receive(), timeout=5.0)
                except asyncio.TimeoutError:
                    log.warning("auth: websocket receive timed out before close")
                await send({"type": "websocket.close", "code": 1008})
            else:
                log.warning("auth: unknown scope type %r, dropping", scope["type"])
            return

        method = scope["method"]
        if method == "OPTIONS":
            await self.app(scope, receive, send)
            return

        # Health probe target — kubelet won't send a bearer. No upstream
        # calls, no tenant context, safe to expose unauthenticated.
        if scope["path"] == "/healthz":
            await self.app(scope, receive, send)
            return

        headers = Headers(scope=scope)
        qs = QueryParams(scope["query_string"])

        header = headers.get("authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        if not token:
            token = qs.get("api_key", "").strip()

        matched: str | None = None
        if token:
            for k in API_KEYS:
                if secrets.compare_digest(token, k):
                    matched = k
                    break

        client = scope.get("client")
        if matched is None:
            log.warning(
                "auth: rejected %s %r from %s",
                method, scope["path"], client[0] if client else "?",
            )
            await JSONResponse({"error": "unauthorized"}, status_code=401)(scope, receive, send)
            return

        allowed = KEY_HASH_MAP.get(matched, frozenset())
        token_ctx = current_allowed_hashes.set(allowed)
        try:
            await self.app(scope, receive, send)
        finally:
            current_allowed_hashes.reset(token_ctx)


app = mcp.http_app(
    path="/",
    middleware=[Middleware(AuthMiddleware)],
)


if __name__ == "__main__":
    uvicorn.run(app, host=MCP_HOST, port=MCP_PORT, log_level=LOG_LEVEL.lower(), access_log=False)
