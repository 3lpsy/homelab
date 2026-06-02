use std::collections::HashSet;
use std::sync::Arc;

use futures::future::join_all;
use jiff::civil::Date;
use rmcp::model::{CallToolResult, Content};
use rmcp::ErrorData;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use mcp_common::errors::{tool_internal, tool_invalid};

use crate::scope::constant_time_contains;
use crate::server::Config;

// --- arg structs ---

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetKeyInfoArgs {
    #[serde(default)]
    pub key_hash: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetSpendLogsArgs {
    pub start_date: String,
    pub end_date: String,
    #[serde(default)]
    pub key_hash: Option<String>,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetDailySummaryArgs {
    pub start_date: String,
    pub end_date: String,
    #[serde(default)]
    pub key_hash: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetMonthlySummaryArgs {
    pub month: String,
    #[serde(default)]
    pub key_hash: Option<String>,
}

// --- response models ---

#[derive(Debug, Serialize)]
struct MyKey {
    key_hash: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    key_alias: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    spend: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_budget: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    models: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

#[derive(Debug, Serialize)]
struct KeyInfo {
    key_hash: String,
    key_alias: Option<String>,
    spend: Option<f64>,
    max_budget: Option<f64>,
    models: Option<Vec<String>>,
    tpm_limit: Option<i64>,
    rpm_limit: Option<i64>,
    budget_duration: Option<String>,
    created_at: Option<String>,
    expires: Option<String>,
}

#[derive(Debug, Serialize)]
struct DailyRow {
    date: String,
    spend: f64,
    total_tokens: i64,
    prompt_tokens: i64,
    completion_tokens: i64,
    request_count: i64,
    by_model: serde_json::Map<String, Value>,
}

// --- helpers ---

fn validate_hash(allowlist: &HashSet<String>, key_hash: &str) -> Result<String, ErrorData> {
    if allowlist.is_empty() {
        return Err(tool_invalid(
            "No LiteLLM key hashes are bound to this MCP bearer. Ask your admin to add your key's hash to the MCP key-hash map.",
        ));
    }
    let kh = key_hash.trim().to_lowercase();
    if kh.len() != 64 || !kh.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
        return Err(tool_invalid(format!(
            "key_hash must be 64-char lowercase hex, got {key_hash:?}"
        )));
    }
    if !constant_time_contains(allowlist, &kh) {
        return Err(tool_invalid("key_hash not in this MCP bearer's allowlist"));
    }
    Ok(kh)
}

fn resolve_hash(allowlist: &HashSet<String>, key_hash: Option<&str>) -> Result<String, ErrorData> {
    if let Some(h) = key_hash {
        return validate_hash(allowlist, h);
    }
    if allowlist.is_empty() {
        return Err(tool_invalid(
            "No LiteLLM key hashes are bound to this MCP bearer. Ask your admin to add your key's hash to the MCP key-hash map.",
        ));
    }
    if allowlist.len() > 1 {
        return Err(tool_invalid(format!(
            "Multiple key hashes in allowlist ({}). Call `list_my_keys` and pass one as `key_hash`.",
            allowlist.len()
        )));
    }
    Ok(allowlist.iter().next().cloned().unwrap())
}

async fn get_json(cfg: &Arc<Config>, path: &str, params: &[(String, String)]) -> Result<Value, ErrorData> {
    let mut url = format!("{}{}", cfg.base_url, path);
    let qs = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs(params.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .finish();
    if !qs.is_empty() {
        url.push('?');
        url.push_str(&qs);
    }
    let resp = cfg.client.get(&url).send().await;
    let resp = match resp {
        Ok(r) => r,
        Err(e) if e.is_timeout() => {
            return Err(tool_invalid(format!(
                "LiteLLM timed out — proxy may be slow or the tailnet hop is down ({e})"
            )));
        }
        Err(e) => {
            return Err(tool_invalid(format!(
                "LiteLLM unreachable ({e}) — check the mcp-litellm pod's tailscale sidecar"
            )));
        }
    };
    let status = resp.status();
    if status.as_u16() == 401 {
        return Err(tool_invalid(
            "LiteLLM returned 401 — master key rejected. The MCP's master key is invalid or rotated.",
        ));
    }
    if status.as_u16() == 403 {
        return Err(tool_invalid(
            "LiteLLM returned 403 — master key lacks permission for this route (unexpected)",
        ));
    }
    if status.as_u16() == 404 {
        return Err(tool_invalid(format!(
            "LiteLLM returned 404 for {path} — endpoint not available on this proxy version"
        )));
    }
    if !status.is_success() {
        return Err(tool_invalid(format!(
            "LiteLLM returned HTTP {}",
            status.as_u16()
        )));
    }
    resp.json::<Value>()
        .await
        .map_err(|e| tool_invalid(format!("LiteLLM returned non-JSON response: {e}")))
}

fn unwrap_info(v: &Value) -> Option<&Value> {
    let obj = v.as_object()?;
    obj.get("info").and_then(|i| i.as_object().map(|_| obj.get("info").unwrap()))
        .or(Some(v))
}

fn key_info_from(kh: &str, info: &Value) -> KeyInfo {
    let pick_str = |k: &str| info.get(k).and_then(|v| v.as_str()).map(String::from);
    let pick_f64 = |k: &str| info.get(k).and_then(|v| v.as_f64());
    let pick_i64 = |k: &str| info.get(k).and_then(|v| v.as_i64());
    let pick_models = || {
        info.get("models").and_then(|v| v.as_array()).map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(String::from))
                .collect::<Vec<_>>()
        })
    };
    KeyInfo {
        key_hash: kh.into(),
        key_alias: pick_str("key_alias"),
        spend: pick_f64("spend"),
        max_budget: pick_f64("max_budget"),
        models: pick_models(),
        tpm_limit: pick_i64("tpm_limit"),
        rpm_limit: pick_i64("rpm_limit"),
        budget_duration: pick_str("budget_duration"),
        created_at: pick_str("created_at"),
        expires: pick_str("expires"),
    }
}

fn validate_date(s: &str, label: &str) -> Result<Date, ErrorData> {
    s.parse::<Date>().map_err(|_| {
        tool_invalid(format!("{label} must be YYYY-MM-DD, got {s:?}"))
    })
}

fn validate_month(s: &str) -> Result<(i16, i8), ErrorData> {
    if s.len() != 7 || s.as_bytes()[4] != b'-' {
        return Err(tool_invalid(format!(
            "month must be YYYY-MM (e.g. '2026-04'), got {s:?}"
        )));
    }
    let year: i16 = s[..4]
        .parse()
        .map_err(|_| tool_invalid(format!("month must be YYYY-MM, got {s:?}")))?;
    let mon: i8 = s[5..7]
        .parse()
        .map_err(|_| tool_invalid(format!("month must be YYYY-MM, got {s:?}")))?;
    if !(1..=12).contains(&mon) {
        return Err(tool_invalid(format!(
            "month must be YYYY-MM (e.g. '2026-04'), got {s:?}"
        )));
    }
    Ok((year, mon))
}

fn row_date(row: &Value) -> Option<String> {
    let raw = row
        .get("startTime")
        .or_else(|| row.get("start_time"))
        .or_else(|| row.get("request_time"))
        .and_then(|v| v.as_str())?;
    if raw.is_empty() {
        return None;
    }
    let normalized = raw.replace('Z', "+00:00");
    if let Ok(ts) = normalized.parse::<jiff::Timestamp>() {
        return Some(ts.to_zoned(jiff::tz::TimeZone::UTC).date().to_string());
    }
    if raw.len() >= 10 {
        return Some(raw[..10].to_string());
    }
    None
}

fn row_spend(row: &Value) -> f64 {
    for k in ["spend", "cost", "response_cost"] {
        if let Some(v) = row.get(k).and_then(|v| v.as_f64()) {
            return v;
        }
    }
    0.0
}

fn row_tokens(row: &Value, k: &str) -> i64 {
    row.get(k).and_then(|v| v.as_i64()).unwrap_or(0)
}

fn row_model(row: &Value) -> String {
    row.get("model")
        .or_else(|| row.get("model_id"))
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string()
}

fn row_session_id(row: &Value) -> Option<String> {
    if let Some(s) = row.get("session_id").and_then(|v| v.as_str()) {
        if !s.is_empty() {
            return Some(s.to_string());
        }
    }
    let meta = row.get("metadata").and_then(|v| v.as_object())?;
    meta.get("session_id")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from)
}

async fn paginate_spend(
    cfg: &Arc<Config>,
    key_hash: &str,
    start: &str,
    end: &str,
    cap: usize,
) -> Result<(Vec<Value>, usize, bool), ErrorData> {
    let mut rows: Vec<Value> = Vec::new();
    let mut page = 1usize;
    let page_size = 100usize;
    let mut upstream_total = 0usize;
    loop {
        let params = vec![
            ("api_key".into(), key_hash.into()),
            ("start_date".into(), start.into()),
            ("end_date".into(), end.into()),
            ("page".into(), page.to_string()),
            ("page_size".into(), page_size.to_string()),
        ];
        let data = get_json(cfg, "/spend/logs/v2", &params).await?;
        let obj = data
            .as_object()
            .ok_or_else(|| tool_invalid("LiteLLM /spend/logs/v2 returned unexpected shape"))?;
        let batch = obj
            .get("data")
            .and_then(|v| v.as_array())
            .ok_or_else(|| tool_invalid("LiteLLM /spend/logs/v2 returned unexpected shape"))?
            .clone();
        if let Some(t) = obj.get("total").and_then(|v| v.as_u64()) {
            upstream_total = t as usize;
        }
        rows.extend(batch.iter().cloned());
        if batch.is_empty() {
            break;
        }
        if rows.len() >= cap {
            break;
        }
        if upstream_total > 0 && rows.len() >= upstream_total {
            break;
        }
        if let Some(tp) = obj.get("total_pages").and_then(|v| v.as_u64()) {
            if page as u64 >= tp {
                break;
            }
        }
        page += 1;
    }
    if upstream_total == 0 {
        upstream_total = rows.len();
    }
    let truncated = upstream_total > cap && rows.len() >= cap;
    rows.truncate(cap);
    Ok((rows, upstream_total, truncated))
}

fn aggregate_daily(rows: &[Value]) -> (Vec<DailyRow>, usize) {
    use std::collections::HashMap;
    let mut buckets: HashMap<String, DailyRow> = HashMap::new();
    let mut skipped = 0usize;
    for r in rows {
        let Some(d) = row_date(r) else {
            skipped += 1;
            continue;
        };
        let entry = buckets.entry(d.clone()).or_insert(DailyRow {
            date: d,
            spend: 0.0,
            total_tokens: 0,
            prompt_tokens: 0,
            completion_tokens: 0,
            request_count: 0,
            by_model: serde_json::Map::new(),
        });
        let s = row_spend(r);
        entry.spend += s;
        entry.total_tokens += row_tokens(r, "total_tokens");
        entry.prompt_tokens += row_tokens(r, "prompt_tokens");
        entry.completion_tokens += row_tokens(r, "completion_tokens");
        entry.request_count += 1;
        let model = row_model(r);
        let cur = entry
            .by_model
            .get(&model)
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        entry.by_model.insert(model, json!(round6(cur + s)));
    }
    let mut out: Vec<DailyRow> = buckets.into_values().collect();
    out.sort_by(|a, b| a.date.cmp(&b.date));
    for d in &mut out {
        d.spend = round6(d.spend);
    }
    (out, skipped)
}

fn round6(v: f64) -> f64 {
    (v * 1_000_000.0).round() / 1_000_000.0
}

/// Stringify an rmcp `ErrorData` to a single readable message (mirrors the
/// Python `str(e)` shape used by `list_my_keys` per-entry errors).
fn error_message(e: &ErrorData) -> String {
    e.message.to_string()
}

fn json_result<T: Serialize>(v: &T) -> Result<CallToolResult, ErrorData> {
    let text = serde_json::to_string(v).map_err(|e| tool_internal(format!("serialize: {e}")))?;
    Ok(CallToolResult::success(vec![Content::text(text)]))
}

// --- tools ---

pub async fn list_my_keys(
    cfg: &Arc<Config>,
    allowlist: Arc<HashSet<String>>,
) -> Result<CallToolResult, ErrorData> {
    if allowlist.is_empty() {
        return json_result(&json!({ "keys": [] }));
    }
    let mut hashes: Vec<String> = allowlist.iter().cloned().collect();
    hashes.sort();
    let futs = hashes.into_iter().map(|h| {
        let cfg = cfg.clone();
        async move { (h.clone(), get_json(&cfg, "/key/info", &[("key".into(), h)]).await) }
    });
    let results = join_all(futs).await;
    let keys: Vec<MyKey> = results
        .into_iter()
        .map(|(h, r)| match r {
            Ok(data) => {
                let info = match unwrap_info(&data) {
                    Some(i) => i,
                    None => {
                        return MyKey {
                            key_hash: h,
                            key_alias: None,
                            spend: None,
                            max_budget: None,
                            models: None,
                            error: Some("unexpected /key/info shape".into()),
                        };
                    }
                };
                MyKey {
                    key_hash: h,
                    key_alias: info.get("key_alias").and_then(|v| v.as_str()).map(String::from),
                    spend: info.get("spend").and_then(|v| v.as_f64()),
                    max_budget: info.get("max_budget").and_then(|v| v.as_f64()),
                    models: info.get("models").and_then(|v| v.as_array()).map(|a| {
                        a.iter()
                            .filter_map(|x| x.as_str().map(String::from))
                            .collect()
                    }),
                    error: None,
                }
            }
            Err(e) => MyKey {
                key_hash: h,
                key_alias: None,
                spend: None,
                max_budget: None,
                models: None,
                error: Some(error_message(&e)),
            },
        })
        .collect();
    json_result(&json!({ "keys": keys }))
}

pub async fn get_key_info(
    cfg: &Arc<Config>,
    allowlist: Arc<HashSet<String>>,
    args: GetKeyInfoArgs,
) -> Result<CallToolResult, ErrorData> {
    let kh = resolve_hash(&allowlist, args.key_hash.as_deref())?;
    let data = get_json(cfg, "/key/info", &[("key".into(), kh.clone())]).await?;
    let info = unwrap_info(&data)
        .ok_or_else(|| tool_invalid("LiteLLM /key/info returned unexpected shape"))?;
    json_result(&key_info_from(&kh, info))
}

pub async fn get_spend_logs(
    cfg: &Arc<Config>,
    allowlist: Arc<HashSet<String>>,
    args: GetSpendLogsArgs,
) -> Result<CallToolResult, ErrorData> {
    let kh = resolve_hash(&allowlist, args.key_hash.as_deref())?;
    let s = validate_date(&args.start_date, "start_date")?;
    let e = validate_date(&args.end_date, "end_date")?;
    if e < s {
        return Err(tool_invalid(format!(
            "end_date {} precedes start_date {}",
            args.end_date, args.start_date
        )));
    }
    let cap = match args.limit {
        Some(l) => l.min(cfg.max_logs),
        None => cfg.max_logs,
    };
    let (mut rows, upstream_total, truncated) =
        paginate_spend(cfg, &kh, &args.start_date, &args.end_date, cap).await?;
    if let Some(sid) = args.session_id.as_deref() {
        rows.retain(|r| row_session_id(r).as_deref() == Some(sid));
    }
    json_result(&json!({
        "key_hash": kh,
        "start_date": args.start_date,
        "end_date": args.end_date,
        "count": upstream_total,
        "truncated": truncated,
        "logs": rows,
    }))
}

pub async fn get_daily_summary(
    cfg: &Arc<Config>,
    allowlist: Arc<HashSet<String>>,
    args: GetDailySummaryArgs,
) -> Result<CallToolResult, ErrorData> {
    let kh = resolve_hash(&allowlist, args.key_hash.as_deref())?;
    let s = validate_date(&args.start_date, "start_date")?;
    let e = validate_date(&args.end_date, "end_date")?;
    if e < s {
        return Err(tool_invalid(format!(
            "end_date {} precedes start_date {}",
            args.end_date, args.start_date
        )));
    }
    let (rows, upstream_total, truncated) =
        paginate_spend(cfg, &kh, &args.start_date, &args.end_date, cfg.max_logs).await?;
    let (days, skipped) = aggregate_daily(&rows);
    let total_spend = round6(days.iter().map(|d| d.spend).sum());
    let total_tokens: i64 = days.iter().map(|d| d.total_tokens).sum();
    let total_requests: i64 = days.iter().map(|d| d.request_count).sum();
    json_result(&json!({
        "key_hash": kh,
        "start_date": args.start_date,
        "end_date": args.end_date,
        "days": days,
        "total_spend": total_spend,
        "total_tokens": total_tokens,
        "total_requests": total_requests,
        "log_count": upstream_total,
        "skipped_rows": skipped,
        "truncated": truncated,
    }))
}

pub async fn get_monthly_summary(
    cfg: &Arc<Config>,
    allowlist: Arc<HashSet<String>>,
    args: GetMonthlySummaryArgs,
) -> Result<CallToolResult, ErrorData> {
    let (year, mon) = validate_month(&args.month)?;
    let kh = resolve_hash(&allowlist, args.key_hash.as_deref())?;
    let start = Date::new(year, mon, 1).map_err(|e| tool_invalid(e.to_string()))?;
    let last_day = start.last_of_month().day();
    let end = Date::new(year, mon, last_day).map_err(|e| tool_invalid(e.to_string()))?;
    let (rows, upstream_total, truncated) = paginate_spend(
        cfg,
        &kh,
        &start.to_string(),
        &end.to_string(),
        cfg.max_logs,
    )
    .await?;

    let mut total_spend = 0.0;
    let mut total_tokens: i64 = 0;
    let mut prompt_tokens: i64 = 0;
    let mut completion_tokens: i64 = 0;
    let mut total_requests: i64 = 0;
    let mut skipped = 0usize;
    let mut by_model: serde_json::Map<String, Value> = serde_json::Map::new();
    let mut by_day: serde_json::Map<String, Value> = serde_json::Map::new();

    for r in &rows {
        let s = row_spend(r);
        total_spend += s;
        total_tokens += row_tokens(r, "total_tokens");
        prompt_tokens += row_tokens(r, "prompt_tokens");
        completion_tokens += row_tokens(r, "completion_tokens");
        total_requests += 1;
        let model = row_model(r);
        let cur = by_model
            .get(&model)
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        by_model.insert(model, json!(round6(cur + s)));
        match row_date(r) {
            Some(d) => {
                let cur = by_day.get(&d).and_then(|v| v.as_f64()).unwrap_or(0.0);
                by_day.insert(d, json!(round6(cur + s)));
            }
            None => skipped += 1,
        }
    }

    json_result(&json!({
        "key_hash": kh,
        "month": args.month,
        "start_date": start.to_string(),
        "end_date": end.to_string(),
        "total_spend": round6(total_spend),
        "total_tokens": total_tokens,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_requests": total_requests,
        "by_model": by_model,
        "by_day": by_day,
        "log_count": upstream_total,
        "skipped_rows": skipped,
        "truncated": truncated,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round6_basic() {
        assert!((round6(1.234567) - 1.234567).abs() < 1e-9);
    }

    #[test]
    fn date_validation() {
        assert!(validate_date("2026-04-23", "x").is_ok());
        assert!(validate_date("not-a-date", "x").is_err());
    }

    #[test]
    fn month_validation() {
        assert_eq!(validate_month("2026-04").unwrap(), (2026, 4));
        assert!(validate_month("2026-13").is_err());
        assert!(validate_month("badformat").is_err());
    }
}
