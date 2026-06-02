use std::path::PathBuf;
use std::sync::Arc;

use glob::Pattern;
use rmcp::model::{CallToolResult, Content};
use rmcp::ErrorData;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;

use mcp_common::auth::TenantCtx;
use mcp_common::errors::{tool_internal, tool_invalid};
use mcp_common::tenant::hash_tenant;

use crate::edit::{apply_one, normalize_line_endings, unified_diff, validate_edits, EditOp};
use crate::sandbox::{
    check_quota, display, ensure_session_root, load_sessions_sync, reject_symlink, remove_session,
    safe, save_sessions_sync, session_root_path, tenant_dir as sandbox_tenant_dir, upsert_session,
};
use crate::server::Config;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ReadFileArgs {
    pub session_id: String,
    pub path: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ReadMultipleArgs {
    pub session_id: String,
    pub paths: Vec<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct WriteFileArgs {
    pub session_id: String,
    pub path: String,
    pub content: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct EditFileArgs {
    pub session_id: String,
    pub path: String,
    pub edits: Vec<EditOp>,
    #[serde(default)]
    pub dry_run: bool,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CreateDirArgs {
    pub session_id: String,
    pub path: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ListDirArgs {
    pub session_id: String,
    #[serde(default = "dot")]
    pub path: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DirTreeArgs {
    pub session_id: String,
    #[serde(default = "dot")]
    pub path: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct MoveFileArgs {
    pub session_id: String,
    pub source: String,
    pub destination: String,
    #[serde(default)]
    pub overwrite: bool,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SearchFilesArgs {
    pub session_id: String,
    pub pattern: String,
    #[serde(default = "dot")]
    pub path: String,
    #[serde(default)]
    pub exclude_patterns: Option<Vec<String>>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct FileInfoArgs {
    pub session_id: String,
    pub path: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ListAllowedArgs {
    pub session_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DestroySessionArgs {
    pub session_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DescribeSessionArgs {
    pub session_id: String,
    pub description: String,
}

fn dot() -> String {
    ".".into()
}

fn tenant_hash_str(cfg: &Arc<Config>, t: &TenantCtx) -> String {
    hash_tenant(&cfg.salt, &t.api_key).as_str().to_string()
}

fn json_ok<T: Serialize>(v: &T) -> Result<CallToolResult, ErrorData> {
    let text = serde_json::to_string(v).map_err(|e| tool_internal(format!("serialize: {e}")))?;
    Ok(CallToolResult::success(vec![Content::text(text)]))
}

fn text_ok(s: impl Into<String>) -> Result<CallToolResult, ErrorData> {
    Ok(CallToolResult::success(vec![Content::text(s.into())]))
}

pub async fn read_file(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: ReadFileArgs,
) -> Result<CallToolResult, ErrorData> {
    let p = safe(cfg, t, &args.session_id, &args.path, true)?;
    reject_symlink(&p)?;
    let md = std::fs::metadata(&p).map_err(|e| tool_internal(format!("stat: {e}")))?;
    if md.len() as usize > cfg.max_file_bytes {
        return Err(tool_invalid(format!(
            "file exceeds MCP_MAX_FILE_BYTES ({} > {})",
            md.len(),
            cfg.max_file_bytes
        )));
    }
    let body = std::fs::read_to_string(&p).map_err(|e| tool_invalid(format!("read: {e}")))?;
    text_ok(body)
}

pub async fn read_multiple_files(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: ReadMultipleArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.paths.len() > cfg.max_read_batch {
        return Err(tool_invalid(format!(
            "too many paths ({} > MCP_MAX_READ_BATCH={})",
            args.paths.len(),
            cfg.max_read_batch
        )));
    }
    let mut out = serde_json::Map::new();
    for rel in &args.paths {
        let v = match (|| -> Result<String, String> {
            let p = safe(cfg, t, &args.session_id, rel, true)
                .map_err(|e| format!("ValueError: {}", e.message))?;
            reject_symlink(&p).map_err(|e| format!("PermissionError: {}", e.message))?;
            let md = std::fs::metadata(&p).map_err(|e| format!("OSError: {e}"))?;
            if md.len() as usize > cfg.max_file_bytes {
                return Err(format!(
                    "ValueError: file exceeds MCP_MAX_FILE_BYTES ({} > {})",
                    md.len(),
                    cfg.max_file_bytes
                ));
            }
            std::fs::read_to_string(&p).map_err(|e| format!("OSError: {e}"))
        })() {
            Ok(s) => json!({ "ok": true, "content": s }),
            Err(e) => json!({ "ok": false, "error": e }),
        };
        out.insert(rel.clone(), v);
    }
    json_ok(&serde_json::Value::Object(out))
}

pub async fn write_file(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: WriteFileArgs,
) -> Result<CallToolResult, ErrorData> {
    let n = args.content.len();
    if n > cfg.max_file_bytes {
        return Err(tool_invalid(format!(
            "content exceeds MCP_MAX_FILE_BYTES ({n} > {})",
            cfg.max_file_bytes
        )));
    }
    let lock = cfg.tenant_lock(&tenant_hash_str(cfg, t));
    let _g = lock.lock().await;
    let p = safe(cfg, t, &args.session_id, &args.path, false)?;
    let mut replaced = 0usize;
    if p.exists() {
        reject_symlink(&p)?;
        replaced = std::fs::metadata(&p).map(|m| m.len() as usize).unwrap_or(0);
    }
    check_quota(cfg, t, n, replaced)?;
    let tmp = p.with_extension(format!("tmp.{}", std::process::id()));
    std::fs::write(&tmp, &args.content).map_err(|e| tool_internal(format!("write: {e}")))?;
    std::fs::rename(&tmp, &p).map_err(|e| tool_internal(format!("rename: {e}")))?;
    let root = ensure_session_root(cfg, t, &args.session_id)?;
    json_ok(&json!({ "path": display(&p, &root), "bytes": n }))
}

pub async fn edit_file(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: EditFileArgs,
) -> Result<CallToolResult, ErrorData> {
    validate_edits(cfg, &args.edits)?;
    let lock = cfg.tenant_lock(&tenant_hash_str(cfg, t));
    let _g = lock.lock().await;
    let p = safe(cfg, t, &args.session_id, &args.path, true)?;
    reject_symlink(&p)?;
    let md = std::fs::metadata(&p).map_err(|e| tool_internal(format!("stat: {e}")))?;
    if md.len() as usize > cfg.max_file_bytes {
        return Err(tool_invalid(format!(
            "file exceeds MCP_MAX_FILE_BYTES ({} > {})",
            md.len(),
            cfg.max_file_bytes
        )));
    }
    let raw = std::fs::read_to_string(&p).map_err(|e| tool_invalid(format!("read: {e}")))?;
    let had_crlf = raw.contains("\r\n");
    let original = normalize_line_endings(&raw);
    let mut modified = original.clone();
    for edit in &args.edits {
        match apply_one(&modified, edit) {
            Some(m) => modified = m,
            None => {
                return Err(tool_invalid(format!(
                    "Could not find exact match for edit:\n{}",
                    edit.old_text
                )));
            }
        }
    }
    let root = ensure_session_root(cfg, t, &args.session_id)?;
    let diff = unified_diff(&original, &modified, &display(&p, &root));
    let out = if had_crlf {
        modified.replace('\n', "\r\n")
    } else {
        modified.clone()
    };
    if out.len() > cfg.max_file_bytes {
        return Err(tool_invalid(format!(
            "edited content exceeds MCP_MAX_FILE_BYTES ({} > {})",
            out.len(),
            cfg.max_file_bytes
        )));
    }
    if !args.dry_run {
        check_quota(cfg, t, out.len(), md.len() as usize)?;
        let tmp = p.with_extension(format!("tmp.{}", std::process::id()));
        std::fs::write(&tmp, &out).map_err(|e| tool_internal(format!("write: {e}")))?;
        std::fs::rename(&tmp, &p).map_err(|e| tool_internal(format!("rename: {e}")))?;
    }
    let mut fence = String::from("```");
    while diff.contains(&fence) {
        fence.push('`');
    }
    text_ok(format!("{fence}diff\n{diff}{fence}\n\n"))
}

pub async fn create_directory(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: CreateDirArgs,
) -> Result<CallToolResult, ErrorData> {
    let p = safe(cfg, t, &args.session_id, &args.path, false)?;
    std::fs::create_dir_all(&p).map_err(|e| tool_internal(format!("mkdir: {e}")))?;
    let root = ensure_session_root(cfg, t, &args.session_id)?;
    json_ok(&json!({ "path": display(&p, &root) }))
}

pub async fn list_directory(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: ListDirArgs,
) -> Result<CallToolResult, ErrorData> {
    let p = safe(cfg, t, &args.session_id, &args.path, true)?;
    if !p.is_dir() {
        return Err(tool_invalid(format!("not a directory: {}", args.path)));
    }
    let mut entries: Vec<(String, String)> = Vec::new();
    let mut truncated = false;
    for de in std::fs::read_dir(&p).map_err(|e| tool_internal(format!("read_dir: {e}")))? {
        if entries.len() >= cfg.max_dir_entries {
            truncated = true;
            break;
        }
        let Ok(de) = de else { continue };
        let name = de.file_name().to_string_lossy().to_string();
        let md = de.metadata().ok();
        let typ = if md
            .as_ref()
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(false)
        {
            "symlink"
        } else if md.as_ref().map(|m| m.is_dir()).unwrap_or(false) {
            "dir"
        } else {
            "file"
        };
        entries.push((name, typ.to_string()));
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let mut result: Vec<serde_json::Value> = entries
        .into_iter()
        .map(|(n, t)| json!({ "name": n, "type": t }))
        .collect();
    if truncated {
        result.push(json!({ "name": "...", "type": "truncated" }));
    }
    json_ok(&result)
}

pub async fn directory_tree(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: DirTreeArgs,
) -> Result<CallToolResult, ErrorData> {
    let p = safe(cfg, t, &args.session_id, &args.path, true)?;
    if !p.is_dir() {
        return Err(tool_invalid(format!("not a directory: {}", args.path)));
    }
    let mut counter = 0usize;
    let nodes = walk(&p, 0, cfg, &mut counter);
    json_ok(&nodes)
}

fn walk(d: &std::path::Path, depth: usize, cfg: &Arc<Config>, counter: &mut usize) -> Vec<serde_json::Value> {
    if *counter >= cfg.max_tree_nodes {
        return vec![json!({ "name": "...", "type": "truncated" })];
    }
    let mut names: Vec<String> = Vec::new();
    let mut per_dir_truncated = false;
    if let Ok(rd) = std::fs::read_dir(d) {
        for entry in rd {
            if names.len() >= cfg.max_dir_entries {
                per_dir_truncated = true;
                break;
            }
            let Ok(e) = entry else { continue };
            names.push(e.file_name().to_string_lossy().to_string());
        }
    }
    names.sort();
    let mut nodes: Vec<serde_json::Value> = Vec::new();
    for name in names {
        if *counter >= cfg.max_tree_nodes {
            nodes.push(json!({ "name": "...", "type": "truncated" }));
            return nodes;
        }
        *counter += 1;
        let child = d.join(&name);
        let md = std::fs::symlink_metadata(&child).ok();
        let is_link = md.as_ref().map(|m| m.file_type().is_symlink()).unwrap_or(false);
        let is_dir = !is_link && md.as_ref().map(|m| m.is_dir()).unwrap_or(false);
        if is_dir {
            if depth >= cfg.max_tree_depth {
                nodes.push(json!({
                    "name": name,
                    "type": "dir",
                    "children": [{ "name": "...", "type": "truncated" }],
                }));
            } else {
                nodes.push(json!({
                    "name": name,
                    "type": "dir",
                    "children": walk(&child, depth + 1, cfg, counter),
                }));
            }
        } else {
            let typ = if is_link { "symlink" } else { "file" };
            nodes.push(json!({ "name": name, "type": typ }));
        }
    }
    if per_dir_truncated {
        nodes.push(json!({ "name": "...", "type": "truncated" }));
    }
    nodes
}

pub async fn move_file(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: MoveFileArgs,
) -> Result<CallToolResult, ErrorData> {
    let src = safe(cfg, t, &args.session_id, &args.source, true)?;
    reject_symlink(&src)?;
    let dst = safe(cfg, t, &args.session_id, &args.destination, false)?;
    if dst.exists() {
        reject_symlink(&dst)?;
        if !args.overwrite {
            return Err(tool_invalid(format!(
                "destination exists (pass overwrite=True to replace): {}",
                args.destination
            )));
        }
    }
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent).map_err(|e| tool_internal(format!("mkdir: {e}")))?;
    }
    std::fs::rename(&src, &dst).map_err(|e| tool_internal(format!("rename: {e}")))?;
    let root = ensure_session_root(cfg, t, &args.session_id)?;
    json_ok(&json!({
        "source": display(&src, &root),
        "destination": display(&dst, &root),
    }))
}

pub async fn search_files(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: SearchFilesArgs,
) -> Result<CallToolResult, ErrorData> {
    let root_path = safe(cfg, t, &args.session_id, &args.path, true)?;
    if !root_path.is_dir() {
        return Err(tool_invalid(format!("not a directory: {}", args.path)));
    }
    let pat = Pattern::new(&args.pattern).map_err(|e| tool_invalid(format!("bad pattern: {e}")))?;
    let excludes: Vec<Pattern> = args
        .exclude_patterns
        .unwrap_or_default()
        .iter()
        .filter_map(|p| Pattern::new(p).ok())
        .collect();
    let session_root = ensure_session_root(cfg, t, &args.session_id)?;
    let mut hits: Vec<String> = Vec::new();
    let mut truncated = false;
    // `filter_entry` prunes recursion: when an excluded dir is rejected here,
    // walkdir does not descend into it. Matches Python's `dirnames[:] = [...]`
    // mutation in `os.walk`.
    let walker = walkdir::WalkDir::new(&root_path)
        .follow_links(false)
        .into_iter()
        .filter_entry(|e| {
            if e.file_type().is_symlink() {
                return false;
            }
            let name = e.file_name().to_string_lossy();
            !excludes.iter().any(|g| g.matches(&name))
        });
    for entry in walker {
        let Ok(e) = entry else { continue };
        if e.file_type().is_symlink() {
            continue;
        }
        let name_os = e.file_name();
        let name = name_os.to_string_lossy();
        if pat.matches(&name) {
            hits.push(display(e.path(), &session_root));
            if hits.len() >= cfg.max_search_hits {
                truncated = true;
                break;
            }
        }
    }
    hits.sort();
    if truncated {
        hits.push(format!("... (truncated at {})", cfg.max_search_hits));
    }
    json_ok(&hits)
}

pub async fn get_file_info(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: FileInfoArgs,
) -> Result<CallToolResult, ErrorData> {
    let p = safe(cfg, t, &args.session_id, &args.path, true)?;
    reject_symlink(&p)?;
    let md = std::fs::metadata(&p).map_err(|e| tool_internal(format!("stat: {e}")))?;
    let root = ensure_session_root(cfg, t, &args.session_id)?;
    let typ = if md.is_dir() { "dir" } else { "file" };
    use std::os::unix::fs::MetadataExt;
    json_ok(&json!({
        "path": display(&p, &root),
        "type": typ,
        "size": md.len(),
        "mtime": md.mtime() as f64 + (md.mtime_nsec() as f64 / 1e9),
        "ctime": md.ctime() as f64 + (md.ctime_nsec() as f64 / 1e9),
        "mode": format!("0o{:o}", md.mode()),
    }))
}

pub async fn list_allowed_directories(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: ListAllowedArgs,
) -> Result<CallToolResult, ErrorData> {
    // Validate session_id shape without creating the dir.
    let _ = session_root_path(cfg, t, &args.session_id)?;
    json_ok(&vec!["/".to_string()])
}

pub async fn destroy_session(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: DestroySessionArgs,
) -> Result<CallToolResult, ErrorData> {
    let root: PathBuf = session_root_path(cfg, t, &args.session_id)?;
    if !root.exists() {
        remove_session(cfg, t, &args.session_id);
        return json_ok(&json!({ "session_id": args.session_id, "removed": false }));
    }
    std::fs::remove_dir_all(&root).map_err(|e| tool_internal(format!("rmdir: {e}")))?;
    remove_session(cfg, t, &args.session_id);
    json_ok(&json!({ "session_id": args.session_id, "removed": true }))
}

pub async fn list_sessions(cfg: &Arc<Config>, t: &TenantCtx) -> Result<CallToolResult, ErrorData> {
    let _ = sandbox_tenant_dir(cfg, t);
    let sessions = load_sessions_sync(cfg, t);
    json_ok(&sessions)
}

pub async fn describe_session(
    cfg: &Arc<Config>,
    t: &TenantCtx,
    args: DescribeSessionArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.description.len() > cfg.max_description {
        return Err(tool_invalid(format!(
            "description exceeds {} chars (got {})",
            cfg.max_description,
            args.description.len()
        )));
    }
    ensure_session_root(cfg, t, &args.session_id)?;
    upsert_session(cfg, t, &args.session_id, Some(args.description.clone()));
    // touch save_sessions_sync via upsert_session above.
    let _ = save_sessions_sync;
    json_ok(&json!({
        "session_id": args.session_id,
        "description": args.description,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg_with(tmp: &std::path::Path) -> Arc<Config> {
        Arc::new(Config {
            salt: b"saltsalt".to_vec(),
            data_root: tmp.to_path_buf(),
            max_file_bytes: 10 * 1024 * 1024,
            max_read_batch: 32,
            max_edits: 64,
            max_edit_bytes: 256 * 1024,
            max_description: 1024,
            max_tenant_bytes: 16 * 1024 * 1024,
            max_sessions: 16,
            max_dir_entries: 2000,
            max_tree_depth: 32,
            max_tree_nodes: 5000,
            max_search_hits: 2000,
            max_session_id_chars: 128,
            locks: dashmap::DashMap::new(),
        })
    }

    fn tenant(s: &str) -> TenantCtx {
        TenantCtx { api_key: Arc::from(s) }
    }

    #[tokio::test]
    async fn write_then_read() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = cfg_with(dir.path());
        let t = tenant("k1");
        write_file(
            &cfg,
            &t,
            WriteFileArgs {
                session_id: "s1".into(),
                path: "hello.txt".into(),
                content: "hi there".into(),
            },
        )
        .await
        .unwrap();
        let r = read_file(
            &cfg,
            &t,
            ReadFileArgs {
                session_id: "s1".into(),
                path: "hello.txt".into(),
            },
        )
        .await
        .unwrap();
        let json = serde_json::to_string(&r).unwrap();
        assert!(json.contains("hi there"));
    }

    #[tokio::test]
    async fn rejects_escape() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = cfg_with(dir.path());
        let t = tenant("k1");
        let r = read_file(
            &cfg,
            &t,
            ReadFileArgs {
                session_id: "s1".into(),
                path: "../../etc/passwd".into(),
            },
        )
        .await;
        assert!(r.is_err());
    }
}
