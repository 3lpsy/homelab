use std::path::PathBuf;
use std::sync::Arc;

use dashmap::DashMap;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ServerCapabilities, ServerInfo};
use rmcp::service::RequestContext;
use rmcp::{tool, tool_handler, tool_router, ErrorData, RoleServer, ServerHandler};
use tokio::sync::Mutex;

use mcp_common::auth::TenantCtx;
use mcp_common::errors::tool_internal;

use crate::tools;

pub const INSTRUCTIONS: &str = "Per-tenant knowledge graph. All state is scoped to the caller's API key — \
no cross-tenant reads or writes.";

pub struct Config {
    pub salt: Vec<u8>,
    pub data_root: PathBuf,
    pub max_graph_bytes: usize,
    pub max_entities: usize,
    pub max_relations: usize,
    pub max_observations: usize,
    pub max_names: usize,
    pub max_string: usize,
    pub max_query: usize,
    pub locks: DashMap<String, Arc<Mutex<()>>>,
}

impl Config {
    pub fn tenant_lock(&self, hash: &str) -> Arc<Mutex<()>> {
        if let Some(l) = self.locks.get(hash) {
            return l.clone();
        }
        let entry = self
            .locks
            .entry(hash.to_string())
            .or_insert_with(|| Arc::new(Mutex::new(())));
        entry.clone()
    }
}

#[derive(Clone)]
pub struct MemoryServer {
    pub config: Arc<Config>,
    #[allow(dead_code)]
    tool_router: ToolRouter<Self>,
}

impl MemoryServer {
    pub fn new(config: Arc<Config>) -> Self {
        Self {
            config,
            tool_router: Self::tool_router(),
        }
    }
}

pub fn tenant_for(ctx: &RequestContext<RoleServer>) -> Result<TenantCtx, ErrorData> {
    let parts = ctx
        .extensions
        .get::<http::request::Parts>()
        .ok_or_else(|| tool_internal("no http parts"))?;
    parts
        .extensions
        .get::<TenantCtx>()
        .cloned()
        .ok_or_else(|| tool_internal("no tenant context"))
}

#[tool_router]
impl MemoryServer {
    #[tool(description = "Create entities. Existing names are skipped (idempotent).")]
    async fn create_entities(
        &self,
        Parameters(a): Parameters<tools::CreateEntitiesArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let tenant = tenant_for(&ctx)?;
        tools::create_entities(&self.config, &tenant, a).await
    }

    #[tool(description = "Create relations. Duplicate (from, to, relationType) triples are skipped.")]
    async fn create_relations(
        &self,
        Parameters(a): Parameters<tools::CreateRelationsArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let tenant = tenant_for(&ctx)?;
        tools::create_relations(&self.config, &tenant, a).await
    }

    #[tool(description = "Append observations to named entities.")]
    async fn add_observations(
        &self,
        Parameters(a): Parameters<tools::AddObservationsArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let tenant = tenant_for(&ctx)?;
        tools::add_observations(&self.config, &tenant, a).await
    }

    #[tool(description = "Delete entities by name. Also removes relations touching them.")]
    async fn delete_entities(
        &self,
        Parameters(a): Parameters<tools::DeleteEntitiesArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let tenant = tenant_for(&ctx)?;
        tools::delete_entities(&self.config, &tenant, a).await
    }

    #[tool(description = "Remove specific observations from named entities.")]
    async fn delete_observations(
        &self,
        Parameters(a): Parameters<tools::DeleteObservationsArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let tenant = tenant_for(&ctx)?;
        tools::delete_observations(&self.config, &tenant, a).await
    }

    #[tool(description = "Remove specific (from, to, relationType) relations.")]
    async fn delete_relations(
        &self,
        Parameters(a): Parameters<tools::DeleteRelationsArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let tenant = tenant_for(&ctx)?;
        tools::delete_relations(&self.config, &tenant, a).await
    }

    #[tool(description = "Return the entire graph for the caller's tenant.")]
    async fn read_graph(
        &self,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let tenant = tenant_for(&ctx)?;
        tools::read_graph(&self.config, &tenant).await
    }

    #[tool(description = "Substring match over entity name / entityType / observations.")]
    async fn search_nodes(
        &self,
        Parameters(a): Parameters<tools::SearchNodesArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let tenant = tenant_for(&ctx)?;
        tools::search_nodes(&self.config, &tenant, a).await
    }

    #[tool(description = "Fetch named entities plus relations that touch at least one of them on both ends.")]
    async fn open_nodes(
        &self,
        Parameters(a): Parameters<tools::OpenNodesArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let tenant = tenant_for(&ctx)?;
        tools::open_nodes(&self.config, &tenant, a).await
    }
}

#[tool_handler]
impl ServerHandler for MemoryServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(INSTRUCTIONS)
    }
}
