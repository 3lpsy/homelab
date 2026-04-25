"""Unit tests for mcp-time server.py.

Runs tool functions directly (bypassing FastMCP dispatch). Run with:

  uv run --with pytest --with fastmcp --with pydantic --with tzdata \
         --with uvicorn --with starlette pytest test_server.py
"""
import asyncio
import os

os.environ["MCP_API_KEYS"] = "key-a,key-b"
os.environ["MCP_DEFAULT_TIMEZONE"] = "America/Chicago"
os.environ.setdefault("LOG_LEVEL", "error")

from datetime import datetime  # noqa: E402
from zoneinfo import ZoneInfo  # noqa: E402

import pytest  # noqa: E402
from fastmcp.exceptions import ToolError  # noqa: E402

import server  # noqa: E402


def _call(coro):
    return asyncio.run(coro)


# --- get_current_time -----------------------------------------------------


def test_get_current_time_explicit_tz():
    res = _call(server.get_current_time(timezone="UTC"))
    assert isinstance(res, server.TimeResult)
    assert res.timezone == "UTC"
    # Parses as RFC3339 and carries the requested zone's offset.
    dt = datetime.fromisoformat(res.datetime)
    assert dt.utcoffset().total_seconds() == 0
    assert res.day_of_week in {
        "Monday", "Tuesday", "Wednesday", "Thursday",
        "Friday", "Saturday", "Sunday",
    }


def test_get_current_time_defaults_to_env():
    res = _call(server.get_current_time())
    assert res.timezone == server.MCP_DEFAULT_TIMEZONE == "America/Chicago"
    dt = datetime.fromisoformat(res.datetime)
    # America/Chicago is either UTC-6 (CST) or UTC-5 (CDT); is_dst should agree.
    off_hours = dt.utcoffset().total_seconds() / 3600
    if res.is_dst:
        assert off_hours == -5
    else:
        assert off_hours == -6


def test_get_current_time_invalid_tz():
    with pytest.raises(ToolError) as ei:
        _call(server.get_current_time(timezone="Not/A_Zone"))
    assert "timezone" in str(ei.value)
    assert "Not/A_Zone" in str(ei.value)


def test_get_current_time_empty_string_falls_back_to_default():
    # Empty string is treated as "omitted" — matches how the HTTP transport
    # sometimes delivers missing optional params.
    res = _call(server.get_current_time(timezone=""))
    assert res.timezone == "America/Chicago"


def test_get_current_time_whitespace_falls_back_to_default():
    # Whitespace-only should behave the same as empty-string — the previous
    # implementation errored with "timezone '' is not a valid IANA timezone".
    res = _call(server.get_current_time(timezone="   "))
    assert res.timezone == "America/Chicago"


# --- fixed-offset legacy alias warning ------------------------------------


@pytest.mark.parametrize("tz", ["EST", "MST", "HST"])
def test_get_current_time_legacy_alias_warns(tz):
    # tzdata ships a handful of bare abbreviations as fixed-offset zones
    # (EST, MST, HST — and NOT CST/PST, which are ambiguous and so not
    # aliased). An LLM that picks these up from user text gets the wrong
    # result half the year; we resolve them anyway but surface a warning
    # so the caller self-corrects on the next call. HST in particular is
    # benign for Hawaii (no DST), but most people typing "HST" don't
    # know that and we still nudge toward Pacific/Honolulu.
    res = _call(server.get_current_time(timezone=tz))
    assert res.timezone == tz
    assert res.warning is not None
    assert tz in res.warning
    assert "America/" in res.warning  # points at the safer replacement form


@pytest.mark.parametrize("tz", ["UTC", "GMT", "Zulu"])
def test_get_current_time_bare_universal_names_no_warning(tz):
    # UTC / GMT / Zulu are universally understood zero-offset and do not
    # pretend to track DST — do not pester the LLM.
    res = _call(server.get_current_time(timezone=tz))
    assert res.warning is None


@pytest.mark.parametrize("tz", [
    "America/New_York", "Europe/London", "Asia/Kolkata",
    "Asia/Kathmandu", "Pacific/Honolulu", "America/Phoenix",
])
def test_get_current_time_area_location_no_warning(tz):
    res = _call(server.get_current_time(timezone=tz))
    assert res.warning is None


def test_convert_time_propagates_warning_on_either_side():
    # A warning on either source or target must reach the caller — the
    # tool returns both TimeResults, so the LLM sees either.
    res = _call(server.convert_time(
        time="14:30",
        source_timezone="EST",
        target_timezone="Europe/London",
    ))
    assert res.source.warning is not None
    assert res.target.warning is None


# --- convert_time ---------------------------------------------------------


def test_convert_time_basic():
    res = _call(server.convert_time(
        time="09:00",
        source_timezone="America/New_York",
        target_timezone="Europe/London",
    ))
    assert isinstance(res, server.TimeConversionResult)
    assert res.source.timezone == "America/New_York"
    assert res.target.timezone == "Europe/London"
    # NY and London are always 5h apart (both observe DST on different rules
    # but the gap between them is locked at +5 except for ~2 weeks/year where
    # it drifts to +4 or +6). Just check the sign and integer format.
    assert res.time_difference.endswith("h")
    assert res.time_difference.startswith("+")
    # Source time should round-trip hour/minute.
    src_dt = datetime.fromisoformat(res.source.datetime)
    assert (src_dt.hour, src_dt.minute) == (9, 0)


def test_convert_time_defaults_both_to_env():
    res = _call(server.convert_time(time="12:00"))
    assert res.source.timezone == "America/Chicago"
    assert res.target.timezone == "America/Chicago"
    assert res.time_difference == "+0.0h"


def test_convert_time_fractional_offset():
    # Asia/Kathmandu is UTC+5:45 — offset from UTC is fractional.
    res = _call(server.convert_time(
        time="12:00",
        source_timezone="UTC",
        target_timezone="Asia/Kathmandu",
    ))
    assert res.time_difference == "+5.75h"


def test_convert_time_half_hour_offset():
    # Asia/Kolkata is UTC+5:30.
    res = _call(server.convert_time(
        time="12:00",
        source_timezone="UTC",
        target_timezone="Asia/Kolkata",
    ))
    assert res.time_difference == "+5.5h"


def test_convert_time_negative_difference():
    res = _call(server.convert_time(
        time="12:00",
        source_timezone="Europe/London",
        target_timezone="America/New_York",
    ))
    assert res.time_difference.startswith("-")


def test_convert_time_invalid_source_tz():
    with pytest.raises(ToolError) as ei:
        _call(server.convert_time(
            time="12:00",
            source_timezone="Bogus/Zone",
            target_timezone="UTC",
        ))
    assert "source_timezone" in str(ei.value)


def test_convert_time_invalid_target_tz():
    with pytest.raises(ToolError) as ei:
        _call(server.convert_time(
            time="12:00",
            source_timezone="UTC",
            target_timezone="Bogus/Zone",
        ))
    assert "target_timezone" in str(ei.value)


@pytest.mark.parametrize("bad", ["", "9", "25:00", "12:60", "noon", "12-30"])
def test_convert_time_invalid_time_format(bad):
    with pytest.raises(ToolError) as ei:
        _call(server.convert_time(time=bad, source_timezone="UTC", target_timezone="UTC"))
    assert "HH:MM" in str(ei.value)


def test_convert_time_edge_midnight():
    res = _call(server.convert_time(
        time="00:00",
        source_timezone="UTC",
        target_timezone="UTC",
    ))
    src_dt = datetime.fromisoformat(res.source.datetime)
    assert (src_dt.hour, src_dt.minute, src_dt.second) == (0, 0, 0)


# --- _format_hours --------------------------------------------------------


@pytest.mark.parametrize("hours,expected", [
    (0.0, "+0.0"),
    (5.0, "+5.0"),
    (-5.0, "-5.0"),
    (5.5, "+5.5"),   # India: UTC+5:30
    (-3.5, "-3.5"),
    (5.75, "+5.75"), # Nepal: UTC+5:45
    (-2.75, "-2.75"),
])
def test_format_hours(hours, expected):
    assert server._format_hours(hours) == expected


# --- input length caps ----------------------------------------------------


def test_tz_max_length_enforced_via_tool_schema():
    # TzParam carries Field(max_length=64). Validate that the constraint
    # survives into the MCP tool inputSchema so clients reject long strings
    # before they reach ZoneInfo.
    tool = asyncio.run(server.mcp.get_tool("get_current_time"))
    tz_schema = tool.parameters["properties"]["timezone"]
    # FastMCP flattens a Union[str, None] into {"anyOf": [...]} — the
    # string branch carries the max_length; pydantic may also promote it
    # to the outer schema depending on version.
    max_len = tz_schema.get("maxLength")
    if max_len is None:
        # anyOf form — pull from the string branch.
        for branch in tz_schema.get("anyOf", []):
            if branch.get("type") == "string":
                max_len = branch["maxLength"]
                break
    assert max_len == 64


def test_time_max_length_enforced_via_tool_schema():
    tool = asyncio.run(server.mcp.get_tool("convert_time"))
    sch = tool.parameters["properties"]["time"]
    assert sch["maxLength"] == 8
    assert sch["minLength"] == 1


# --- instructions wiring --------------------------------------------------


def test_instructions_present_on_server():
    inst = getattr(server.mcp, "instructions", None) or ""
    assert inst.strip()
    assert "IANA" in inst
    assert "HH:MM" in inst
    # Default tz must appear so an OSS LLM knows what "omitted" means here.
    assert server.MCP_DEFAULT_TIMEZONE in inst


# --- _zone helper ---------------------------------------------------------


def test_zone_returns_zoneinfo():
    z = server._zone("America/New_York", "timezone")
    assert isinstance(z, ZoneInfo)


def test_zone_bad_name_raises_toolerror():
    with pytest.raises(ToolError) as ei:
        server._zone("Mars/Olympus", "source_timezone")
    # Label is in the message so callers can tell which arg was bad.
    assert "source_timezone" in str(ei.value)
    assert "Mars/Olympus" in str(ei.value)


# --- auth middleware ------------------------------------------------------


def _run_auth(scope, inner=None):
    """Drive AuthMiddleware once and return the list of sent ASGI messages
    plus whatever the inner app produces. Inner defaults to a 200 stub."""
    sent: list[dict] = []

    async def _send(msg):
        sent.append(msg)

    async def _recv():
        return {"type": "http.request", "body": b"", "more_body": False}

    if inner is None:
        async def inner(scope, receive, send):
            await send({"type": "http.response.start", "status": 200, "headers": []})
            await send({"type": "http.response.body", "body": b"ok"})

    mw = server.AuthMiddleware(inner)
    asyncio.run(mw(scope, _recv, _send))
    return sent


def test_auth_rejects_missing_bearer():
    sent = _run_auth({
        "type": "http",
        "method": "POST",
        "path": "/",
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
        "path": "/",
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
        "path": "/",
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
        "path": "/",
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
        "path": "/",
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

    mw = server.AuthMiddleware(lambda *a, **kw: None)
    asyncio.run(mw({"type": "websocket"}, _recv, _send))
    assert sent == [{"type": "websocket.close", "code": 1008}]
