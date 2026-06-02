use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use ipnet::IpNet;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ServerCapabilities, ServerInfo};
use rmcp::{tool, tool_handler, tool_router, ErrorData, ServerHandler};

use crate::tools;

pub const INSTRUCTIONS: &str = "Two tools for web access:\n  1. `search(query, ...)` — web search via SearXNG. \
Returns title/url/snippet/engine for each hit plus optional infoboxes. Use when you need to *find* pages.\n  \
2. `fetch(url, max_chars=...)` — retrieve a specific URL and return its plain-text body. HTML is stripped. \
Use when you already know the URL (e.g. from a prior `search` result) and need its content.\n\n\
`fetch` blocks private, loopback, link-local, and cluster-internal addresses (SSRF defense) — \
expect `error: blocked: ...` for those.\n\
For small models: lower `max_chars` (1000-5000) to stay within your context window.";

pub struct Config {
    pub searxng_url: String,
    pub fetch_max_bytes: usize,
    pub fetch_timeout: Duration,
    pub fetch_max_redirects: usize,
    pub search_timeout: Duration,
    pub allowed_cidrs: Vec<IpNet>,
    pub known_categories: HashSet<String>,
}

#[derive(Clone)]
pub struct SearxngServer {
    pub config: Arc<Config>,
    #[allow(dead_code)]
    tool_router: ToolRouter<Self>,
}

impl SearxngServer {
    pub fn new(config: Arc<Config>) -> Self {
        Self {
            config,
            tool_router: Self::tool_router(),
        }
    }
}

#[tool_router]
impl SearxngServer {
    #[tool(description = "Search the web via SearXNG.")]
    async fn search(
        &self,
        Parameters(args): Parameters<tools::SearchArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::search(&self.config, args).await
    }

    #[tool(description = "Fetch a URL and return its text content. HTML is stripped to plain text.")]
    async fn fetch(
        &self,
        Parameters(args): Parameters<tools::FetchArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        tools::fetch(&self.config, args).await
    }
}

#[tool_handler]
impl ServerHandler for SearxngServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(INSTRUCTIONS)
    }
}
