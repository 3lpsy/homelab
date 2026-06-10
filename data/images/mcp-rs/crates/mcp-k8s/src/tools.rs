use std::sync::Arc;

use k8s_openapi::api::core::v1::{Event, Pod};
use kube::api::{Api, DynamicObject, GroupVersionKind, ListParams, LogParams};
use kube::core::{ApiResource, GroupVersionResource};
use rmcp::model::{CallToolResult, Content};
use rmcp::ErrorData;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use mcp_common::errors::{tool_internal, tool_invalid};

use crate::qty::{parse_cpu_millicores, parse_memory_bytes};
use crate::redact::redact_pod;
use crate::server::Config;

// --- arg structs ---

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PodsListArgs {
    pub namespace: String,
    #[serde(default)]
    pub label_selector: Option<String>,
    #[serde(default)]
    pub field_selector: Option<String>,
    #[serde(default = "default_detail")]
    pub detail: String,
}

fn default_detail() -> String {
    "summary".into()
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PodsGetArgs {
    pub name: String,
    pub namespace: String,
    #[serde(default = "default_detail")]
    pub detail: String,
    #[serde(default)]
    pub reveal_env: bool,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PodsLogArgs {
    pub name: String,
    pub namespace: String,
    #[serde(default)]
    pub container: Option<String>,
    #[serde(default = "default_tail_lines")]
    pub tail_lines: i64,
    #[serde(default)]
    pub since_seconds: Option<i64>,
    #[serde(default)]
    pub previous: bool,
}

fn default_tail_lines() -> i64 {
    100
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PodsTopArgs {
    #[serde(default)]
    pub namespace: Option<String>,
    #[serde(default = "default_sort")]
    pub sort_by: String,
    #[serde(default)]
    pub limit: Option<usize>,
}

fn default_sort() -> String {
    "cpu".into()
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct EventsListArgs {
    pub namespace: String,
    #[serde(default)]
    pub field_selector: Option<String>,
    #[serde(default)]
    pub since_seconds: Option<i64>,
    #[serde(default)]
    pub types: Option<Vec<String>>,
}

// --- helpers ---

fn check_ns(cfg: &Arc<Config>, ns: &str) -> Result<(), ErrorData> {
    if !cfg.allowed_ns.contains(ns) {
        Err(tool_invalid(format!("namespace not allowed: {ns:?}")))
    } else {
        Ok(())
    }
}

fn map_kube_err(e: kube::Error, what: &str) -> ErrorData {
    match &e {
        kube::Error::Api(api) => match api.code {
            403 => tool_invalid(format!("forbidden: {what}")),
            404 => tool_invalid(format!("not found: {what}")),
            503 => tool_invalid(format!("unavailable: {what}: {}", api.reason)),
            400 | 422 => tool_invalid(format!("bad request: {what}: {}", api.message)),
            _ => tool_internal(format!("k8s error {}: {what}: {}", api.code, api.message)),
        },
        _ => tool_internal(format!("k8s error: {what}: {e}")),
    }
}

/// Hard deadline for a kube API future. Without it a stalled API-server
/// connection or a stale projected SA token (these expire ~hourly) hangs the
/// tool indefinitely — observed as a multi-hour hang on a CronJob namespace
/// whose pods were Init:Error. On timeout the call is aborted and a clear error
/// is returned to the agent; the next call re-establishes the connection /
/// refreshes the token. Split from `k8s_call` so it's unit-testable without a
/// cluster.
async fn with_deadline<F, T>(
    timeout: std::time::Duration,
    what: &str,
    fut: F,
) -> Result<T, ErrorData>
where
    F: std::future::Future<Output = Result<T, kube::Error>>,
{
    match tokio::time::timeout(timeout, fut).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(map_kube_err(e, what)),
        Err(_elapsed) => Err(tool_internal(format!(
            "k8s API timeout after {}s: {what} — request aborted (API server unreachable or the ServiceAccount token went stale; retry to re-establish)",
            timeout.as_secs()
        ))),
    }
}

/// `with_deadline` using the configured `api_timeout`. Wrap every kube call.
async fn k8s_call<F, T>(cfg: &Arc<Config>, what: &str, fut: F) -> Result<T, ErrorData>
where
    F: std::future::Future<Output = Result<T, kube::Error>>,
{
    with_deadline(cfg.api_timeout, what, fut).await
}

fn pod_summary(pod: &Pod) -> Value {
    let meta = &pod.metadata;
    let spec = pod.spec.as_ref();
    let status = pod.status.as_ref();
    let cstats: std::collections::HashMap<&str, _> = status
        .and_then(|s| s.container_statuses.as_ref())
        .map(|v| v.iter().map(|s| (s.name.as_str(), s)).collect())
        .unwrap_or_default();
    let istats: std::collections::HashMap<&str, _> = status
        .and_then(|s| s.init_container_statuses.as_ref())
        .map(|v| v.iter().map(|s| (s.name.as_str(), s)).collect())
        .unwrap_or_default();

    let containers: Vec<Value> = spec
        .map(|s| {
            s.containers
                .iter()
                .map(|c| {
                    let st = cstats.get(c.name.as_str());
                    container_summary(c, st.copied())
                })
                .collect()
        })
        .unwrap_or_default();

    let init_containers: Vec<Value> = spec
        .and_then(|s| s.init_containers.as_ref())
        .map(|init| {
            init.iter()
                .map(|c| {
                    let st = istats.get(c.name.as_str());
                    container_summary(c, st.copied())
                })
                .collect()
        })
        .unwrap_or_default();

    let ready_count = containers
        .iter()
        .filter(|c| c.get("ready").and_then(Value::as_bool).unwrap_or(false))
        .count();
    let total = containers.len();
    let restarts: i64 = containers
        .iter()
        .map(|c| c.get("restart_count").and_then(Value::as_i64).unwrap_or(0))
        .sum();

    let age = meta
        .creation_timestamp
        .as_ref()
        .map(|t| format_age(t))
        .unwrap_or_else(|| "?".into());

    json!({
        "name": meta.name.clone().unwrap_or_else(|| "?".into()),
        "namespace": meta.namespace.clone().unwrap_or_else(|| "?".into()),
        "phase": status.and_then(|s| s.phase.clone()).unwrap_or_else(|| "Unknown".into()),
        "ready": format!("{ready_count}/{total}"),
        "restarts": restarts,
        "node": spec.and_then(|s| s.node_name.clone()),
        "pod_ip": status.and_then(|s| s.pod_ip.clone()),
        "age": age,
        "containers": containers,
        "init_containers": init_containers,
    })
}

fn container_summary(
    c: &k8s_openapi::api::core::v1::Container,
    status: Option<&k8s_openapi::api::core::v1::ContainerStatus>,
) -> Value {
    let env_names: Vec<String> = c
        .env
        .as_ref()
        .map(|e| e.iter().map(|x| x.name.clone()).collect())
        .unwrap_or_default();
    let (state_label, state_reason) = match status.and_then(|s| s.state.as_ref()) {
        Some(s) => {
            if s.running.is_some() {
                ("running", None)
            } else if let Some(w) = &s.waiting {
                ("waiting", w.reason.clone())
            } else if let Some(t) = &s.terminated {
                ("terminated", t.reason.clone())
            } else {
                ("unknown", None)
            }
        }
        None => ("unknown", None),
    };
    json!({
        "name": c.name,
        "image": c.image.clone().unwrap_or_else(|| "?".into()),
        "ready": status.map(|s| s.ready).unwrap_or(false),
        "restart_count": status.map(|s| s.restart_count).unwrap_or(0),
        "state": state_label,
        "state_reason": state_reason,
        "env_names": env_names,
        "env_redacted": true,
    })
}

fn format_age(t: &k8s_openapi::apimachinery::pkg::apis::meta::v1::Time) -> String {
    let secs_ago = (jiff::Timestamp::now().as_second() - t.0.as_second()).max(0);
    if secs_ago < 60 {
        format!("{secs_ago}s")
    } else if secs_ago < 3600 {
        format!("{}m", secs_ago / 60)
    } else if secs_ago < 86400 {
        format!("{}h", secs_ago / 3600)
    } else {
        format!("{}d", secs_ago / 86400)
    }
}

fn pod_to_value(pod: &Pod) -> Value {
    serde_json::to_value(pod).unwrap_or(Value::Null)
}

// --- tools ---

pub async fn pods_list(
    cfg: &Arc<Config>,
    args: PodsListArgs,
) -> Result<CallToolResult, ErrorData> {
    check_ns(cfg, &args.namespace)?;
    let api: Api<Pod> = Api::namespaced(cfg.client.clone(), &args.namespace);
    let mut params = ListParams::default().limit((cfg.max_pods + 1) as u32);
    if let Some(l) = args.label_selector {
        params = params.labels(&l);
    }
    if let Some(f) = args.field_selector {
        params = params.fields(&f);
    }
    let list = k8s_call(
        cfg,
        &format!("list pods in {}", args.namespace),
        api.list(&params),
    )
    .await?;
    let mut items: Vec<Pod> = list.items;
    let truncated = items.len() > cfg.max_pods;
    items.truncate(cfg.max_pods);

    let want_full = args.detail == "full";
    if want_full {
        let mut out: Vec<Value> = Vec::with_capacity(items.len());
        for p in &items {
            let mut v = pod_to_value(p);
            redact_pod(&mut v, false);
            out.push(v);
        }
        return json_ok(&json!({
            "namespace": args.namespace,
            "items": out,
            "item_count": out.len(),
            "truncated": truncated,
        }));
    }
    let summaries: Vec<Value> = items.iter().map(pod_summary).collect();
    json_ok(&json!({
        "namespace": args.namespace,
        "items": summaries,
        "item_count": summaries.len(),
        "truncated": truncated,
    }))
}

pub async fn pods_get(
    cfg: &Arc<Config>,
    args: PodsGetArgs,
) -> Result<CallToolResult, ErrorData> {
    check_ns(cfg, &args.namespace)?;
    let api: Api<Pod> = Api::namespaced(cfg.client.clone(), &args.namespace);
    let pod = k8s_call(
        cfg,
        &format!("get pod {}/{}", args.namespace, args.name),
        api.get(&args.name),
    )
    .await?;

    if args.detail == "full" {
        let mut v = pod_to_value(&pod);
        redact_pod(&mut v, args.reveal_env && cfg.allow_reveal_env);
        return json_ok(&v);
    }

    let mut summary = pod_summary(&pod);

    // recent events for the pod
    let events_api: Api<Event> = Api::namespaced(cfg.client.clone(), &args.namespace);
    let ev_params = ListParams::default()
        .fields(&format!("involvedObject.name={}", args.name))
        .limit(10);
    let recent = tokio::time::timeout(cfg.api_timeout, events_api.list(&ev_params))
        .await
        .ok()
        .and_then(Result::ok)
        .map(|l| {
            l.items
                .into_iter()
                .map(|e| event_to_summary(&e))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    if let Some(obj) = summary.as_object_mut() {
        obj.insert("events_recent".into(), Value::Array(recent));
        // Add conditions trimmed.
        if let Some(conds) = pod.status.as_ref().and_then(|s| s.conditions.as_ref()) {
            let trimmed: Vec<Value> = conds
                .iter()
                .map(|c| {
                    json!({
                        "type": c.type_,
                        "status": c.status,
                        "reason": c.reason.clone(),
                    })
                })
                .collect();
            obj.insert("conditions".into(), Value::Array(trimmed));
        }
        if let Some(spec) = pod.spec.as_ref() {
            obj.insert(
                "service_account".into(),
                json!(spec.service_account_name.clone()),
            );
            obj.insert(
                "volumes".into(),
                json!(spec
                    .volumes
                    .as_ref()
                    .map(|v| v.iter().map(|x| x.name.clone()).collect::<Vec<_>>())
                    .unwrap_or_default()),
            );
        }
        if let Some(status) = pod.status.as_ref() {
            obj.insert("qos_class".into(), json!(status.qos_class.clone()));
            obj.insert("host_ip".into(), json!(status.host_ip.clone()));
            obj.insert(
                "start_time".into(),
                json!(status.start_time.as_ref().map(|t| t.0.to_string())),
            );
        }
    }

    json_ok(&summary)
}

pub async fn pods_log(
    cfg: &Arc<Config>,
    args: PodsLogArgs,
) -> Result<CallToolResult, ErrorData> {
    check_ns(cfg, &args.namespace)?;
    let api: Api<Pod> = Api::namespaced(cfg.client.clone(), &args.namespace);
    let capped_tail = args.tail_lines.min(cfg.max_log_tail_lines as i64);

    let container = if let Some(c) = args.container.clone() {
        c
    } else {
        let pod = k8s_call(
            cfg,
            &format!("get pod {}/{}", args.namespace, args.name),
            api.get(&args.name),
        )
        .await?;
        let names: Vec<String> = pod
            .spec
            .as_ref()
            .map(|s| s.containers.iter().map(|c| c.name.clone()).collect())
            .unwrap_or_default();
        if names.len() > 1 {
            return Err(tool_invalid(format!(
                "pod {}/{} has multiple containers; pass container=, choices: {:?}",
                args.namespace, args.name, names
            )));
        }
        names.into_iter().next().unwrap_or_else(|| "?".into())
    };

    let mut lp = LogParams {
        container: Some(container.clone()),
        tail_lines: Some(capped_tail),
        previous: args.previous,
        ..Default::default()
    };
    if let Some(s) = args.since_seconds {
        lp.since_seconds = Some(s);
    }
    // If the target container never started (e.g. an init failed, leaving the
    // app container in PodInitializing) there are no logs — the k8s API returns
    // 400, which map_kube_err surfaces verbatim ("container ... is waiting to
    // start: PodInitializing") rather than hanging. previous=true fetches a
    // terminated container's last logs where available.
    let body = k8s_call(
        cfg,
        &format!("logs {}/{}", args.namespace, args.name),
        api.logs(&args.name, &lp),
    )
    .await?;

    let bytes = body.as_bytes();
    let mut truncated_head = false;
    let body = if bytes.len() > cfg.max_log_bytes {
        truncated_head = true;
        let start = bytes.len() - cfg.max_log_bytes;
        let mut s = &bytes[start..];
        // align to newline
        if let Some(pos) = s.iter().position(|b| *b == b'\n') {
            s = &s[pos + 1..];
        }
        String::from_utf8_lossy(s).to_string()
    } else {
        body
    };

    let returned_lines = body.lines().count();

    json_ok(&json!({
        "name": args.name,
        "namespace": args.namespace,
        "container": container,
        "tail_lines": capped_tail,
        "returned_lines": returned_lines,
        "truncated_head": truncated_head,
        "log": body,
    }))
}

pub async fn pods_top(
    cfg: &Arc<Config>,
    args: PodsTopArgs,
) -> Result<CallToolResult, ErrorData> {
    if let Some(ns) = args.namespace.as_deref() {
        check_ns(cfg, ns)?;
    }
    let gvk = GroupVersionKind::gvk("metrics.k8s.io", "v1beta1", "PodMetrics");
    let gvr = GroupVersionResource::gvr("metrics.k8s.io", "v1beta1", "pods");
    let ar = ApiResource::from_gvk_with_plural(&gvk, "pods");

    let api: Api<DynamicObject> = match args.namespace.as_deref() {
        Some(ns) => Api::namespaced_with(cfg.client.clone(), ns, &ar),
        None => Api::all_with(cfg.client.clone(), &ar),
    };

    let list = match tokio::time::timeout(cfg.api_timeout, api.list(&ListParams::default())).await {
        Ok(Ok(l)) => l,
        Ok(Err(kube::Error::Api(api_err))) if api_err.code == 503 || api_err.code == 404 => {
            return Err(tool_invalid(
                "metrics-server unavailable (metrics.k8s.io API not registered)",
            ));
        }
        Ok(Err(e)) => return Err(map_kube_err(e, "list pod metrics")),
        Err(_) => {
            return Err(tool_internal(format!(
                "k8s API timeout after {}s: list pod metrics — request aborted",
                cfg.api_timeout.as_secs()
            )))
        }
    };

    let _ = gvr; // suppress unused

    let mut metrics: Vec<Value> = Vec::new();
    for item in list.items {
        let raw = serde_json::to_value(&item).unwrap_or(Value::Null);
        let meta = item.metadata;
        let ns = meta.namespace.clone().unwrap_or_default();
        let name = meta.name.clone().unwrap_or_default();
        if ns.is_empty() || name.is_empty() {
            continue;
        }
        if args.namespace.is_none() && !cfg.allowed_ns.contains(&ns) {
            continue;
        }
        let containers_arr = raw
            .get("containers")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let mut containers_out: Vec<Value> = Vec::new();
        let mut total_cpu = 0i64;
        let mut total_mem = 0i64;
        for c in containers_arr {
            let cname = c.get("name").and_then(|v| v.as_str()).unwrap_or("?").to_string();
            let usage = c.get("usage").and_then(|v| v.as_object()).cloned().unwrap_or_default();
            let cpu_str = usage.get("cpu").and_then(|v| v.as_str()).unwrap_or("0");
            let mem_str = usage.get("memory").and_then(|v| v.as_str()).unwrap_or("0");
            let cpu = match parse_cpu_millicores(cpu_str) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let mem = match parse_memory_bytes(mem_str) {
                Ok(v) => v,
                Err(_) => continue,
            };
            containers_out.push(json!({
                "name": cname,
                "cpu_millicores": cpu,
                "memory_bytes": mem,
            }));
            total_cpu += cpu;
            total_mem += mem;
        }
        metrics.push(json!({
            "namespace": ns,
            "name": name,
            "containers": containers_out,
            "total_cpu_millicores": total_cpu,
            "total_memory_bytes": total_mem,
        }));
    }

    metrics.sort_by(|a, b| match args.sort_by.as_str() {
        "memory" => b
            .get("total_memory_bytes")
            .and_then(Value::as_i64)
            .cmp(&a.get("total_memory_bytes").and_then(Value::as_i64)),
        "name" => {
            let an = (
                a.get("namespace").and_then(Value::as_str).unwrap_or(""),
                a.get("name").and_then(Value::as_str).unwrap_or(""),
            );
            let bn = (
                b.get("namespace").and_then(Value::as_str).unwrap_or(""),
                b.get("name").and_then(Value::as_str).unwrap_or(""),
            );
            an.cmp(&bn)
        }
        _ => b
            .get("total_cpu_millicores")
            .and_then(Value::as_i64)
            .cmp(&a.get("total_cpu_millicores").and_then(Value::as_i64)),
    });

    let cap = match args.limit {
        Some(l) => l.min(cfg.max_pods),
        None => cfg.max_pods,
    };
    let truncated = metrics.len() > cap;
    metrics.truncate(cap);

    json_ok(&json!({
        "items": metrics,
        "item_count": metrics.len(),
        "truncated": truncated,
    }))
}

pub async fn events_list(
    cfg: &Arc<Config>,
    args: EventsListArgs,
) -> Result<CallToolResult, ErrorData> {
    check_ns(cfg, &args.namespace)?;
    let api: Api<Event> = Api::namespaced(cfg.client.clone(), &args.namespace);
    let mut params = ListParams::default().limit((cfg.max_events + 1) as u32);
    if let Some(f) = args.field_selector {
        params = params.fields(&f);
    }
    let list = k8s_call(
        cfg,
        &format!("list events in {}", args.namespace),
        api.list(&params),
    )
    .await?;

    let allowed_types: std::collections::HashSet<String> = args
        .types
        .unwrap_or_else(|| vec!["Normal".into(), "Warning".into()])
        .into_iter()
        .collect();

    let cutoff_secs = args.since_seconds.map(|s| {
        jiff::Timestamp::now().as_second() - s
    });

    let mut summaries: Vec<Value> = Vec::new();
    for ev in list.items {
        let t = ev.type_.clone().unwrap_or_else(|| "Normal".into());
        if !allowed_types.contains(&t) {
            continue;
        }
        if let Some(cutoff) = cutoff_secs {
            let last_secs = ev
                .last_timestamp
                .as_ref()
                .map(|t| t.0.as_second())
                .or_else(|| ev.event_time.as_ref().map(|t| t.0.as_second()));
            match last_secs {
                None => continue,
                Some(s) if s < cutoff => continue,
                _ => {}
            }
        }
        summaries.push(event_to_summary(&ev));
    }

    summaries.sort_by(|a, b| {
        let av = a
            .get("last_seen")
            .and_then(Value::as_str)
            .or_else(|| a.get("first_seen").and_then(Value::as_str))
            .unwrap_or("");
        let bv = b
            .get("last_seen")
            .and_then(Value::as_str)
            .or_else(|| b.get("first_seen").and_then(Value::as_str))
            .unwrap_or("");
        bv.cmp(av)
    });
    let truncated = summaries.len() > cfg.max_events;
    summaries.truncate(cfg.max_events);

    json_ok(&json!({
        "namespace": args.namespace,
        "items": summaries,
        "item_count": summaries.len(),
        "truncated": truncated,
    }))
}

fn event_to_summary(ev: &Event) -> Value {
    let invo = ev
        .involved_object
        .clone();
    let inv = json!({
        "kind": invo.kind,
        "name": invo.name,
        "namespace": invo.namespace,
    });
    let first_seen = ev
        .first_timestamp
        .as_ref()
        .map(|t| t.0.to_string())
        .or_else(|| ev.event_time.as_ref().map(|t| t.0.to_string()));
    let last_seen = ev
        .last_timestamp
        .as_ref()
        .map(|t| t.0.to_string())
        .or_else(|| ev.event_time.as_ref().map(|t| t.0.to_string()));
    json!({
        "type": ev.type_.clone().unwrap_or_else(|| "Normal".into()),
        "reason": ev.reason.clone(),
        "message": ev.message.clone(),
        "involved_object": inv,
        "count": ev.count.unwrap_or(0),
        "first_seen": first_seen,
        "last_seen": last_seen,
        "source": ev.source.as_ref().and_then(|s| s.component.clone()),
    })
}

fn json_ok<T: Serialize>(v: &T) -> Result<CallToolResult, ErrorData> {
    let text = serde_json::to_string(v).map_err(|e| tool_internal(format!("serialize: {e}")))?;
    Ok(CallToolResult::success(vec![Content::text(text)]))
}

#[cfg(test)]
mod tests {
    use super::with_deadline;
    use std::time::Duration;

    // A future that resolves before the deadline passes through unchanged.
    #[tokio::test]
    async fn fast_future_passes_through() {
        let r: Result<i32, _> =
            with_deadline(Duration::from_secs(5), "fast", async { Ok::<i32, kube::Error>(42) })
                .await;
        assert_eq!(r.unwrap(), 42);
    }

    // A future slower than the deadline is aborted with an error — never hangs.
    // 10ms real deadline vs a 60s sleep → returns in ~10ms (no test-util needed).
    #[tokio::test]
    async fn slow_future_times_out() {
        let r: Result<i32, _> = with_deadline(Duration::from_millis(10), "slow", async {
            tokio::time::sleep(Duration::from_secs(60)).await;
            Ok::<i32, kube::Error>(1)
        })
        .await;
        assert!(r.is_err(), "a call past the deadline must error, not hang");
    }
}
