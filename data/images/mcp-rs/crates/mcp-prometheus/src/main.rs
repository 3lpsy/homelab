mod client;
mod server;
mod tools;
mod validate;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use mcp_common::{auth::BearerLayer, env, errors::McpError, run_streamable_http, trace::init_tracing};

#[tokio::main]
async fn main() -> Result<(), McpError> {
    init_tracing("mcp-prometheus");

    let host = env::env_str("MCP_HOST", "0.0.0.0");
    let port = env::env_usize("MCP_PORT", 8000)?;
    let prom_url = env::env_required("PROMETHEUS_URL")?
        .trim_end_matches('/')
        .to_string();
    let prom_user = env::env_opt("PROMETHEUS_USERNAME");
    let prom_pass = env::env_opt("PROMETHEUS_PASSWORD");
    let prom_token = env::env_opt("PROMETHEUS_TOKEN");
    let prom_orgid = env::env_opt("PROMETHEUS_ORGID");
    let tls_skip_verify = env::env_bool("PROMETHEUS_TLS_SKIP_VERIFY");
    let tls_ca_cert = env::env_opt("PROMETHEUS_TLS_CA_CERT");
    let timeout = env::env_f64("PROMETHEUS_TIMEOUT", 30.0)?;
    let query_timeout = env::env_str("MCP_QUERY_TIMEOUT", "30s");
    let max_series = env::env_usize("MCP_MAX_SERIES", 10000)?;
    let allow_config = env::env_bool("MCP_ALLOW_CONFIG");

    if prom_token.is_some() && (prom_user.is_some() || prom_pass.is_some()) {
        return Err(McpError::Boot(
            "PROMETHEUS_TOKEN is mutually exclusive with PROMETHEUS_USERNAME/PROMETHEUS_PASSWORD".into(),
        ));
    }
    if prom_user.is_some() != prom_pass.is_some() {
        return Err(McpError::Boot(
            "PROMETHEUS_USERNAME and PROMETHEUS_PASSWORD must both be set or both unset".into(),
        ));
    }

    let query_timeout_sec = validate::duration_seconds(&query_timeout)
        .map_err(|e| McpError::Boot(format!("MCP_QUERY_TIMEOUT invalid: {e}")))?;

    let auth = BearerLayer::from_env()?;
    tracing::info!(
        prometheus = %prom_url,
        api_keys = auth.key_count(),
        orgid = prom_orgid.is_some(),
        tls_skip_verify,
        allow_config,
        "startup"
    );

    let client = client::build_client(
        &prom_url,
        prom_user.as_deref(),
        prom_pass.as_deref(),
        prom_token.as_deref(),
        prom_orgid.as_deref(),
        tls_skip_verify,
        tls_ca_cert.as_deref(),
        Duration::from_secs_f64(timeout),
    )?;

    let cfg = Arc::new(server::Config {
        base_url: prom_url,
        client,
        query_timeout,
        query_timeout_sec,
        max_series,
        allow_config,
    });

    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .map_err(|e| McpError::Boot(format!("bad bind addr: {e}")))?;

    let factory_cfg = cfg.clone();
    run_streamable_http(addr, auth, move || server::PrometheusServer::new(factory_cfg.clone())).await
}
