mod graph;
mod server;
mod tools;

use std::net::SocketAddr;
use std::sync::Arc;

use mcp_common::{auth::BearerLayer, env, errors::McpError, run_streamable_http, tenant, trace::init_tracing};

#[tokio::main]
async fn main() -> Result<(), McpError> {
    init_tracing("mcp-memory");

    let host = env::env_str("MCP_HOST", "0.0.0.0");
    let port = env::env_usize("MCP_PORT", 8000)?;
    let max_graph_bytes = env::env_usize("MCP_MAX_GRAPH_BYTES", 32 * 1024 * 1024)?;
    let max_entities = env::env_usize("MCP_MAX_ENTITIES_PER_CALL", 256)?;
    let max_relations = env::env_usize("MCP_MAX_RELATIONS_PER_CALL", 256)?;
    let max_observations = env::env_usize("MCP_MAX_OBSERVATIONS_PER_CALL", 256)?;
    let max_names = env::env_usize("MCP_MAX_NAMES_PER_CALL", 256)?;
    let max_string = env::env_usize("MCP_MAX_STRING_CHARS", 4096)?;
    let max_query = env::env_usize("MCP_MAX_QUERY_CHARS", 512)?;

    let tenant_root = tenant::init_tenant_root()?;

    let auth = BearerLayer::from_env()?;
    tracing::info!(
        data_root = %tenant_root.root.display(),
        api_keys = auth.key_count(),
        max_graph_bytes,
        "startup"
    );

    let cfg = Arc::new(server::Config {
        salt: tenant_root.salt,
        data_root: tenant_root.root,
        max_graph_bytes,
        max_entities,
        max_relations,
        max_observations,
        max_names,
        max_string,
        max_query,
        locks: dashmap::DashMap::new(),
    });

    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .map_err(|e| McpError::Boot(format!("bad bind addr: {e}")))?;

    let factory_cfg = cfg.clone();
    run_streamable_http(addr, auth, move || server::MemoryServer::new(factory_cfg.clone())).await
}
