"""Unit tests for mcp-k8s server.py.

Runs the tool functions directly (bypassing FastMCP dispatch) against
fake kubernetes API client objects. No real cluster access. Run with:

  uv run --with pytest --with fastmcp --with pydantic --with kubernetes \
         --with uvicorn --with starlette pytest test_server.py
"""
import asyncio
import os
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock

os.environ["MCP_API_KEYS"] = "key-a,key-b"
os.environ["MCP_K8S_ALLOWED_NAMESPACES"] = "mcp,monitoring,nextcloud"
os.environ["MCP_MAX_PODS"] = "5"
os.environ["MCP_MAX_EVENTS"] = "5"
os.environ["MCP_MAX_LOG_BYTES"] = "1024"
os.environ["MCP_MAX_LOG_TAIL_LINES"] = "200"
os.environ.setdefault("LOG_LEVEL", "error")

import pytest  # noqa: E402
from fastmcp.exceptions import ToolError  # noqa: E402
from kubernetes import client as k8s_client  # noqa: E402
from kubernetes.client.rest import ApiException  # noqa: E402

import server  # noqa: E402


def _call(coro):
    return asyncio.run(coro)


# --- Fixture builders ------------------------------------------------------


def _make_container_status(name, ready=True, restarts=0, state="running", reason=None):
    if state == "running":
        st = k8s_client.V1ContainerState(running=k8s_client.V1ContainerStateRunning(started_at=datetime.now(timezone.utc)))
    elif state == "waiting":
        st = k8s_client.V1ContainerState(waiting=k8s_client.V1ContainerStateWaiting(reason=reason or "Waiting"))
    else:
        st = k8s_client.V1ContainerState(terminated=k8s_client.V1ContainerStateTerminated(reason=reason or "Completed", exit_code=0))
    return k8s_client.V1ContainerStatus(
        name=name,
        ready=ready,
        restart_count=restarts,
        state=st,
        image="img",
        image_id="img-id",
    )


def _make_pod(name, namespace, *, containers=None, env=None, phase="Running",
              age_seconds=3600, container_statuses=None, conditions=None,
              node="n1", pod_ip="10.0.0.1"):
    """Build a real V1Pod. `env` is applied to all containers as
    [{"name": "K", "value": "V"}, ...] dicts (we pass through V1EnvVar)."""
    env_vars = [k8s_client.V1EnvVar(name=e["name"], value=e.get("value")) for e in (env or [])]
    if containers is None:
        containers = [k8s_client.V1Container(name="main", image="myimg:1", env=env_vars)]
    else:
        containers = [
            k8s_client.V1Container(name=c["name"], image=c.get("image", "myimg:1"), env=env_vars)
            for c in containers
        ]
    if container_statuses is None:
        container_statuses = [_make_container_status(c.name) for c in containers]
    return k8s_client.V1Pod(
        metadata=k8s_client.V1ObjectMeta(
            name=name,
            namespace=namespace,
            creation_timestamp=datetime.now(timezone.utc) - timedelta(seconds=age_seconds),
            managed_fields=[k8s_client.V1ManagedFieldsEntry(manager="kubectl", operation="Apply")],
        ),
        spec=k8s_client.V1PodSpec(
            containers=containers,
            node_name=node,
            service_account_name="default",
            volumes=[k8s_client.V1Volume(name="tmp", empty_dir=k8s_client.V1EmptyDirVolumeSource())],
        ),
        status=k8s_client.V1PodStatus(
            phase=phase,
            pod_ip=pod_ip,
            host_ip="192.168.1.10",
            qos_class="BestEffort",
            container_statuses=container_statuses,
            conditions=conditions or [
                k8s_client.V1PodCondition(type="Ready", status="True"),
            ],
            start_time=datetime.now(timezone.utc) - timedelta(seconds=age_seconds),
        ),
    )


def _make_event(reason, message, namespace="mcp", *, type_="Normal",
                involved_name="some-pod", count=1, age_seconds=60):
    ts = datetime.now(timezone.utc) - timedelta(seconds=age_seconds)
    return k8s_client.CoreV1Event(
        metadata=k8s_client.V1ObjectMeta(name=f"{involved_name}.{reason}", namespace=namespace),
        involved_object=k8s_client.V1ObjectReference(kind="Pod", name=involved_name, namespace=namespace),
        reason=reason,
        message=message,
        type=type_,
        count=count,
        first_timestamp=ts,
        last_timestamp=ts,
        source=k8s_client.V1EventSource(component="kubelet", host="n1"),
    )


@pytest.fixture(autouse=True)
def _wire_clients(monkeypatch):
    """Provide fake _core_v1 / _custom_v1 / _api_client for every test, so
    no test ever calls _load_k8s()."""
    api_client = k8s_client.ApiClient()
    monkeypatch.setattr(server, "_core_v1", MagicMock())
    monkeypatch.setattr(server, "_custom_v1", MagicMock())
    monkeypatch.setattr(server, "_api_client", api_client)
    monkeypatch.setattr(server, "_ensure_clients", lambda: None)


# --- _parse_quantity -------------------------------------------------------


@pytest.mark.parametrize("s,expected", [
    ("0", 0.0),
    ("1", 1.0),
    ("1.5", 1.5),
    ("100m", 0.1),
    ("250m", 0.25),
    ("123456n", 123456e-9),
    ("500u", 500e-6),
    ("1k", 1000.0),
    ("1K", 1000.0),
    ("1M", 1e6),
    ("1G", 1e9),
    ("1Ki", 1024.0),
    ("1Mi", 1024 ** 2),
    ("1Gi", 1024 ** 3),
    ("512Mi", 512 * 1024 ** 2),
    ("2Gi", 2 * 1024 ** 3),
])
def test_parse_quantity_known(s, expected):
    assert server._parse_quantity(s) == expected


@pytest.mark.parametrize("bad", ["", "abc", "1Q", "Mi", " "])
def test_parse_quantity_malformed(bad):
    with pytest.raises(ValueError):
        server._parse_quantity(bad)


def test_parse_cpu_millicores():
    assert server._parse_cpu_millicores("100m") == 100
    assert server._parse_cpu_millicores("1") == 1000
    assert server._parse_cpu_millicores("1.5") == 1500
    # metrics.k8s.io reports CPU usage in nanocores. 123456789n = ~123ms.
    assert server._parse_cpu_millicores("123456789n") == 123


def test_pods_top_parses_nanocore_cpu(monkeypatch):
    body = {"items": [{
        "metadata": {"name": "p", "namespace": "mcp"},
        "containers": [{"name": "c", "usage": {"cpu": "123456789n", "memory": "10Mi"}}],
    }]}
    server._custom_v1.list_cluster_custom_object.return_value = body
    res = _call(server.pods_top())
    assert res.items[0].containers[0].cpu_millicores == 123
    assert res.items[0].containers[0].memory_bytes == 10 * 1024 ** 2


def test_parse_memory_bytes():
    assert server._parse_memory_bytes("512Mi") == 512 * 1024 ** 2
    assert server._parse_memory_bytes("1Gi") == 1024 ** 3


# --- _format_age -----------------------------------------------------------


def test_format_age_units():
    now = datetime.now(timezone.utc)
    assert server._format_age(now - timedelta(seconds=30)).endswith("s")
    assert server._format_age(now - timedelta(minutes=5)).endswith("m")
    assert server._format_age(now - timedelta(hours=2)).endswith("h")
    assert server._format_age(now - timedelta(days=3)) == "3d"
    assert server._format_age(None) == "?"


# --- pods_list -------------------------------------------------------------


def test_pods_list_summary_trims_managed_fields(monkeypatch):
    pod = _make_pod("p1", "mcp", env=[{"name": "DB_PASSWORD", "value": "supersecret"}])
    server._core_v1.list_namespaced_pod.return_value = SimpleNamespace(items=[pod])

    res = _call(server.pods_list(namespace="mcp"))
    assert isinstance(res, server.PodsListResult)
    assert res.item_count == 1
    summary = res.items[0]
    assert summary.name == "p1"
    assert summary.namespace == "mcp"
    assert summary.containers[0].env_names == ["DB_PASSWORD"]
    # The Pydantic model has no field for the value — redaction is structural.
    assert summary.containers[0].env_redacted is True


def test_pods_list_full_strips_managed_fields_and_redacts_env(monkeypatch):
    pod = _make_pod("p1", "mcp", env=[{"name": "DB_PASSWORD", "value": "supersecret"}])
    server._core_v1.list_namespaced_pod.return_value = SimpleNamespace(items=[pod])

    res = _call(server.pods_list(namespace="mcp", detail="full"))
    assert isinstance(res, server.PodsListFullResult)
    full = res.items[0]
    assert "managedFields" not in full["metadata"]
    env = full["spec"]["containers"][0]["env"]
    assert env == [{"name": "DB_PASSWORD"}]
    assert "supersecret" not in str(full)


def test_pods_list_truncates_at_max_pods(monkeypatch):
    pods = [_make_pod(f"p{i}", "mcp") for i in range(server.MCP_MAX_PODS + 3)]
    server._core_v1.list_namespaced_pod.return_value = SimpleNamespace(items=pods)

    res = _call(server.pods_list(namespace="mcp"))
    assert res.truncated is True
    assert res.item_count == server.MCP_MAX_PODS


def test_pods_list_label_selector_forwarded(monkeypatch):
    server._core_v1.list_namespaced_pod.return_value = SimpleNamespace(items=[])
    _call(server.pods_list(namespace="mcp", label_selector="app=foo", field_selector="status.phase=Running"))
    args, kwargs = server._core_v1.list_namespaced_pod.call_args
    assert kwargs["label_selector"] == "app=foo"
    assert kwargs["field_selector"] == "status.phase=Running"


def test_pods_list_namespace_not_allowed():
    with pytest.raises(ToolError) as ei:
        _call(server.pods_list(namespace="vault"))
    assert "vault" in str(ei.value)
    assert "not allowed" in str(ei.value)
    # Allowlist check happens before any API call.
    server._core_v1.list_namespaced_pod.assert_not_called()


def test_pods_list_forbidden_maps_to_tool_error():
    server._core_v1.list_namespaced_pod.side_effect = ApiException(status=403, reason="Forbidden")
    with pytest.raises(ToolError) as ei:
        _call(server.pods_list(namespace="mcp"))
    assert "forbidden" in str(ei.value)


def test_pods_list_400_surfaces_body_message():
    e = ApiException(status=400, reason="Bad Request")
    e.body = '{"kind":"Status","message":"unable to parse field selector \\"unknown.field=foo\\""}'
    server._core_v1.list_namespaced_pod.side_effect = e
    with pytest.raises(ToolError) as ei:
        _call(server.pods_list(namespace="mcp", field_selector="unknown.field=foo"))
    msg = str(ei.value)
    assert "bad request" in msg
    assert "unable to parse field selector" in msg


def test_pods_log_400_surfaces_body_message_for_invalid_container():
    pod = _make_pod("p1", "mcp", containers=[{"name": "app"}, {"name": "side"}])
    server._core_v1.read_namespaced_pod.return_value = pod
    e = ApiException(status=400, reason="Bad Request")
    e.body = '{"kind":"Status","message":"container \\"x\\" in pod \\"p1\\" is not valid"}'
    server._core_v1.read_namespaced_pod_log.side_effect = e
    with pytest.raises(ToolError) as ei:
        _call(server.pods_log(name="p1", namespace="mcp", container="x"))
    assert "is not valid" in str(ei.value)


# --- pods_get --------------------------------------------------------------


def test_pods_get_summary_redacts_env_and_embeds_events():
    pod = _make_pod("p1", "mcp", env=[{"name": "TOKEN", "value": "abc"}])
    server._core_v1.read_namespaced_pod.return_value = pod
    server._core_v1.list_namespaced_event.return_value = SimpleNamespace(items=[
        _make_event("Started", "Container started"),
    ])

    res = _call(server.pods_get(name="p1", namespace="mcp"))
    assert isinstance(res, server.PodDetail)
    assert res.containers[0].env_names == ["TOKEN"]
    assert res.containers[0].env_redacted is True
    assert len(res.events_recent) == 1
    assert res.events_recent[0].reason == "Started"


def test_pods_get_full_still_redacts_when_reveal_env_disabled(monkeypatch):
    monkeypatch.setattr(server, "ALLOW_REVEAL_ENV", False)
    pod = _make_pod("p1", "mcp", env=[{"name": "T", "value": "secret"}])
    server._core_v1.read_namespaced_pod.return_value = pod

    res = _call(server.pods_get(name="p1", namespace="mcp", detail="full", reveal_env=True))
    assert "secret" not in str(res)
    env = res["spec"]["containers"][0]["env"]
    assert env == [{"name": "T"}]


def test_pods_get_full_reveal_env_when_both_set(monkeypatch):
    monkeypatch.setattr(server, "ALLOW_REVEAL_ENV", True)
    pod = _make_pod("p1", "mcp", env=[{"name": "T", "value": "sec"}])
    server._core_v1.read_namespaced_pod.return_value = pod

    res = _call(server.pods_get(name="p1", namespace="mcp", detail="full", reveal_env=True))
    assert res["spec"]["containers"][0]["env"][0]["value"] == "sec"


def test_pods_get_not_found_maps_to_tool_error():
    server._core_v1.read_namespaced_pod.side_effect = ApiException(status=404, reason="Not Found")
    with pytest.raises(ToolError) as ei:
        _call(server.pods_get(name="missing", namespace="mcp"))
    assert "not found" in str(ei.value)


# --- pods_log --------------------------------------------------------------


def test_pods_log_tail_clamped_to_ceiling(monkeypatch):
    pod = _make_pod("p1", "mcp")
    server._core_v1.read_namespaced_pod.return_value = pod
    server._core_v1.read_namespaced_pod_log.return_value = "line\n"

    _call(server.pods_log(name="p1", namespace="mcp", tail_lines=99999))
    _, kwargs = server._core_v1.read_namespaced_pod_log.call_args
    assert kwargs["tail_lines"] == server.MCP_MAX_LOG_TAIL_LINES


def test_pods_log_oversize_head_trimmed(monkeypatch):
    pod = _make_pod("p1", "mcp")
    server._core_v1.read_namespaced_pod.return_value = pod
    # Build a log of MCP_MAX_LOG_BYTES * 2 with line breaks.
    body = ("\n".join(f"line-{i:05d}" for i in range(500)) + "\n")
    assert len(body.encode("utf-8")) > server.MCP_MAX_LOG_BYTES
    server._core_v1.read_namespaced_pod_log.return_value = body

    res = _call(server.pods_log(name="p1", namespace="mcp"))
    assert res.truncated_head is True
    assert len(res.log.encode("utf-8")) <= server.MCP_MAX_LOG_BYTES
    # The retained bytes should include the most recent line.
    assert "line-00499" in res.log
    # Head bytes (first line) should be gone.
    assert "line-00000" not in res.log


def test_pods_log_multi_container_without_arg_raises_with_names():
    pod = _make_pod("p1", "mcp", containers=[{"name": "app"}, {"name": "sidecar"}])
    server._core_v1.read_namespaced_pod.return_value = pod

    with pytest.raises(ToolError) as ei:
        _call(server.pods_log(name="p1", namespace="mcp"))
    msg = str(ei.value)
    assert "multiple containers" in msg
    assert "'app'" in msg
    assert "'sidecar'" in msg


def test_pods_log_previous_forwarded():
    pod = _make_pod("p1", "mcp")
    server._core_v1.read_namespaced_pod.return_value = pod
    server._core_v1.read_namespaced_pod_log.return_value = "x\n"
    _call(server.pods_log(name="p1", namespace="mcp", previous=True, since_seconds=120))
    _, kwargs = server._core_v1.read_namespaced_pod_log.call_args
    assert kwargs["previous"] is True
    assert kwargs["since_seconds"] == 120


def test_pods_log_namespace_not_allowed():
    with pytest.raises(ToolError):
        _call(server.pods_log(name="p1", namespace="vault"))
    server._core_v1.read_namespaced_pod_log.assert_not_called()


# --- pods_top --------------------------------------------------------------


_METRICS_BODY = {
    "items": [
        {
            "metadata": {"name": "a", "namespace": "mcp"},
            "containers": [{"name": "main", "usage": {"cpu": "10m", "memory": "50Mi"}}],
        },
        {
            "metadata": {"name": "b", "namespace": "mcp"},
            "containers": [{"name": "main", "usage": {"cpu": "200m", "memory": "10Mi"}}],
        },
        {
            "metadata": {"name": "c", "namespace": "vault"},  # not allowed
            "containers": [{"name": "main", "usage": {"cpu": "999m", "memory": "999Mi"}}],
        },
    ]
}


def test_pods_top_filters_unallowed_namespaces_in_cluster_mode():
    server._custom_v1.list_cluster_custom_object.return_value = _METRICS_BODY
    res = _call(server.pods_top())
    names = [(m.namespace, m.name) for m in res.items]
    assert ("vault", "c") not in names
    assert ("mcp", "a") in names
    assert ("mcp", "b") in names


def test_pods_top_sort_by_memory_desc():
    server._custom_v1.list_cluster_custom_object.return_value = _METRICS_BODY
    res = _call(server.pods_top(sort_by="memory"))
    # mcp/a has 50Mi, mcp/b has 10Mi. memory-desc puts a first.
    assert res.items[0].name == "a"


def test_pods_top_sort_by_cpu_desc_default():
    server._custom_v1.list_cluster_custom_object.return_value = _METRICS_BODY
    res = _call(server.pods_top())
    # mcp/b has 200m, mcp/a has 10m. cpu-desc puts b first.
    assert res.items[0].name == "b"


def test_pods_top_namespace_allowlist_enforced():
    with pytest.raises(ToolError):
        _call(server.pods_top(namespace="vault"))
    server._custom_v1.list_namespaced_custom_object.assert_not_called()


def test_pods_top_limit_caps():
    server._custom_v1.list_cluster_custom_object.return_value = _METRICS_BODY
    res = _call(server.pods_top(limit=1))
    assert res.item_count == 1
    assert res.truncated is True


def test_pods_top_metrics_server_unavailable_503():
    server._custom_v1.list_cluster_custom_object.side_effect = ApiException(
        status=503, reason="Service Unavailable"
    )
    with pytest.raises(ToolError) as ei:
        _call(server.pods_top())
    assert "metrics-server unavailable" in str(ei.value)


# --- events_list -----------------------------------------------------------


def test_events_list_orders_newest_first():
    old = _make_event("Old", "old", age_seconds=1000)
    new = _make_event("New", "new", age_seconds=10)
    server._core_v1.list_namespaced_event.return_value = SimpleNamespace(items=[old, new])
    res = _call(server.events_list(namespace="mcp"))
    assert [e.reason for e in res.items] == ["New", "Old"]


def test_events_list_types_filter():
    n = _make_event("A", "normal-evt", type_="Normal")
    w = _make_event("B", "warn-evt", type_="Warning")
    server._core_v1.list_namespaced_event.return_value = SimpleNamespace(items=[n, w])
    res = _call(server.events_list(namespace="mcp", types=["Warning"]))
    assert [e.reason for e in res.items] == ["B"]


def test_events_list_since_seconds_filter():
    old = _make_event("Old", "old", age_seconds=10_000)
    new = _make_event("New", "new", age_seconds=10)
    server._core_v1.list_namespaced_event.return_value = SimpleNamespace(items=[old, new])
    res = _call(server.events_list(namespace="mcp", since_seconds=60))
    assert [e.reason for e in res.items] == ["New"]


def test_events_list_namespace_allowlist():
    with pytest.raises(ToolError):
        _call(server.events_list(namespace="vault"))


def test_events_list_truncates():
    items = [_make_event(f"E{i}", "msg", age_seconds=i + 1) for i in range(server.MCP_MAX_EVENTS + 3)]
    server._core_v1.list_namespaced_event.return_value = SimpleNamespace(items=items)
    res = _call(server.events_list(namespace="mcp"))
    assert res.truncated is True
    assert res.item_count == server.MCP_MAX_EVENTS


# --- AuthMiddleware --------------------------------------------------------


def _run_auth(scope, inner=None):
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
    sent = _run_auth({"type": "http", "method": "POST", "path": "/", "query_string": b"", "headers": [], "client": ("1.2.3.4", 1234)})
    assert next(m for m in sent if m["type"] == "http.response.start")["status"] == 401


def test_auth_accepts_valid_bearer():
    sent = _run_auth({
        "type": "http", "method": "POST", "path": "/", "query_string": b"",
        "headers": [(b"authorization", b"Bearer key-a")], "client": ("1.2.3.4", 1234),
    })
    assert next(m for m in sent if m["type"] == "http.response.start")["status"] == 200


def test_auth_accepts_query_param_key():
    sent = _run_auth({
        "type": "http", "method": "POST", "path": "/", "query_string": b"api_key=key-b",
        "headers": [], "client": ("1.2.3.4", 1234),
    })
    assert next(m for m in sent if m["type"] == "http.response.start")["status"] == 200


def test_auth_allows_healthz_unauthenticated():
    sent = _run_auth({
        "type": "http", "method": "GET", "path": "/healthz", "query_string": b"",
        "headers": [], "client": ("1.2.3.4", 1234),
    })
    assert next(m for m in sent if m["type"] == "http.response.start")["status"] == 200


def test_auth_allows_options_unauthenticated():
    sent = _run_auth({
        "type": "http", "method": "OPTIONS", "path": "/", "query_string": b"",
        "headers": [], "client": ("1.2.3.4", 1234),
    })
    assert next(m for m in sent if m["type"] == "http.response.start")["status"] == 200
