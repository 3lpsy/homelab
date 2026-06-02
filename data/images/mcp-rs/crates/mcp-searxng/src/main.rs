mod server;
mod ssrf;
mod strip;
mod tools;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use mcp_common::{auth::BearerLayer, env, errors::McpError, run_streamable_http, trace::init_tracing};

#[tokio::main]
async fn main() -> Result<(), McpError> {
    init_tracing("mcp-searxng");

    let host = env::env_str("MCP_HOST", "0.0.0.0");
    let port = env::env_usize("MCP_PORT", 8000)?;
    let searxng_url = env::env_str("MCP_SEARXNG_URL", "http://localhost:8080")
        .trim_end_matches('/')
        .to_string();
    let fetch_max_bytes = env::env_usize("MCP_FETCH_MAX_BYTES", 10 * 1024 * 1024)?;
    let fetch_timeout = env::env_f64("MCP_FETCH_TIMEOUT", 15.0)?;
    let fetch_max_redirects = env::env_usize("MCP_FETCH_MAX_REDIRECTS", 5)?;
    let search_timeout = env::env_f64("MCP_SEARCH_TIMEOUT", 15.0)?;

    let allowed_cidrs = ssrf::parse_cidrs(&env::env_str("MCP_ALLOWED_PRIVATE_CIDRS", ""));
    let known_categories = tools::parse_categories(&env::env_str(
        "MCP_SEARXNG_CATEGORIES",
        "general,images,videos,news,map,music,it,science,files,social media",
    ));

    let auth = BearerLayer::from_env()?;
    tracing::info!(
        searxng = %searxng_url,
        api_keys = auth.key_count(),
        allowed_cidrs = allowed_cidrs.len(),
        "startup"
    );

    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .map_err(|e| McpError::Boot(format!("bad bind addr: {e}")))?;

    let config = Arc::new(server::Config {
        searxng_url,
        fetch_max_bytes,
        fetch_timeout: Duration::from_secs_f64(fetch_timeout),
        fetch_max_redirects,
        search_timeout: Duration::from_secs_f64(search_timeout),
        allowed_cidrs,
        known_categories,
    });

    let factory_cfg = config.clone();
    run_streamable_http(addr, auth, move || server::SearxngServer::new(factory_cfg.clone())).await
}
