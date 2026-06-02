// Identical to the mcp-time common helper — duplicated because CARGO_BIN_EXE_*
// is bound at the bin-owning crate's compile time.

use std::net::TcpListener;
use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, Instant};

use tokio::process::{Child, Command};

pub fn pick_port() -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").expect("bind 0");
    let port = l.local_addr().unwrap().port();
    drop(l);
    port
}

pub struct Server {
    pub child: Child,
    pub port: u16,
    pub api_key: String,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

pub async fn wait_ready(port: u16, deadline: Duration) -> Result<(), String> {
    let start = Instant::now();
    let client = reqwest::Client::new();
    loop {
        if start.elapsed() > deadline {
            return Err(format!("server on :{port} never came up"));
        }
        if let Ok(r) = client
            .get(format!("http://127.0.0.1:{port}/healthz"))
            .send()
            .await
        {
            if r.status().is_success() {
                return Ok(());
            }
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

pub async fn spawn_bin(
    bin: &Path,
    api_key: &str,
    extra_env: &[(&str, &str)],
) -> Result<Server, String> {
    let port = pick_port();
    let mut cmd = Command::new(bin);
    cmd.env("MCP_HOST", "127.0.0.1");
    cmd.env("MCP_PORT", port.to_string());
    cmd.env("MCP_API_KEYS", api_key);
    cmd.env("RUST_LOG", "warn");
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::piped());
    let child = cmd.spawn().map_err(|e| format!("spawn: {e}"))?;
    let s = Server {
        child,
        port,
        api_key: api_key.to_string(),
    };
    wait_ready(port, Duration::from_secs(10)).await?;
    Ok(s)
}

pub async fn initialize(srv: &Server) -> Result<(reqwest::Client, String), String> {
    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("client: {e}"))?;
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "it", "version": "1.0"},
        }
    });
    let resp = client
        .post(format!("http://127.0.0.1:{}/", srv.port))
        .header("Authorization", format!("Bearer {}", srv.api_key))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .body(body.to_string())
        .send()
        .await
        .map_err(|e| format!("init send: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("init bad status: {}", resp.status()));
    }
    let session_id = resp
        .headers()
        .get("mcp-session-id")
        .and_then(|v| v.to_str().ok())
        .ok_or("no session id")?
        .to_string();
    let initialized = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": {},
    });
    client
        .post(format!("http://127.0.0.1:{}/", srv.port))
        .header("Authorization", format!("Bearer {}", srv.api_key))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Mcp-Session-Id", &session_id)
        .body(initialized.to_string())
        .send()
        .await
        .map_err(|e| format!("initialized send: {e}"))?;
    Ok((client, session_id))
}

pub async fn call_tool(
    srv: &Server,
    client: &reqwest::Client,
    session_id: &str,
    name: &str,
    args: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": { "name": name, "arguments": args },
    });
    let resp = client
        .post(format!("http://127.0.0.1:{}/", srv.port))
        .header("Authorization", format!("Bearer {}", srv.api_key))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Mcp-Session-Id", session_id)
        .body(body.to_string())
        .send()
        .await
        .map_err(|e| format!("tools/call: {e}"))?;
    let text = resp.text().await.map_err(|e| format!("body: {e}"))?;
    Ok(parse_first_json(&text))
}

fn parse_first_json(text: &str) -> serde_json::Value {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(text) {
        return v;
    }
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("data:") {
            let s = rest.trim();
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(s) {
                return v;
            }
        }
    }
    serde_json::Value::Null
}
