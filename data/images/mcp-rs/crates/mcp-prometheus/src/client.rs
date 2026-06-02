use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderName, HeaderValue, AUTHORIZATION, USER_AGENT};
use reqwest::Client;

use mcp_common::errors::McpError;

#[allow(clippy::too_many_arguments)]
pub fn build_client(
    _base_url: &str,
    basic_user: Option<&str>,
    basic_pass: Option<&str>,
    bearer_token: Option<&str>,
    orgid: Option<&str>,
    tls_skip_verify: bool,
    tls_ca_cert: Option<&str>,
    timeout: Duration,
) -> Result<Client, McpError> {
    let mut headers = HeaderMap::new();
    headers.insert(USER_AGENT, HeaderValue::from_static("mcp-prometheus/1.0"));
    if let Some(o) = orgid {
        let v =
            HeaderValue::from_str(o).map_err(|e| McpError::Boot(format!("bad ORGID: {e}")))?;
        headers.insert(HeaderName::from_static("x-scope-orgid"), v);
    }
    if let Some(t) = bearer_token {
        let v = HeaderValue::from_str(&format!("Bearer {t}"))
            .map_err(|e| McpError::Boot(format!("bad token: {e}")))?;
        headers.insert(AUTHORIZATION, v);
    } else if let (Some(u), Some(p)) = (basic_user, basic_pass) {
        let token = format!("{u}:{p}");
        use base64::Engine;
        let encoded = base64::engine::general_purpose::STANDARD.encode(token);
        let v = HeaderValue::from_str(&format!("Basic {encoded}"))
            .map_err(|e| McpError::Boot(format!("bad basic auth: {e}")))?;
        headers.insert(AUTHORIZATION, v);
    }

    let mut builder = Client::builder()
        .default_headers(headers)
        .timeout(timeout)
        .danger_accept_invalid_certs(tls_skip_verify);

    if let Some(ca) = tls_ca_cert {
        let bytes = std::fs::read(ca)
            .map_err(|e| McpError::Boot(format!("PROMETHEUS_TLS_CA_CERT {ca}: {e}")))?;
        let cert = reqwest::Certificate::from_pem(&bytes)
            .map_err(|e| McpError::Boot(format!("PROMETHEUS_TLS_CA_CERT parse: {e}")))?;
        builder = builder.add_root_certificate(cert);
    }

    builder
        .build()
        .map_err(|e| McpError::Boot(format!("reqwest client: {e}")))
}
