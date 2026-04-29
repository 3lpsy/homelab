"""Kubernetes MCP server.

Read-only access to a Kubernetes cluster via the in-cluster ServiceAccount
token. Five tools:

  - pods_list      list pods in a namespace
  - pods_get       full status for one pod (env values redacted by default)
  - pods_log       container logs (tail-with-cap, multi-container aware)
  - pods_top       pod CPU/memory from metrics.k8s.io
  - events_list    recent events for a namespace

Replaces a previous two-container pod (containers/kubernetes-mcp-server +
auth-gate sidecar). All five tools used to be allowlisted out of upstream's
~80; that upstream returns full K8s objects with managedFields and noisy
status conditions, unusable as primary tool output for OSS / open-weight
models. This server returns trimmed Pydantic summaries by default and
exposes `detail="full"` for callers that need the raw shape (still with
managedFields stripped). Env values are always redacted unless the caller
explicitly opts in AND the deployment sets MCP_K8S_REVEAL_ENV=1.

Auth is fail-closed (empty MCP_API_KEYS rejects every request). Allowed
namespaces are checked client-side before any K8s call so misuse returns
a cheap ToolError without leaking namespace existence.

Environment:
  MCP_API_KEYS               CSV of accepted Bearer tokens. Empty = fail-closed.
  MCP_K8S_ALLOWED_NAMESPACES CSV. Tools refuse other namespaces with ToolError.
  MCP_K8S_REVEAL_ENV         "1" allows callers to pass reveal_env=True. Default off.
  MCP_K8S_LOCAL              "1" loads ~/.kube/config instead of in-cluster
                             (for `uv run` local dev only — never set in-cluster).
  MCP_MAX_PODS               Cap on pods returned per call (default 100).
  MCP_MAX_EVENTS             Cap on events returned per call (default 200).
  MCP_MAX_LOG_BYTES          Cap on log body size (default 262144 / 256 KiB).
  MCP_MAX_LOG_TAIL_LINES     Ceiling on tail_lines arg (default 5000).
  MCP_HOST / MCP_PORT        Bind (default 0.0.0.0:8000).
  LOG_LEVEL                  debug / info / warning / error (default info).
"""

import json
import os
import re
from datetime import datetime, timezone
from typing import Annotated, Any, Literal

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from kubernetes import client as k8s_client
from kubernetes import config as k8s_config
from kubernetes.client.rest import ApiException
from pydantic import BaseModel, ConfigDict, Field

from mcp_common import bootstrap, env_bool, env_csv_set, env_int, setup_logging

API_KEYS = env_csv_set("MCP_API_KEYS")
ALLOWED_NAMESPACES = frozenset(env_csv_set("MCP_K8S_ALLOWED_NAMESPACES"))
ALLOW_REVEAL_ENV = env_bool("MCP_K8S_REVEAL_ENV")
LOCAL_KUBECONFIG = env_bool("MCP_K8S_LOCAL")

MCP_MAX_PODS = env_int("MCP_MAX_PODS", "100")
MCP_MAX_EVENTS = env_int("MCP_MAX_EVENTS", "200")
# 64 KiB / 2000 lines: tuned to fit comfortably inside an OSS 7B/8B model's
# tool-result window. Bigger tails round-trip but get truncated to fit. Bump
# both env vars per-deployment if you have a longer-context client.
MCP_MAX_LOG_BYTES = env_int("MCP_MAX_LOG_BYTES", "65536")
MCP_MAX_LOG_TAIL_LINES = env_int("MCP_MAX_LOG_TAIL_LINES", "2000")
MCP_HOST = os.environ.get("MCP_HOST", "0.0.0.0")
MCP_PORT = env_int("MCP_PORT", "8000")

# urllib3 chatter at INFO level logs every kubernetes API call URL — noise
# for a server that hits the API on every tool call.
log = setup_logging("mcp-k8s", mute=["urllib3"])


# --- K8s clients -----------------------------------------------------------
#
# Initialised lazily so test_server.py can monkeypatch _core_v1 / _custom_v1
# before any tool runs without needing a real kubeconfig at import time.


def _load_k8s() -> None:
    if LOCAL_KUBECONFIG:
        k8s_config.load_kube_config()
        return
    k8s_config.load_incluster_config()


_core_v1: k8s_client.CoreV1Api | None = None
_custom_v1: k8s_client.CustomObjectsApi | None = None
_api_client: k8s_client.ApiClient | None = None


def _ensure_clients() -> None:
    global _core_v1, _custom_v1, _api_client
    if _core_v1 is not None:
        return
    _load_k8s()
    _api_client = k8s_client.ApiClient()
    _core_v1 = k8s_client.CoreV1Api(_api_client)
    _custom_v1 = k8s_client.CustomObjectsApi(_api_client)


log.info(
    "startup: api_keys=%d allowed_namespaces=%d reveal_env=%s local=%s "
    "max_pods=%d max_events=%d max_log_bytes=%d max_log_tail_lines=%d",
    len(API_KEYS), len(ALLOWED_NAMESPACES), ALLOW_REVEAL_ENV, LOCAL_KUBECONFIG,
    MCP_MAX_PODS, MCP_MAX_EVENTS, MCP_MAX_LOG_BYTES, MCP_MAX_LOG_TAIL_LINES,
)


# --- Helpers ---------------------------------------------------------------


_QUANTITY_RE = re.compile(r"^(?P<num>-?\d+(?:\.\d+)?)(?P<suf>[A-Za-z]*)$")
_QUANTITY_SUFFIX = {
    "":   1.0,
    # Sub-unit prefixes — metrics.k8s.io routinely returns CPU as
    # nanocores ("12345n"), so missing these suffixes silently drops
    # rows during pods_top parsing. K8s quantity grammar also defines
    # micro ("u"); pico/femto are theoretically valid but unused.
    "n":  1e-9,
    "u":  1e-6,
    "m":  1e-3,
    "k":  1e3,
    "K":  1e3,
    "M":  1e6,
    "G":  1e9,
    "T":  1e12,
    "P":  1e15,
    "E":  1e18,
    "Ki": 1024,
    "Mi": 1024 ** 2,
    "Gi": 1024 ** 3,
    "Ti": 1024 ** 4,
    "Pi": 1024 ** 5,
    "Ei": 1024 ** 6,
}


def _parse_quantity(s: str) -> float:
    """Parse a Kubernetes quantity (`100m`, `512Mi`, `1.5`, `2Gi`) to a float
    in base units. CPU callers multiply by 1000 to get millicores; memory
    callers consume the result as bytes directly.

    Raises ValueError for anything malformed.
    """
    if s is None:
        raise ValueError("quantity is None")
    s = s.strip()
    if not s:
        raise ValueError("quantity is empty")
    m = _QUANTITY_RE.match(s)
    if not m:
        raise ValueError(f"not a Kubernetes quantity: {s!r}")
    suf = m.group("suf")
    if suf not in _QUANTITY_SUFFIX:
        raise ValueError(f"unknown quantity suffix in {s!r}: {suf!r}")
    return float(m.group("num")) * _QUANTITY_SUFFIX[suf]


def _parse_cpu_millicores(s: str) -> int:
    """K8s CPU quantity → integer millicores."""
    return int(round(_parse_quantity(s) * 1000))


def _parse_memory_bytes(s: str) -> int:
    """K8s memory quantity → integer bytes."""
    return int(round(_parse_quantity(s)))


def _format_age(then: datetime | None) -> str:
    """Largest-unit age string ('5d', '2h', '30s'). None → '?'."""
    if then is None:
        return "?"
    if then.tzinfo is None:
        then = then.replace(tzinfo=timezone.utc)
    delta = datetime.now(timezone.utc) - then
    secs = int(delta.total_seconds())
    if secs < 0:
        return "0s"
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h"
    return f"{secs // 86400}d"


def _check_namespace(ns: str) -> None:
    """Refuse a request before issuing any K8s call when ns is not allowlisted.
    Cheaper than a 403 round-trip and avoids leaking namespace existence."""
    if ns not in ALLOWED_NAMESPACES:
        raise ToolError(f"namespace not allowed: {ns!r}")


def _map_api_error(e: ApiException, what: str) -> ToolError:
    """Coerce a kubernetes ApiException into a ToolError with a short
    human-readable message. Surfaces the API's `message` body (capped) for
    400 / 422 / 5xx since those usually carry the actionable detail
    (invalid selector, unknown container, previous instance not found)."""
    status = e.status
    reason = (e.reason or "").strip()
    body_msg = ""
    if e.body:
        try:
            parsed = json.loads(e.body)
            body_msg = str(parsed.get("message", "")).strip()[:512]
        except (json.JSONDecodeError, TypeError, ValueError):
            pass
    if status == 403:
        return ToolError(f"forbidden: {what}")
    if status == 404:
        return ToolError(f"not found: {what}")
    if status == 503:
        return ToolError(f"unavailable: {what} ({reason or 'service unavailable'})")
    if status == 400 or status == 422:
        return ToolError(f"bad request: {what}: {body_msg or reason or 'invalid args'}")
    suffix = f": {body_msg}" if body_msg else ""
    return ToolError(f"k8s error {status} {reason or 'unknown'}: {what}{suffix}")


# --- Pydantic models -------------------------------------------------------


class ContainerSummary(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    image: str
    ready: bool
    restart_count: int
    state: Literal["running", "waiting", "terminated", "unknown"]
    state_reason: str | None = None
    env_names: list[str] = Field(default_factory=list)
    env_redacted: bool = True


class PodSummary(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    namespace: str
    phase: str
    ready: str
    restarts: int
    node: str | None = None
    pod_ip: str | None = None
    age: str
    containers: list[ContainerSummary] = Field(default_factory=list)
    init_containers: list[ContainerSummary] = Field(default_factory=list)


class PodCondition(BaseModel):
    model_config = ConfigDict(extra="forbid")
    type: str
    status: str
    reason: str | None = None


class EventSummary(BaseModel):
    model_config = ConfigDict(extra="forbid")
    type: str
    reason: str | None = None
    message: str | None = None
    involved_object: dict[str, str] = Field(default_factory=dict)
    count: int = 0
    first_seen: str | None = None
    last_seen: str | None = None
    source: str | None = None


class PodDetail(PodSummary):
    model_config = ConfigDict(extra="forbid")
    start_time: str | None = None
    qos_class: str | None = None
    service_account: str | None = None
    host_ip: str | None = None
    volumes: list[str] = Field(default_factory=list)
    conditions: list[PodCondition] = Field(default_factory=list)
    events_recent: list[EventSummary] = Field(default_factory=list)


class PodsListResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    namespace: str
    items: list[PodSummary] = Field(default_factory=list)
    item_count: int = 0
    truncated: bool = False


class PodsListFullResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    namespace: str
    items: list[dict] = Field(default_factory=list)
    item_count: int = 0
    truncated: bool = False


class LogResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    namespace: str
    container: str
    tail_lines: int
    returned_lines: int
    truncated_head: bool
    log: str


class ContainerMetric(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    cpu_millicores: int
    memory_bytes: int


class PodMetric(BaseModel):
    model_config = ConfigDict(extra="forbid")
    namespace: str
    name: str
    containers: list[ContainerMetric] = Field(default_factory=list)
    total_cpu_millicores: int
    total_memory_bytes: int


class TopResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    items: list[PodMetric] = Field(default_factory=list)
    item_count: int = 0
    truncated: bool = False


class EventsListResult(BaseModel):
    model_config = ConfigDict(extra="forbid")
    namespace: str
    items: list[EventSummary] = Field(default_factory=list)
    item_count: int = 0
    truncated: bool = False


# --- Trim helpers ----------------------------------------------------------


def _container_state(state: Any) -> tuple[Literal["running", "waiting", "terminated", "unknown"], str | None]:
    if state is None:
        return "unknown", None
    if getattr(state, "running", None) is not None:
        return "running", None
    waiting = getattr(state, "waiting", None)
    if waiting is not None:
        return "waiting", getattr(waiting, "reason", None)
    terminated = getattr(state, "terminated", None)
    if terminated is not None:
        return "terminated", getattr(terminated, "reason", None)
    return "unknown", None


def _container_summary(spec: Any, status: Any | None) -> ContainerSummary:
    """Build a ContainerSummary from the spec entry plus optional matching
    status. env values are dropped — only names survive."""
    env_names: list[str] = []
    for e in getattr(spec, "env", None) or []:
        nm = getattr(e, "name", None)
        if nm:
            env_names.append(nm)

    state_label: Literal["running", "waiting", "terminated", "unknown"] = "unknown"
    state_reason: str | None = None
    ready = False
    restart_count = 0
    if status is not None:
        ready = bool(getattr(status, "ready", False))
        restart_count = int(getattr(status, "restart_count", 0) or 0)
        state_label, state_reason = _container_state(getattr(status, "state", None))

    return ContainerSummary(
        name=getattr(spec, "name", "?"),
        image=getattr(spec, "image", "?") or "?",
        ready=ready,
        restart_count=restart_count,
        state=state_label,
        state_reason=state_reason,
        env_names=env_names,
        env_redacted=True,
    )


def _statuses_by_name(statuses: Any) -> dict[str, Any]:
    return {getattr(s, "name", ""): s for s in (statuses or [])}


def _pod_summary(pod: Any) -> PodSummary:
    meta = pod.metadata
    spec = pod.spec
    status = pod.status
    cstats = _statuses_by_name(getattr(status, "container_statuses", None))
    istats = _statuses_by_name(getattr(status, "init_container_statuses", None))

    containers = [
        _container_summary(c, cstats.get(getattr(c, "name", ""))) for c in (getattr(spec, "containers", None) or [])
    ]
    init_containers = [
        _container_summary(c, istats.get(getattr(c, "name", ""))) for c in (getattr(spec, "init_containers", None) or [])
    ]
    ready_count = sum(1 for c in containers if c.ready)
    restarts = sum(c.restart_count for c in containers)

    return PodSummary(
        name=getattr(meta, "name", "?"),
        namespace=getattr(meta, "namespace", "?"),
        phase=getattr(status, "phase", None) or "Unknown",
        ready=f"{ready_count}/{len(containers)}",
        restarts=restarts,
        node=getattr(spec, "node_name", None),
        pod_ip=getattr(status, "pod_ip", None),
        age=_format_age(getattr(meta, "creation_timestamp", None)),
        containers=containers,
        init_containers=init_containers,
    )


def _pod_detail(pod: Any, recent_events: list[EventSummary]) -> PodDetail:
    summary = _pod_summary(pod)
    spec = pod.spec
    status = pod.status

    conditions: list[PodCondition] = []
    for c in (getattr(status, "conditions", None) or []):
        conditions.append(
            PodCondition(
                type=getattr(c, "type", "?"),
                status=getattr(c, "status", "?"),
                reason=getattr(c, "reason", None),
            )
        )

    volumes = [getattr(v, "name", "?") for v in (getattr(spec, "volumes", None) or [])]
    start_time = getattr(status, "start_time", None)
    return PodDetail(
        **summary.model_dump(),
        start_time=start_time.isoformat() if hasattr(start_time, "isoformat") else (start_time or None),
        qos_class=getattr(status, "qos_class", None),
        service_account=getattr(spec, "service_account_name", None),
        host_ip=getattr(status, "host_ip", None),
        volumes=volumes,
        conditions=conditions,
        events_recent=recent_events,
    )


def _full_pod(pod: Any) -> dict:
    """Sanitize the raw V1Pod to a dict suitable for JSON, then strip
    managedFields. Always strip — managedFields is the single biggest source
    of noise and is never useful to a tool consumer."""
    assert _api_client is not None
    out = _api_client.sanitize_for_serialization(pod)
    if isinstance(out, dict):
        meta = out.get("metadata")
        if isinstance(meta, dict):
            meta.pop("managedFields", None)
    return out


def _redact_full_pod(d: dict, reveal_env: bool) -> dict:
    """In full mode, env values are still redacted unless the caller opted in
    AND the deployment allows it. ConfigMap/Secret valueFrom refs are
    dropped entirely (only env name survives) so a single env entry can't
    name a Secret key path."""
    if reveal_env and ALLOW_REVEAL_ENV:
        return d
    spec = d.get("spec") if isinstance(d, dict) else None
    if not isinstance(spec, dict):
        return d
    for key in ("containers", "initContainers", "ephemeralContainers"):
        for c in (spec.get(key) or []):
            env = c.get("env")
            if isinstance(env, list):
                c["env"] = [{"name": e.get("name")} for e in env if isinstance(e, dict) and e.get("name")]
            # Don't strip envFrom; it references ConfigMap/Secret names but no
            # values, and the names alone are useful diagnostic context. They
            # would already be visible to anyone with `pods list` RBAC.
    return d


def _event_summary(ev: Any) -> EventSummary:
    """Trim a V1Event to the fields a debugger actually wants. Drop
    metadata.managedFields, lastTimestamp millisecond noise, source.host
    (rarely useful, almost always the node name which is already on Pod)."""
    obj = getattr(ev, "involved_object", None)
    inv: dict[str, str] = {}
    if obj is not None:
        for k, attr in (("kind", "kind"), ("name", "name"), ("namespace", "namespace")):
            v = getattr(obj, attr, None)
            if v:
                inv[k] = v
    src = getattr(ev, "source", None)
    src_component = getattr(src, "component", None) if src is not None else None

    def _fmt(t: Any) -> str | None:
        if t is None:
            return None
        if hasattr(t, "isoformat"):
            return t.isoformat()
        return str(t)

    return EventSummary(
        type=getattr(ev, "type", None) or "Normal",
        reason=getattr(ev, "reason", None),
        message=getattr(ev, "message", None),
        involved_object=inv,
        count=int(getattr(ev, "count", 0) or 0),
        first_seen=_fmt(getattr(ev, "first_timestamp", None) or getattr(ev, "event_time", None)),
        last_seen=_fmt(getattr(ev, "last_timestamp", None) or getattr(ev, "event_time", None)),
        source=src_component,
    )


# --- FastMCP ---------------------------------------------------------------


_INSTRUCTIONS = """\
Read-only Kubernetes access via the in-cluster ServiceAccount. Five tools:

  - pods_list(namespace, label_selector?, field_selector?, detail?)
  - pods_get(name, namespace, detail?)
  - pods_log(name, namespace, container?, tail_lines?, since_seconds?, previous?)
  - pods_top(namespace?, sort_by?, limit?)
  - events_list(namespace, field_selector?, since_seconds?, types?)

Defaults are tuned for OSS / open-weight LLMs:
  - pods_list/pods_get return a trimmed PodSummary (no managedFields,
    conditions trimmed, env values redacted). Pass `detail="full"` for the
    full Kubernetes object (still without managedFields; env still
    redacted unless the deployment opted into reveal_env).
  - pods_log defaults to tail_lines=100 and is capped at MCP_MAX_LOG_BYTES.
    For a multi-container pod you must pass `container=`.
  - pods_top returns CPU in millicores and memory in bytes.

Requests against namespaces outside the deployment's allowlist are rejected
with no API call. Write verbs are not exposed."""

mcp = FastMCP("k8s", instructions=_INSTRUCTIONS)


# --- Tools -----------------------------------------------------------------


DetailParam = Annotated[
    Literal["summary", "full"],
    Field(description="`summary` (default, trimmed) or `full` (raw object minus managedFields)."),
]


def _list_pod_events(namespace: str, pod_name: str, limit: int) -> list[EventSummary]:
    assert _core_v1 is not None
    try:
        ev = _core_v1.list_namespaced_event(
            namespace,
            field_selector=f"involvedObject.name={pod_name}",
            limit=limit,
        )
    except ApiException as e:
        # An RBAC gap on events is non-fatal for pods_get — log and continue.
        log.warning("events fetch for %s/%s failed: %s", namespace, pod_name, e.status)
        return []
    items = sorted(
        ev.items or [],
        key=lambda x: getattr(x, "last_timestamp", None) or getattr(x, "event_time", None) or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )
    return [_event_summary(e) for e in items[:limit]]


@mcp.tool()
async def pods_list(
    namespace: Annotated[str, Field(min_length=1, max_length=253, description="Namespace to list pods in.")],
    label_selector: Annotated[str | None, Field(max_length=1024, description="K8s label selector (e.g. 'app=nginx').")] = None,
    field_selector: Annotated[str | None, Field(max_length=1024, description="K8s field selector (e.g. 'status.phase=Running').")] = None,
    detail: DetailParam = "summary",
) -> PodsListResult | PodsListFullResult:
    """List pods in `namespace`, optionally filtered by selectors. Returns
    trimmed PodSummary by default; `detail="full"` returns sanitized raw
    pods (managedFields stripped, env values still redacted)."""
    _check_namespace(namespace)
    _ensure_clients()
    assert _core_v1 is not None

    cap = MCP_MAX_PODS
    try:
        resp = _core_v1.list_namespaced_pod(
            namespace,
            label_selector=label_selector or "",
            field_selector=field_selector or "",
            limit=cap + 1,
        )
    except ApiException as e:
        raise _map_api_error(e, f"list pods in {namespace}") from e

    items = list(resp.items or [])
    truncated = len(items) > cap
    if truncated:
        items = items[:cap]

    log.info("pods_list ns=%s n=%d truncated=%s detail=%s", namespace, len(items), truncated, detail)

    if detail == "full":
        full = [_redact_full_pod(_full_pod(p), reveal_env=False) for p in items]
        return PodsListFullResult(
            namespace=namespace,
            items=full,
            item_count=len(full),
            truncated=truncated,
        )

    summaries = [_pod_summary(p) for p in items]
    return PodsListResult(
        namespace=namespace,
        items=summaries,
        item_count=len(summaries),
        truncated=truncated,
    )


@mcp.tool()
async def pods_get(
    name: Annotated[str, Field(min_length=1, max_length=253, description="Pod name.")],
    namespace: Annotated[str, Field(min_length=1, max_length=253, description="Namespace.")],
    detail: DetailParam = "summary",
    reveal_env: Annotated[bool, Field(description="Only honoured if MCP_K8S_REVEAL_ENV=1 on the deployment. Default false.")] = False,
) -> PodDetail | dict:
    """Return pod spec+status. Summary form trims conditions, drops
    managedFields, redacts env values. Full form is the sanitized raw pod
    (managedFields stripped). Recent events involving this pod are embedded
    in the summary form's `events_recent`."""
    _check_namespace(namespace)
    _ensure_clients()
    assert _core_v1 is not None

    try:
        pod = _core_v1.read_namespaced_pod(name, namespace)
    except ApiException as e:
        raise _map_api_error(e, f"get pod {namespace}/{name}") from e

    log.info("pods_get ns=%s name=%s detail=%s", namespace, name, detail)

    if detail == "full":
        return _redact_full_pod(_full_pod(pod), reveal_env=reveal_env)

    events = _list_pod_events(namespace, name, limit=10)
    return _pod_detail(pod, events)


@mcp.tool()
async def pods_log(
    name: Annotated[str, Field(min_length=1, max_length=253, description="Pod name.")],
    namespace: Annotated[str, Field(min_length=1, max_length=253, description="Namespace.")],
    container: Annotated[str | None, Field(max_length=253, description="Container name. Required when the pod has more than one container.")] = None,
    tail_lines: Annotated[int, Field(ge=1, description="Last N lines to return. Capped at MCP_MAX_LOG_TAIL_LINES.")] = 100,
    since_seconds: Annotated[int | None, Field(ge=1, description="Only return logs newer than N seconds ago.")] = None,
    previous: Annotated[bool, Field(description="Read logs from the previous container instance (post-crash).")] = False,
) -> LogResult:
    """Read container logs. Tail-with-cap; the response body is truncated
    at MCP_MAX_LOG_BYTES (head removed first since the most recent lines
    are usually the most useful for debugging)."""
    _check_namespace(namespace)
    _ensure_clients()
    assert _core_v1 is not None

    capped_tail = min(tail_lines, MCP_MAX_LOG_TAIL_LINES)

    if container is None:
        # Disambiguate before reading; otherwise the API picks the first
        # container silently and a multi-container pod looks fine to the
        # caller while only one container's logs come back.
        try:
            pod = _core_v1.read_namespaced_pod(name, namespace)
        except ApiException as e:
            raise _map_api_error(e, f"get pod {namespace}/{name}") from e
        names = [getattr(c, "name", "?") for c in (getattr(pod.spec, "containers", None) or [])]
        if len(names) > 1:
            raise ToolError(
                f"pod {namespace}/{name} has multiple containers; pass container=, choices: "
                + ", ".join(repr(n) for n in names)
            )
        container = names[0] if names else None

    try:
        body: str = _core_v1.read_namespaced_pod_log(
            name=name,
            namespace=namespace,
            container=container,
            tail_lines=capped_tail,
            since_seconds=since_seconds,
            previous=previous,
        )
    except ApiException as e:
        raise _map_api_error(e, f"logs {namespace}/{name}") from e

    if not isinstance(body, str):
        # Defensive: kubernetes>=28 returns str by default but some clients
        # may return bytes for binary log streams. Decode with replacement.
        body = bytes(body).decode("utf-8", errors="replace")

    truncated_head = False
    if len(body.encode("utf-8")) > MCP_MAX_LOG_BYTES:
        # Drop bytes from the front; align to a newline so the caller doesn't
        # see a partial first line.
        encoded = body.encode("utf-8")
        encoded = encoded[-MCP_MAX_LOG_BYTES:]
        nl = encoded.find(b"\n")
        if 0 <= nl < len(encoded) - 1:
            encoded = encoded[nl + 1:]
        body = encoded.decode("utf-8", errors="replace")
        truncated_head = True

    returned_lines = body.count("\n") + (0 if body.endswith("\n") or not body else 1)
    log.info(
        "pods_log ns=%s name=%s container=%s tail=%d returned=%d truncated_head=%s",
        namespace, name, container, capped_tail, returned_lines, truncated_head,
    )

    return LogResult(
        name=name,
        namespace=namespace,
        container=container or "?",
        tail_lines=capped_tail,
        returned_lines=returned_lines,
        truncated_head=truncated_head,
        log=body,
    )


def _pod_metric_from_dict(d: dict) -> PodMetric | None:
    """Build a PodMetric from a single metrics.k8s.io pods item. Returns
    None for unparseable rows so a stray malformed entry doesn't tank the
    whole list."""
    meta = d.get("metadata") or {}
    ns = meta.get("namespace")
    name = meta.get("name")
    if not ns or not name:
        return None
    containers: list[ContainerMetric] = []
    total_cpu = 0
    total_mem = 0
    for c in (d.get("containers") or []):
        usage = c.get("usage") or {}
        try:
            cpu = _parse_cpu_millicores(usage.get("cpu", "0"))
            mem = _parse_memory_bytes(usage.get("memory", "0"))
        except ValueError:
            continue
        containers.append(ContainerMetric(name=c.get("name", "?"), cpu_millicores=cpu, memory_bytes=mem))
        total_cpu += cpu
        total_mem += mem
    return PodMetric(
        namespace=ns,
        name=name,
        containers=containers,
        total_cpu_millicores=total_cpu,
        total_memory_bytes=total_mem,
    )


@mcp.tool()
async def pods_top(
    namespace: Annotated[str | None, Field(max_length=253, description="Namespace; omit for all allowed namespaces.")] = None,
    sort_by: Annotated[Literal["cpu", "memory", "name"], Field(description="Sort key.")] = "cpu",
    limit: Annotated[int | None, Field(ge=1, description="Cap on rows returned. Capped at MCP_MAX_PODS.")] = None,
) -> TopResult:
    """Pod CPU/memory usage from metrics.k8s.io. CPU is millicores, memory
    is bytes. Defaults sort descending by CPU."""
    if namespace is not None:
        _check_namespace(namespace)
    _ensure_clients()
    assert _custom_v1 is not None

    try:
        if namespace is None:
            raw = _custom_v1.list_cluster_custom_object(
                group="metrics.k8s.io", version="v1beta1", plural="pods",
            )
        else:
            raw = _custom_v1.list_namespaced_custom_object(
                group="metrics.k8s.io", version="v1beta1", namespace=namespace, plural="pods",
            )
    except ApiException as e:
        if e.status == 503 or e.status == 404:
            raise ToolError("metrics-server unavailable (metrics.k8s.io API not registered)") from e
        raise _map_api_error(e, "list pod metrics") from e

    metrics: list[PodMetric] = []
    for item in (raw.get("items") if isinstance(raw, dict) else None) or []:
        m = _pod_metric_from_dict(item)
        if m is None:
            continue
        # Cluster-wide LIST returns every namespace; filter to allowlist
        # client-side so an unallowed namespace's metrics never surface.
        if namespace is None and m.namespace not in ALLOWED_NAMESPACES:
            continue
        metrics.append(m)

    if sort_by == "cpu":
        metrics.sort(key=lambda m: m.total_cpu_millicores, reverse=True)
    elif sort_by == "memory":
        metrics.sort(key=lambda m: m.total_memory_bytes, reverse=True)
    else:
        metrics.sort(key=lambda m: (m.namespace, m.name))

    cap = MCP_MAX_PODS if limit is None else min(limit, MCP_MAX_PODS)
    truncated = len(metrics) > cap
    if truncated:
        metrics = metrics[:cap]

    log.info("pods_top ns=%s sort=%s n=%d truncated=%s", namespace or "*", sort_by, len(metrics), truncated)

    return TopResult(items=metrics, item_count=len(metrics), truncated=truncated)


@mcp.tool()
async def events_list(
    namespace: Annotated[str, Field(min_length=1, max_length=253, description="Namespace.")],
    field_selector: Annotated[str | None, Field(max_length=1024, description="K8s field selector.")] = None,
    since_seconds: Annotated[int | None, Field(ge=1, description="Only return events whose lastTimestamp is within the last N seconds.")] = None,
    types: Annotated[
        list[Literal["Normal", "Warning"]] | None,
        Field(description="Filter event types. Default: both."),
    ] = None,
) -> EventsListResult:
    """List events for a namespace, sorted newest-first. Cap at
    MCP_MAX_EVENTS. `since_seconds` is applied client-side after fetching
    because the API doesn't filter by timestamp."""
    _check_namespace(namespace)
    _ensure_clients()
    assert _core_v1 is not None

    cap = MCP_MAX_EVENTS
    try:
        resp = _core_v1.list_namespaced_event(
            namespace,
            field_selector=field_selector or "",
            limit=cap + 1,
        )
    except ApiException as e:
        raise _map_api_error(e, f"list events in {namespace}") from e

    raw_items = list(resp.items or [])
    type_set = set(types) if types else {"Normal", "Warning"}
    cutoff: datetime | None = None
    if since_seconds is not None:
        cutoff = datetime.now(timezone.utc).replace(microsecond=0)
        cutoff = cutoff.fromtimestamp(cutoff.timestamp() - since_seconds, tz=timezone.utc)

    summaries: list[EventSummary] = []
    for ev in raw_items:
        ev_type = getattr(ev, "type", "Normal") or "Normal"
        if ev_type not in type_set:
            continue
        last = getattr(ev, "last_timestamp", None) or getattr(ev, "event_time", None)
        if cutoff is not None:
            if last is None:
                continue
            if last.tzinfo is None:
                last = last.replace(tzinfo=timezone.utc)
            if last < cutoff:
                continue
        summaries.append(_event_summary(ev))

    summaries.sort(
        key=lambda s: s.last_seen or s.first_seen or "",
        reverse=True,
    )
    truncated = len(summaries) > cap
    if truncated:
        summaries = summaries[:cap]

    log.info("events_list ns=%s n=%d truncated=%s types=%s", namespace, len(summaries), truncated, sorted(type_set))

    return EventsListResult(
        namespace=namespace,
        items=summaries,
        item_count=len(summaries),
        truncated=truncated,
    )


if __name__ == "__main__":
    bootstrap.run(
        mcp,
        host=MCP_HOST,
        port=MCP_PORT,
        api_keys=API_KEYS,
        logger=log,
    )
