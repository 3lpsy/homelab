mod common;
use common::*;

use std::path::PathBuf;

fn bin_path() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_mcp-filesystem"))
}

fn extract_text(v: &serde_json::Value) -> String {
    v.pointer("/result/content/0/text")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string()
}

#[tokio::test]
async fn write_then_read_roundtrip() {
    let tmp = tempfile::tempdir().unwrap();
    let api_key = "fs-key";
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

    let written = call_tool(
        &srv,
        &client,
        &session_id,
        "write_file",
        serde_json::json!({
            "session_id": "sess-1",
            "path": "notes/hi.txt",
            "content": "hello world",
        }),
    )
    .await
    .expect("write_file");
    let txt = extract_text(&written);
    assert!(txt.contains("notes/hi.txt"), "expected path in result: {txt}");
    assert!(txt.contains("\"bytes\":11"), "expected bytes count: {txt}");

    let read = call_tool(
        &srv,
        &client,
        &session_id,
        "read_file",
        serde_json::json!({
            "session_id": "sess-1",
            "path": "notes/hi.txt",
        }),
    )
    .await
    .expect("read_file");
    assert_eq!(extract_text(&read), "hello world");
}

#[tokio::test]
async fn escape_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let api_key = "fs-key";
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

    // First create a file so the sandbox root exists and traversal is meaningful.
    call_tool(
        &srv,
        &client,
        &session_id,
        "write_file",
        serde_json::json!({
            "session_id": "esc",
            "path": "ok.txt",
            "content": "fine",
        }),
    )
    .await
    .expect("seed");

    let r = call_tool(
        &srv,
        &client,
        &session_id,
        "read_file",
        serde_json::json!({
            "session_id": "esc",
            "path": "../../etc/passwd",
        }),
    )
    .await
    .expect("call returned");
    // Tool returned an error (rmcp JSON-RPC error result), surfaced under /error.
    let err_msg = r
        .pointer("/error/message")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    assert!(
        err_msg.contains("escapes")
            || r.pointer("/result/isError")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
        "expected escape rejection, got: {r}"
    );
}

#[tokio::test]
async fn tenants_isolated() {
    let tmp = tempfile::tempdir().unwrap();
    // Two keys, one server. `initialize_with`/`call_tool_with` pick the bearer
    // per request so we exercise both tenants against the same process.
    let srv = spawn_bin(
        &bin_path(),
        "alice,bob",
        &[
            ("MCP_PATH_SALT", "saltsalt"),
            ("MCP_DATA_ROOT", tmp.path().to_str().unwrap()),
        ],
    )
    .await
    .expect("spawn");

    let (a_client, a_session) = initialize_with(srv.port, "alice").await.expect("alice init");
    call_tool_with(
        srv.port,
        "alice",
        &a_client,
        &a_session,
        "write_file",
        serde_json::json!({
            "session_id": "shared",
            "path": "secret.txt",
            "content": "alice's secret",
        }),
    )
    .await
    .expect("alice write");

    let (b_client, b_session) = initialize_with(srv.port, "bob").await.expect("bob init");
    let r = call_tool_with(
        srv.port,
        "bob",
        &b_client,
        &b_session,
        "read_file",
        serde_json::json!({
            "session_id": "shared",
            "path": "secret.txt",
        }),
    )
    .await
    .expect("bob call");
    let body = extract_text(&r);
    assert!(
        body != "alice's secret",
        "tenant isolation broken: bob read alice's file: {r}"
    );
}

#[tokio::test]
async fn search_files_prunes_excluded_dirs() {
    let tmp = tempfile::tempdir().unwrap();
    let api_key = "fs-key";
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

    // Layout:
    //   keep/match.log
    //   skip/match.log    <- skip/ matches the exclude pattern
    for path in &["keep/match.log", "skip/match.log"] {
        call_tool(
            &srv,
            &client,
            &session_id,
            "write_file",
            serde_json::json!({
                "session_id": "search",
                "path": path,
                "content": "x",
            }),
        )
        .await
        .expect("seed");
    }

    let r = call_tool(
        &srv,
        &client,
        &session_id,
        "search_files",
        serde_json::json!({
            "session_id": "search",
            "pattern": "*.log",
            "exclude_patterns": ["skip"],
        }),
    )
    .await
    .expect("call");
    let txt = extract_text(&r);
    let hits: Vec<String> = serde_json::from_str(&txt).expect("json");
    assert!(
        hits.iter().any(|h| h.contains("keep/match.log")),
        "expected keep/match.log: {hits:?}"
    );
    assert!(
        !hits.iter().any(|h| h.contains("skip/match.log")),
        "skip/ was supposed to be pruned: {hits:?}"
    );
}

#[tokio::test]
async fn tools_list_advertises_all_14_tools() {
    let tmp = tempfile::tempdir().unwrap();
    let api_key = "fs-key";
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
    for expected in &[
        "read_file",
        "read_multiple_files",
        "write_file",
        "edit_file",
        "create_directory",
        "list_directory",
        "directory_tree",
        "move_file",
        "search_files",
        "get_file_info",
        "list_allowed_directories",
        "destroy_session",
        "list_sessions",
        "describe_session",
    ] {
        assert!(names.contains(&expected.to_string()), "missing {expected}: {names:?}");
    }
}
