mod edit;
mod sandbox;
mod server;
mod tools;

use std::net::SocketAddr;
use std::sync::Arc;

use mcp_common::{auth::BearerLayer, env, errors::McpError, run_streamable_http, tenant, trace::init_tracing};

#[tokio::main]
async fn main() -> Result<(), McpError> {
    init_tracing("mcp-filesystem");

    let host = env::env_str("MCP_HOST", "0.0.0.0");
    let port = env::env_usize("MCP_PORT", 8000)?;
    let max_file_bytes = env::env_usize("MCP_MAX_FILE_BYTES", 10 * 1024 * 1024)?;
    let max_read_batch = env::env_usize("MCP_MAX_READ_BATCH", 32)?;
    let max_edits = env::env_usize("MCP_MAX_EDITS", 64)?;
    let max_edit_bytes = env::env_usize("MCP_MAX_EDIT_BYTES", 256 * 1024)?;
    let max_description = env::env_usize("MCP_MAX_DESCRIPTION_CHARS", 1024)?;
    let max_tenant_bytes = env::env_usize("MCP_MAX_TENANT_BYTES", 1024 * 1024 * 1024)?;
    let max_sessions = env::env_usize("MCP_MAX_SESSIONS_PER_TENANT", 256)?;
    let max_dir_entries = env::env_usize("MCP_MAX_DIR_ENTRIES", 2000)?;
    let max_tree_depth = env::env_usize("MCP_MAX_TREE_DEPTH", 32)?;
    let max_tree_nodes = env::env_usize("MCP_MAX_TREE_NODES", 5000)?;
    let max_search_hits = env::env_usize("MCP_MAX_SEARCH_HITS", 2000)?;
    let max_session_id_chars = env::env_usize("MCP_MAX_SESSION_ID_CHARS", 128)?;

    let tenant_root = tenant::init_tenant_root()?;

    let auth = BearerLayer::from_env()?;
    tracing::info!(
        data_root = %tenant_root.root.display(),
        api_keys = auth.key_count(),
        "startup"
    );

    let cfg = Arc::new(server::Config {
        salt: tenant_root.salt,
        data_root: tenant_root.root,
        max_file_bytes,
        max_read_batch,
        max_edits,
        max_edit_bytes,
        max_description,
        max_tenant_bytes,
        max_sessions,
        max_dir_entries,
        max_tree_depth,
        max_tree_nodes,
        max_search_hits,
        max_session_id_chars,
        locks: dashmap::DashMap::new(),
    });

    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .map_err(|e| McpError::Boot(format!("bad bind addr: {e}")))?;

    let factory_cfg = cfg.clone();
    run_streamable_http(addr, auth, move || server::FsServer::new(factory_cfg.clone())).await
}
