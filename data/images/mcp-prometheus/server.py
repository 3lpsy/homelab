"""Prometheus MCP server.

Thin read-only wrapper around a Prometheus HTTP API, exposing the 18 tools
from giantswarm/mcp-prometheus (execute_query, execute_range_query,
find_series, list_label_names/values, get_metric_metadata, get_targets,
get_targets_metadata, get_rules, get_alerts, get_alertmanagers,
query_exemplars, get_build_info, get_runtime_info, get_flags, get_config,
get_tsdb_stats, check_ready) over the MCP streamable-http transport. Auth
is fail-closed (empty `MCP_API_KEYS` rejects every request).

Environment:
  MCP_API_KEYS           CSV of accepted Bearer tokens. Empty/unset is fail-closed.
  PROMETHEUS_URL         Base URL of Prometheus (required; no default).
  PROMETHEUS_USERNAME    Basic-auth user (optional; mutually exclusive with TOKEN).
  PROMETHEUS_PASSWORD    Basic-auth password (optional).
  PROMETHEUS_TOKEN       Bearer token (optional; mutually exclusive with USERNAME).
  PROMETHEUS_ORGID       Value for X-Scope-OrgID header (Mimir/Cortex tenant).
                         Empty/unset means header is omitted.
  PROMETHEUS_TLS_SKIP_VERIFY  "true"/"1" to disable TLS verify. Default false.
  PROMETHEUS_TLS_CA_CERT      Path to a CA bundle file. Default system bundle.
  PROMETHEUS_TIMEOUT     httpx timeout seconds (default 30).
  MCP_QUERY_TIMEOUT      Prom eval-time cap (Prom duration, default '30s').
                         Injected as `timeout=` on /query and /query_range when
                         caller omits it; caller-supplied values above this are
                         clamped down.
  MCP_MAX_SERIES         Hard cap on result series per tool (default 10000).
                         Pushed upstream as `limit=` on /query, /query_range,
                         /series, /labels, /label/X/values; caller-supplied
                         limits are min'd against this.
  MCP_HOST               Bind host (default 0.0.0.0).
  MCP_PORT               Bind port (default 8000).
  LOG_LEVEL              debug / info / warning / error (default info).
"""

import asyncio
import json
import logging
import math
import os
import re
import secrets
from datetime import datetime
from typing import Annotated, Any, Literal

import httpx
import uvicorn
from fastmcp import FastMCP
from pydantic import BaseModel, ConfigDict, Field, ValidationError
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


API_KEYS = {k.strip() for k in os.environ.get("MCP_API_KEYS", "").split(",") if k.strip()}
MCP_ALLOW_CONFIG = os.environ.get("MCP_ALLOW_CONFIG", "").lower() in ("1", "true", "yes")
PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "").rstrip("/")
PROMETHEUS_USERNAME = os.environ.get("PROMETHEUS_USERNAME", "")
PROMETHEUS_PASSWORD = os.environ.get("PROMETHEUS_PASSWORD", "")
PROMETHEUS_TOKEN = os.environ.get("PROMETHEUS_TOKEN", "")
PROMETHEUS_ORGID = os.environ.get("PROMETHEUS_ORGID", "")
PROMETHEUS_TLS_SKIP_VERIFY = os.environ.get("PROMETHEUS_TLS_SKIP_VERIFY", "").lower() in ("1", "true", "yes")
PROMETHEUS_TLS_CA_CERT = os.environ.get("PROMETHEUS_TLS_CA_CERT", "")
PROMETHEUS_TIMEOUT = _env_float("PROMETHEUS_TIMEOUT", "30")
MCP_QUERY_TIMEOUT = os.environ.get("MCP_QUERY_TIMEOUT", "30s")
MCP_MAX_SERIES = _env_int("MCP_MAX_SERIES", "10000")
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = _env_int("MCP_PORT", "8000")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
# httpx logs full request URLs (including query strings) at INFO. PromQL
# expressions land in the query string and may contain sensitive label
# selectors; mute to WARNING so only failures surface.
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("mcp-prometheus")

if not PROMETHEUS_URL:
    raise SystemExit("PROMETHEUS_URL must be set")
if PROMETHEUS_TOKEN and (PROMETHEUS_USERNAME or PROMETHEUS_PASSWORD):
    raise SystemExit("PROMETHEUS_TOKEN is mutually exclusive with PROMETHEUS_USERNAME/PROMETHEUS_PASSWORD")
if bool(PROMETHEUS_USERNAME) != bool(PROMETHEUS_PASSWORD):
    raise SystemExit("PROMETHEUS_USERNAME and PROMETHEUS_PASSWORD must both be set or both unset")
if PROMETHEUS_TLS_CA_CERT and not os.path.isfile(PROMETHEUS_TLS_CA_CERT):
    raise SystemExit(f"PROMETHEUS_TLS_CA_CERT not found: {PROMETHEUS_TLS_CA_CERT}")

log.info(
    "startup: prometheus=%s api_keys=%d orgid=%s tls_skip_verify=%s ca_cert=%s allow_config=%s log_level=%s",
    PROMETHEUS_URL,
    len(API_KEYS),
    "set" if PROMETHEUS_ORGID else "unset",
    PROMETHEUS_TLS_SKIP_VERIFY,
    PROMETHEUS_TLS_CA_CERT or "system",
    MCP_ALLOW_CONFIG,
    LOG_LEVEL,
)


# --- Pydantic models -------------------------------------------------------


# Inputs that need richer validation than a plain annotation are defined as
# models so a caller can still pass keyword args and fastmcp builds the JSON
# schema from the model. Simpler tools use Annotated[...] directly on the
# function parameter.

def _validate_time(v: str) -> str:
    """Accept RFC3339 or a unix timestamp (int/float as string). Returns the
    string unchanged so we forward exactly what Prometheus was asked for.
    """
    s = v.strip()
    if not s:
        raise ValueError("must be non-empty")
    # Unix timestamp (integer or float). Reject inf/nan — float() accepts them.
    try:
        f = float(s)
    except ValueError:
        pass
    else:
        if not math.isfinite(f):
            raise ValueError(f"timestamp must be finite: {v!r}")
        return s
    # RFC3339: fromisoformat handles most variants; normalise trailing Z.
    try:
        datetime.fromisoformat(s.replace("Z", "+00:00"))
        return s
    except ValueError as e:
        raise ValueError(f"not RFC3339 or unix timestamp: {v!r}") from e


_UNIT_SEC = {"ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0, "d": 86400.0, "w": 604800.0, "y": 31536000.0}
# Prometheus accepts compound durations like "1h30m" or "2d12h" — a non-empty
# ordered sequence of <number><unit> segments. A bare float is also accepted
# and means seconds (matches `timeout=` semantics on /query).
_SEGMENT_RE = re.compile(r"(\d+(?:\.\d+)?)(ms|s|m|h|d|w|y)")
_COMPOUND_RE = re.compile(r"^(?:\d+(?:\.\d+)?(?:ms|s|m|h|d|w|y))+$")
_BARE_FLOAT_RE = re.compile(r"^\d+(?:\.\d+)?$")


def _validate_step(v: str) -> str:
    s = v.strip()
    if not s:
        raise ValueError("must be non-empty")
    if not (_COMPOUND_RE.match(s) or _BARE_FLOAT_RE.match(s)):
        raise ValueError(f"not a Prometheus duration or float seconds: {v!r}")
    return s


def _duration_seconds(v: str) -> float:
    """Parse a Prom duration ('15s', '500ms', '1h30m', '1.5') to seconds.
    Bare floats are interpreted as seconds."""
    s = v.strip()
    if _BARE_FLOAT_RE.match(s):
        return float(s)
    segments = _SEGMENT_RE.findall(s)
    # Require the segments to cover the whole string — otherwise a stray
    # token like '1h abc' would silently parse as '1h'.
    if not segments or "".join(n + u for n, u in segments) != s:
        raise ValueError(f"not a Prometheus duration: {v!r}")
    return sum(float(n) * _UNIT_SEC[u] for n, u in segments)


def _capped_query_timeout(caller: str | None) -> str:
    """Inject MCP_QUERY_TIMEOUT when caller omits, else min(caller, cap)."""
    if caller is None:
        return MCP_QUERY_TIMEOUT
    return caller if _duration_seconds(caller) <= _MCP_QUERY_TIMEOUT_SEC else MCP_QUERY_TIMEOUT


def _capped_limit(caller: int | None) -> int:
    """Push-down limit: caller's value capped to MCP_MAX_SERIES, default cap."""
    return MCP_MAX_SERIES if caller is None else min(caller, MCP_MAX_SERIES)


# Metadata entries carry verbose help strings; at MCP_MAX_SERIES count a
# typical deployment blows the MCP token cap. Default metadata tools lower
# so an unarg'd call stays in budget; callers can opt into more up to
# MCP_MAX_SERIES.
_METADATA_DEFAULT = 300


def _capped_metadata_limit(caller: int | None) -> int:
    base = _METADATA_DEFAULT if caller is None else caller
    return min(base, MCP_MAX_SERIES)


# Validate MCP_QUERY_TIMEOUT at import; bad values fail-closed at startup.
try:
    _validate_step(MCP_QUERY_TIMEOUT)
    _MCP_QUERY_TIMEOUT_SEC = _duration_seconds(MCP_QUERY_TIMEOUT)
except ValueError as _e:
    raise SystemExit(f"MCP_QUERY_TIMEOUT invalid: {_e}") from _e


TimeParam = Annotated[
    str,
    Field(description="RFC3339 timestamp or unix seconds."),
]
StepParam = Annotated[
    str,
    Field(description="Prometheus duration (e.g. '15s', '1m') or bare float seconds."),
]


class PromError(BaseModel):
    """Structured error return — every tool may return this in place of its
    response model. The LLM can read `error_type` to decide whether the
    failure is retryable."""

    model_config = ConfigDict(extra="forbid")
    error: str
    error_type: Literal[
        "validation",
        "upstream_http",
        "upstream_json",
        "upstream_api",
        "timeout",
    ]
    status: int | None = None
    warnings: list[str] = Field(default_factory=list)


class QueryResult(BaseModel):
    """Instant or range PromQL query result."""

    model_config = ConfigDict(extra="forbid")
    resultType: Literal["matrix", "vector", "scalar", "string"]
    # vector/matrix: list of series dicts. scalar/string: 2-tuple [ts, value].
    result: list[Any]
    stats: dict | None = None
    warnings: list[str] = Field(default_factory=list)
    series_count: int
    truncated: bool = False


class SeriesResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    series: list[dict[str, str]]
    series_count: int
    truncated: bool = False
    warnings: list[str] = Field(default_factory=list)


class LabelListResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    labels: list[str]
    warnings: list[str] = Field(default_factory=list)


class MetricMetadataResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    # Prometheus shape: {metric_name: [{type, help, unit}, ...]}
    metadata: dict[str, list[dict]]


class TargetsMetadataResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    metadata: list[dict]
    series_count: int
    truncated: bool = False


class TargetsResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    active: list[dict]
    dropped: list[dict] = Field(default_factory=list)


class RulesResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    groups: list[dict]


class AlertsResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    alerts: list[dict]


class AlertManagersResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    active: list[dict]
    dropped: list[dict] = Field(default_factory=list)


class ExemplarsResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    exemplars: list[dict]
    series_count: int
    truncated: bool = False


class BuildInfoResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    version: str = ""
    revision: str = ""
    branch: str = ""
    buildUser: str = ""
    buildDate: str = ""
    goVersion: str = ""


class RuntimeInfoResult(BaseModel):
    model_config = ConfigDict(extra="allow")  # Prometheus varies this shape across versions


class FlagsResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    flags: dict[str, str]


class ConfigResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    yaml: str


class TSDBStatsResult(BaseModel):
    model_config = ConfigDict(extra="allow")  # Prometheus adds/removes fields across versions


class ReadyResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    ready: bool
    status: int
    message: str


# --- HTTP client -----------------------------------------------------------


def _build_singleton_client() -> httpx.AsyncClient:
    """Construct the module-level httpx client once at import time."""
    headers: dict[str, str] = {"User-Agent": "mcp-prometheus/1.0"}
    if PROMETHEUS_ORGID:
        headers["X-Scope-OrgID"] = PROMETHEUS_ORGID

    auth: httpx.Auth | None = None
    if PROMETHEUS_TOKEN:
        headers["Authorization"] = f"Bearer {PROMETHEUS_TOKEN}"
    elif PROMETHEUS_USERNAME:
        auth = httpx.BasicAuth(PROMETHEUS_USERNAME, PROMETHEUS_PASSWORD)

    verify: bool | str = True
    if PROMETHEUS_TLS_SKIP_VERIFY:
        verify = False
    elif PROMETHEUS_TLS_CA_CERT:
        verify = PROMETHEUS_TLS_CA_CERT

    return httpx.AsyncClient(
        base_url=PROMETHEUS_URL,
        headers=headers,
        auth=auth,
        verify=verify,
        timeout=PROMETHEUS_TIMEOUT,
    )


# Singleton reused across tool calls — keeps TCP/keepalive pool warm for
# bursty PromQL workloads (e.g. an LLM chaining list_label_values then
# execute_range_query). Tests monkeypatch `_client` to inject a MockTransport.
_http_singleton = _build_singleton_client()


def _client() -> httpx.AsyncClient:
    """Return the singleton httpx client. Callers must NOT close it."""
    return _http_singleton


class _Ok(BaseModel):
    """Internal success envelope for _get_api. `data` is whatever Prometheus
    returned under the top-level `data` field — dict for /query|/status/*,
    list for /series|/labels|/label/X/values."""

    model_config = ConfigDict(arbitrary_types_allowed=True)
    data: Any
    warnings: list[str] = Field(default_factory=list)
    status: int = 200


async def _get_api(path: str, params: list[tuple[str, Any]]) -> _Ok | PromError:
    """GET a Prometheus endpoint and unwrap the `{status, data, warnings}`
    envelope. Returns PromError on any failure. No exception escapes."""

    try:
        c = _client()
        r = await c.get(path, params=params)
    except httpx.TimeoutException as e:
        # Scrub `str(e)` from the caller-facing message — httpx exception
        # text frequently carries the upstream URL/host, which for Mimir or
        # authed Prom deployments leaks tenant identifiers.
        log.warning("GET %s timed out (%s)", path, type(e).__name__)
        return PromError(error=f"upstream timeout ({type(e).__name__})", error_type="timeout")
    except httpx.HTTPError as e:
        log.warning("GET %s http error (%s)", path, type(e).__name__)
        return PromError(error=f"upstream unreachable ({type(e).__name__})", error_type="upstream_http")

    if r.status_code >= 400:
        log.info("GET %s -> %d", path, r.status_code)
        # Prometheus surfaces PromQL errors in JSON bodies even on 4xx.
        body_error = ""
        try:
            body = r.json()
            body_error = str(body.get("error") or body.get("errorType") or "")
        except (json.JSONDecodeError, ValueError):
            # Non-JSON 4xx usually means nginx/proxy HTML error page. Cap at
            # 512 bytes so we don't ship a full error page back through MCP,
            # and decode from content (not .text) so a non-UTF-8 body can't
            # raise during error handling.
            body_error = r.content[:512].decode(errors="replace")
        return PromError(
            error=body_error or f"HTTP {r.status_code}",
            error_type="upstream_http",
            status=r.status_code,
        )

    try:
        body = r.json()
    except (json.JSONDecodeError, ValueError) as e:
        log.warning("GET %s: JSON parse failed (%s)", path, type(e).__name__)
        return PromError(error=f"upstream returned non-JSON: {e}", error_type="upstream_json", status=r.status_code)

    warnings = body.get("warnings") or []
    if body.get("status") == "error":
        log.info("GET %s: prometheus error: %s", path, body.get("error"))
        return PromError(
            error=str(body.get("error") or body.get("errorType") or "unknown error"),
            error_type="upstream_api",
            status=r.status_code,
            warnings=warnings,
        )

    if "data" not in body:
        log.warning("GET %s: response has no 'data' field", path)
        return PromError(error="missing data field in response", error_type="upstream_json", status=r.status_code)

    return _Ok(data=body["data"], warnings=warnings, status=r.status_code)


def _truncate(items: list, limit: int | None) -> tuple[list, bool]:
    """Apply the client-side cap. `limit=None` uses MCP_MAX_SERIES; callers
    pass their own cap when the tool has a limit parameter."""

    cap = MCP_MAX_SERIES if limit is None else min(limit, MCP_MAX_SERIES)
    if len(items) > cap:
        return items[:cap], True
    return items, False


def _build(ctor, **fields):
    """Build a response model, mapping ValidationError to PromError so an
    upstream shape surprise surfaces as a structured tool error instead of
    crashing the MCP dispatcher."""
    try:
        return ctor(**fields)
    except ValidationError as e:
        log.warning("response shape mismatch for %s: %s", ctor.__name__, e)
        return PromError(error=f"response shape mismatch: {e}", error_type="upstream_json")


# --- Tools -----------------------------------------------------------------


async def _healthz(_request: Any) -> JSONResponse:
    """Liveness + readiness probe target. No auth, no upstream calls."""
    return JSONResponse({"ok": True})


mcp = FastMCP(
    "prometheus",
    instructions=(
        "Read-only access to a Prometheus server. 18 tools cover queries, "
        "series discovery, rules, alerts, and server metadata.\n\n"
        "Discovery flow — prefer this ordering for small models:\n"
        "  1. `list_label_names()` or `list_label_values(label='job')` to see "
        "what targets are scraped.\n"
        "  2. `find_series(match=['up'])` to discover concrete series.\n"
        "  3. `execute_query(query='up')` for the latest value, or "
        "`execute_range_query(query, start, end, step)` for a time range.\n"
        "  4. `get_rules()` / `get_alerts()` for recording+alert rules and "
        "firing alerts.\n\n"
        "Times: RFC3339 (`2026-04-23T00:00:00Z`) or unix seconds (`1745366400`).\n"
        "Step/timeout: Prom durations like `15s`, `1m`, `1h30m`, or bare "
        "float seconds.\n"
        "All list-style results cap at MCP_MAX_SERIES; check `truncated` and "
        "narrow your selectors if set."
    ),
)


mcp.custom_route("/healthz", methods=["GET"])(_healthz)


@mcp.tool()
async def execute_query(
    query: Annotated[str, Field(min_length=1, max_length=8192, description="PromQL expression.")],
    time: TimeParam | None = None,
    timeout: str | None = None,
    limit: Annotated[int | None, Field(ge=1, le=MCP_MAX_SERIES)] = None,
) -> QueryResult | PromError:
    """Instant PromQL query — evaluates `query` at a single point in time.

    Args:
      query: PromQL expression (e.g. `up`, `rate(http_requests_total[5m])`).
      time: evaluation timestamp; defaults to server `now`.
      timeout: per-request eval timeout (Prom duration). Capped at
        MCP_QUERY_TIMEOUT; injected when omitted.
      limit: cap on returned series. Capped at MCP_MAX_SERIES; pushed upstream
        as `limit=` (Prom 2.50+).
    """
    params: list[tuple[str, Any]] = [("query", query)]
    if time is not None:
        try:
            _validate_time(time)
        except ValueError as e:
            return PromError(error=str(e), error_type="validation")
        params.append(("time", time))
    if timeout is not None:
        try:
            _validate_step(timeout)
        except ValueError as e:
            return PromError(error=f"timeout: {e}", error_type="validation")
    params.append(("timeout", _capped_query_timeout(timeout)))
    params.append(("limit", str(_capped_limit(limit))))

    res = await _get_api("/api/v1/query", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /query shape", error_type="upstream_json")

    result_list = res.data.get("result") or []
    # Only vector/matrix are lists-of-series worth truncating; scalar/string are 2-tuples.
    is_series_list = isinstance(result_list, list) and all(isinstance(x, dict) for x in result_list)
    if is_series_list:
        truncated_list, truncated = _truncate(result_list, limit)
    else:
        truncated_list, truncated = result_list, False

    return _build(
        QueryResult,
        resultType=res.data.get("resultType", "vector"),
        result=truncated_list,
        stats=res.data.get("stats"),
        warnings=res.warnings,
        series_count=len(result_list) if is_series_list else 1,
        truncated=truncated,
    )


@mcp.tool()
async def execute_range_query(
    query: Annotated[str, Field(min_length=1, max_length=8192, description="PromQL expression.")],
    start: TimeParam,
    end: TimeParam,
    step: StepParam,
    timeout: str | None = None,
    limit: Annotated[int | None, Field(ge=1, le=MCP_MAX_SERIES)] = None,
) -> QueryResult | PromError:
    """Range PromQL query — evaluates `query` at each `step` between `start`
    and `end`. `timeout` capped at MCP_QUERY_TIMEOUT; `limit` capped at
    MCP_MAX_SERIES."""
    try:
        _validate_time(start)
        _validate_time(end)
        _validate_step(step)
        if timeout is not None:
            _validate_step(timeout)
    except ValueError as e:
        return PromError(error=str(e), error_type="validation")

    params: list[tuple[str, Any]] = [
        ("query", query),
        ("start", start),
        ("end", end),
        ("step", step),
        ("timeout", _capped_query_timeout(timeout)),
        ("limit", str(_capped_limit(limit))),
    ]

    res = await _get_api("/api/v1/query_range", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /query_range shape", error_type="upstream_json")

    result_list = res.data.get("result") or []
    is_series_list = isinstance(result_list, list) and all(isinstance(x, dict) for x in result_list)
    if is_series_list:
        truncated_list, truncated = _truncate(result_list, limit)
    else:
        truncated_list, truncated = result_list, False

    return _build(
        QueryResult,
        resultType=res.data.get("resultType", "matrix"),
        result=truncated_list,
        stats=res.data.get("stats"),
        warnings=res.warnings,
        series_count=len(result_list) if is_series_list else 1,
        truncated=truncated,
    )


@mcp.tool()
async def find_series(
    match: Annotated[
        list[Annotated[str, Field(min_length=1, max_length=4096)]],
        Field(min_length=1, max_length=32, description="Series selectors; each is a PromQL matcher e.g. `up{job=\"node\"}`."),
    ],
    start: TimeParam | None = None,
    end: TimeParam | None = None,
    limit: Annotated[int | None, Field(ge=1, le=MCP_MAX_SERIES)] = None,
) -> SeriesResult | PromError:
    """Find series matching selectors. `limit` capped at MCP_MAX_SERIES."""
    try:
        if start is not None:
            _validate_time(start)
        if end is not None:
            _validate_time(end)
    except ValueError as e:
        return PromError(error=str(e), error_type="validation")

    params: list[tuple[str, Any]] = [("match[]", m) for m in match]
    if start is not None:
        params.append(("start", start))
    if end is not None:
        params.append(("end", end))
    params.append(("limit", str(_capped_limit(limit))))

    res = await _get_api("/api/v1/series", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, list):
        return PromError(error="unexpected /series shape", error_type="upstream_json")
    truncated_list, truncated = _truncate(res.data, limit)
    return _build(
        SeriesResult,
        series=truncated_list,
        series_count=len(res.data),
        truncated=truncated,
        warnings=res.warnings,
    )


@mcp.tool()
async def list_label_names(
    match: Annotated[
        list[Annotated[str, Field(min_length=1, max_length=4096)]] | None,
        Field(max_length=32),
    ] = None,
    start: TimeParam | None = None,
    end: TimeParam | None = None,
    limit: Annotated[int | None, Field(ge=1, le=MCP_MAX_SERIES)] = None,
) -> LabelListResult | PromError:
    """List label names visible across all series. Optional selectors narrow
    the scope. `limit` capped at MCP_MAX_SERIES."""
    try:
        if start is not None:
            _validate_time(start)
        if end is not None:
            _validate_time(end)
    except ValueError as e:
        return PromError(error=str(e), error_type="validation")

    params: list[tuple[str, Any]] = []
    if match:
        params.extend(("match[]", m) for m in match)
    if start is not None:
        params.append(("start", start))
    if end is not None:
        params.append(("end", end))
    params.append(("limit", str(_capped_limit(limit))))

    res = await _get_api("/api/v1/labels", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, list):
        return PromError(error="unexpected /labels shape", error_type="upstream_json")
    return _build(LabelListResult, labels=res.data, warnings=res.warnings)


_LABEL_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")


@mcp.tool()
async def list_label_values(
    label: Annotated[str, Field(min_length=1, pattern=r"^[a-zA-Z_][a-zA-Z0-9_]*$", description="Label name (valid Prometheus identifier).")],
    match: Annotated[
        list[Annotated[str, Field(min_length=1, max_length=4096)]] | None,
        Field(max_length=32),
    ] = None,
    start: TimeParam | None = None,
    end: TimeParam | None = None,
    limit: Annotated[int | None, Field(ge=1, le=MCP_MAX_SERIES)] = None,
) -> LabelListResult | PromError:
    """List every distinct value seen for one label (e.g. `label='job'` lists
    scrape jobs). `limit` capped at MCP_MAX_SERIES."""
    # Re-check label shape at runtime: the Annotated Field pattern is only
    # enforced by MCP/pydantic when the tool is invoked via JSON-RPC dispatch.
    # A direct Python caller could otherwise slip `/` or `..` into the URL path.
    if not _LABEL_RE.match(label):
        return PromError(error=f"invalid label name: {label!r}", error_type="validation")
    try:
        if start is not None:
            _validate_time(start)
        if end is not None:
            _validate_time(end)
    except ValueError as e:
        return PromError(error=str(e), error_type="validation")

    params: list[tuple[str, Any]] = []
    if match:
        params.extend(("match[]", m) for m in match)
    if start is not None:
        params.append(("start", start))
    if end is not None:
        params.append(("end", end))
    params.append(("limit", str(_capped_limit(limit))))

    res = await _get_api(f"/api/v1/label/{label}/values", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, list):
        return PromError(error="unexpected /label/values shape", error_type="upstream_json")
    return _build(LabelListResult, labels=res.data, warnings=res.warnings)


@mcp.tool()
async def get_metric_metadata(
    metric: Annotated[str | None, Field(max_length=512)] = None,
    limit: Annotated[
        int | None,
        Field(ge=1, le=MCP_MAX_SERIES, description=f"Cap at MCP_MAX_SERIES ({MCP_MAX_SERIES}); server default is {_METADATA_DEFAULT} since metadata rows carry verbose help strings."),
    ] = None,
) -> MetricMetadataResult | PromError:
    """Per-metric metadata: type, help text, and unit."""
    params: list[tuple[str, Any]] = [("limit", str(_capped_metadata_limit(limit)))]
    if metric:
        params.append(("metric", metric))
    res = await _get_api("/api/v1/metadata", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /metadata shape", error_type="upstream_json")
    return _build(MetricMetadataResult, metadata=res.data)


# Fields kept when `include_discovered=False` (the default). Everything else
# on a Prometheus target entry — notably `discoveredLabels` (the full set of
# `__meta_kubernetes_*` annotations) and `globalUrl` — gets dropped because
# it easily dwarfs the useful payload on a Kubernetes cluster. OSS LLMs with
# 8-32K context blow past the window on a single `get_targets()` otherwise.
_TARGET_SLIM_FIELDS = frozenset({
    "labels",
    "scrapePool",
    "scrapeUrl",
    "health",
    "lastError",
    "lastScrape",
    "lastScrapeDuration",
    "scrapeInterval",
    "scrapeTimeout",
})


def _slim_target(t: dict) -> dict:
    return {k: v for k, v in t.items() if k in _TARGET_SLIM_FIELDS}


@mcp.tool()
async def get_targets(
    state: Literal["active", "dropped", "any"] | None = None,
    include_discovered: Annotated[
        bool,
        Field(description=(
            "Include `discoveredLabels` and `globalUrl` on each target. "
            "Off by default — those fields are ~50 `__meta_kubernetes_*` "
            "entries per target and explode response size. Turn on only "
            "when debugging scrape relabel rules."
        )),
    ] = False,
) -> TargetsResult | PromError:
    """List scrape targets, optionally filtered by state (active/dropped).

    By default returns a slim per-target dict (labels, scrapePool, scrapeUrl,
    health, lastError, lastScrape*, scrapeInterval, scrapeTimeout). Pass
    `include_discovered=True` for the full upstream payload.
    """
    params: list[tuple[str, Any]] = []
    if state is not None:
        params.append(("state", state))
    res = await _get_api("/api/v1/targets", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /targets shape", error_type="upstream_json")
    active = res.data.get("activeTargets") or []
    dropped = res.data.get("droppedTargets") or []
    if not include_discovered:
        active = [_slim_target(t) for t in active]
        dropped = [_slim_target(t) for t in dropped]
    return _build(TargetsResult, active=active, dropped=dropped)


@mcp.tool()
async def get_targets_metadata(
    match_target: Annotated[str | None, Field(max_length=2048)] = None,
    metric: Annotated[str | None, Field(max_length=512)] = None,
    limit: Annotated[
        int | None,
        Field(ge=1, le=MCP_MAX_SERIES, description=f"Cap at MCP_MAX_SERIES ({MCP_MAX_SERIES}); server default is {_METADATA_DEFAULT}."),
    ] = None,
) -> TargetsMetadataResult | PromError:
    """Metadata for metrics scraped from specific targets."""
    effective_limit = _capped_metadata_limit(limit)
    params: list[tuple[str, Any]] = [("limit", str(effective_limit))]
    if match_target:
        params.append(("match_target", match_target))
    if metric:
        params.append(("metric", metric))
    res = await _get_api("/api/v1/targets/metadata", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, list):
        return PromError(error="unexpected /targets/metadata shape", error_type="upstream_json")
    truncated_list, truncated = _truncate(res.data, effective_limit)
    return _build(
        TargetsMetadataResult,
        metadata=truncated_list,
        series_count=len(res.data),
        truncated=truncated,
    )


@mcp.tool()
async def get_rules(
    rule_type: Literal["alert", "record"] | None = None,
) -> RulesResult | PromError:
    """Alert + recording rule groups.

    Args:
      rule_type: filter to "alert" or "record" only. Omit for both.
    """
    params: list[tuple[str, Any]] = []
    if rule_type is not None:
        params.append(("type", rule_type))
    res = await _get_api("/api/v1/rules", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /rules shape", error_type="upstream_json")
    return _build(RulesResult, groups=res.data.get("groups") or [])


@mcp.tool()
async def get_alerts() -> AlertsResult | PromError:
    """All currently firing alerts."""
    res = await _get_api("/api/v1/alerts", [])
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /alerts shape", error_type="upstream_json")
    return _build(AlertsResult, alerts=res.data.get("alerts") or [])


@mcp.tool()
async def get_alertmanagers() -> AlertManagersResult | PromError:
    """Registered Alertmanagers the server is routing alerts to."""
    res = await _get_api("/api/v1/alertmanagers", [])
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /alertmanagers shape", error_type="upstream_json")
    return _build(
        AlertManagersResult,
        active=res.data.get("activeAlertmanagers") or [],
        dropped=res.data.get("droppedAlertmanagers") or [],
    )


@mcp.tool()
async def query_exemplars(
    query: Annotated[str, Field(min_length=1, max_length=8192)],
    start: TimeParam,
    end: TimeParam,
    limit: Annotated[int | None, Field(ge=1, le=MCP_MAX_SERIES)] = None,
) -> ExemplarsResult | PromError:
    """Exemplars for a PromQL query. `limit` applied client-side only
    (upstream has no limit param for this endpoint)."""
    try:
        _validate_time(start)
        _validate_time(end)
    except ValueError as e:
        return PromError(error=str(e), error_type="validation")

    params: list[tuple[str, Any]] = [
        ("query", query),
        ("start", start),
        ("end", end),
    ]
    res = await _get_api("/api/v1/query_exemplars", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, list):
        return PromError(error="unexpected /query_exemplars shape", error_type="upstream_json")
    truncated_list, truncated = _truncate(res.data, limit)
    return _build(ExemplarsResult, exemplars=truncated_list, series_count=len(res.data), truncated=truncated)


@mcp.tool()
async def get_build_info() -> BuildInfoResult | PromError:
    """Prometheus build info: version, revision, build date."""
    res = await _get_api("/api/v1/status/buildinfo", [])
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /status/buildinfo shape", error_type="upstream_json")
    # Coerce missing fields to "" so forbid-extra model still validates when
    # the upstream omits a field (older Prom versions).
    return _build(BuildInfoResult, **{k: res.data.get(k) or "" for k in BuildInfoResult.model_fields})


@mcp.tool()
async def get_runtime_info() -> RuntimeInfoResult | PromError:
    """Runtime info: uptime, GC stats, storage retention."""
    res = await _get_api("/api/v1/status/runtimeinfo", [])
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /status/runtimeinfo shape", error_type="upstream_json")
    return _build(RuntimeInfoResult, **res.data)


@mcp.tool()
async def get_flags() -> FlagsResult | PromError:
    """CLI flags the server was started with."""
    res = await _get_api("/api/v1/status/flags", [])
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /status/flags shape", error_type="upstream_json")
    return _build(FlagsResult, flags=res.data)


@mcp.tool()
async def get_config() -> ConfigResult | PromError:
    """Loaded prometheus.yml. Gated behind MCP_ALLOW_CONFIG — the raw config
    can contain remote_write credentials and alerting-route tokens depending
    on the upstream's setup, so we refuse by default."""
    if not MCP_ALLOW_CONFIG:
        return PromError(
            error="get_config is disabled on this MCP server (set MCP_ALLOW_CONFIG=true to enable).",
            error_type="validation",
        )
    res = await _get_api("/api/v1/status/config", [])
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /status/config shape", error_type="upstream_json")
    y = res.data.get("yaml")
    if not isinstance(y, str):
        return PromError(error="config missing yaml field", error_type="upstream_json")
    return _build(ConfigResult, yaml=y)


@mcp.tool()
async def get_tsdb_stats(
    limit: Annotated[int | None, Field(ge=1, le=MCP_MAX_SERIES)] = None,
) -> TSDBStatsResult | PromError:
    """TSDB head + cardinality stats (label counts, chunk counts)."""
    params: list[tuple[str, Any]] = []
    if limit is not None:
        params.append(("limit", str(_capped_limit(limit))))
    res = await _get_api("/api/v1/status/tsdb", params)
    if isinstance(res, PromError):
        return res
    if not isinstance(res.data, dict):
        return PromError(error="unexpected /status/tsdb shape", error_type="upstream_json")
    return _build(TSDBStatsResult, **res.data)


@mcp.tool()
async def check_ready() -> ReadyResult | PromError:
    """Check whether Prometheus is ready to serve queries."""
    try:
        c = _client()
        r = await c.get("/-/ready")
    except httpx.TimeoutException as e:
        log.warning("GET /-/ready timed out (%s)", type(e).__name__)
        return PromError(error=f"upstream timeout ({type(e).__name__})", error_type="timeout")
    except httpx.HTTPError as e:
        log.warning("GET /-/ready http error (%s)", type(e).__name__)
        return PromError(error=f"upstream unreachable ({type(e).__name__})", error_type="upstream_http")
    return _build(
        ReadyResult,
        ready=r.status_code == 200,
        status=r.status_code,
        message=r.text.strip()[:512],
    )


# --- Auth middleware (verbatim from mcp-searxng) ---------------------------


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
                    # Drain the initial `websocket.connect` so the close frame
                    # is well-formed; bound the wait so a client that never
                    # sends can't pin the handler.
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
