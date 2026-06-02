mod common;
use common::*;

use std::path::PathBuf;

fn bin_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_mcp-memory"))
}

#[tokio::test]
async fn memory_roundtrip() {
    let tmp = tempfile::tempdir().unwrap();
    let api_key = "mem-key";
    let srv = spawn_bin(
        &bin_path(),
        api_key,
        &[
            ("MCP_PATH_SALT", "saltsalt"),
            ("MCP_DATA_ROOT", tmp.path().to_str().unwrap()),
        ],
    )
    .await
    .expect("spawn");
    let (client, session_id) = initialize(&srv).await.expect("init");
    let create = call_tool(
        &srv,
        &client,
        &session_id,
        "create_entities",
        serde_json::json!({
            "entities": [
                {"name": "alice", "entityType": "person", "observations": ["likes rust"]}
            ]
        }),
    )
    .await
    .expect("create");
    assert!(create.pointer("/result/content").is_some());

    let read = call_tool(&srv, &client, &session_id, "read_graph", serde_json::json!({}))
        .await
        .expect("read");
    let txt = read
        .pointer("/result/content/0/text")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    assert!(txt.contains("alice"), "expected alice in graph: {txt}");
}
