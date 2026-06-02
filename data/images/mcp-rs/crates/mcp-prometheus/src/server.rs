use std::sync::Arc;

use reqwest::Client;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ServerCapabilities, ServerInfo};
use rmcp::{tool, tool_handler, tool_router, ErrorData, ServerHandler};

use crate::tools;

pub const INSTRUCTIONS: &str = "Read-only access to a Prometheus server. 18 tools cover queries, \
series discovery, rules, alerts, and server metadata.\n\nDiscovery flow — prefer this ordering for \
small models:\n  1. `list_label_names()` or `list_label_values(label='job')` to see what targets are \
scraped.\n  2. `find_series(match=['up'])` to discover concrete series.\n  3. `execute_query(query='up')` \
for the latest value, or `execute_range_query(query, start, end, step)` for a time range.\n  4. \
`get_rules()` / `get_alerts()` for recording+alert rules and firing alerts.\n\nTimes: RFC3339 \
(`2026-04-23T00:00:00Z`) or unix seconds (`1745366400`).\nStep/timeout: Prom durations like `15s`, \
`1m`, `1h30m`, or bare float seconds.\nAll list-style results cap at MCP_MAX_SERIES; check \
`truncated` and narrow your selectors if set.";

pub struct Config {
    pub base_url: String,
    pub client: Client,
    pub query_timeout: String,
    pub query_timeout_sec: f64,
    pub max_series: usize,
    pub allow_config: bool,
}

#[derive(Clone)]
pub struct PrometheusServer {
    pub config: Arc<Config>,
    #[allow(dead_code)]
    tool_router: ToolRouter<Self>,
}

impl PrometheusServer {
    pub fn new(config: Arc<Config>) -> Self {
        Self {
            config,
            tool_router: Self::tool_router(),
        }
    }
}

#[tool_router]
impl PrometheusServer {
    #[tool(description = "Instant PromQL query — evaluates `query` at a single point in time.")]
    async fn execute_query(
        &self,
        Parameters(a): Parameters<tools::ExecuteQueryArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::execute_query(&self.config, a).await
    }

    #[tool(description = "Range PromQL query — evaluates `query` at each `step` between `start` and `end`.")]
    async fn execute_range_query(
        &self,
        Parameters(a): Parameters<tools::ExecuteRangeQueryArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::execute_range_query(&self.config, a).await
    }

    #[tool(description = "Find series matching selectors.")]
    async fn find_series(
        &self,
        Parameters(a): Parameters<tools::FindSeriesArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::find_series(&self.config, a).await
    }

    #[tool(description = "List label names visible across all series.")]
    async fn list_label_names(
        &self,
        Parameters(a): Parameters<tools::ListLabelNamesArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::list_label_names(&self.config, a).await
    }

    #[tool(description = "List every distinct value seen for one label.")]
    async fn list_label_values(
        &self,
        Parameters(a): Parameters<tools::ListLabelValuesArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::list_label_values(&self.config, a).await
    }

    #[tool(description = "Per-metric metadata: type, help text, and unit.")]
    async fn get_metric_metadata(
        &self,
        Parameters(a): Parameters<tools::GetMetricMetadataArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::get_metric_metadata(&self.config, a).await
    }

    #[tool(description = "List scrape targets, optionally filtered by state.")]
    async fn get_targets(
        &self,
        Parameters(a): Parameters<tools::GetTargetsArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::get_targets(&self.config, a).await
    }

    #[tool(description = "Metadata for metrics scraped from specific targets.")]
    async fn get_targets_metadata(
        &self,
        Parameters(a): Parameters<tools::GetTargetsMetadataArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::get_targets_metadata(&self.config, a).await
    }

    #[tool(description = "Alert + recording rule groups.")]
    async fn get_rules(
        &self,
        Parameters(a): Parameters<tools::GetRulesArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::get_rules(&self.config, a).await
    }

    #[tool(description = "All currently firing alerts.")]
    async fn get_alerts(&self) -> Result<CallToolResult, ErrorData> {
        tools::get_alerts(&self.config).await
    }

    #[tool(description = "Registered Alertmanagers the server is routing alerts to.")]
    async fn get_alertmanagers(&self) -> Result<CallToolResult, ErrorData> {
        tools::get_alertmanagers(&self.config).await
    }

    #[tool(description = "Exemplars for a PromQL query.")]
    async fn query_exemplars(
        &self,
        Parameters(a): Parameters<tools::QueryExemplarsArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::query_exemplars(&self.config, a).await
    }

    #[tool(description = "Prometheus build info: version, revision, build date.")]
    async fn get_build_info(&self) -> Result<CallToolResult, ErrorData> {
        tools::get_build_info(&self.config).await
    }

    #[tool(description = "Runtime info: uptime, GC stats, storage retention.")]
    async fn get_runtime_info(&self) -> Result<CallToolResult, ErrorData> {
        tools::get_runtime_info(&self.config).await
    }

    #[tool(description = "CLI flags the server was started with.")]
    async fn get_flags(&self) -> Result<CallToolResult, ErrorData> {
        tools::get_flags(&self.config).await
    }

    #[tool(description = "Loaded prometheus.yml. Gated behind MCP_ALLOW_CONFIG.")]
    async fn get_config(&self) -> Result<CallToolResult, ErrorData> {
        tools::get_config(&self.config).await
    }

    #[tool(description = "TSDB head + cardinality stats.")]
    async fn get_tsdb_stats(
        &self,
        Parameters(a): Parameters<tools::GetTsdbStatsArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::get_tsdb_stats(&self.config, a).await
    }

    #[tool(description = "Check whether Prometheus is ready to serve queries.")]
    async fn check_ready(&self) -> Result<CallToolResult, ErrorData> {
        tools::check_ready(&self.config).await
    }
}

#[tool_handler]
impl ServerHandler for PrometheusServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(INSTRUCTIONS)
    }
}
