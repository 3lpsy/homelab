"""Unit tests for mcp-litellm server.py.

Runs tool functions directly (bypassing FastMCP dispatch) against an
httpx.MockTransport, with the per-bearer allowlist ContextVar set per test.
Run with:

  uv run --with pytest --with fastmcp --with pydantic --with httpx \
         --with uvicorn --with starlette pytest test_server.py
"""
import asyncio
import json
import os

BEARER = "mcp-bearer-a"
HASH_A = "a" * 64  # in allowlist
HASH_B = "b" * 64  # in allowlist
HASH_OUTSIDE = "c" * 64  # NOT in allowlist — must be rejected

os.environ["MCP_API_KEYS"] = f"{BEARER},mcp-bearer-other"
os.environ["MCP_KEY_HASH_MAP"] = json.dumps(
    {
        BEARER: [HASH_A, HASH_B],
        "mcp-bearer-other": [HASH_OUTSIDE],
    }
)
os.environ["LITELLM_BASE_URL"] = "http://litellm.test"
os.environ["LITELLM_MASTER_KEY"] = "sk-master-test"
os.environ.setdefault("LOG_LEVEL", "error")

import httpx  # noqa: E402
import pytest  # noqa: E402
from fastmcp.exceptions import ToolError  # noqa: E402

import server  # noqa: E402


def _call(coro):
    return asyncio.run(coro)


def _patch_client(monkeypatch, handler):
    """Replace server._client with one backed by an httpx.MockTransport.
    Preserves the master-key Authorization header so tests verify it lands."""
    transport = httpx.MockTransport(handler)

    def _fake_client():
        return httpx.AsyncClient(
            base_url=server.LITELLM_BASE_URL,
            transport=transport,
            timeout=server.MCP_UPSTREAM_TIMEOUT,
            headers={
                "User-Agent": "mcp-litellm/2.0",
                "Authorization": f"Bearer {server.LITELLM_MASTER_KEY}",
            },
        )

    monkeypatch.setattr(server, "_client", _fake_client)


@pytest.fixture(autouse=True)
def _bind_allowlist():
    tok = server.current_allowed_hashes.set(frozenset({HASH_A, HASH_B}))
    yield
    server.current_allowed_hashes.reset(tok)


# --- startup parsing -----------------------------------------------------


def test_parse_hash_map_empty():
    assert server._parse_hash_map("") == {}
    assert server._parse_hash_map("   ") == {}


def test_parse_hash_map_ok():
    raw = json.dumps({"alice": [HASH_A], "bob": [HASH_A, HASH_B]})
    m = server._parse_hash_map(raw)
    assert m["alice"] == frozenset({HASH_A})
    assert m["bob"] == frozenset({HASH_A, HASH_B})


def test_parse_hash_map_rejects_non_json():
    with pytest.raises(SystemExit):
        server._parse_hash_map("not json")


def test_parse_hash_map_rejects_non_object():
    with pytest.raises(SystemExit):
        server._parse_hash_map(json.dumps([HASH_A]))


def test_parse_hash_map_rejects_non_list_value():
    with pytest.raises(SystemExit):
        server._parse_hash_map(json.dumps({"alice": HASH_A}))


def test_parse_hash_map_rejects_bad_hash():
    with pytest.raises(SystemExit):
        server._parse_hash_map(json.dumps({"alice": ["short"]}))
    with pytest.raises(SystemExit):
        server._parse_hash_map(json.dumps({"alice": ["A" * 64]}))  # uppercase
    with pytest.raises(SystemExit):
        server._parse_hash_map(json.dumps({"alice": ["z" * 64]}))  # non-hex


# --- _validate_hash -------------------------------------------------------


def test_validate_hash_accepts_allowed():
    assert server._validate_hash(HASH_A) == HASH_A


def test_validate_hash_accepts_mixed_case_input():
    # Canonicalises to lowercase before comparing.
    assert server._validate_hash(HASH_A.upper()) == HASH_A


def test_validate_hash_rejects_outside_allowlist():
    with pytest.raises(ToolError, match="not in this MCP bearer's allowlist"):
        server._validate_hash(HASH_OUTSIDE)


def test_validate_hash_rejects_malformed():
    with pytest.raises(ToolError, match="64-char"):
        server._validate_hash("short")


def test_validate_hash_rejects_empty_allowlist():
    server.current_allowed_hashes.set(frozenset())
    with pytest.raises(ToolError, match="No LiteLLM key hashes are bound"):
        server._validate_hash(HASH_A)


# --- list_my_keys ---------------------------------------------------------


def test_list_my_keys_happy(monkeypatch):
    captured = {"calls": []}

    def handler(req):
        captured["calls"].append(dict(req.url.params))
        # Respond differently per hash so we verify both are queried.
        qs = dict(req.url.params)
        return httpx.Response(
            200,
            json={
                "key_alias": f"alias-{qs['key'][:4]}",
                "spend": 1.23 if qs["key"] == HASH_A else 4.56,
                "max_budget": 20.0,
                "models": ["claude-opus-4-7"],
            },
        )

    _patch_client(monkeypatch, handler)
    res = _call(server.list_my_keys())
    assert isinstance(res, server.MyKeysResult)
    hashes_returned = {k.key_hash for k in res.keys}
    assert hashes_returned == {HASH_A, HASH_B}
    a = next(k for k in res.keys if k.key_hash == HASH_A)
    assert a.spend == 1.23
    assert a.key_alias == f"alias-{HASH_A[:4]}"
    # Both hashes hit upstream.
    called_hashes = {c["key"] for c in captured["calls"]}
    assert called_hashes == {HASH_A, HASH_B}


def test_list_my_keys_empty_allowlist():
    server.current_allowed_hashes.set(frozenset())
    res = _call(server.list_my_keys())
    assert res.keys == []


def test_list_my_keys_upstream_error_per_hash(monkeypatch):
    """One hash fails, the other succeeds — we return both with a per-entry
    error string rather than failing the whole tool call."""
    def handler(req):
        qs = dict(req.url.params)
        if qs["key"] == HASH_A:
            return httpx.Response(404, json={"detail": "not found"})
        return httpx.Response(200, json={"key_alias": "ok", "spend": 0.5, "max_budget": 10})

    _patch_client(monkeypatch, handler)
    res = _call(server.list_my_keys())
    by_hash = {k.key_hash: k for k in res.keys}
    assert by_hash[HASH_A].error is not None
    assert "404" in by_hash[HASH_A].error
    assert by_hash[HASH_B].spend == 0.5
    assert by_hash[HASH_B].error is None


def test_list_my_keys_handles_wrapped_info(monkeypatch):
    """Some LiteLLM versions wrap the payload in {'info': {...}}."""
    def handler(_req):
        return httpx.Response(200, json={"info": {"key_alias": "wrapped", "spend": 7.7}})

    _patch_client(monkeypatch, handler)
    res = _call(server.list_my_keys())
    assert all(k.key_alias == "wrapped" for k in res.keys)
    assert all(k.spend == 7.7 for k in res.keys)


# --- get_key_info ---------------------------------------------------------


def test_get_key_info_happy(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        captured["auth"] = req.headers.get("authorization")
        return httpx.Response(200, json={"spend": 1.5, "max_budget": 50.0})

    _patch_client(monkeypatch, handler)
    res = _call(server.get_key_info(key_hash=HASH_A))
    assert isinstance(res, server.KeyInfo)
    assert res.model_dump()["spend"] == 1.5
    assert captured["params"]["key"] == HASH_A
    assert captured["auth"] == f"Bearer {server.LITELLM_MASTER_KEY}"


def test_get_key_info_rejects_outside_hash(monkeypatch):
    called = {"n": 0}

    def handler(_req):
        called["n"] += 1
        return httpx.Response(200, json={})

    _patch_client(monkeypatch, handler)
    with pytest.raises(ToolError, match="not in this MCP bearer's allowlist"):
        _call(server.get_key_info(key_hash=HASH_OUTSIDE))
    # Upstream must not have been hit — validation precedes the network call.
    assert called["n"] == 0


# --- get_spend_logs -------------------------------------------------------


def _v2_page(rows, page=1, page_size=100, total=None):
    total = len(rows) if total is None else total
    return httpx.Response(
        200,
        json={
            "data": rows,
            "total": total,
            "page": page,
            "page_size": page_size,
            "total_pages": max(1, (total + page_size - 1) // page_size),
        },
    )


def test_get_spend_logs_happy(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        captured["path"] = req.url.path
        return _v2_page([
            {"request_id": "r1", "startTime": "2026-04-22T10:00:00Z", "spend": 0.01, "total_tokens": 100, "model": "claude-opus-4-7"},
            {"request_id": "r2", "startTime": "2026-04-22T11:00:00Z", "spend": 0.02, "total_tokens": 200, "model": "claude-opus-4-7"},
        ])

    _patch_client(monkeypatch, handler)
    res = _call(server.get_spend_logs(key_hash=HASH_A, start_date="2026-04-01", end_date="2026-04-22"))
    assert res.key_hash == HASH_A
    assert res.count == 2
    assert res.truncated is False
    assert captured["path"].endswith("/spend/logs/v2")
    assert captured["params"]["api_key"] == HASH_A
    assert "session_id" not in captured["params"]


def test_get_spend_logs_session_filter_is_client_side(monkeypatch):
    """session_id is *not* forwarded upstream (LiteLLM ignores it); the MCP
    applies the filter in Python after pagination."""
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return _v2_page([
            {"request_id": "r1", "spend": 0.01, "session_id": "sess-1"},
            {"request_id": "r2", "spend": 0.02, "session_id": "sess-other"},
            {"request_id": "r3", "spend": 0.03, "metadata": {"session_id": "sess-1"}},
        ])

    _patch_client(monkeypatch, handler)
    res = _call(server.get_spend_logs(key_hash=HASH_A, start_date="2026-04-01", end_date="2026-04-22", session_id="sess-1"))
    assert "session_id" not in captured["params"]
    assert {r["request_id"] for r in res.logs} == {"r1", "r3"}


def test_get_spend_logs_paginates_and_caps(monkeypatch):
    """Upstream pages 100 at a time; we stop at MCP_MAX_LOGS and flag
    truncated when upstream reports more rows than the cap."""
    call_count = {"n": 0}

    def handler(req):
        call_count["n"] += 1
        page = int(req.url.params["page"])
        total = server.MCP_MAX_LOGS + 50
        batch = [{"request_id": f"r{(page-1)*100+i}", "spend": 0.01} for i in range(100)]
        return _v2_page(batch, page=page, page_size=100, total=total)

    _patch_client(monkeypatch, handler)
    res = _call(server.get_spend_logs(key_hash=HASH_A, start_date="2026-04-01", end_date="2026-04-22"))
    assert res.truncated is True
    assert len(res.logs) == server.MCP_MAX_LOGS
    assert res.count == server.MCP_MAX_LOGS + 50
    # Exactly ceil(MCP_MAX_LOGS / 100) pages fetched.
    assert call_count["n"] == (server.MCP_MAX_LOGS + 99) // 100


def test_get_spend_logs_rejects_outside_hash(monkeypatch):
    _patch_client(monkeypatch, lambda _r: _v2_page([]))
    with pytest.raises(ToolError, match="not in this MCP bearer's allowlist"):
        _call(server.get_spend_logs(key_hash=HASH_OUTSIDE, start_date="2026-04-01", end_date="2026-04-22"))


def test_get_spend_logs_auto_selects_single_key(monkeypatch):
    """If the caller's allowlist has exactly one hash, key_hash is optional."""
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return _v2_page([])

    tok = server.current_allowed_hashes.set(frozenset({HASH_A}))
    try:
        _patch_client(monkeypatch, handler)
        _call(server.get_spend_logs(start_date="2026-04-01", end_date="2026-04-22"))
        assert captured["params"]["api_key"] == HASH_A
    finally:
        server.current_allowed_hashes.reset(tok)


def test_get_spend_logs_refuses_auto_when_ambiguous(monkeypatch):
    _patch_client(monkeypatch, lambda _r: _v2_page([]))
    with pytest.raises(ToolError, match="Multiple key hashes"):
        _call(server.get_spend_logs(start_date="2026-04-01", end_date="2026-04-22"))


# --- get_daily_summary ---------------------------------------------------


def test_get_daily_summary_aggregates(monkeypatch):
    def handler(_req):
        return _v2_page([
            {"startTime": "2026-04-22T10:00:00Z", "spend": 0.10, "total_tokens": 100, "prompt_tokens": 60, "completion_tokens": 40, "model": "claude-opus-4-7"},
            {"startTime": "2026-04-22T11:00:00Z", "spend": 0.20, "total_tokens": 200, "prompt_tokens": 120, "completion_tokens": 80, "model": "claude-opus-4-7"},
            {"startTime": "2026-04-23T09:00:00Z", "spend": 0.05, "total_tokens": 50, "prompt_tokens": 30, "completion_tokens": 20, "model": "claude-haiku-4-5"},
        ])

    _patch_client(monkeypatch, handler)
    res = _call(server.get_daily_summary(key_hash=HASH_A, start_date="2026-04-22", end_date="2026-04-23"))
    assert res.total_spend == pytest.approx(0.35)
    assert res.total_tokens == 350
    assert res.total_requests == 3
    by_date = {d.date: d for d in res.days}
    assert set(by_date) == {"2026-04-22", "2026-04-23"}
    assert by_date["2026-04-22"].spend == pytest.approx(0.30)
    assert by_date["2026-04-22"].request_count == 2
    assert by_date["2026-04-22"].by_model == {"claude-opus-4-7": pytest.approx(0.30)}
    assert by_date["2026-04-23"].by_model == {"claude-haiku-4-5": pytest.approx(0.05)}


def test_get_daily_summary_handles_missing_date_field(monkeypatch):
    """Rows without startTime are skipped from day buckets but don't crash."""
    def handler(_req):
        return _v2_page([
            {"startTime": "2026-04-22T10:00:00Z", "spend": 0.10, "model": "m"},
            {"spend": 0.99, "model": "orphan"},  # no startTime
        ])

    _patch_client(monkeypatch, handler)
    res = _call(server.get_daily_summary(key_hash=HASH_A, start_date="2026-04-22", end_date="2026-04-22"))
    assert len(res.days) == 1
    assert res.days[0].spend == pytest.approx(0.10)
    assert res.skipped_rows == 1


def test_get_daily_summary_bad_date_range():
    with pytest.raises(ToolError, match="precedes"):
        _call(server.get_daily_summary(key_hash=HASH_A, start_date="2026-04-22", end_date="2026-04-01"))


@pytest.mark.parametrize("bad_start", ["bogus", "2026-4-01", "2026/04/22", "22-04-2026"])
def test_get_daily_summary_bad_start_date(bad_start):
    # Pattern-mismatch errors used to leak pydantic's validation-URL blob;
    # now they surface as a single-line ToolError that names the arg.
    with pytest.raises(ToolError) as ei:
        _call(server.get_daily_summary(
            key_hash=HASH_A, start_date=bad_start, end_date="2026-04-22",
        ))
    msg = str(ei.value)
    assert "start_date must be YYYY-MM-DD" in msg
    assert bad_start in msg
    assert "pydantic.dev" not in msg


def test_get_daily_summary_bad_end_date():
    with pytest.raises(ToolError) as ei:
        _call(server.get_daily_summary(
            key_hash=HASH_A, start_date="2026-04-01", end_date="nope",
        ))
    msg = str(ei.value)
    assert "end_date must be YYYY-MM-DD" in msg
    assert "nope" in msg


def test_get_spend_logs_bad_start_date():
    # Same clean-error treatment on get_spend_logs.
    with pytest.raises(ToolError) as ei:
        _call(server.get_spend_logs(
            key_hash=HASH_A, start_date="junk", end_date="2026-04-22",
        ))
    assert "start_date must be YYYY-MM-DD" in str(ei.value)


# --- get_monthly_summary --------------------------------------------------


def test_get_monthly_summary_happy(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return _v2_page([
            {"startTime": "2026-04-01T00:00:00Z", "spend": 1.0, "total_tokens": 100, "prompt_tokens": 60, "completion_tokens": 40, "model": "claude-opus-4-7"},
            {"startTime": "2026-04-15T00:00:00Z", "spend": 0.5, "total_tokens": 50, "prompt_tokens": 30, "completion_tokens": 20, "model": "claude-haiku-4-5"},
            {"startTime": "2026-04-30T00:00:00Z", "spend": 0.25, "total_tokens": 25, "prompt_tokens": 15, "completion_tokens": 10, "model": "claude-opus-4-7"},
        ])

    _patch_client(monkeypatch, handler)
    res = _call(server.get_monthly_summary(key_hash=HASH_A, month="2026-04"))
    assert res.month == "2026-04"
    assert res.start_date == "2026-04-01"
    assert res.end_date == "2026-04-30"
    assert res.total_spend == pytest.approx(1.75)
    assert res.total_tokens == 175
    assert res.prompt_tokens == 105
    assert res.completion_tokens == 70
    assert res.total_requests == 3
    assert res.by_model["claude-opus-4-7"] == pytest.approx(1.25)
    assert res.by_model["claude-haiku-4-5"] == pytest.approx(0.5)
    assert res.by_day["2026-04-01"] == pytest.approx(1.0)
    assert captured["params"]["start_date"] == "2026-04-01"
    assert captured["params"]["end_date"] == "2026-04-30"


def test_get_monthly_summary_leap_february(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return _v2_page([])

    _patch_client(monkeypatch, handler)
    res = _call(server.get_monthly_summary(key_hash=HASH_A, month="2024-02"))
    assert captured["params"]["end_date"] == "2024-02-29"
    assert res.end_date == "2024-02-29"


@pytest.mark.parametrize("bad", ["2026-13", "2026-00", "bogus", "2026", "2026-4", "26-04"])
def test_get_monthly_summary_bad_month(monkeypatch, bad):
    # Bad month values produce a single-line ToolError — no pydantic
    # validation-error blob with an "https://errors.pydantic.dev/..." URL.
    _patch_client(monkeypatch, lambda _r: _v2_page([]))
    with pytest.raises(ToolError) as ei:
        _call(server.get_monthly_summary(key_hash=HASH_A, month=bad))
    msg = str(ei.value)
    assert "month must be YYYY-MM" in msg
    assert bad in msg
    # No leaked pydantic internals.
    assert "pydantic.dev" not in msg
    assert "string_pattern_mismatch" not in msg


def test_get_monthly_summary_empty(monkeypatch):
    _patch_client(monkeypatch, lambda _r: _v2_page([]))
    res = _call(server.get_monthly_summary(key_hash=HASH_A, month="2026-04"))
    assert res.total_spend == 0
    assert res.total_requests == 0
    assert res.by_model == {}
    assert res.by_day == {}


# --- upstream error mapping → ToolError ----------------------------------


def test_401_maps_cleanly(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(401, json={"detail": "invalid key"}))
    with pytest.raises(ToolError, match="master key rejected"):
        _call(server.get_key_info(key_hash=HASH_A))


def test_403_flagged_as_unexpected(monkeypatch):
    # master key shouldn't ever 403; surface as unexpected
    _patch_client(monkeypatch, lambda _r: httpx.Response(403, json={"detail": "nope"}))
    with pytest.raises(ToolError, match="unexpected"):
        _call(server.get_key_info(key_hash=HASH_A))


def test_404_maps_cleanly(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(404, json={"detail": "gone"}))
    with pytest.raises(ToolError, match="404"):
        _call(server.get_key_info(key_hash=HASH_A))


def test_500_maps_to_generic_http(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(503, text="down"))
    with pytest.raises(ToolError, match="HTTP 503"):
        _call(server.get_key_info(key_hash=HASH_A))


def test_timeout_maps_to_tool_error(monkeypatch):
    def handler(_req):
        raise httpx.TimeoutException("slow")

    _patch_client(monkeypatch, handler)
    with pytest.raises(ToolError, match="timed out"):
        _call(server.get_key_info(key_hash=HASH_A))


def test_connect_error_maps_to_sidecar_hint(monkeypatch):
    def handler(_req):
        raise httpx.ConnectError("refused")

    _patch_client(monkeypatch, handler)
    with pytest.raises(ToolError, match="tailscale sidecar"):
        _call(server.get_key_info(key_hash=HASH_A))


def test_non_json_body_raises_tool_error(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, text="<html>oops</html>"))
    with pytest.raises(ToolError, match="non-JSON"):
        _call(server.get_key_info(key_hash=HASH_A))


# --- row helpers (standalone) --------------------------------------------


def test_row_date_iso():
    assert server._row_date({"startTime": "2026-04-22T10:00:00Z"}) == "2026-04-22"


def test_row_date_snake_case():
    assert server._row_date({"start_time": "2026-04-22T10:00:00+00:00"}) == "2026-04-22"


def test_row_date_date_only_fallback():
    assert server._row_date({"startTime": "2026-04-22"}) == "2026-04-22"


def test_row_date_missing():
    assert server._row_date({}) is None
    assert server._row_date({"startTime": ""}) is None


def test_row_spend_alternatives():
    assert server._row_spend({"spend": 1.5}) == 1.5
    assert server._row_spend({"cost": 2.0}) == 2.0
    assert server._row_spend({"response_cost": 0.5}) == 0.5
    assert server._row_spend({}) == 0.0


def test_row_model_unknown():
    assert server._row_model({}) == "unknown"


def test_validate_date_range_equal_ok():
    server._validate_date_range("2026-04-22", "2026-04-22")


def test_validate_date_range_bad_format():
    with pytest.raises(ToolError, match="YYYY-MM-DD"):
        server._validate_date_range("xxx", "2026-04-22")
