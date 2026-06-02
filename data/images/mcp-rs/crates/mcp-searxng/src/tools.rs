use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderName, HeaderValue, HOST, USER_AGENT};
use reqwest::redirect::Policy;
use rmcp::model::{CallToolResult, Content};
use rmcp::ErrorData;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use url::Url;

use mcp_common::errors::{tool_internal, tool_invalid};

use crate::server::Config;
use crate::ssrf::resolve_and_validate;
use crate::strip::html_to_text;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SearchArgs {
    #[schemars(description = "Search query string.")]
    pub query: String,
    #[schemars(description = "Max results to return (1-100, default 10).")]
    #[serde(default = "default_limit")]
    pub limit: u32,
    #[serde(default)]
    pub categories: Option<String>,
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default)]
    pub time_range: Option<String>,
    #[serde(default)]
    pub safesearch: Option<u8>,
}

fn default_limit() -> u32 {
    10
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct FetchArgs {
    #[schemars(description = "Absolute http(s) URL to fetch.")]
    pub url: String,
    #[schemars(description = "Truncate returned text to this many characters (1-200000, default 5000).")]
    #[serde(default = "default_max_chars")]
    pub max_chars: usize,
}

fn default_max_chars() -> usize {
    5000
}

#[derive(Debug, Serialize)]
struct SearchResultItem {
    title: Option<String>,
    url: Option<String>,
    snippet: Option<String>,
    engine: Option<String>,
    score: Option<f64>,
    published_date: Option<String>,
}

#[derive(Debug, Serialize)]
struct Infobox {
    title: Option<String>,
    content: Option<String>,
    urls: Option<serde_json::Value>,
}

#[derive(Debug, Serialize)]
struct SearchResponse {
    query: String,
    count: usize,
    results: Vec<SearchResultItem>,
    suggestions: Vec<String>,
    infoboxes: Vec<Infobox>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    dropped_categories: Vec<String>,
}

#[derive(Debug, Serialize)]
struct FetchResponse {
    url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    bytes_read: Option<usize>,
    truncated: bool,
    text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

pub fn parse_categories(raw: &str) -> HashSet<String> {
    raw.split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_lowercase())
        .collect()
}

fn split_categories(raw: &str, known: &HashSet<String>) -> (Vec<String>, Vec<String>) {
    let mut kept = Vec::new();
    let mut dropped = Vec::new();
    for c in raw.split(',') {
        let name = c.trim();
        if name.is_empty() {
            continue;
        }
        if known.contains(&name.to_lowercase()) {
            kept.push(name.to_string());
        } else {
            dropped.push(name.to_string());
        }
    }
    (kept, dropped)
}

pub async fn search(cfg: &Arc<Config>, args: SearchArgs) -> Result<CallToolResult, ErrorData> {
    if args.query.is_empty() || args.query.len() > 4096 {
        return Err(tool_invalid("query length 1..=4096"));
    }
    let limit = args.limit.clamp(1, 100) as usize;
    let safesearch = args.safesearch.unwrap_or(0).min(2);

    let mut query_params: Vec<(String, String)> = vec![
        ("q".into(), args.query.clone()),
        ("format".into(), "json".into()),
        ("safesearch".into(), safesearch.to_string()),
    ];

    let mut dropped: Vec<String> = Vec::new();
    if let Some(cat) = args.categories.as_deref() {
        let (kept, drop) = split_categories(cat, &cfg.known_categories);
        if !kept.is_empty() {
            query_params.push(("categories".into(), kept.join(",")));
        }
        dropped = drop;
    }
    if let Some(lang) = args.language {
        query_params.push(("language".into(), lang));
    }
    if let Some(tr) = args.time_range {
        query_params.push(("time_range".into(), tr));
    }

    let mut url = format!("{}/search", cfg.searxng_url);
    let qs = url::form_urlencoded::Serializer::new(String::new())
        .extend_pairs(query_params.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .finish();
    if !qs.is_empty() {
        url.push('?');
        url.push_str(&qs);
    }
    let client = reqwest::Client::builder()
        .timeout(cfg.search_timeout)
        .build()
        .map_err(|e| tool_internal(format!("client build: {e}")))?;
    let res = client.get(&url).send().await;

    match res {
        Ok(r) if r.status().is_success() => {
            let body: serde_json::Value = match r.json().await {
                Ok(v) => v,
                Err(e) => {
                    tracing::warn!(query = %args.query, "search non-JSON");
                    return json_result(&SearchResponse {
                        query: args.query,
                        count: 0,
                        results: vec![],
                        suggestions: vec![],
                        infoboxes: vec![],
                        error: Some(format!("upstream returned non-JSON ({e})")),
                        dropped_categories: dropped,
                    });
                }
            };
            let results: Vec<SearchResultItem> = body
                .get("results")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .take(limit)
                        .map(|item| SearchResultItem {
                            title: item.get("title").and_then(|v| v.as_str()).map(String::from),
                            url: item.get("url").and_then(|v| v.as_str()).map(String::from),
                            snippet: item
                                .get("content")
                                .and_then(|v| v.as_str())
                                .map(String::from),
                            engine: item.get("engine").and_then(|v| v.as_str()).map(String::from),
                            score: item.get("score").and_then(|v| v.as_f64()),
                            published_date: item
                                .get("publishedDate")
                                .and_then(|v| v.as_str())
                                .map(String::from),
                        })
                        .collect()
                })
                .unwrap_or_default();
            let infoboxes: Vec<Infobox> = body
                .get("infoboxes")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .map(|b| Infobox {
                            title: b.get("infobox").and_then(|v| v.as_str()).map(String::from),
                            content: b.get("content").and_then(|v| v.as_str()).map(String::from),
                            urls: b.get("urls").cloned(),
                        })
                        .collect()
                })
                .unwrap_or_default();
            let suggestions: Vec<String> = body
                .get("suggestions")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();

            tracing::info!(query = %args.query, hits = results.len(), dropped = ?dropped, "search");

            json_result(&SearchResponse {
                query: args.query,
                count: results.len(),
                results,
                suggestions,
                infoboxes,
                error: None,
                dropped_categories: dropped,
            })
        }
        Ok(r) => {
            let status = r.status();
            tracing::warn!(query = %args.query, %status, "search http error");
            json_result(&SearchResponse {
                query: args.query,
                count: 0,
                results: vec![],
                suggestions: vec![],
                infoboxes: vec![],
                error: Some(format!("upstream unreachable (HTTP {})", status.as_u16())),
                dropped_categories: dropped,
            })
        }
        Err(e) => {
            tracing::warn!(query = %args.query, err = %e, "search transport error");
            json_result(&SearchResponse {
                query: args.query,
                count: 0,
                results: vec![],
                suggestions: vec![],
                infoboxes: vec![],
                error: Some(format!("upstream unreachable ({e})")),
                dropped_categories: dropped,
            })
        }
    }
}

pub async fn fetch(cfg: &Arc<Config>, args: FetchArgs) -> Result<CallToolResult, ErrorData> {
    if args.url.is_empty() || args.url.len() > 2048 {
        return Err(tool_invalid("url length 1..=2048"));
    }
    let max_chars = args.max_chars.clamp(1, 200_000);

    let mut current = args.url.clone();
    let mut status: Option<u16> = None;
    let mut ctype = String::new();
    let mut bytes_read: usize = 0;
    let mut chunks: Vec<u8> = Vec::with_capacity(8 * 1024);

    let client = reqwest::Client::builder()
        .timeout(cfg.fetch_timeout)
        .redirect(Policy::none())
        .build()
        .map_err(|e| tool_internal(format!("client build: {e}")))?;

    let mut hops = 0;
    loop {
        if hops > cfg.fetch_max_redirects {
            return json_result(&FetchResponse {
                url: current,
                status,
                content_type: Some(ctype),
                bytes_read: None,
                truncated: false,
                text: String::new(),
                error: Some(format!(
                    "blocked: too many redirects (> {})",
                    cfg.fetch_max_redirects
                )),
            });
        }

        let resolved = match resolve_and_validate(&current, &cfg.allowed_cidrs) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(url = %args.url, err = %e, "fetch ssrf reject");
                return json_result(&FetchResponse {
                    url: current,
                    status: None,
                    content_type: None,
                    bytes_read: None,
                    truncated: false,
                    text: String::new(),
                    error: Some(format!("blocked: {e}")),
                });
            }
        };

        let (request_url, host_override) =
            pin_url(&current, &resolved.host, &resolved.ips[0].to_string(), resolved.port, &resolved.scheme);

        let mut headers = HeaderMap::new();
        headers.insert(
            USER_AGENT,
            HeaderValue::from_static("mcp-searxng/1.0"),
        );
        if let Some(host_hdr) = host_override {
            if let Ok(v) = HeaderValue::from_str(&host_hdr) {
                headers.insert(HOST, v);
            }
        }
        let custom: HeaderName = HeaderName::from_static("accept");
        headers.insert(custom, HeaderValue::from_static("*/*"));

        let resp = client.get(&request_url).headers(headers).send().await;
        match resp {
            Err(e) if e.is_timeout() => {
                return json_result(&FetchResponse {
                    url: current,
                    status: None,
                    content_type: None,
                    bytes_read: None,
                    truncated: false,
                    text: String::new(),
                    error: Some(format!("upstream timeout ({e})")),
                });
            }
            Err(e) => {
                tracing::warn!(url = %current, err = %e, "fetch transport error");
                return json_result(&FetchResponse {
                    url: current,
                    status: None,
                    content_type: None,
                    bytes_read: None,
                    truncated: false,
                    text: String::new(),
                    error: Some(format!("upstream unreachable ({e})")),
                });
            }
            Ok(r) => {
                status = Some(r.status().as_u16());
                ctype = r
                    .headers()
                    .get(http::header::CONTENT_TYPE)
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or("")
                    .to_lowercase();
                let code = r.status();
                if code.is_redirection() {
                    if let Some(loc) = r.headers().get(http::header::LOCATION).cloned() {
                        let loc_str = loc.to_str().unwrap_or("").to_string();
                        let base = Url::parse(&current).map_err(|e| tool_invalid(e.to_string()))?;
                        let next = base
                            .join(&loc_str)
                            .map_err(|e| tool_invalid(e.to_string()))?;
                        current = next.to_string();
                        hops += 1;
                        continue;
                    }
                }
                if code.as_u16() >= 400 {
                    return json_result(&FetchResponse {
                        url: current,
                        status,
                        content_type: Some(ctype),
                        bytes_read: None,
                        truncated: false,
                        text: String::new(),
                        error: Some(format!("HTTP {}", code.as_u16())),
                    });
                }
                let mut stream = r.bytes_stream();
                use futures::StreamExt;
                while let Some(chunk) = stream.next().await {
                    match chunk {
                        Ok(bytes) => {
                            if bytes_read + bytes.len() > cfg.fetch_max_bytes {
                                let take = cfg.fetch_max_bytes - bytes_read;
                                chunks.extend_from_slice(&bytes[..take]);
                                bytes_read = cfg.fetch_max_bytes;
                                break;
                            }
                            bytes_read += bytes.len();
                            chunks.extend_from_slice(&bytes);
                        }
                        Err(e) => {
                            tracing::warn!(err = %e, "fetch chunk error");
                            break;
                        }
                    }
                }
                break;
            }
        }
    }

    let mut text = String::from_utf8_lossy(&chunks).to_string();
    if ctype.contains("html") || (ctype.is_empty() && text[..text.len().min(1024)].to_lowercase().contains("<html")) {
        text = html_to_text(&text);
    }

    // Char-boundary-safe truncate by character count, matching Python's
    // `text[:max_chars*2]` (char-indexed, never panics on multibyte UTF-8).
    let pre_filter_cap = max_chars.saturating_mul(2);
    if text.chars().count() > pre_filter_cap {
        text = text.chars().take(pre_filter_cap).collect();
    }
    text = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n");

    let truncated = text.chars().count() > max_chars;
    if truncated {
        text = text.chars().take(max_chars).collect();
    }

    tracing::info!(
        url = %current,
        status = ?status,
        bytes = bytes_read,
        truncated = truncated,
        "fetch"
    );

    json_result(&FetchResponse {
        url: current,
        status,
        content_type: Some(ctype),
        bytes_read: Some(bytes_read),
        truncated,
        text,
        error: None,
    })
}

fn pin_url(
    url_str: &str,
    host: &str,
    ip: &str,
    port: u16,
    scheme: &str,
) -> (String, Option<String>) {
    if scheme == "https" {
        return (url_str.to_string(), None);
    }
    let u = match Url::parse(url_str) {
        Ok(u) => u,
        Err(_) => return (url_str.to_string(), None),
    };
    let ip_host = if ip.contains(':') {
        format!("[{ip}]")
    } else {
        ip.to_string()
    };
    let netloc = if port == 80 {
        ip_host
    } else {
        format!("{ip_host}:{port}")
    };
    let path = u.path();
    let query = u
        .query()
        .map(|q| format!("?{q}"))
        .unwrap_or_default();
    let fragment = u
        .fragment()
        .map(|f| format!("#{f}"))
        .unwrap_or_default();
    let rewritten = format!("{scheme}://{netloc}{path}{query}{fragment}");
    let host_header = if port == 80 {
        host.to_string()
    } else {
        format!("{host}:{port}")
    };
    (rewritten, Some(host_header))
}

fn json_result<T: Serialize>(v: &T) -> Result<CallToolResult, ErrorData> {
    let text = serde_json::to_string(v).map_err(|e| tool_internal(format!("serialize: {e}")))?;
    Ok(CallToolResult::success(vec![Content::text(text)]))
}

#[allow(dead_code)]
fn _unused(_: Duration) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_split() {
        let known = parse_categories("general,news,images");
        let (kept, drop) = split_categories("news,Hocus,general", &known);
        assert_eq!(kept, vec!["news", "general"]);
        assert_eq!(drop, vec!["Hocus"]);
    }
}
