"""Time MCP server.

Port of `mcp-server-time` to fastmcp v2 streamable-http with bearer-key auth.
Exposes `get_current_time` and `convert_time`. No per-tenant state — the server
is a pure function of system clock + zoneinfo. Auth is fail-closed (empty
`MCP_API_KEYS` rejects every request).

Environment:
  MCP_API_KEYS           CSV of accepted Bearer tokens. Empty/unset is fail-closed.
  MCP_DEFAULT_TIMEZONE   IANA zone used when a tool call omits the timezone arg
                         (default 'America/Chicago'). Validated at boot.
  MCP_HOST               Bind host (default 0.0.0.0).
  MCP_PORT               Bind port (default 8000).
  LOG_LEVEL              debug / info / warning / error (default info).
"""

import logging
import os
import secrets
from datetime import datetime, timedelta
from typing import Annotated
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import uvicorn
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import BaseModel, ConfigDict, Field
from starlette.datastructures import Headers, QueryParams
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send


def _env_int(name: str, default: str) -> int:
    raw = os.environ.get(name, default)
    try:
        return int(raw)
    except ValueError as e:
        raise SystemExit(f"{name} must be an int, got {raw!r}") from e


API_KEYS = {k.strip() for k in os.environ.get("MCP_API_KEYS", "").split(",") if k.strip()}
MCP_DEFAULT_TIMEZONE = os.environ.get("MCP_DEFAULT_TIMEZONE", "America/Chicago").strip()
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = _env_int("MCP_PORT", "8000")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("mcp-time")

# Validate the default zone at import so a typo fails the pod instead of every
# tool call. ZoneInfoNotFoundError is the only failure mode once we have the
# tzdata package installed in the image.
try:
    ZoneInfo(MCP_DEFAULT_TIMEZONE)
except ZoneInfoNotFoundError as _e:
    raise SystemExit(
        f"MCP_DEFAULT_TIMEZONE invalid IANA zone: {MCP_DEFAULT_TIMEZONE!r}"
    ) from _e

log.info(
    "startup: default_tz=%s api_keys=%d log_level=%s",
    MCP_DEFAULT_TIMEZONE, len(API_KEYS), LOG_LEVEL,
)


class TimeResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    timezone: str
    datetime: str
    day_of_week: str
    is_dst: bool
    # Populated when the caller passed a fixed-offset legacy alias like
    # "EST" / "CST" / "PST" instead of a real Area/Location zone. These
    # aliases exist in tzdata but are DST-unaware, so an LLM that picked
    # them up from user text ("convert 2pm EST to …") gets the wrong
    # result half the year. Surfaced so the LLM can self-correct on the
    # next call without the server hard-rejecting established workflows.
    warning: str | None = None


class TimeConversionResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    source: TimeResult
    target: TimeResult
    time_difference: str


def _zone(tz_name: str, label: str) -> ZoneInfo:
    """Resolve an IANA name to a ZoneInfo, turning lookup failure into a
    ToolError. `label` names the arg in the message so the caller can tell
    which of source/target was bad."""
    try:
        return ZoneInfo(tz_name)
    except ZoneInfoNotFoundError as e:
        raise ToolError(
            f"{label} {tz_name!r} is not a valid IANA timezone "
            "(e.g. 'America/New_York', 'Europe/London', 'UTC')"
        ) from e


# Bare top-level names in tzdata that are NOT misleading — "UTC" and "GMT"
# are universally understood zero-offset, and "Zulu" is an alias of UTC.
# Everything else without a "/" (EST, CST, MST, PST, HST, EET, CET, ...)
# is a legacy alias. Some of those European ones DO track DST, but the
# Area/Location form is still the safer recommendation for an LLM that
# may not know which is which.
_BARE_ZONE_OK = frozenset({"UTC", "GMT", "Zulu"})


def _zone_warning(tz_name: str) -> str | None:
    """Return a warning string for misleading zone names, else None.

    Fires when the caller hands over a bare abbreviation like "EST" — they
    resolve in zoneinfo but silently drop DST, so a 14:30-EST → UTC
    conversion in April is an hour off from what the user actually meant.
    """
    if "/" in tz_name:
        return None
    if tz_name in _BARE_ZONE_OK:
        return None
    return (
        f"zone {tz_name!r} is a fixed-offset legacy alias without full DST "
        "support — it will not shift for summer/winter time. For DST-aware "
        "behavior use an Area/Location zone like 'America/New_York', "
        "'Europe/London', 'Asia/Kolkata'."
    )


def _format_hours(hours: float) -> str:
    """Render a signed hour offset with the shortest decimal form that
    represents it exactly, always keeping at least one digit after the dot
    so clients can parse with a single regex.

    "+5.0", "-5.0", "+5.5", "+5.75" — never "+5" or "+5.50".
    """
    one = f"{hours:+.1f}"
    # Keep 1-decimal form if it round-trips exactly (covers whole hours,
    # and :30 offsets like India). Otherwise drop to 2 decimals for :45
    # offsets (Nepal, Chatham). No real IANA zone has finer than :15.
    if float(one) == hours:
        return one
    return f"{hours:+.2f}"


def _time_result(tz_name: str, dt: datetime) -> TimeResult:
    return TimeResult(
        timezone=tz_name,
        datetime=dt.isoformat(timespec="seconds"),
        day_of_week=dt.strftime("%A"),
        is_dst=bool(dt.dst()),
        warning=_zone_warning(tz_name),
    )


_INSTRUCTIONS = f"""\
Wall-clock time helpers. No server-side state — every call is a pure
function of the host clock + IANA tzdata.

Tools:
  - `get_current_time(timezone)`: current time in the given zone.
  - `convert_time(time, source_timezone, target_timezone)`: convert an
    `HH:MM` (24-hour) time from one zone to another using TODAY'S date
    in the source zone.

Conventions:
  - Timezones are IANA names: "America/New_York", "Europe/London", "UTC",
    "Asia/Kolkata", "Asia/Kathmandu", ... NOT abbreviations like "EST",
    "PST", or UTC offsets like "+05:30".
  - Time strings are 24-hour "HH:MM" — "09:05", "17:30", "00:00". NOT
    "9am", "5:30 PM", or seconds/milliseconds.
  - Omit a timezone argument (or pass "") to use the server default:
    {MCP_DEFAULT_TIMEZONE!r}.

Outputs include `timezone`, `datetime` (ISO 8601 with offset), `day_of_week`
(English), and `is_dst`. `convert_time` also returns `time_difference`
in the form "+5.0h", "+5.5h", "+5.75h".
"""

async def _healthz(_request) -> JSONResponse:
    """Liveness + readiness probe target. No auth, no upstream calls."""
    return JSONResponse({"ok": True})


mcp = FastMCP("time", instructions=_INSTRUCTIONS)


mcp.custom_route("/healthz", methods=["GET"])(_healthz)


TzParam = Annotated[
    str | None,
    Field(
        max_length=64,
        description=(
            "IANA timezone name (e.g. 'America/New_York', 'Europe/London', "
            f"'UTC'). Omit to use the server default ({MCP_DEFAULT_TIMEZONE})."
        ),
    ),
]


def _resolve_tz(raw: str | None) -> str:
    """Pick the timezone name: caller-supplied if non-blank, else the server
    default. Treats empty-string and whitespace-only the same — both are
    what HTTP transports often send for 'omitted'."""
    if raw is None:
        return MCP_DEFAULT_TIMEZONE
    stripped = raw.strip()
    return stripped or MCP_DEFAULT_TIMEZONE


@mcp.tool()
async def get_current_time(timezone: TzParam = None) -> TimeResult:
    """Current wall-clock time in the given IANA timezone."""
    tz_name = _resolve_tz(timezone)
    tz = _zone(tz_name, "timezone")
    now = datetime.now(tz)
    log.info("get_current_time: tz=%s", tz_name)
    return _time_result(tz_name, now)


@mcp.tool()
async def convert_time(
    time: Annotated[
        str,
        Field(
            min_length=1,
            max_length=8,
            description="Time to convert in 24-hour HH:MM format (e.g. '14:30').",
        ),
    ],
    source_timezone: TzParam = None,
    target_timezone: TzParam = None,
) -> TimeConversionResult:
    """Convert HH:MM (today's date in source tz) between IANA timezones."""
    src_name = _resolve_tz(source_timezone)
    tgt_name = _resolve_tz(target_timezone)
    src = _zone(src_name, "source_timezone")
    tgt = _zone(tgt_name, "target_timezone")

    try:
        parsed = datetime.strptime(time, "%H:%M").time()
    except ValueError as e:
        raise ToolError(
            f"time {time!r} is not valid HH:MM (24-hour, e.g. '09:05', '17:30')"
        ) from e

    now = datetime.now(src)
    source_time = datetime(
        now.year, now.month, now.day, parsed.hour, parsed.minute, tzinfo=src,
    )
    target_time = source_time.astimezone(tgt)

    src_off = source_time.utcoffset() or timedelta()
    tgt_off = target_time.utcoffset() or timedelta()
    hours = (tgt_off - src_off).total_seconds() / 3600
    diff = f"{_format_hours(hours)}h"

    log.info("convert_time: %s %s -> %s (%s)", time, src_name, tgt_name, diff)
    return TimeConversionResult(
        source=_time_result(src_name, source_time),
        target=_time_result(tgt_name, target_time),
        time_difference=diff,
    )


# Pure ASGI middleware — matches mcp-prometheus / mcp-searxng shape. No
# per-tenant state on this server so no contextvar is bound; token is only
# used to authorize the request.
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
