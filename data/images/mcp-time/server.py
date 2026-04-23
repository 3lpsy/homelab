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


def _time_result(tz_name: str, dt: datetime) -> TimeResult:
    return TimeResult(
        timezone=tz_name,
        datetime=dt.isoformat(timespec="seconds"),
        day_of_week=dt.strftime("%A"),
        is_dst=bool(dt.dst()),
    )


mcp = FastMCP("time")


TzParam = Annotated[
    str | None,
    Field(
        description=(
            "IANA timezone name (e.g. 'America/New_York', 'Europe/London', "
            f"'UTC'). Omit to use the server default ({MCP_DEFAULT_TIMEZONE})."
        ),
    ),
]


@mcp.tool()
async def get_current_time(timezone: TzParam = None) -> TimeResult:
    """Current wall-clock time in the given IANA timezone."""
    tz_name = (timezone or MCP_DEFAULT_TIMEZONE).strip()
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
            description="Time to convert in 24-hour HH:MM format (e.g. '14:30').",
        ),
    ],
    source_timezone: TzParam = None,
    target_timezone: TzParam = None,
) -> TimeConversionResult:
    """Convert HH:MM (today's date in source tz) between IANA timezones."""
    src_name = (source_timezone or MCP_DEFAULT_TIMEZONE).strip()
    tgt_name = (target_timezone or MCP_DEFAULT_TIMEZONE).strip()
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
    if hours.is_integer():
        diff = f"{hours:+.1f}h"
    else:
        # Fractional offsets like Nepal (UTC+5:45) or India (UTC+5:30).
        diff = f"{hours:+.2f}".rstrip("0").rstrip(".") + "h"

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
