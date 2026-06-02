mod server;
mod tools;

use std::net::SocketAddr;

use mcp_common::{auth::BearerLayer, env, errors::McpError, run_streamable_http, trace::init_tracing};

#[tokio::main]
async fn main() -> Result<(), McpError> {
    init_tracing("mcp-time");

    let host = env::env_str("MCP_HOST", "0.0.0.0");
    let port = env::env_usize("MCP_PORT", 8000)?;
    let default_tz = env::env_str("MCP_DEFAULT_TIMEZONE", "America/Chicago");

    if let Err(e) = jiff::tz::TimeZone::get(&default_tz) {
        return Err(McpError::Boot(format!(
            "MCP_DEFAULT_TIMEZONE invalid IANA zone {default_tz:?}: {e}"
        )));
    }

    let auth = BearerLayer::from_env()?;
    tracing::info!(default_tz, api_keys = auth.key_count(), "startup");

    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .map_err(|e| McpError::Boot(format!("bad bind addr: {e}")))?;

    let tz_for_handler = default_tz.clone();
    run_streamable_http(addr, auth, move || {
        server::TimeServer::new(tz_for_handler.clone())
    })
    .await
}
