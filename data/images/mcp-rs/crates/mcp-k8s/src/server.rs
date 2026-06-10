use std::collections::HashSet;
use std::sync::Arc;

use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ServerCapabilities, ServerInfo};
use rmcp::{tool, tool_handler, tool_router, ErrorData, ServerHandler};

use crate::tools;

pub const INSTRUCTIONS: &str = "Read-only Kubernetes access via the in-cluster ServiceAccount. Five tools:\n\
  - pods_list(namespace, label_selector?, field_selector?, detail?)\n  \
- pods_get(name, namespace, detail?)\n  \
- pods_log(name, namespace, container?, tail_lines?, since_seconds?, previous?)\n  \
- pods_top(namespace?, sort_by?, limit?)\n  \
- events_list(namespace, field_selector?, since_seconds?, types?)\n\n\
Defaults are tuned for OSS / open-weight LLMs.\nRequests against namespaces outside the deployment's \
allowlist are rejected with no API call. Write verbs are not exposed.";

pub struct Config {
    pub client: kube::Client,
    pub allowed_ns: HashSet<String>,
    pub allow_reveal_env: bool,
    pub max_pods: usize,
    pub max_events: usize,
    pub max_log_bytes: usize,
    pub max_log_tail_lines: usize,
    /// Hard per-call deadline for every kube API request. Without it a stalled
    /// API-server connection or a stale projected SA token (these tokens expire
    /// ~hourly) hangs the tool indefinitely — observed as a multi-hour hang.
    pub api_timeout: std::time::Duration,
}

#[derive(Clone)]
pub struct K8sServer {
    pub config: Arc<Config>,
    #[allow(dead_code)]
    tool_router: ToolRouter<Self>,
}

impl K8sServer {
    pub fn new(config: Arc<Config>) -> Self {
        Self {
            config,
            tool_router: Self::tool_router(),
        }
    }
}

#[tool_router]
impl K8sServer {
    #[tool(description = "List pods in a namespace.")]
    async fn pods_list(
        &self,
        Parameters(a): Parameters<tools::PodsListArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::pods_list(&self.config, a).await
    }

    #[tool(description = "Return pod spec+status. Summary by default; pass detail=\"full\" for raw object minus managedFields.")]
    async fn pods_get(
        &self,
        Parameters(a): Parameters<tools::PodsGetArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::pods_get(&self.config, a).await
    }

    #[tool(description = "Read container logs. Tail-with-cap, multi-container aware.")]
    async fn pods_log(
        &self,
        Parameters(a): Parameters<tools::PodsLogArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::pods_log(&self.config, a).await
    }

    #[tool(description = "Pod CPU/memory usage from metrics.k8s.io. CPU in millicores, memory in bytes.")]
    async fn pods_top(
        &self,
        Parameters(a): Parameters<tools::PodsTopArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::pods_top(&self.config, a).await
    }

    #[tool(description = "List events for a namespace, sorted newest-first.")]
    async fn events_list(
        &self,
        Parameters(a): Parameters<tools::EventsListArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::events_list(&self.config, a).await
    }
}

#[tool_handler]
impl ServerHandler for K8sServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(INSTRUCTIONS)
    }
}
