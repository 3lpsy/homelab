mod common;
use common::*;

use std::path::PathBuf;

use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn bin_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_mcp-litellm"))
}

const HASH_A: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
const HASH_B: &str = "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100";

async fn start_with_upstream(upstream: &str, hash_map: &str, api_key: &str) -> Server {
    spawn_bin(
        &bin_path(),
        api_key,
        &[
            ("LITELLM_BASE_URL", upstream),
            ("LITELLM_MASTER_KEY", "master"),
            ("MCP_KEY_HASH_MAP", hash_map),
        ],
    )
    .await
    .expect("spawn")
}

#[tokio::test]
async fn list_my_keys_returns_allowlisted_hashes() {
    let mock = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/key/info"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "info": {
                "key_hash": HASH_A,
                "key_alias": "alpha",
                "spend": 12.5,
                "max_budget": 100.0,
                "models": ["m1", "m2"]
            }
        })))
        .mount(&mock)
        .await;

    let map = format!(r#"{{"alice": ["{HASH_A}"]}}"#);
    let srv = start_with_upstream(&mock.uri(), &map, "alice").await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(&srv, &client, &sid, "list_my_keys", serde_json::json!({}))
        .await
        .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["keys"].as_array().map(|a| a.len()), Some(1));
    assert_eq!(body["keys"][0]["key_hash"], HASH_A);
    assert_eq!(body["keys"][0]["key_alias"], "alpha");
}

#[tokio::test]
async fn get_key_info_rejects_hash_outside_allowlist() {
    let mock = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/key/info"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"info": {}})))
        .mount(&mock)
        .await;

    let map = format!(r#"{{"alice": ["{HASH_A}"]}}"#);
    let srv = start_with_upstream(&mock.uri(), &map, "alice").await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "get_key_info",
        serde_json::json!({ "key_hash": HASH_B }),
    )
    .await
    .expect("call");
    let err = r
        .pointer("/error/message")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    assert!(
        err.contains("not in this MCP bearer's allowlist"),
        "expected allowlist reject, got {r}"
    );
}

#[tokio::test]
async fn get_spend_logs_paginates_and_truncates() {
    let mock = MockServer::start().await;
    // Page 1: 3 rows, total=5.
    Mock::given(method("GET"))
        .and(path("/spend/logs/v2"))
        .and(query_param("page", "1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "data": [
                {"startTime": "2026-04-01T00:00:00Z", "spend": 0.1, "model": "m1"},
                {"startTime": "2026-04-02T00:00:00Z", "spend": 0.2, "model": "m1"},
                {"startTime": "2026-04-03T00:00:00Z", "spend": 0.3, "model": "m2"},
            ],
            "total": 5,
            "total_pages": 2
        })))
        .mount(&mock)
        .await;
    Mock::given(method("GET"))
        .and(path("/spend/logs/v2"))
        .and(query_param("page", "2"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "data": [
                {"startTime": "2026-04-04T00:00:00Z", "spend": 0.4, "model": "m2"},
                {"startTime": "2026-04-05T00:00:00Z", "spend": 0.5, "model": "m1"},
            ],
            "total": 5,
            "total_pages": 2
        })))
        .mount(&mock)
        .await;

    let map = format!(r#"{{"alice": ["{HASH_A}"]}}"#);
    let srv = spawn_bin(
        &bin_path(),
        "alice",
        &[
            ("LITELLM_BASE_URL", &mock.uri()),
            ("LITELLM_MASTER_KEY", "master"),
            ("MCP_KEY_HASH_MAP", &map),
            ("MCP_MAX_LOGS", "4"),
        ],
    )
    .await
    .expect("spawn");
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "get_spend_logs",
        serde_json::json!({
            "start_date": "2026-04-01",
            "end_date": "2026-04-30",
        }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["count"], 5);
    assert_eq!(body["truncated"], true);
    assert_eq!(body["logs"].as_array().map(|a| a.len()), Some(4));
}

#[tokio::test]
async fn empty_allowlist_returns_empty_keys() {
    let mock = MockServer::start().await;
    let srv = start_with_upstream(&mock.uri(), "", "alice").await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(&srv, &client, &sid, "list_my_keys", serde_json::json!({}))
        .await
        .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    assert_eq!(body["keys"].as_array().map(|a| a.len()), Some(0));
}
