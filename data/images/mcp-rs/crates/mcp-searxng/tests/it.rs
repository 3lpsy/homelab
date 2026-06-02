mod common;
use common::*;

use std::path::PathBuf;

use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn bin_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_mcp-searxng"))
}

async fn start_with_upstream(upstream: &str) -> Server {
    spawn_bin(
        &bin_path(),
        "sx-key",
        &[("MCP_SEARXNG_URL", upstream)],
    )
    .await
    .expect("spawn")
}

#[tokio::test]
async fn search_happy_path() {
    let mock = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/search"))
        .and(query_param("q", "rust mcp"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "results": [
                {
                    "title": "Rust MCP SDK",
                    "url": "https://example.com/rust",
                    "content": "An MCP SDK in Rust",
                    "engine": "test"
                }
            ],
            "infoboxes": [],
            "suggestions": []
        })))
        .mount(&mock)
        .await;

    let srv = start_with_upstream(&mock.uri()).await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "search",
        serde_json::json!({ "query": "rust mcp", "limit": 5 }),
    )
    .await
    .expect("call");
    let txt = extract_text(&r);
    let body: serde_json::Value = serde_json::from_str(&txt).expect("json");
    assert_eq!(body["count"], 1);
    assert_eq!(body["results"][0]["title"], "Rust MCP SDK");
}

#[tokio::test]
async fn search_dropped_categories_surface() {
    let mock = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/search"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "results": [],
            "infoboxes": [],
            "suggestions": []
        })))
        .mount(&mock)
        .await;

    let srv = start_with_upstream(&mock.uri()).await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "search",
        serde_json::json!({ "query": "x", "categories": "news,bogus,Hocus" }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    let dropped: Vec<&str> = body["dropped_categories"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    assert!(dropped.contains(&"bogus"));
    assert!(dropped.contains(&"Hocus"));
}

#[tokio::test]
async fn fetch_blocks_localhost() {
    // No upstream needed — SSRF guard fires before any DNS.
    let srv = start_with_upstream("http://unused.example/").await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "fetch",
        serde_json::json!({ "url": "http://localhost/secret", "max_chars": 1000 }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.starts_with("blocked:"), "expected blocked: error, got {body:?}");
}

#[tokio::test]
async fn fetch_blocks_private_ip_literal() {
    let srv = start_with_upstream("http://unused.example/").await;
    let (client, sid) = initialize(&srv).await.expect("init");
    let r = call_tool(
        &srv,
        &client,
        &sid,
        "fetch",
        serde_json::json!({ "url": "http://10.0.0.1/", "max_chars": 1000 }),
    )
    .await
    .expect("call");
    let body: serde_json::Value = serde_json::from_str(&extract_text(&r)).expect("json");
    let err = body["error"].as_str().unwrap_or("");
    assert!(err.starts_with("blocked:"), "expected blocked: error, got {body:?}");
}
