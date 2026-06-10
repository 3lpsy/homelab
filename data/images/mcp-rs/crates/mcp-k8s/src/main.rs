mod qty;
mod redact;
mod server;
mod tools;

use std::collections::HashSet;
use std::net::SocketAddr;
use std::sync::Arc;

use mcp_common::{auth::BearerLayer, env, errors::McpError, run_streamable_http, trace::init_tracing};

#[tokio::main]
async fn main() -> Result<(), McpError> {
    // rustls 0.23 panics on first TLS use when multiple crypto providers are
    // compiled in and none has been installed as the process-wide default.
    // Both `aws-lc-rs` (from kube-client's transitive rustls dep) and `ring`
    // (from kube's `ring` feature) land in this binary, so we pin aws-lc-rs
    // here. `.ok()` because re-installing in dev/test is harmless.
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    init_tracing("mcp-k8s");

    let host = env::env_str("MCP_HOST", "0.0.0.0");
    let port = env::env_usize("MCP_PORT", 8000)?;
    let allowed_ns: HashSet<String> = env::env_csv_set("MCP_K8S_ALLOWED_NAMESPACES");
    let allow_reveal_env = env::env_bool("MCP_K8S_REVEAL_ENV");
    let local = env::env_bool("MCP_K8S_LOCAL");
    let max_pods = env::env_usize("MCP_MAX_PODS", 100)?;
    let max_events = env::env_usize("MCP_MAX_EVENTS", 200)?;
    let max_log_bytes = env::env_usize("MCP_MAX_LOG_BYTES", 65536)?;
    let max_log_tail_lines = env::env_usize("MCP_MAX_LOG_TAIL_LINES", 2000)?;
    // Hard deadline on every kube API call so a stalled connection / expired SA
    // token can never hang a tool. 30s default.
    let api_timeout = std::time::Duration::from_secs_f64(env::env_f64("MCP_K8S_API_TIMEOUT", 30.0)?);

    let auth = BearerLayer::from_env()?;
    tracing::info!(
        api_keys = auth.key_count(),
        allowed_namespaces = allowed_ns.len(),
        allow_reveal_env,
        local,
        max_pods,
        max_events,
        max_log_bytes,
        max_log_tail_lines,
        api_timeout_secs = api_timeout.as_secs_f64(),
        "startup"
    );

    let kube_client = if local {
        kube::Client::try_default()
            .await
            .map_err(|e| McpError::Boot(format!("kube local: {e}")))?
    } else {
        kube::Client::try_default()
            .await
            .map_err(|e| McpError::Boot(format!("kube in-cluster: {e}")))?
    };

    let cfg = Arc::new(server::Config {
        client: kube_client,
        allowed_ns,
        allow_reveal_env,
        max_pods,
        max_events,
        max_log_bytes,
        max_log_tail_lines,
        api_timeout,
    });

    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .map_err(|e| McpError::Boot(format!("bad bind addr: {e}")))?;

    let factory_cfg = cfg.clone();
    run_streamable_http(addr, auth, move || server::K8sServer::new(factory_cfg.clone())).await
}
