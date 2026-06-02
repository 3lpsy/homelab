mod common;
use common::*;

use std::path::PathBuf;

fn bin_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_mcp-time"))
}

#[tokio::test]
async fn lists_tools_and_calls_get_current_time() {
    let api_key = "time-key";
    let srv = spawn_bin(&bin_path(), api_key, &[("MCP_DEFAULT_TIMEZONE", "UTC")])
        .await
        .expect("spawn");
    let (client, session_id) = initialize(&srv).await.expect("init");
    let tools = tools_list(&srv, &client, &session_id).await.expect("list");
    let names: Vec<String> = tools
        .pointer("/result/tools")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|t| t.get("name").and_then(|n| n.as_str()).map(String::from))
                .collect()
        })
        .unwrap_or_default();
    assert!(names.iter().any(|n| n == "get_current_time"));
    assert!(names.iter().any(|n| n == "convert_time"));

    let r = call_tool(
        &srv,
        &client,
        &session_id,
        "get_current_time",
        serde_json::json!({"timezone": "UTC"}),
    )
    .await
    .expect("call");
    assert!(r.pointer("/result/content").is_some(), "missing content: {r}");
}

#[tokio::test]
async fn rejects_missing_bearer() {
    let api_key = "time-key";
    let srv = spawn_bin(&bin_path(), api_key, &[("MCP_DEFAULT_TIMEZONE", "UTC")])
        .await
        .expect("spawn");
    let client = reqwest::Client::new();
    let resp = client
        .post(format!("http://127.0.0.1:{}/", srv.port))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .body(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        .send()
        .await
        .expect("send");
    assert_eq!(resp.status().as_u16(), 401);
}
