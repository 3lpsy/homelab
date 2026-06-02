use tracing_subscriber::prelude::*;
use tracing_subscriber::EnvFilter;

/// JSON tracing-subscriber bound to `RUST_LOG` (default `info`).
/// Honours `LOG_LEVEL` as a fallback so the upstream TF contract continues
/// to drive log verbosity for these MCP servers.
pub fn init_tracing(service: &str) {
    let filter = EnvFilter::try_from_default_env()
        .or_else(|_| {
            let lvl = std::env::var("LOG_LEVEL").unwrap_or_else(|_| "info".into());
            EnvFilter::try_new(lvl)
        })
        .unwrap_or_else(|_| EnvFilter::new("info"));
    let layer = tracing_subscriber::fmt::layer()
        .json()
        .with_current_span(false)
        .with_target(true)
        .flatten_event(true);
    let subscriber = tracing_subscriber::registry().with(filter).with(layer);
    let _ = tracing::subscriber::set_global_default(subscriber);
    tracing::info!(service, "tracing initialized");
}
