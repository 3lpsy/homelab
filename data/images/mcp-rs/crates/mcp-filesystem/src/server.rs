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

pub const INSTRUCTIONS: &str = "Per-tenant sandboxed filesystem. Every tool takes a `session_id` string.\n\n\
SESSION_ID — pick a stable name per task (e.g. \"bug-42\", \"scratch-notes\") and REUSE IT across tool \
calls so files accumulate in one namespace. Different session_ids get different, isolated sandboxes; do \
NOT send a random UUID per call or your files will scatter. Allowed chars: [A-Za-z0-9._-], max \
MCP_MAX_SESSION_ID_CHARS (default 128).\n\nDESTRUCTIVE: `destroy_session` wipes every file in the \
session. Only call when the user explicitly asks to wipe it.";

pub struct Config {
    pub salt: Vec<u8>,
    pub data_root: PathBuf,
    pub max_file_bytes: usize,
    pub max_read_batch: usize,
    pub max_edits: usize,
    pub max_edit_bytes: usize,
    pub max_description: usize,
    pub max_tenant_bytes: usize,
    pub max_sessions: usize,
    pub max_dir_entries: usize,
    pub max_tree_depth: usize,
    pub max_tree_nodes: usize,
    pub max_search_hits: usize,
    pub max_session_id_chars: usize,
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
pub struct FsServer {
    pub config: Arc<Config>,
    #[allow(dead_code)]
    tool_router: ToolRouter<Self>,
}

impl FsServer {
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
impl FsServer {
    #[tool(description = "Read a UTF-8 text file within the session root.")]
    async fn read_file(
        &self,
        Parameters(a): Parameters<tools::ReadFileArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::read_file(&self.config, &t, a).await
    }

    #[tool(description = "Read several files in one call.")]
    async fn read_multiple_files(
        &self,
        Parameters(a): Parameters<tools::ReadMultipleArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::read_multiple_files(&self.config, &t, a).await
    }

    #[tool(description = "Write content to a file, creating parent dirs as needed.")]
    async fn write_file(
        &self,
        Parameters(a): Parameters<tools::WriteFileArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::write_file(&self.config, &t, a).await
    }

    #[tool(description = "Apply sequential {oldText, newText} line edits to a text file.")]
    async fn edit_file(
        &self,
        Parameters(a): Parameters<tools::EditFileArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::edit_file(&self.config, &t, a).await
    }

    #[tool(description = "Create a directory (and parents) inside the session root.")]
    async fn create_directory(
        &self,
        Parameters(a): Parameters<tools::CreateDirArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::create_directory(&self.config, &t, a).await
    }

    #[tool(description = "List entries: name + type (file/dir/symlink).")]
    async fn list_directory(
        &self,
        Parameters(a): Parameters<tools::ListDirArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::list_directory(&self.config, &t, a).await
    }

    #[tool(description = "Recursive nested listing.")]
    async fn directory_tree(
        &self,
        Parameters(a): Parameters<tools::DirTreeArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::directory_tree(&self.config, &t, a).await
    }

    #[tool(description = "Move/rename a file or directory within the session root.")]
    async fn move_file(
        &self,
        Parameters(a): Parameters<tools::MoveFileArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::move_file(&self.config, &t, a).await
    }

    #[tool(description = "Recursively search for names matching `pattern` (glob).")]
    async fn search_files(
        &self,
        Parameters(a): Parameters<tools::SearchFilesArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::search_files(&self.config, &t, a).await
    }

    #[tool(description = "Stat info for a path within the session root.")]
    async fn get_file_info(
        &self,
        Parameters(a): Parameters<tools::FileInfoArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::get_file_info(&self.config, &t, a).await
    }

    #[tool(description = "Return the visible roots for this session.")]
    async fn list_allowed_directories(
        &self,
        Parameters(a): Parameters<tools::ListAllowedArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::list_allowed_directories(&self.config, &t, a).await
    }

    #[tool(description = "Delete every file and directory in this session's root. Irreversible.")]
    async fn destroy_session(
        &self,
        Parameters(a): Parameters<tools::DestroySessionArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::destroy_session(&self.config, &t, a).await
    }

    #[tool(description = "Return every session known to this tenant.")]
    async fn list_sessions(
        &self,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::list_sessions(&self.config, &t).await
    }

    #[tool(description = "Set a human-readable description for a session.")]
    async fn describe_session(
        &self,
        Parameters(a): Parameters<tools::DescribeSessionArgs>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let t = tenant_for(&ctx)?;
        tools::describe_session(&self.config, &t, a).await
    }
}

#[tool_handler]
impl ServerHandler for FsServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(INSTRUCTIONS)
    }
}
