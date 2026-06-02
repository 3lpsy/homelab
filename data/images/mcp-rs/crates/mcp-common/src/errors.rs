use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};

pub type McpResult<T> = Result<T, McpError>;

#[derive(thiserror::Error, Debug)]
pub enum McpError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("invalid argument: {0}")]
    Invalid(String),
    #[error("upstream: {0}")]
    Upstream(String),
    #[error("timeout: {0}")]
    Timeout(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("boot: {0}")]
    Boot(String),
    #[error("internal: {0}")]
    Internal(String),
}

impl IntoResponse for McpError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            McpError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized".to_string()),
            McpError::Forbidden(m) => (StatusCode::FORBIDDEN, m.clone()),
            McpError::NotFound(m) => (StatusCode::NOT_FOUND, m.clone()),
            McpError::Invalid(m) => (StatusCode::BAD_REQUEST, m.clone()),
            McpError::Timeout(m) => (StatusCode::GATEWAY_TIMEOUT, m.clone()),
            McpError::Upstream(m) => (StatusCode::BAD_GATEWAY, m.clone()),
            _ => (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string()),
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}

impl From<McpError> for rmcp::ErrorData {
    fn from(value: McpError) -> Self {
        match value {
            McpError::Invalid(m) => rmcp::ErrorData::invalid_params(m, None),
            McpError::NotFound(m) => rmcp::ErrorData::invalid_params(m, None),
            McpError::Forbidden(m) => rmcp::ErrorData::invalid_params(m, None),
            McpError::Unauthorized => {
                rmcp::ErrorData::invalid_request("unauthorized".to_string(), None)
            }
            McpError::Timeout(m) => rmcp::ErrorData::internal_error(m, None),
            McpError::Upstream(m) => rmcp::ErrorData::internal_error(m, None),
            McpError::Io(e) => rmcp::ErrorData::internal_error(e.to_string(), None),
            McpError::Boot(m) => rmcp::ErrorData::internal_error(m, None),
            McpError::Internal(m) => rmcp::ErrorData::internal_error(m, None),
        }
    }
}

pub fn tool_invalid(msg: impl Into<String>) -> rmcp::ErrorData {
    rmcp::ErrorData::invalid_params(msg.into(), None)
}

pub fn tool_internal(msg: impl Into<String>) -> rmcp::ErrorData {
    rmcp::ErrorData::internal_error(msg.into(), None)
}
