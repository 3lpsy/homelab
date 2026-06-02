mod scope;
mod server;
mod tools;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use mcp_common::{auth::BearerLayer, env, errors::McpError, run_streamable_http, trace::init_tracing};

#[tokio::main]
async fn main() -> Result<(), McpError> {
    init_tracing("mcp-litellm");

    let host = env::env_str("MCP_HOST", "0.0.0.0");
    let port = env::env_usize("MCP_PORT", 8000)?;
    let base = env::env_required("LITELLM_BASE_URL")?
        .trim_end_matches('/')
        .to_string();
    let master_key = env::env_required("LITELLM_MASTER_KEY")?;
    let tls_skip_verify = env::env_bool("LITELLM_TLS_SKIP_VERIFY");
    let timeout = env::env_f64("MCP_UPSTREAM_TIMEOUT", 60.0)?;
    let max_logs = env::env_usize("MCP_MAX_LOGS", 2000)?;

    let raw_map = env::env_str("MCP_KEY_HASH_MAP", "");
    let hash_map = scope::parse_hash_map(&raw_map)
        .map_err(|e| McpError::Boot(format!("MCP_KEY_HASH_MAP: {e}")))?;
    let scope_table = Arc::new(scope::ScopeTable::new(hash_map));

    let auth = BearerLayer::from_env()?;
    tracing::info!(
        base = %base,
        api_keys = auth.key_count(),
        hash_map_tenants = scope_table.tenant_count(),
        hash_map_hashes = scope_table.total_hashes(),
        tls_skip_verify,
        timeout,
        max_logs,
        "startup"
    );

    let client = server::build_client(&base, &master_key, tls_skip_verify, Duration::from_secs_f64(timeout))?;
    let cfg = Arc::new(server::Config {
        base_url: base,
        client,
        max_logs,
        scope: scope_table,
    });

    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .map_err(|e| McpError::Boot(format!("bad bind addr: {e}")))?;

    let factory_cfg = cfg.clone();
    run_streamable_http(addr, auth, move || server::LiteLlmServer::new(factory_cfg.clone())).await
}
