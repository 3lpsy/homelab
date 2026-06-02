use std::collections::HashSet;
use std::sync::Arc;
use std::task::{Context, Poll};

use axum::body::Body;
use axum::http::{Request, Response, StatusCode};
use axum::response::IntoResponse;
use futures::future::BoxFuture;
use subtle::ConstantTimeEq;
use tower::{Layer, Service};

use crate::env;
use crate::errors::McpError;

/// Per-request tenant context, propagated into rmcp tool handlers via the
/// axum request extension.
#[derive(Clone, Debug)]
pub struct TenantCtx {
    pub api_key: Arc<str>,
}

#[derive(Clone)]
pub struct BearerLayer {
    keys: Arc<HashSet<String>>,
}

impl BearerLayer {
    pub fn new(keys: HashSet<String>) -> Self {
        Self {
            keys: Arc::new(keys),
        }
    }

    pub fn from_env() -> Result<Self, McpError> {
        Ok(Self::new(env::env_csv_set("MCP_API_KEYS")))
    }

    pub fn key_count(&self) -> usize {
        self.keys.len()
    }
}

impl<S> Layer<S> for BearerLayer {
    type Service = BearerService<S>;

    fn layer(&self, inner: S) -> Self::Service {
        BearerService {
            inner,
            keys: self.keys.clone(),
        }
    }
}

#[derive(Clone)]
pub struct BearerService<S> {
    inner: S,
    keys: Arc<HashSet<String>>,
}

impl<S> Service<Request<Body>> for BearerService<S>
where
    S: Service<Request<Body>, Response = Response<Body>> + Clone + Send + 'static,
    S::Future: Send + 'static,
    S::Error: Send,
{
    type Response = Response<Body>;
    type Error = S::Error;
    type Future = BoxFuture<'static, Result<Self::Response, Self::Error>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, mut req: Request<Body>) -> Self::Future {
        let clone = self.inner.clone();
        let mut inner = std::mem::replace(&mut self.inner, clone);
        let keys = self.keys.clone();

        Box::pin(async move {
            if req.method() == axum::http::Method::OPTIONS {
                return inner.call(req).await;
            }
            if req.uri().path() == "/healthz" {
                return inner.call(req).await;
            }

            let token = extract_bearer(&req);
            let matched = token.as_deref().and_then(|t| match_key(&keys, t));
            let Some(matched) = matched else {
                tracing::warn!(method = %req.method(), path = %req.uri().path(), "auth: rejected");
                return Ok(unauthorized());
            };

            req.extensions_mut().insert(TenantCtx {
                api_key: Arc::from(matched),
            });

            inner.call(req).await
        })
    }
}

fn extract_bearer(req: &Request<Body>) -> Option<String> {
    if let Some(h) = req.headers().get(axum::http::header::AUTHORIZATION) {
        if let Ok(s) = h.to_str() {
            // RFC 6750 §2.1 — the "Bearer" scheme token is case-insensitive.
            // Python lowercased the whole header and matched `"bearer "`; mirror
            // that so "BEARER ...", "Bearer ...", "bEaReR ..." all work.
            if s.len() >= 7 && s[..7].eq_ignore_ascii_case("bearer ") {
                let token = s[7..].trim().to_string();
                if !token.is_empty() {
                    return Some(token);
                }
            }
        }
    }
    let query = req.uri().query()?;
    for (k, v) in url::form_urlencoded::parse(query.as_bytes()) {
        if k == "api_key" && !v.is_empty() {
            return Some(v.into_owned());
        }
    }
    None
}

fn match_key(keys: &HashSet<String>, candidate: &str) -> Option<String> {
    if keys.is_empty() {
        return None;
    }
    let cand_bytes = candidate.as_bytes();
    for k in keys.iter() {
        if k.len() == cand_bytes.len()
            && bool::from(k.as_bytes().ct_eq(cand_bytes))
        {
            return Some(k.clone());
        }
    }
    None
}

fn unauthorized() -> Response<Body> {
    (
        StatusCode::UNAUTHORIZED,
        axum::Json(serde_json::json!({ "error": "unauthorized" })),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;
    use axum::extract::Extension;
    use axum::routing::{get, post};
    use axum::Router;
    use http::Request as HttpRequest;
    use tower::ServiceExt;

    fn keys(arr: &[&str]) -> HashSet<String> {
        arr.iter().map(|s| s.to_string()).collect()
    }

    fn app(keys: HashSet<String>) -> Router {
        Router::new()
            .route(
                "/echo",
                post(|Extension(ctx): Extension<TenantCtx>| async move {
                    ctx.api_key.to_string()
                }),
            )
            .route(
                "/whoami",
                get(|Extension(ctx): Extension<TenantCtx>| async move {
                    ctx.api_key.to_string()
                }),
            )
            .route("/healthz", get(|| async { "ok" }))
            .layer(BearerLayer::new(keys))
    }

    async fn body_string(resp: Response<Body>) -> (StatusCode, String) {
        let (parts, body) = resp.into_parts();
        let bytes = to_bytes(body, 64 * 1024).await.unwrap();
        (parts.status, String::from_utf8_lossy(&bytes).to_string())
    }

    #[tokio::test]
    async fn bearer_scheme_is_case_insensitive() {
        // RFC 6750 §2.1 — scheme token "Bearer" is case-insensitive.
        for prefix in ["Bearer ", "bearer ", "BEARER ", "BeArEr "] {
            let app = app(keys(&["k1"]));
            let req = HttpRequest::builder()
                .method("GET")
                .uri("/whoami")
                .header("Authorization", format!("{prefix}k1"))
                .body(Body::empty())
                .unwrap();
            let resp = app.oneshot(req).await.unwrap();
            let (status, body) = body_string(resp).await;
            assert_eq!(status, StatusCode::OK, "prefix {prefix:?} should accept");
            assert_eq!(body, "k1");
        }
    }

    #[tokio::test]
    async fn header_bearer_accepted_and_tenant_injected() {
        let app = app(keys(&["k1", "k2"]));
        let req = HttpRequest::builder()
            .method("POST")
            .uri("/echo")
            .header("Authorization", "Bearer k2")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = body_string(resp).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "k2");
    }

    #[tokio::test]
    async fn query_api_key_fallback() {
        let app = app(keys(&["only"]));
        let req = HttpRequest::builder()
            .method("GET")
            .uri("/whoami?api_key=only")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = body_string(resp).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "only");
    }

    #[tokio::test]
    async fn missing_bearer_returns_401() {
        let app = app(keys(&["k1"]));
        let req = HttpRequest::builder()
            .method("GET")
            .uri("/whoami")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, _) = body_string(resp).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn wrong_bearer_returns_401() {
        let app = app(keys(&["k1"]));
        let req = HttpRequest::builder()
            .method("GET")
            .uri("/whoami")
            .header("Authorization", "Bearer not-a-key")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, _) = body_string(resp).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn empty_keyset_rejects_everything() {
        let app = app(keys(&[]));
        let req = HttpRequest::builder()
            .method("GET")
            .uri("/whoami")
            .header("Authorization", "Bearer anything")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, _) = body_string(resp).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn options_preflight_bypasses_auth() {
        let app = app(keys(&["k1"]));
        let req = HttpRequest::builder()
            .method("OPTIONS")
            .uri("/echo")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        // Auth doesn't block, but axum's POST route doesn't handle OPTIONS;
        // upstream returns 405. The point: it's NOT 401.
        assert_ne!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn healthz_bypasses_auth() {
        let app = app(keys(&["k1"]));
        let req = HttpRequest::builder()
            .method("GET")
            .uri("/healthz")
            .body(Body::empty())
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let (status, body) = body_string(resp).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body, "ok");
    }
}
