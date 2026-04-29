"""Unit tests for mcp-prometheus server.py.

Runs the tool functions directly (bypassing FastMCP dispatch) against an
httpx.MockTransport. Run with:

  uv run --with pytest --with fastmcp --with pydantic --with httpx \
         --with uvicorn --with starlette pytest test_server.py
"""
# Make the sibling `data/images/mcp-common/` package importable for tests
# without polluting `data/images/` with a top-level pyproject.toml + conftest.
import pathlib as _pathlib
import sys as _sys

_sys.path.insert(0, str(_pathlib.Path(__file__).resolve().parent.parent / "mcp-common"))

import asyncio
import json
import os

os.environ["MCP_API_KEYS"] = "key-a,key-b"
os.environ["PROMETHEUS_URL"] = "http://prom.test"
os.environ.setdefault("LOG_LEVEL", "error")

import httpx  # noqa: E402
import pytest  # noqa: E402

import server  # noqa: E402


def _call(coro):
    return asyncio.run(coro)


def _patch_client(monkeypatch, handler):
    """Replace server._client with one backed by an httpx.MockTransport
    built from `handler(request) -> httpx.Response`."""
    transport = httpx.MockTransport(handler)

    def _fake_client():
        return httpx.AsyncClient(
            base_url=server.PROMETHEUS_URL,
            transport=transport,
            timeout=server.PROMETHEUS_TIMEOUT,
        )

    monkeypatch.setattr(server, "_client", _fake_client)


# --- happy path: instant query -------------------------------------------


def test_execute_query_vector(monkeypatch):
    captured = {}

    def handler(req):
        captured["url"] = str(req.url)
        captured["params"] = dict(req.url.params)
        body = {
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [
                    {"metric": {"__name__": "up", "job": "node"}, "value": [1700000000, "1"]},
                    {"metric": {"__name__": "up", "job": "api"}, "value": [1700000000, "0"]},
                ],
            },
            "warnings": [],
        }
        return httpx.Response(200, json=body)

    _patch_client(monkeypatch, handler)
    res = _call(server.execute_query(query="up"))
    assert isinstance(res, server.QueryResult)
    assert res.resultType == "vector"
    assert res.series_count == 2
    assert res.truncated is False
    assert captured["params"]["query"] == "up"


def test_execute_query_limit_truncates(monkeypatch):
    def handler(_req):
        body = {
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [{"metric": {"i": str(i)}, "value": [0, str(i)]} for i in range(5)],
            },
        }
        return httpx.Response(200, json=body)

    _patch_client(monkeypatch, handler)
    res = _call(server.execute_query(query="up", limit=2))
    assert isinstance(res, server.QueryResult)
    assert res.truncated is True
    assert len(res.result) == 2
    assert res.series_count == 5


# --- range query ----------------------------------------------------------


def test_execute_range_query(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "matrix", "result": []}})

    _patch_client(monkeypatch, handler)
    res = _call(server.execute_range_query(query="up", start="2025-01-01T00:00:00Z", end="2025-01-01T01:00:00Z", step="15s"))
    assert isinstance(res, server.QueryResult)
    assert res.resultType == "matrix"
    assert captured["params"]["step"] == "15s"


def test_execute_range_query_bad_time(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, json={}))
    res = _call(server.execute_range_query(query="up", start="not-a-time", end="2025-01-01", step="15s"))
    assert isinstance(res, server.PromError)
    assert res.error_type == "validation"


def test_execute_range_query_bad_step(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, json={}))
    res = _call(server.execute_range_query(query="up", start="0", end="1", step="bad-step"))
    assert isinstance(res, server.PromError)
    assert res.error_type == "validation"


# --- prometheus API-level error (200 body, status=error) ------------------


def test_promql_parse_error(monkeypatch):
    def handler(_req):
        return httpx.Response(
            400,
            json={
                "status": "error",
                "errorType": "bad_data",
                "error": "invalid parameter \"query\": parse error",
            },
        )

    _patch_client(monkeypatch, handler)
    res = _call(server.execute_query(query="not valid promql"))
    assert isinstance(res, server.PromError)
    assert res.error_type == "upstream_http"
    assert res.status == 400
    assert "parse error" in res.error


def test_upstream_api_error_200(monkeypatch):
    """Prometheus occasionally returns status=error with HTTP 200."""
    def handler(_req):
        return httpx.Response(200, json={"status": "error", "errorType": "execution", "error": "oom"})

    _patch_client(monkeypatch, handler)
    res = _call(server.execute_query(query="up"))
    assert isinstance(res, server.PromError)
    assert res.error_type == "upstream_api"
    assert "oom" in res.error


# --- network failures -----------------------------------------------------


def test_upstream_5xx(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(503, text="unavailable"))
    res = _call(server.execute_query(query="up"))
    assert isinstance(res, server.PromError)
    assert res.status == 503


def test_timeout(monkeypatch):
    def handler(_req):
        raise httpx.TimeoutException("slow")

    _patch_client(monkeypatch, handler)
    res = _call(server.execute_query(query="up"))
    assert isinstance(res, server.PromError)
    assert res.error_type == "timeout"


def test_connect_error(monkeypatch):
    def handler(_req):
        raise httpx.ConnectError("refused")

    _patch_client(monkeypatch, handler)
    res = _call(server.get_targets())
    assert isinstance(res, server.PromError)
    assert res.error_type == "upstream_http"


def test_non_json_body(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, text="plain text, not json"))
    res = _call(server.get_flags())
    assert isinstance(res, server.PromError)
    assert res.error_type == "upstream_json"


# --- series / labels ------------------------------------------------------


def test_find_series(monkeypatch):
    captured = {}

    def handler(req):
        captured["qs"] = req.url.query.decode()
        return httpx.Response(
            200,
            json={"status": "success", "data": [{"__name__": "up", "job": "node"}, {"__name__": "up", "job": "api"}]},
        )

    _patch_client(monkeypatch, handler)
    res = _call(server.find_series(match=["up{job=\"node\"}", "up{job=\"api\"}"]))
    assert isinstance(res, server.SeriesResult)
    assert res.series_count == 2
    # Both match[] entries should be in the query string.
    assert captured["qs"].count("match%5B%5D=") == 2


def test_list_label_names(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, json={"status": "success", "data": ["__name__", "job", "instance"]}))
    res = _call(server.list_label_names())
    assert isinstance(res, server.LabelListResult)
    assert "job" in res.labels


def test_list_label_values(monkeypatch):
    captured = {}

    def handler(req):
        captured["path"] = req.url.path
        return httpx.Response(200, json={"status": "success", "data": ["node", "api"]})

    _patch_client(monkeypatch, handler)
    res = _call(server.list_label_values(label="job"))
    assert isinstance(res, server.LabelListResult)
    assert res.labels == ["node", "api"]
    assert captured["path"] == "/api/v1/label/job/values"


def test_list_label_values_rejects_bad_name(monkeypatch):
    # Runtime regex guard rejects before any HTTP call — no upstream contacted.
    called = {"n": 0}

    def handler(_req):
        called["n"] += 1
        return httpx.Response(200, json={"status": "success", "data": []})

    _patch_client(monkeypatch, handler)
    res = _call(server.list_label_values(label="bad-name"))
    assert isinstance(res, server.PromError)
    assert res.error_type == "validation"
    assert called["n"] == 0


# --- metadata / targets / rules / alerts ----------------------------------


def test_get_metric_metadata(monkeypatch):
    _patch_client(
        monkeypatch,
        lambda _r: httpx.Response(
            200,
            json={"status": "success", "data": {"up": [{"type": "gauge", "help": "1 if up", "unit": ""}]}},
        ),
    )
    res = _call(server.get_metric_metadata())
    assert isinstance(res, server.MetricMetadataResult)
    assert "up" in res.metadata


def test_get_targets(monkeypatch):
    _patch_client(
        monkeypatch,
        lambda _r: httpx.Response(
            200,
            json={
                "status": "success",
                "data": {"activeTargets": [{"health": "up"}], "droppedTargets": []},
            },
        ),
    )
    res = _call(server.get_targets())
    assert isinstance(res, server.TargetsResult)
    assert len(res.active) == 1


def test_get_targets_slims_discovered_labels_by_default(monkeypatch):
    # The default response must drop `discoveredLabels` and `globalUrl` —
    # these two fields alone are ~90% of the payload on k8s clusters and
    # will overflow OSS-LLM context windows on a single call.
    upstream = {
        "status": "success",
        "data": {
            "activeTargets": [{
                "labels": {"job": "node", "instance": "host:9100"},
                "discoveredLabels": {
                    "__meta_kubernetes_node_annotation_csi_volume_kubernetes_io_nodeid": "x",
                    "__meta_kubernetes_node_label_kubernetes_io_os": "linux",
                },
                "scrapePool": "node",
                "scrapeUrl": "http://host:9100/metrics",
                "globalUrl": "http://host:9100/metrics",
                "lastError": "",
                "lastScrape": "2026-04-24T00:00:00Z",
                "lastScrapeDuration": 0.01,
                "health": "up",
                "scrapeInterval": "30s",
                "scrapeTimeout": "10s",
            }],
            "droppedTargets": [{
                "discoveredLabels": {"__meta_k_foo": "bar"},
                "labels": {"job": "ignored"},
            }],
        },
    }
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, json=upstream))
    res = _call(server.get_targets())
    assert isinstance(res, server.TargetsResult)
    assert len(res.active) == 1
    slim = res.active[0]
    assert "discoveredLabels" not in slim
    assert "globalUrl" not in slim
    # Kept fields round-trip.
    assert slim["labels"] == {"job": "node", "instance": "host:9100"}
    assert slim["scrapeUrl"] == "http://host:9100/metrics"
    assert slim["health"] == "up"
    # Dropped targets are slimmed too.
    assert "discoveredLabels" not in res.dropped[0]
    assert res.dropped[0]["labels"] == {"job": "ignored"}


def test_get_targets_include_discovered_preserves_raw(monkeypatch):
    # Opt-in surfaces the full upstream payload for scrape-config debugging.
    upstream = {
        "status": "success",
        "data": {
            "activeTargets": [{
                "labels": {"job": "node"},
                "discoveredLabels": {"__meta_kubernetes_x": "y"},
                "globalUrl": "http://host:9100/metrics",
                "health": "up",
            }],
            "droppedTargets": [],
        },
    }
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, json=upstream))
    res = _call(server.get_targets(include_discovered=True))
    assert res.active[0]["discoveredLabels"] == {"__meta_kubernetes_x": "y"}
    assert res.active[0]["globalUrl"] == "http://host:9100/metrics"


def test_get_targets_metadata(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, json={"status": "success", "data": [{"metric": "up"}]}))
    res = _call(server.get_targets_metadata())
    assert isinstance(res, server.TargetsMetadataResult)
    assert res.metadata == [{"metric": "up"}]


def test_get_rules(monkeypatch):
    captured = {}

    def handler(req):
        captured["type"] = req.url.params.get("type")
        return httpx.Response(200, json={"status": "success", "data": {"groups": [{"name": "g1", "rules": []}]}})

    _patch_client(monkeypatch, handler)
    res = _call(server.get_rules(rule_type="alert"))
    assert isinstance(res, server.RulesResult)
    assert captured["type"] == "alert"


def test_get_alerts(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, json={"status": "success", "data": {"alerts": [{"state": "firing"}]}}))
    res = _call(server.get_alerts())
    assert isinstance(res, server.AlertsResult)
    assert res.alerts[0]["state"] == "firing"


def test_get_alertmanagers(monkeypatch):
    _patch_client(
        monkeypatch,
        lambda _r: httpx.Response(
            200,
            json={"status": "success", "data": {"activeAlertmanagers": [{"url": "http://am:9093/api/v2/alerts"}]}},
        ),
    )
    res = _call(server.get_alertmanagers())
    assert isinstance(res, server.AlertManagersResult)
    assert len(res.active) == 1


# --- exemplars / status ---------------------------------------------------


def test_query_exemplars(monkeypatch):
    _patch_client(
        monkeypatch,
        lambda _r: httpx.Response(200, json={"status": "success", "data": [{"seriesLabels": {"a": "b"}, "exemplars": []}]}),
    )
    res = _call(server.query_exemplars(query="up", start="0", end="1"))
    assert isinstance(res, server.ExemplarsResult)
    assert res.series_count == 1


def test_get_build_info(monkeypatch):
    _patch_client(
        monkeypatch,
        lambda _r: httpx.Response(
            200,
            json={
                "status": "success",
                "data": {
                    "version": "2.52.0",
                    "revision": "abc",
                    "branch": "main",
                    "buildUser": "ci",
                    "buildDate": "2025-01-01",
                    "goVersion": "go1.22",
                },
            },
        ),
    )
    res = _call(server.get_build_info())
    assert isinstance(res, server.BuildInfoResult)
    assert res.version == "2.52.0"


def test_get_runtime_info(monkeypatch):
    _patch_client(
        monkeypatch,
        lambda _r: httpx.Response(200, json={"status": "success", "data": {"startTime": "2025-01-01T00:00:00Z", "CWD": "/"}}),
    )
    res = _call(server.get_runtime_info())
    assert isinstance(res, server.RuntimeInfoResult)
    # extra=allow keeps arbitrary fields.
    assert res.model_dump().get("CWD") == "/"


def test_get_flags(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, json={"status": "success", "data": {"log.level": "info"}}))
    res = _call(server.get_flags())
    assert isinstance(res, server.FlagsResult)
    assert res.flags["log.level"] == "info"


def test_get_config_disabled_by_default(monkeypatch):
    # Default MCP_ALLOW_CONFIG=false → tool refuses and never hits upstream.
    called = {"n": 0}

    def handler(_r):
        called["n"] += 1
        return httpx.Response(200, json={"status": "success", "data": {"yaml": "x"}})

    _patch_client(monkeypatch, handler)
    res = _call(server.get_config())
    assert isinstance(res, server.PromError)
    assert res.error_type == "validation"
    assert "MCP_ALLOW_CONFIG" in res.error
    assert called["n"] == 0


def test_get_config_enabled(monkeypatch):
    monkeypatch.setattr(server, "MCP_ALLOW_CONFIG", True)
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, json={"status": "success", "data": {"yaml": "global:\n  scrape_interval: 15s\n"}}))
    res = _call(server.get_config())
    assert isinstance(res, server.ConfigResult)
    assert "scrape_interval" in res.yaml


def test_get_tsdb_stats(monkeypatch):
    _patch_client(
        monkeypatch,
        lambda _r: httpx.Response(200, json={"status": "success", "data": {"headStats": {"numSeries": 1000}}}),
    )
    res = _call(server.get_tsdb_stats(limit=10))
    assert isinstance(res, server.TSDBStatsResult)
    assert res.model_dump().get("headStats", {}).get("numSeries") == 1000


# --- check_ready (text endpoint) ------------------------------------------


def test_check_ready_ok(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(200, text="Prometheus Server is Ready.\n"))
    res = _call(server.check_ready())
    assert isinstance(res, server.ReadyResult)
    assert res.ready is True
    assert res.status == 200


def test_check_ready_not_ready(monkeypatch):
    _patch_client(monkeypatch, lambda _r: httpx.Response(503, text="starting up"))
    res = _call(server.check_ready())
    assert isinstance(res, server.ReadyResult)
    assert res.ready is False


def test_check_ready_timeout(monkeypatch):
    def handler(_req):
        raise httpx.TimeoutException("slow")

    _patch_client(monkeypatch, handler)
    res = _call(server.check_ready())
    assert isinstance(res, server.PromError)
    assert res.error_type == "timeout"


# --- validators (standalone) ---------------------------------------------


def test_validate_time_rfc3339():
    assert server._validate_time("2025-01-01T00:00:00Z") == "2025-01-01T00:00:00Z"


def test_validate_time_unix():
    assert server._validate_time("1700000000.5") == "1700000000.5"


def test_validate_time_rejects_garbage():
    with pytest.raises(ValueError):
        server._validate_time("yesterday")


def test_validate_step():
    for good in ("15s", "1m", "1h", "500ms", "2w", "1.5"):
        assert server._validate_step(good) == good
    for bad in ("15 s", "1 minute", "abc", "5x"):
        with pytest.raises(ValueError):
            server._validate_step(bad)


# --- limit push-down + timeout cap ---------------------------------------


def test_execute_query_pushes_limit_and_default_timeout(monkeypatch):
    """Caller omits limit/timeout → server injects MCP_MAX_SERIES + MCP_QUERY_TIMEOUT."""
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": []}})

    _patch_client(monkeypatch, handler)
    _call(server.execute_query(query="up"))
    assert captured["params"]["limit"] == str(server.MCP_MAX_SERIES)
    assert captured["params"]["timeout"] == server.MCP_QUERY_TIMEOUT


def test_execute_query_caps_caller_limit(monkeypatch):
    """Caller limit above MCP_MAX_SERIES would violate Field le; at-or-below is forwarded."""
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": []}})

    _patch_client(monkeypatch, handler)
    _call(server.execute_query(query="up", limit=5))
    assert captured["params"]["limit"] == "5"


def test_execute_query_clamps_long_timeout(monkeypatch):
    """Caller timeout > MCP_QUERY_TIMEOUT is clamped to the env cap."""
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "vector", "result": []}})

    _patch_client(monkeypatch, handler)
    _call(server.execute_query(query="up", timeout="10m"))
    assert captured["params"]["timeout"] == server.MCP_QUERY_TIMEOUT  # clamped to 30s


def test_execute_range_query_injects_limit_and_timeout(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "matrix", "result": []}})

    _patch_client(monkeypatch, handler)
    _call(server.execute_range_query(query="up", start="0", end="1", step="15s"))
    assert captured["params"]["limit"] == str(server.MCP_MAX_SERIES)
    assert captured["params"]["timeout"] == server.MCP_QUERY_TIMEOUT


def test_find_series_pushes_limit(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return httpx.Response(200, json={"status": "success", "data": []})

    _patch_client(monkeypatch, handler)
    _call(server.find_series(match=["up"], limit=42))
    assert captured["params"]["limit"] == "42"


def test_list_label_names_pushes_limit(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return httpx.Response(200, json={"status": "success", "data": []})

    _patch_client(monkeypatch, handler)
    _call(server.list_label_names())
    assert captured["params"]["limit"] == str(server.MCP_MAX_SERIES)


def test_list_label_values_pushes_limit(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return httpx.Response(200, json={"status": "success", "data": []})

    _patch_client(monkeypatch, handler)
    _call(server.list_label_values(label="job", limit=7))
    assert captured["params"]["limit"] == "7"


def test_duration_seconds():
    assert server._duration_seconds("30s") == 30.0
    assert server._duration_seconds("500ms") == 0.5
    assert server._duration_seconds("1m") == 60.0
    assert server._duration_seconds("1.5") == 1.5
    with pytest.raises(ValueError):
        server._duration_seconds("abc")


# --- new coverage for remaining review fixes ------------------------------


def test_validate_time_rejects_inf():
    for bad in ("inf", "-inf", "+inf", "nan", "NaN"):
        with pytest.raises(ValueError):
            server._validate_time(bad)


def test_validate_step_compound():
    assert server._validate_step("1h30m") == "1h30m"
    assert server._validate_step("2d12h") == "2d12h"
    assert server._duration_seconds("1h30m") == 3600 + 30 * 60
    assert server._duration_seconds("2d12h") == 2 * 86400 + 12 * 3600
    # Stray tokens must still fail.
    with pytest.raises(ValueError):
        server._duration_seconds("1h abc")


def test_execute_query_scalar_series_count(monkeypatch):
    def handler(_req):
        return httpx.Response(
            200,
            json={"status": "success", "data": {"resultType": "scalar", "result": [1700000000, "3.14"]}},
        )

    _patch_client(monkeypatch, handler)
    res = _call(server.execute_query(query="scalar(up)"))
    assert isinstance(res, server.QueryResult)
    assert res.resultType == "scalar"
    assert res.series_count == 1
    assert res.result == [1700000000, "3.14"]


def test_build_info_null_field(monkeypatch):
    def handler(_req):
        return httpx.Response(
            200,
            json={
                "status": "success",
                "data": {
                    "version": None,
                    "revision": "abc",
                    "branch": "main",
                    "buildUser": "ci",
                    "buildDate": "2025-01-01",
                    "goVersion": "go1.22",
                },
            },
        )

    _patch_client(monkeypatch, handler)
    res = _call(server.get_build_info())
    assert isinstance(res, server.BuildInfoResult)
    assert res.version == ""
    assert res.revision == "abc"


def test_metric_metadata_caps_limit(monkeypatch):
    captured = {}

    def handler(req):
        captured["params"] = dict(req.url.params)
        return httpx.Response(200, json={"status": "success", "data": {}})

    _patch_client(monkeypatch, handler)
    # Direct Python call bypasses the Field le=MCP_MAX_SERIES so we can
    # verify _capped_limit actually clamps.
    _call(server.get_metric_metadata(limit=server.MCP_MAX_SERIES + 5))
    assert captured["params"]["limit"] == str(server.MCP_MAX_SERIES)


def test_pydantic_mismatch_returns_promerror(monkeypatch):
    # resultType "histogram" is not in QueryResult.resultType Literal →
    # ValidationError must surface as PromError, not crash the tool.
    def handler(_req):
        return httpx.Response(
            200,
            json={"status": "success", "data": {"resultType": "histogram", "result": []}},
        )

    _patch_client(monkeypatch, handler)
    res = _call(server.execute_query(query="up"))
    assert isinstance(res, server.PromError)
    assert res.error_type == "upstream_json"
