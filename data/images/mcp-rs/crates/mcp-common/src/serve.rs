use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::http::{HeaderValue, StatusCode};
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use rmcp::transport::streamable_http_server::session::local::LocalSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use rmcp::service::Service;
use rmcp::RoleServer;
use tokio::net::TcpListener;
use tokio::signal::unix::{signal, SignalKind};

use crate::auth::BearerLayer;
use crate::errors::McpError;

/// Boot helper: wire `BearerLayer` + axum router around the rmcp
/// streamable-HTTP service, then listen on `bind` until SIGTERM/SIGINT.
pub async fn run_streamable_http<S, F>(
    bind: SocketAddr,
    auth: BearerLayer,
    handler_factory: F,
) -> Result<(), McpError>
where
    S: Service<RoleServer> + Send + 'static,
    F: Fn() -> S + Send + Sync + 'static,
{
    let factory = Arc::new(handler_factory);
    // Stateless mode: no Mcp-Session-Id is issued or required, so every
    // request is self-contained. These servers are single-replica behind the
    // shared gateway and their per-tenant isolation comes from the bearer API
    // key on each request (hashed -> on-disk sandbox), NOT from session-scoped
    // server state, and the tools are plain request/response (no server-push
    // SSE). Stateful mode (the rmcp default) keeps sessions in the in-memory
    // LocalSessionManager, so any pod restart invalidates every client's
    // session id -> clients get "Session not found" until they re-initialize
    // (which opencode does not do on its own). Stateless survives restarts and
    // would also survive multiple replicas.
    let config = StreamableHttpServerConfig::default()
        .disable_allowed_hosts()
        .disable_allowed_origins()
        .with_sse_keep_alive(Some(Duration::from_secs(30)))
        .with_stateful_mode(false);

    let svc: StreamableHttpService<S, LocalSessionManager> = StreamableHttpService::new(
        move || Ok((factory)()),
        Arc::new(LocalSessionManager::default()),
        config,
    );

    let app = Router::new()
        .route("/healthz", get(healthz))
        .fallback_service(svc)
        .layer(auth);

    let listener = TcpListener::bind(bind)
        .await
        .map_err(|e| McpError::Boot(format!("bind {bind}: {e}")))?;
    tracing::info!(%bind, "listening");

    axum::serve(listener, app.into_make_service())
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|e| McpError::Boot(format!("serve: {e}")))
}

async fn healthz() -> impl IntoResponse {
    (
        StatusCode::OK,
        [(
            axum::http::header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        )],
        axum::Json(serde_json::json!({ "ok": true })),
    )
}

async fn shutdown_signal() {
    let mut term = signal(SignalKind::terminate()).expect("install SIGTERM handler");
    let mut int = signal(SignalKind::interrupt()).expect("install SIGINT handler");
    tokio::select! {
        _ = term.recv() => tracing::info!("SIGTERM received, shutting down"),
        _ = int.recv() => tracing::info!("SIGINT received, shutting down"),
    }
}
