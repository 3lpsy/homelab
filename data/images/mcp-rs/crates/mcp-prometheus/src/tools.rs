use std::sync::Arc;

use rmcp::model::{CallToolResult, Content};
use rmcp::ErrorData;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use mcp_common::errors::tool_internal;

/// Input-length caps that mirror the pydantic `Field(max_length=…)` constraints
/// the Python server enforced before dispatch. Centralised here so a single
/// `check_str_len` call covers each tool's caller-supplied strings.
const MAX_QUERY_CHARS: usize = 8192;
const MAX_MATCH_SELECTOR_CHARS: usize = 4096;
const MAX_MATCH_LIST_LEN: usize = 32;
const MAX_METRIC_CHARS: usize = 512;
const MAX_MATCH_TARGET_CHARS: usize = 2048;

fn check_str_len(s: &str, label: &str, max: usize) -> Result<(), PromError> {
    if s.len() > max {
        return Err(err_validation(format!(
            "{label} too long: {} > {max}",
            s.len()
        )));
    }
    Ok(())
}

fn check_match_selectors(items: &[String]) -> Result<(), PromError> {
    if items.len() > MAX_MATCH_LIST_LEN {
        return Err(err_validation(format!(
            "match list too long: {} > {MAX_MATCH_LIST_LEN}",
            items.len()
        )));
    }
    for (i, m) in items.iter().enumerate() {
        if m.is_empty() {
            return Err(err_validation(format!("match[{i}] must be non-empty")));
        }
        check_str_len(m, &format!("match[{i}]"), MAX_MATCH_SELECTOR_CHARS)?;
    }
    Ok(())
}

use crate::server::Config;
use crate::validate;

// --- arg structs (one per tool) ---

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ExecuteQueryArgs {
    pub query: String,
    #[serde(default)]
    pub time: Option<String>,
    #[serde(default)]
    pub timeout: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ExecuteRangeQueryArgs {
    pub query: String,
    pub start: String,
    pub end: String,
    pub step: String,
    #[serde(default)]
    pub timeout: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct FindSeriesArgs {
    #[serde(rename = "match")]
    pub r#match: Vec<String>,
    #[serde(default)]
    pub start: Option<String>,
    #[serde(default)]
    pub end: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ListLabelNamesArgs {
    #[serde(default, rename = "match")]
    pub r#match: Option<Vec<String>>,
    #[serde(default)]
    pub start: Option<String>,
    #[serde(default)]
    pub end: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ListLabelValuesArgs {
    pub label: String,
    #[serde(default, rename = "match")]
    pub r#match: Option<Vec<String>>,
    #[serde(default)]
    pub start: Option<String>,
    #[serde(default)]
    pub end: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetMetricMetadataArgs {
    #[serde(default)]
    pub metric: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetTargetsArgs {
    #[serde(default)]
    pub state: Option<String>,
    #[serde(default)]
    pub include_discovered: bool,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetTargetsMetadataArgs {
    #[serde(default)]
    pub match_target: Option<String>,
    #[serde(default)]
    pub metric: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetRulesArgs {
    #[serde(default)]
    pub rule_type: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct QueryExemplarsArgs {
    pub query: String,
    pub start: String,
    pub end: String,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetTsdbStatsArgs {
    #[serde(default)]
    pub limit: Option<usize>,
}

// --- error envelope ---

#[derive(Debug, Serialize)]
struct PromError {
    error: String,
    error_type: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<u16>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    warnings: Vec<String>,
}

fn err_validation(msg: impl Into<String>) -> PromError {
    PromError {
        error: msg.into(),
        error_type: "validation",
        status: None,
        warnings: Vec::new(),
    }
}

const TARGET_SLIM_FIELDS: &[&str] = &[
    "labels",
    "scrapePool",
    "scrapeUrl",
    "health",
    "lastError",
    "lastScrape",
    "lastScrapeDuration",
    "scrapeInterval",
    "scrapeTimeout",
];

const METADATA_DEFAULT: usize = 300;

fn capped_query_timeout(cfg: &Arc<Config>, caller: Option<&str>) -> String {
    match caller {
        None => cfg.query_timeout.clone(),
        Some(c) => match validate::duration_seconds(c) {
            Ok(sec) if sec <= cfg.query_timeout_sec => c.to_string(),
            _ => cfg.query_timeout.clone(),
        },
    }
}

fn capped_limit(cfg: &Arc<Config>, caller: Option<usize>) -> usize {
    cfg.max_series.min(caller.unwrap_or(cfg.max_series))
}

fn capped_metadata_limit(cfg: &Arc<Config>, caller: Option<usize>) -> usize {
    let base = caller.unwrap_or(METADATA_DEFAULT);
    base.min(cfg.max_series)
}

// --- HTTP wrapper ---

struct Ok2 {
    data: Value,
    warnings: Vec<String>,
    #[allow(dead_code)]
    status: u16,
}

async fn get_api(
    cfg: &Arc<Config>,
    path: &str,
    params: &[(String, String)],
) -> Result<Ok2, PromError> {
    let mut url = format!("{}{}", cfg.base_url, path);
    let qs = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs(params.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .finish();
    if !qs.is_empty() {
        url.push('?');
        url.push_str(&qs);
    }

    let res = cfg.client.get(&url).send().await;
    let resp = match res {
        Ok(r) => r,
        Err(e) if e.is_timeout() => {
            return Err(PromError {
                error: format!("upstream timeout ({e})"),
                error_type: "timeout",
                status: None,
                warnings: Vec::new(),
            })
        }
        Err(e) => {
            return Err(PromError {
                error: format!("upstream unreachable ({e})"),
                error_type: "upstream_http",
                status: None,
                warnings: Vec::new(),
            })
        }
    };

    let status = resp.status();
    if status.as_u16() >= 400 {
        let body_text = resp.text().await.unwrap_or_default();
        let body_error = serde_json::from_str::<Value>(&body_text)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .or_else(|| v.get("errorType"))
                    .and_then(|s| s.as_str())
                    .map(String::from)
            })
            .unwrap_or_else(|| body_text.chars().take(512).collect());
        return Err(PromError {
            error: if body_error.is_empty() {
                format!("HTTP {}", status.as_u16())
            } else {
                body_error
            },
            error_type: "upstream_http",
            status: Some(status.as_u16()),
            warnings: Vec::new(),
        });
    }

    let body: Value = match resp.json().await {
        Ok(v) => v,
        Err(e) => {
            return Err(PromError {
                error: format!("upstream returned non-JSON: {e}"),
                error_type: "upstream_json",
                status: Some(status.as_u16()),
                warnings: Vec::new(),
            })
        }
    };

    let warnings: Vec<String> = body
        .get("warnings")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default();

    if body.get("status").and_then(|s| s.as_str()) == Some("error") {
        let msg = body
            .get("error")
            .or_else(|| body.get("errorType"))
            .and_then(|s| s.as_str())
            .unwrap_or("unknown error")
            .to_string();
        return Err(PromError {
            error: msg,
            error_type: "upstream_api",
            status: Some(status.as_u16()),
            warnings,
        });
    }

    let data = match body.get("data") {
        Some(d) => d.clone(),
        None => {
            return Err(PromError {
                error: "missing data field in response".into(),
                error_type: "upstream_json",
                status: Some(status.as_u16()),
                warnings,
            })
        }
    };

    Ok(Ok2 {
        data,
        warnings,
        status: status.as_u16(),
    })
}

fn json_ok<T: Serialize>(v: &T) -> Result<CallToolResult, ErrorData> {
    let text = serde_json::to_string(v).map_err(|e| tool_internal(format!("serialize: {e}")))?;
    Ok(CallToolResult::success(vec![Content::text(text)]))
}

fn json_err(e: &PromError) -> Result<CallToolResult, ErrorData> {
    let text = serde_json::to_string(e).map_err(|e| tool_internal(format!("serialize: {e}")))?;
    Ok(CallToolResult::success(vec![Content::text(text)]))
}

fn truncate_list(items: &mut Vec<Value>, cap: usize) -> bool {
    if items.len() > cap {
        items.truncate(cap);
        true
    } else {
        false
    }
}

// --- tool impls ---

pub async fn execute_query(
    cfg: &Arc<Config>,
    args: ExecuteQueryArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.query.is_empty() {
        return json_err(&err_validation("query must be non-empty"));
    }
    if let Err(e) = check_str_len(&args.query, "query", MAX_QUERY_CHARS) {
        return json_err(&e);
    }
    let mut params: Vec<(String, String)> = vec![("query".into(), args.query.clone())];
    if let Some(t) = &args.time {
        if let Err(e) = validate::validate_time(t) {
            return json_err(&err_validation(e));
        }
        params.push(("time".into(), t.clone()));
    }
    if let Some(t) = &args.timeout {
        if let Err(e) = validate::validate_step(t) {
            return json_err(&err_validation(format!("timeout: {e}")));
        }
    }
    params.push(("timeout".into(), capped_query_timeout(cfg, args.timeout.as_deref())));
    params.push(("limit".into(), capped_limit(cfg, args.limit).to_string()));

    let res = get_api(cfg, "/api/v1/query", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let mut data = ok.data;
    let Some(obj) = data.as_object_mut() else {
        return json_err(&PromError {
            error: "unexpected /query shape".into(),
            error_type: "upstream_json",
            status: None,
            warnings: ok.warnings,
        });
    };
    let mut result_arr = match obj.remove("result") {
        Some(Value::Array(a)) => a,
        _ => Vec::new(),
    };
    let is_series = result_arr.iter().all(|x| x.is_object());
    let series_count = if is_series { result_arr.len() } else { 1 };
    let truncated = if is_series {
        truncate_list(&mut result_arr, capped_limit(cfg, args.limit))
    } else {
        false
    };

    json_ok(&json!({
        "resultType": obj.get("resultType").cloned().unwrap_or(json!("vector")),
        "result": result_arr,
        "stats": obj.get("stats").cloned(),
        "warnings": ok.warnings,
        "series_count": series_count,
        "truncated": truncated,
    }))
}

pub async fn execute_range_query(
    cfg: &Arc<Config>,
    args: ExecuteRangeQueryArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.query.is_empty() {
        return json_err(&err_validation("query must be non-empty"));
    }
    if let Err(e) = check_str_len(&args.query, "query", MAX_QUERY_CHARS) {
        return json_err(&e);
    }
    if let Err(e) = validate::validate_time(&args.start) {
        return json_err(&err_validation(e));
    }
    if let Err(e) = validate::validate_time(&args.end) {
        return json_err(&err_validation(e));
    }
    if let Err(e) = validate::validate_step(&args.step) {
        return json_err(&err_validation(e));
    }
    if let Some(t) = &args.timeout {
        if let Err(e) = validate::validate_step(t) {
            return json_err(&err_validation(format!("timeout: {e}")));
        }
    }
    let params: Vec<(String, String)> = vec![
        ("query".into(), args.query.clone()),
        ("start".into(), args.start.clone()),
        ("end".into(), args.end.clone()),
        ("step".into(), args.step.clone()),
        ("timeout".into(), capped_query_timeout(cfg, args.timeout.as_deref())),
        ("limit".into(), capped_limit(cfg, args.limit).to_string()),
    ];

    let res = get_api(cfg, "/api/v1/query_range", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let mut data = ok.data;
    let Some(obj) = data.as_object_mut() else {
        return json_err(&PromError {
            error: "unexpected /query_range shape".into(),
            error_type: "upstream_json",
            status: None,
            warnings: ok.warnings,
        });
    };
    let mut result_arr = match obj.remove("result") {
        Some(Value::Array(a)) => a,
        _ => Vec::new(),
    };
    let is_series = result_arr.iter().all(|x| x.is_object());
    let series_count = if is_series { result_arr.len() } else { 1 };
    let truncated = if is_series {
        truncate_list(&mut result_arr, capped_limit(cfg, args.limit))
    } else {
        false
    };

    json_ok(&json!({
        "resultType": obj.get("resultType").cloned().unwrap_or(json!("matrix")),
        "result": result_arr,
        "stats": obj.get("stats").cloned(),
        "warnings": ok.warnings,
        "series_count": series_count,
        "truncated": truncated,
    }))
}

pub async fn find_series(
    cfg: &Arc<Config>,
    args: FindSeriesArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.r#match.is_empty() {
        return json_err(&err_validation("match must be non-empty"));
    }
    if let Err(e) = check_match_selectors(&args.r#match) {
        return json_err(&e);
    }
    if let Some(s) = &args.start {
        if let Err(e) = validate::validate_time(s) {
            return json_err(&err_validation(e));
        }
    }
    if let Some(s) = &args.end {
        if let Err(e) = validate::validate_time(s) {
            return json_err(&err_validation(e));
        }
    }
    let mut params: Vec<(String, String)> = args
        .r#match
        .iter()
        .map(|m| ("match[]".to_string(), m.clone()))
        .collect();
    if let Some(s) = args.start {
        params.push(("start".into(), s));
    }
    if let Some(s) = args.end {
        params.push(("end".into(), s));
    }
    params.push(("limit".into(), capped_limit(cfg, args.limit).to_string()));

    let res = get_api(cfg, "/api/v1/series", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let mut arr = match ok.data {
        Value::Array(a) => a,
        _ => {
            return json_err(&PromError {
                error: "unexpected /series shape".into(),
                error_type: "upstream_json",
                status: None,
                warnings: ok.warnings,
            })
        }
    };
    let total = arr.len();
    let truncated = truncate_list(&mut arr, capped_limit(cfg, args.limit));
    json_ok(&json!({
        "series": arr,
        "series_count": total,
        "truncated": truncated,
        "warnings": ok.warnings,
    }))
}

pub async fn list_label_names(
    cfg: &Arc<Config>,
    args: ListLabelNamesArgs,
) -> Result<CallToolResult, ErrorData> {
    if let Some(m) = args.r#match.as_ref() {
        if let Err(e) = check_match_selectors(m) {
            return json_err(&e);
        }
    }
    if let Some(s) = &args.start {
        if let Err(e) = validate::validate_time(s) {
            return json_err(&err_validation(e));
        }
    }
    if let Some(s) = &args.end {
        if let Err(e) = validate::validate_time(s) {
            return json_err(&err_validation(e));
        }
    }
    let mut params: Vec<(String, String)> = Vec::new();
    if let Some(m) = args.r#match.as_ref() {
        for x in m {
            params.push(("match[]".into(), x.clone()));
        }
    }
    if let Some(s) = args.start {
        params.push(("start".into(), s));
    }
    if let Some(s) = args.end {
        params.push(("end".into(), s));
    }
    params.push(("limit".into(), capped_limit(cfg, args.limit).to_string()));

    let res = get_api(cfg, "/api/v1/labels", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let arr = match ok.data {
        Value::Array(a) => a,
        _ => {
            return json_err(&PromError {
                error: "unexpected /labels shape".into(),
                error_type: "upstream_json",
                status: None,
                warnings: ok.warnings,
            })
        }
    };
    json_ok(&json!({ "labels": arr, "warnings": ok.warnings }))
}

pub async fn list_label_values(
    cfg: &Arc<Config>,
    args: ListLabelValuesArgs,
) -> Result<CallToolResult, ErrorData> {
    // `chars().all(...)` on an empty iterator returns `true`, so the regex-style
    // validator below would wave through an empty label and we'd hit
    // `/api/v1/label//values`. Explicit non-empty check matches Python's
    // `min_length=1`.
    if args.label.is_empty() {
        return json_err(&err_validation("label must be non-empty"));
    }
    if !args
        .label
        .chars()
        .enumerate()
        .all(|(i, c)| matches!(c, 'a'..='z' | 'A'..='Z' | '_') || (i > 0 && c.is_ascii_digit()))
    {
        return json_err(&err_validation(format!(
            "invalid label name: {:?}",
            args.label
        )));
    }
    if let Some(m) = args.r#match.as_ref() {
        if let Err(e) = check_match_selectors(m) {
            return json_err(&e);
        }
    }
    if let Some(s) = &args.start {
        if let Err(e) = validate::validate_time(s) {
            return json_err(&err_validation(e));
        }
    }
    if let Some(s) = &args.end {
        if let Err(e) = validate::validate_time(s) {
            return json_err(&err_validation(e));
        }
    }
    let mut params: Vec<(String, String)> = Vec::new();
    if let Some(m) = args.r#match.as_ref() {
        for x in m {
            params.push(("match[]".into(), x.clone()));
        }
    }
    if let Some(s) = args.start {
        params.push(("start".into(), s));
    }
    if let Some(s) = args.end {
        params.push(("end".into(), s));
    }
    params.push(("limit".into(), capped_limit(cfg, args.limit).to_string()));

    let path = format!("/api/v1/label/{}/values", args.label);
    let res = get_api(cfg, &path, &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let arr = match ok.data {
        Value::Array(a) => a,
        _ => {
            return json_err(&PromError {
                error: "unexpected /label/values shape".into(),
                error_type: "upstream_json",
                status: None,
                warnings: ok.warnings,
            })
        }
    };
    json_ok(&json!({ "labels": arr, "warnings": ok.warnings }))
}

pub async fn get_metric_metadata(
    cfg: &Arc<Config>,
    args: GetMetricMetadataArgs,
) -> Result<CallToolResult, ErrorData> {
    if let Some(m) = args.metric.as_deref() {
        if let Err(e) = check_str_len(m, "metric", MAX_METRIC_CHARS) {
            return json_err(&e);
        }
    }
    let mut params: Vec<(String, String)> =
        vec![("limit".into(), capped_metadata_limit(cfg, args.limit).to_string())];
    if let Some(m) = args.metric {
        params.push(("metric".into(), m));
    }
    let res = get_api(cfg, "/api/v1/metadata", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let map = match ok.data {
        Value::Object(o) => o,
        _ => {
            return json_err(&PromError {
                error: "unexpected /metadata shape".into(),
                error_type: "upstream_json",
                status: None,
                warnings: ok.warnings,
            })
        }
    };
    json_ok(&json!({ "metadata": map }))
}

pub async fn get_targets(
    cfg: &Arc<Config>,
    args: GetTargetsArgs,
) -> Result<CallToolResult, ErrorData> {
    let mut params: Vec<(String, String)> = Vec::new();
    if let Some(s) = args.state.as_deref() {
        if !matches!(s, "active" | "dropped" | "any") {
            return json_err(&err_validation(format!("invalid state: {s:?}")));
        }
        params.push(("state".into(), s.into()));
    }
    let res = get_api(cfg, "/api/v1/targets", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let obj = match ok.data {
        Value::Object(o) => o,
        _ => {
            return json_err(&PromError {
                error: "unexpected /targets shape".into(),
                error_type: "upstream_json",
                status: None,
                warnings: ok.warnings,
            })
        }
    };
    let active = match obj.get("activeTargets") {
        Some(Value::Array(a)) => a.clone(),
        _ => Vec::new(),
    };
    let dropped = match obj.get("droppedTargets") {
        Some(Value::Array(a)) => a.clone(),
        _ => Vec::new(),
    };
    let (active, dropped) = if args.include_discovered {
        (active, dropped)
    } else {
        (
            active.into_iter().map(slim_target).collect(),
            dropped.into_iter().map(slim_target).collect(),
        )
    };
    json_ok(&json!({ "active": active, "dropped": dropped }))
}

fn slim_target(v: Value) -> Value {
    if let Value::Object(map) = v {
        let mut keep = serde_json::Map::new();
        for (k, val) in map {
            if TARGET_SLIM_FIELDS.contains(&k.as_str()) {
                keep.insert(k, val);
            }
        }
        Value::Object(keep)
    } else {
        v
    }
}

pub async fn get_targets_metadata(
    cfg: &Arc<Config>,
    args: GetTargetsMetadataArgs,
) -> Result<CallToolResult, ErrorData> {
    if let Some(m) = args.match_target.as_deref() {
        if let Err(e) = check_str_len(m, "match_target", MAX_MATCH_TARGET_CHARS) {
            return json_err(&e);
        }
    }
    if let Some(m) = args.metric.as_deref() {
        if let Err(e) = check_str_len(m, "metric", MAX_METRIC_CHARS) {
            return json_err(&e);
        }
    }
    let cap = capped_metadata_limit(cfg, args.limit);
    let mut params: Vec<(String, String)> = vec![("limit".into(), cap.to_string())];
    if let Some(m) = args.match_target {
        params.push(("match_target".into(), m));
    }
    if let Some(m) = args.metric {
        params.push(("metric".into(), m));
    }
    let res = get_api(cfg, "/api/v1/targets/metadata", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let mut arr = match ok.data {
        Value::Array(a) => a,
        _ => {
            return json_err(&PromError {
                error: "unexpected /targets/metadata shape".into(),
                error_type: "upstream_json",
                status: None,
                warnings: ok.warnings,
            })
        }
    };
    let total = arr.len();
    let truncated = truncate_list(&mut arr, cap);
    json_ok(&json!({
        "metadata": arr,
        "series_count": total,
        "truncated": truncated,
    }))
}

pub async fn get_rules(cfg: &Arc<Config>, args: GetRulesArgs) -> Result<CallToolResult, ErrorData> {
    let mut params: Vec<(String, String)> = Vec::new();
    if let Some(t) = args.rule_type.as_deref() {
        if !matches!(t, "alert" | "record") {
            return json_err(&err_validation(format!("invalid rule_type: {t:?}")));
        }
        params.push(("type".into(), t.into()));
    }
    let res = get_api(cfg, "/api/v1/rules", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let groups = match ok.data {
        Value::Object(mut o) => o.remove("groups").unwrap_or(Value::Array(Vec::new())),
        _ => {
            return json_err(&PromError {
                error: "unexpected /rules shape".into(),
                error_type: "upstream_json",
                status: None,
                warnings: ok.warnings,
            })
        }
    };
    json_ok(&json!({ "groups": groups }))
}

pub async fn get_alerts(cfg: &Arc<Config>) -> Result<CallToolResult, ErrorData> {
    let res = get_api(cfg, "/api/v1/alerts", &[]).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let alerts = match ok.data {
        Value::Object(mut o) => o.remove("alerts").unwrap_or(Value::Array(Vec::new())),
        _ => return json_err(&err_validation("unexpected /alerts shape")),
    };
    json_ok(&json!({ "alerts": alerts }))
}

pub async fn get_alertmanagers(cfg: &Arc<Config>) -> Result<CallToolResult, ErrorData> {
    let res = get_api(cfg, "/api/v1/alertmanagers", &[]).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let obj = match ok.data {
        Value::Object(o) => o,
        _ => return json_err(&err_validation("unexpected /alertmanagers shape")),
    };
    json_ok(&json!({
        "active": obj.get("activeAlertmanagers").cloned().unwrap_or(Value::Array(Vec::new())),
        "dropped": obj.get("droppedAlertmanagers").cloned().unwrap_or(Value::Array(Vec::new())),
    }))
}

pub async fn query_exemplars(
    cfg: &Arc<Config>,
    args: QueryExemplarsArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.query.is_empty() {
        return json_err(&err_validation("query must be non-empty"));
    }
    if let Err(e) = check_str_len(&args.query, "query", MAX_QUERY_CHARS) {
        return json_err(&e);
    }
    if let Err(e) = validate::validate_time(&args.start) {
        return json_err(&err_validation(e));
    }
    if let Err(e) = validate::validate_time(&args.end) {
        return json_err(&err_validation(e));
    }
    let params: Vec<(String, String)> = vec![
        ("query".into(), args.query),
        ("start".into(), args.start),
        ("end".into(), args.end),
    ];
    let res = get_api(cfg, "/api/v1/query_exemplars", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let mut arr = match ok.data {
        Value::Array(a) => a,
        _ => return json_err(&err_validation("unexpected /query_exemplars shape")),
    };
    let total = arr.len();
    let truncated = truncate_list(&mut arr, capped_limit(cfg, args.limit));
    json_ok(&json!({
        "exemplars": arr,
        "series_count": total,
        "truncated": truncated,
    }))
}

pub async fn get_build_info(cfg: &Arc<Config>) -> Result<CallToolResult, ErrorData> {
    let res = get_api(cfg, "/api/v1/status/buildinfo", &[]).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let obj = match ok.data {
        Value::Object(o) => o,
        _ => return json_err(&err_validation("unexpected /status/buildinfo shape")),
    };
    let pick = |k: &str| obj.get(k).cloned().unwrap_or(json!(""));
    json_ok(&json!({
        "version": pick("version"),
        "revision": pick("revision"),
        "branch": pick("branch"),
        "buildUser": pick("buildUser"),
        "buildDate": pick("buildDate"),
        "goVersion": pick("goVersion"),
    }))
}

pub async fn get_runtime_info(cfg: &Arc<Config>) -> Result<CallToolResult, ErrorData> {
    let res = get_api(cfg, "/api/v1/status/runtimeinfo", &[]).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    json_ok(&ok.data)
}

pub async fn get_flags(cfg: &Arc<Config>) -> Result<CallToolResult, ErrorData> {
    let res = get_api(cfg, "/api/v1/status/flags", &[]).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let obj = match ok.data {
        Value::Object(o) => o,
        _ => return json_err(&err_validation("unexpected /status/flags shape")),
    };
    json_ok(&json!({ "flags": obj }))
}

pub async fn get_config(cfg: &Arc<Config>) -> Result<CallToolResult, ErrorData> {
    if !cfg.allow_config {
        return json_err(&err_validation(
            "get_config is disabled on this MCP server (set MCP_ALLOW_CONFIG=true to enable).",
        ));
    }
    let res = get_api(cfg, "/api/v1/status/config", &[]).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    let obj = match ok.data {
        Value::Object(o) => o,
        _ => return json_err(&err_validation("unexpected /status/config shape")),
    };
    let yaml = obj
        .get("yaml")
        .and_then(|v| v.as_str())
        .ok_or(())
        .map_err(|_| ErrorData::internal_error("config missing yaml field", None))?;
    json_ok(&json!({ "yaml": yaml }))
}

pub async fn get_tsdb_stats(
    cfg: &Arc<Config>,
    args: GetTsdbStatsArgs,
) -> Result<CallToolResult, ErrorData> {
    let mut params: Vec<(String, String)> = Vec::new();
    if let Some(l) = args.limit {
        params.push(("limit".into(), capped_limit(cfg, Some(l)).to_string()));
    }
    let res = get_api(cfg, "/api/v1/status/tsdb", &params).await;
    let ok = match res {
        Ok(r) => r,
        Err(e) => return json_err(&e),
    };
    json_ok(&ok.data)
}

pub async fn check_ready(cfg: &Arc<Config>) -> Result<CallToolResult, ErrorData> {
    let url = format!("{}/-/ready", cfg.base_url);
    let res = cfg.client.get(&url).send().await;
    match res {
        Ok(r) => {
            let status = r.status().as_u16();
            let message = r.text().await.unwrap_or_default();
            let message = message.trim().chars().take(512).collect::<String>();
            json_ok(&json!({
                "ready": status == 200,
                "status": status,
                "message": message,
            }))
        }
        Err(e) if e.is_timeout() => json_err(&PromError {
            error: format!("upstream timeout ({e})"),
            error_type: "timeout",
            status: None,
            warnings: Vec::new(),
        }),
        Err(e) => json_err(&PromError {
            error: format!("upstream unreachable ({e})"),
            error_type: "upstream_http",
            status: None,
            warnings: Vec::new(),
        }),
    }
}
