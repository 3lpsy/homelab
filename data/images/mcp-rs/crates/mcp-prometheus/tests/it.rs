mod common;
use common::*;

use std::path::PathBuf;

use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn bin_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_mcp-prometheus"))
}

async fn start_with_upstream(upstream: &str) -> Server {
    spawn_bin(
        &bin_path(),
        "p-key",
        &[("PROMETHEUS_URL", upstream)],
    )
    .await
    .expect("spawn")
}

#[tokio::test]
async fn execute_query_unwraps_data() {
    let mock = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/api/v1/query"))
        .and(query_param("query", "up"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [
                    {"metric": {"__name__": "up", "job": "node"}, "value": [1700000000, "1"]}
                ]
            }
        })))
        .mount(&mock)
        .await;

    let srv = start_with_upstream(&mock.uri()).await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "execute_query",
        serde_json::json!({ "query": "up" }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["resultType"], "vector");
    assert_eq!(body["series_count"], 1);
    assert_eq!(body["result"][0]["metric"]["job"], "node");
}

#[tokio::test]
async fn execute_query_surfaces_upstream_error() {
    let mock = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/api/v1/query"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "status": "error",
            "errorType": "bad_data",
            "error": "parse error at char 1"
        })))
        .mount(&mock)
        .await;

    let srv = start_with_upstream(&mock.uri()).await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "execute_query",
        serde_json::json!({ "query": "{{{" }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["error_type"], "upstream_api");
    assert!(body["error"].as_str().unwrap_or("").contains("parse"));
}

#[tokio::test]
async fn validation_rejects_garbage_time() {
    let mock = MockServer::start().await;
    let srv = start_with_upstream(&mock.uri()).await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "execute_query",
        serde_json::json!({ "query": "up", "time": "not-a-time" }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["error_type"], "validation");
}

#[tokio::test]
async fn rejects_oversized_query() {
    let mock = MockServer::start().await;
    let srv = start_with_upstream(&mock.uri()).await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let huge = "a".repeat(9000);
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "execute_query",
        serde_json::json!({ "query": huge }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["error_type"], "validation");
}

#[tokio::test]
async fn rejects_too_many_match_selectors() {
    let mock = MockServer::start().await;
    let srv = start_with_upstream(&mock.uri()).await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let matchers: Vec<String> = (0..40).map(|i| format!("up{{i=\"{i}\"}}")).collect();
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "find_series",
        serde_json::json!({ "match": matchers }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["error_type"], "validation");
}

#[tokio::test]
async fn list_label_values_rejects_empty_label() {
    let mock = MockServer::start().await;
    let srv = start_with_upstream(&mock.uri()).await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "list_label_values",
        serde_json::json!({ "label": "" }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["error_type"], "validation");
    assert!(body["error"].as_str().unwrap_or("").contains("label"));
}

#[tokio::test]
async fn find_series_truncates_to_max_series() {
    let mock = MockServer::start().await;
    let big = (0..15)
        .map(|i| serde_json::json!({"__name__": "x", "instance": format!("h{i}")}))
        .collect::<Vec<_>>();
    Mock::given(method("GET"))
        .and(path("/api/v1/series"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "status": "success",
            "data": big
        })))
        .mount(&mock)
        .await;

    let srv = spawn_bin(
        &bin_path(),
        "p-key",
        &[
            ("PROMETHEUS_URL", &mock.uri()),
            ("MCP_MAX_SERIES", "5"),
        ],
    )
    .await
    .expect("spawn");
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "find_series",
        serde_json::json!({ "match": ["up"] }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["series_count"], 15);
    assert_eq!(body["truncated"], true);
    assert_eq!(body["series"].as_array().map(|a| a.len()), Some(5));
}
