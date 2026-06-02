use std::path::{Path, PathBuf};
use std::sync::Arc;

use mcp_common::auth::TenantCtx;
use mcp_common::errors::{tool_internal, tool_invalid};
use mcp_common::tenant::hash_tenant;
use rmcp::ErrorData;

use crate::server::Config;

pub fn validate_session_id(cfg: &Arc<Config>, session_id: &str) -> Result<(), ErrorData> {
    let s = session_id.trim();
    if s.is_empty() {
        return Err(tool_invalid("session_id required"));
    }
    if s.len() > cfg.max_session_id_chars {
        return Err(tool_invalid(format!(
            "session_id too long ({} > MCP_MAX_SESSION_ID_CHARS={})",
            s.len(),
            cfg.max_session_id_chars
        )));
    }
    if !s
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        return Err(tool_invalid(
            "session_id must match [A-Za-z0-9._-]+ (no spaces or other chars)",
        ));
    }
    Ok(())
}

pub fn tenant_dir(cfg: &Arc<Config>, tenant: &TenantCtx) -> PathBuf {
    let h = hash_tenant(&cfg.salt, &tenant.api_key);
    cfg.data_root.join(h.as_str())
}

pub fn sessions_file(cfg: &Arc<Config>, tenant: &TenantCtx) -> PathBuf {
    tenant_dir(cfg, tenant).join("sessions.json")
}

pub fn session_root_path(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    session_id: &str,
) -> Result<PathBuf, ErrorData> {
    validate_session_id(cfg, session_id)?;
    let session_hash = hash_tenant(&cfg.salt, session_id);
    Ok(tenant_dir(cfg, tenant).join(session_hash.as_str()))
}

pub fn ensure_session_root(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    session_id: &str,
) -> Result<PathBuf, ErrorData> {
    let root = session_root_path(cfg, tenant, session_id)?;
    if !root.exists() {
        let sessions = load_sessions_sync(cfg, tenant);
        let already = sessions.iter().any(|s| s.session_id == session_id);
        if !already && sessions.len() >= cfg.max_sessions {
            return Err(tool_invalid(format!(
                "session count exceeded: {} >= MCP_MAX_SESSIONS_PER_TENANT={}",
                sessions.len(),
                cfg.max_sessions
            )));
        }
        std::fs::create_dir_all(&root).map_err(|e| tool_internal(format!("mkdir: {e}")))?;
        if !already {
            upsert_session(cfg, tenant, session_id, None);
        }
    }
    std::fs::canonicalize(&root).map_err(|e| tool_internal(format!("canonicalize: {e}")))
}

pub fn safe(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    session_id: &str,
    user_path: &str,
    must_exist: bool,
) -> Result<PathBuf, ErrorData> {
    let root = ensure_session_root(cfg, tenant, session_id)?;
    let rel = user_path.trim_start_matches('/');
    let candidate = root.join(rel);
    let real = if candidate.exists() {
        std::fs::canonicalize(&candidate).map_err(|e| tool_internal(format!("canonicalize: {e}")))?
    } else {
        canonicalize_parents(&candidate)
    };
    if real != root && !is_within(&real, &root) {
        return Err(tool_invalid(format!("path escapes session root: {user_path}")));
    }
    if !real.exists() {
        if must_exist {
            return Err(tool_invalid(format!("file not found: {user_path}")));
        }
        if let Some(parent) = real.parent() {
            std::fs::create_dir_all(parent).map_err(|e| tool_internal(format!("mkdir parent: {e}")))?;
        }
    }
    Ok(real)
}

pub fn reject_symlink(p: &Path) -> Result<(), ErrorData> {
    match std::fs::symlink_metadata(p) {
        Ok(md) if md.file_type().is_symlink() => Err(tool_invalid(format!(
            "refusing to operate on symlink: {}",
            p.file_name().and_then(|s| s.to_str()).unwrap_or("?")
        ))),
        _ => Ok(()),
    }
}

pub fn is_within(child: &Path, root: &Path) -> bool {
    child.starts_with(root)
}

pub fn display(p: &Path, root: &Path) -> String {
    match p.strip_prefix(root) {
        Ok(rel) => {
            let s = rel.to_string_lossy().to_string();
            if s.is_empty() || s == "." {
                "/".into()
            } else {
                format!("/{s}")
            }
        }
        Err(_) => p.to_string_lossy().to_string(),
    }
}

fn canonicalize_parents(p: &Path) -> PathBuf {
    let mut cur = p.to_path_buf();
    while !cur.exists() {
        match cur.parent() {
            Some(parent) if !parent.as_os_str().is_empty() => cur = parent.to_path_buf(),
            _ => return p.to_path_buf(),
        }
    }
    match std::fs::canonicalize(&cur) {
        Ok(real_parent) => {
            let suffix = p.strip_prefix(&cur).unwrap_or(p);
            real_parent.join(suffix)
        }
        Err(_) => p.to_path_buf(),
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SessionEntry {
    pub session_id: String,
    #[serde(default)]
    pub description: String,
}

pub fn load_sessions_sync(cfg: &Arc<Config>, tenant: &TenantCtx) -> Vec<SessionEntry> {
    let path = sessions_file(cfg, tenant);
    if !path.exists() {
        return Vec::new();
    }
    let Ok(body) = std::fs::read_to_string(&path) else {
        tracing::error!(path = %path.display(), "sessions.json unreadable, treating as empty");
        return Vec::new();
    };
    serde_json::from_str::<Vec<SessionEntry>>(&body).unwrap_or_default()
}

pub fn save_sessions_sync(cfg: &Arc<Config>, tenant: &TenantCtx, sessions: &[SessionEntry]) {
    let path = sessions_file(cfg, tenant);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let body = serde_json::to_string_pretty(sessions).unwrap_or_else(|_| "[]".into());
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    if std::fs::write(&tmp, body).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

pub fn upsert_session(cfg: &Arc<Config>, tenant: &TenantCtx, session_id: &str, description: Option<String>) {
    let mut sessions = load_sessions_sync(cfg, tenant);
    if let Some(s) = sessions.iter_mut().find(|s| s.session_id == session_id) {
        if let Some(d) = description {
            s.description = d;
        }
    } else {
        sessions.push(SessionEntry {
            session_id: session_id.to_string(),
            description: description.unwrap_or_default(),
        });
    }
    save_sessions_sync(cfg, tenant, &sessions);
}

pub fn remove_session(cfg: &Arc<Config>, tenant: &TenantCtx, session_id: &str) {
    let sessions = load_sessions_sync(cfg, tenant);
    let pruned: Vec<SessionEntry> = sessions
        .into_iter()
        .filter(|s| s.session_id != session_id)
        .collect();
    save_sessions_sync(cfg, tenant, &pruned);
}

pub fn tenant_usage(cfg: &Arc<Config>, tenant: &TenantCtx) -> u64 {
    let root = tenant_dir(cfg, tenant);
    if !root.exists() {
        return 0;
    }
    let sessions_idx = sessions_file(cfg, tenant);
    let mut total = 0u64;
    for entry in walkdir::WalkDir::new(&root).follow_links(false) {
        let Ok(e) = entry else { continue };
        if !e.file_type().is_file() {
            continue;
        }
        if e.path() == sessions_idx {
            continue;
        }
        if let Ok(md) = e.metadata() {
            total += md.len();
        }
    }
    total
}

pub fn check_quota(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    new_bytes: usize,
    replaced_bytes: usize,
) -> Result<(), ErrorData> {
    let cur = tenant_usage(cfg, tenant) as i64;
    let projected = cur - replaced_bytes as i64 + new_bytes as i64;
    if projected > cfg.max_tenant_bytes as i64 {
        return Err(tool_invalid(format!(
            "tenant disk quota exceeded: projected {projected} > MCP_MAX_TENANT_BYTES={}",
            cfg.max_tenant_bytes
        )));
    }
    Ok(())
}
