use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::model::{ServerCapabilities, ServerInfo};
use rmcp::{tool, tool_handler, tool_router, ServerHandler};

use crate::tools;

pub fn build_instructions(default_tz: &str) -> String {
    format!(
        "Wall-clock time helpers. No server-side state — every call is a pure function of the \
host clock + IANA tzdata.\n\nTools:\n  - `get_current_time(timezone)`: current time in the given \
zone.\n  - `convert_time(time, source_timezone, target_timezone)`: convert an `HH:MM` (24-hour) \
time from one zone to another using TODAY'S date in the source zone.\n\nConventions:\n  - \
Timezones are IANA names: \"America/New_York\", \"Europe/London\", \"UTC\", \"Asia/Kolkata\", \
\"Asia/Kathmandu\", ... NOT abbreviations like \"EST\", \"PST\", or UTC offsets like \
\"+05:30\".\n  - Time strings are 24-hour \"HH:MM\" — \"09:05\", \"17:30\", \"00:00\". NOT \
\"9am\", \"5:30 PM\", or seconds/milliseconds.\n  - Omit a timezone argument (or pass \"\") to \
use the server default: '{default_tz}'.\n\nOutputs include `timezone`, `datetime` (ISO 8601 \
with offset), `day_of_week` (English), and `is_dst`. `convert_time` also returns \
`time_difference` in the form \"+5.0h\", \"+5.5h\", \"+5.75h\"."
    )
}

#[derive(Clone)]
pub struct TimeServer {
    pub default_tz: String,
    instructions: String,
    #[allow(dead_code)]
    tool_router: ToolRouter<Self>,
}

impl TimeServer {
    pub fn new(default_tz: String) -> Self {
        let instructions = build_instructions(&default_tz);
        Self {
            default_tz,
            instructions,
            tool_router: Self::tool_router(),
        }
    }
}

#[tool_router]
impl TimeServer {
    #[tool(description = "Current wall-clock time in the given IANA timezone.")]
    async fn get_current_time(
        &self,
        params: rmcp::handler::server::wrapper::Parameters<tools::GetCurrentTime>,
    ) -> Result<rmcp::model::CallToolResult, rmcp::ErrorData> {
        tools::get_current_time(&self.default_tz, params.0).await
    }

    #[tool(description = "Convert HH:MM (today's date in source tz) between IANA timezones.")]
    async fn convert_time(
        &self,
        params: rmcp::handler::server::wrapper::Parameters<tools::ConvertTime>,
    ) -> Result<rmcp::model::CallToolResult, rmcp::ErrorData> {
        tools::convert_time(&self.default_tz, params.0).await
    }
}

#[tool_handler]
impl ServerHandler for TimeServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(self.instructions.clone())
    }
}
