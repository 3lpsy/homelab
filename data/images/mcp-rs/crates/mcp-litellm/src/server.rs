use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, USER_AGENT};
use reqwest::Client;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ServerCapabilities, ServerInfo};
use rmcp::service::RequestContext;
use rmcp::{tool, tool_handler, tool_router, ErrorData, RoleServer, ServerHandler};

use mcp_common::auth::TenantCtx;
use mcp_common::errors::{tool_internal, McpError};

use crate::scope::ScopeTable;
use crate::tools;

pub const INSTRUCTIONS: &str = "Read-only view into LiteLLM virtual-key spend for the keys bound to \
this MCP bearer.\n\nStandard flow:\n  1. Call `list_my_keys` first to see which keys you can query. \
Each entry has a `key_hash` and a human `key_alias`.\n  2. Use `get_monthly_summary(month='YYYY-MM')` \
for 'how much did I spend in X month'. Use `get_daily_summary(start_date, end_date)` for a custom \
date range. Use `get_spend_logs` only when per-request rows are actually needed — it is slower and \
truncates beyond MCP_MAX_LOGS.\n  3. If your allowlist has exactly one key, `key_hash` is optional \
on every tool; the single key is used automatically. If it has more than one, pass the `key_hash` \
from step 1.\n\nDates: `YYYY-MM-DD`. Months: `YYYY-MM`. All ranges are inclusive and interpreted in UTC.";

pub struct Config {
    pub base_url: String,
    pub client: Client,
    pub max_logs: usize,
    pub scope: Arc<ScopeTable>,
}

pub fn build_client(
    _base: &str,
    master_key: &str,
    tls_skip_verify: bool,
    timeout: Duration,
) -> Result<Client, McpError> {
    let mut headers = HeaderMap::new();
    headers.insert(USER_AGENT, HeaderValue::from_static("mcp-litellm/2.0"));
    let v = HeaderValue::from_str(&format!("Bearer {master_key}"))
        .map_err(|e| McpError::Boot(format!("bad master key: {e}")))?;
    headers.insert(AUTHORIZATION, v);
    Client::builder()
        .default_headers(headers)
        .timeout(timeout)
        .danger_accept_invalid_certs(tls_skip_verify)
        .build()
        .map_err(|e| McpError::Boot(format!("reqwest client: {e}")))
}

#[derive(Clone)]
pub struct LiteLlmServer {
    pub config: Arc<Config>,
    #[allow(dead_code)]
    tool_router: ToolRouter<Self>,
}

impl LiteLlmServer {
    pub fn new(config: Arc<Config>) -> Self {
        Self {
            config,
            tool_router: Self::tool_router(),
        }
    }
}

fn allowlist_for(
    cfg: &Arc<Config>,
    ctx: &RequestContext<RoleServer>,
) -> Result<Arc<std::collections::HashSet<String>>, ErrorData> {
    let parts = ctx
        .extensions
        .get::<http::request::Parts>()
        .ok_or_else(|| tool_internal("no http parts in request context"))?;
    let tenant: &TenantCtx = parts
        .extensions
        .get::<TenantCtx>()
        .ok_or_else(|| tool_internal("no tenant context"))?;
    Ok(cfg.scope.lookup_for(&tenant.api_key))
}

#[tool_router]
impl LiteLlmServer {
    #[tool(description = "List the LiteLLM virtual keys bound to this MCP bearer.")]
    async fn list_my_keys(
        &self,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let allowlist = allowlist_for(&self.config, &ctx)?;
        tools::list_my_keys(&self.config, allowlist).await
    }

    #[tool(description = "Metadata + lifetime spend for a single LiteLLM virtual key.")]
    async fn get_key_info(
        &self,
        Parameters(a): Parameters<tools::GetKeyInfoArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let allowlist = allowlist_for(&self.config, &ctx)?;
        tools::get_key_info(&self.config, allowlist, a).await
    }

    #[tool(description = "Per-request spend log rows for a key hash.")]
    async fn get_spend_logs(
        &self,
        Parameters(a): Parameters<tools::GetSpendLogsArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let allowlist = allowlist_for(&self.config, &ctx)?;
        tools::get_spend_logs(&self.config, allowlist, a).await
    }

    #[tool(description = "Per-day breakdown for a key hash.")]
    async fn get_daily_summary(
        &self,
        Parameters(a): Parameters<tools::GetDailySummaryArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let allowlist = allowlist_for(&self.config, &ctx)?;
        tools::get_daily_summary(&self.config, allowlist, a).await
    }

    #[tool(description = "Whole-month totals for a key hash.")]
    async fn get_monthly_summary(
        &self,
        Parameters(a): Parameters<tools::GetMonthlySummaryArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let allowlist = allowlist_for(&self.config, &ctx)?;
        tools::get_monthly_summary(&self.config, allowlist, a).await
    }
}

#[tool_handler]
impl ServerHandler for LiteLlmServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(INSTRUCTIONS)
    }
}
