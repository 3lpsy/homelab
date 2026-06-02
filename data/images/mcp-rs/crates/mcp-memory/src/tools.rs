use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;

use rmcp::model::{CallToolResult, Content};
use rmcp::ErrorData;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use mcp_common::auth::TenantCtx;
use mcp_common::errors::{tool_internal, tool_invalid};
use mcp_common::tenant::hash_tenant;

use crate::graph::{rel_key, Entity, Graph, Relation};
use crate::server::Config;

// --- arg structs ---

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CreateEntitiesArgs {
    pub entities: Vec<Entity>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CreateRelationsArgs {
    pub relations: Vec<Relation>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ObservationAdd {
    #[serde(rename = "entityName")]
    pub entity_name: String,
    pub contents: Vec<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct AddObservationsArgs {
    pub observations: Vec<ObservationAdd>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DeleteEntitiesArgs {
    #[serde(rename = "entityNames")]
    pub entity_names: Vec<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ObservationDelete {
    #[serde(rename = "entityName")]
    pub entity_name: String,
    pub observations: Vec<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DeleteObservationsArgs {
    pub deletions: Vec<ObservationDelete>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct DeleteRelationsArgs {
    pub relations: Vec<Relation>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SearchNodesArgs {
    pub query: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct OpenNodesArgs {
    pub names: Vec<String>,
}

// --- helpers ---

fn tenant_dir(cfg: &Arc<Config>, tenant: &TenantCtx) -> PathBuf {
    let h = hash_tenant(&cfg.salt, &tenant.api_key);
    cfg.data_root.join(h.as_str())
}

fn memory_path(cfg: &Arc<Config>, tenant: &TenantCtx) -> PathBuf {
    tenant_dir(cfg, tenant).join("memory.jsonl")
}

fn tenant_hash(cfg: &Arc<Config>, tenant: &TenantCtx) -> String {
    hash_tenant(&cfg.salt, &tenant.api_key).as_str().to_string()
}

async fn load(cfg: &Arc<Config>, tenant: &TenantCtx) -> Result<Graph, ErrorData> {
    let path = memory_path(cfg, tenant);
    match tokio::fs::metadata(&path).await {
        Ok(md) => {
            if md.len() as usize > cfg.max_graph_bytes {
                return Err(tool_invalid(format!(
                    "memory graph is too large to load ({} bytes, limit {}). Delete entities or observations, or ask the admin to raise MCP_MAX_GRAPH_BYTES.",
                    md.len(),
                    cfg.max_graph_bytes
                )));
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Graph::new()),
        Err(e) => return Err(tool_internal(format!("memory graph stat: {e}"))),
    }
    let bytes = tokio::fs::read_to_string(&path)
        .await
        .map_err(|e| tool_internal(format!("memory graph read: {e}")))?;
    Ok(Graph::from_ndjson(&bytes))
}

async fn save(cfg: &Arc<Config>, tenant: &TenantCtx, g: &Graph) -> Result<(), ErrorData> {
    let dir = tenant_dir(cfg, tenant);
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| tool_internal(format!("mkdir: {e}")))?;
    let body = g.to_ndjson();
    if body.len() > cfg.max_graph_bytes {
        return Err(tool_invalid(format!(
            "write would exceed memory graph size limit ({} bytes, limit {}). Delete some entities or observations, or ask the admin to raise MCP_MAX_GRAPH_BYTES.",
            body.len(),
            cfg.max_graph_bytes
        )));
    }
    let target = memory_path(cfg, tenant);
    let tmp = dir.join(format!(
        "memory.jsonl.{}.tmp",
        std::process::id()
    ));
    tokio::fs::write(&tmp, body.as_bytes())
        .await
        .map_err(|e| tool_internal(format!("memory graph write: {e}")))?;
    tokio::fs::rename(&tmp, &target)
        .await
        .map_err(|e| tool_internal(format!("memory graph rename: {e}")))
}

fn check_str_caps(cfg: &Arc<Config>, s: &str, label: &str) -> Result<(), ErrorData> {
    if s.is_empty() {
        return Err(tool_invalid(format!("{label} must be non-empty")));
    }
    if s.len() > cfg.max_string {
        return Err(tool_invalid(format!(
            "{label} exceeds MCP_MAX_STRING_CHARS={}",
            cfg.max_string
        )));
    }
    Ok(())
}

fn json_ok<T: Serialize>(v: &T) -> Result<CallToolResult, ErrorData> {
    let text = serde_json::to_string(v).map_err(|e| tool_internal(format!("serialize: {e}")))?;
    Ok(CallToolResult::success(vec![Content::text(text)]))
}

// --- tools ---

pub async fn create_entities(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    args: CreateEntitiesArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.entities.is_empty() || args.entities.len() > cfg.max_entities {
        return Err(tool_invalid(format!(
            "entities length 1..={}",
            cfg.max_entities
        )));
    }
    for e in &args.entities {
        check_str_caps(cfg, &e.name, "entity.name")?;
        check_str_caps(cfg, &e.entity_type, "entity.entityType")?;
        for o in &e.observations {
            check_str_caps(cfg, o, "observation")?;
        }
    }
    let lock = cfg.tenant_lock(&tenant_hash(cfg, tenant));
    let _g = lock.lock().await;

    let mut g = load(cfg, tenant).await?;
    let mut have: HashSet<String> = g.entities.iter().map(|e| e.name.clone()).collect();
    let mut added: Vec<Entity> = Vec::new();
    for e in args.entities {
        if have.contains(&e.name) {
            continue;
        }
        have.insert(e.name.clone());
        added.push(e.clone());
        g.entities.push(e);
    }
    save(cfg, tenant, &g).await?;
    json_ok(&added)
}

pub async fn create_relations(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    args: CreateRelationsArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.relations.is_empty() || args.relations.len() > cfg.max_relations {
        return Err(tool_invalid(format!(
            "relations length 1..={}",
            cfg.max_relations
        )));
    }
    for r in &args.relations {
        check_str_caps(cfg, &r.from, "relation.from")?;
        check_str_caps(cfg, &r.to, "relation.to")?;
        check_str_caps(cfg, &r.relation_type, "relation.relationType")?;
    }
    let lock = cfg.tenant_lock(&tenant_hash(cfg, tenant));
    let _g = lock.lock().await;
    let mut g = load(cfg, tenant).await?;
    let mut have: HashSet<(String, String, String)> = g.relations.iter().map(rel_key).collect();
    let mut added: Vec<Relation> = Vec::new();
    for r in args.relations {
        let k = rel_key(&r);
        if have.contains(&k) {
            continue;
        }
        have.insert(k);
        added.push(r.clone());
        g.relations.push(r);
    }
    save(cfg, tenant, &g).await?;
    json_ok(&added)
}

pub async fn add_observations(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    args: AddObservationsArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.observations.is_empty() || args.observations.len() > cfg.max_observations {
        return Err(tool_invalid(format!(
            "observations length 1..={}",
            cfg.max_observations
        )));
    }
    let lock = cfg.tenant_lock(&tenant_hash(cfg, tenant));
    let _g = lock.lock().await;
    let mut g = load(cfg, tenant).await?;
    let mut result: Vec<serde_json::Value> = Vec::new();
    for op in &args.observations {
        check_str_caps(cfg, &op.entity_name, "entityName")?;
        for c in &op.contents {
            check_str_caps(cfg, c, "content")?;
        }
        let Some(ent) = g.entities.iter_mut().find(|e| e.name == op.entity_name) else {
            return Err(tool_invalid(format!(
                "entity {:?} does not exist — create it first with create_entities, or check spelling with read_graph/search_nodes",
                op.entity_name
            )));
        };
        let existing: HashSet<String> = ent.observations.iter().cloned().collect();
        let added: Vec<String> = op
            .contents
            .iter()
            .filter(|c| !existing.contains(*c))
            .cloned()
            .collect();
        ent.observations.extend(added.iter().cloned());
        result.push(serde_json::json!({
            "entityName": op.entity_name,
            "addedObservations": added,
        }));
    }
    save(cfg, tenant, &g).await?;
    json_ok(&result)
}

pub async fn delete_entities(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    args: DeleteEntitiesArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.entity_names.is_empty() || args.entity_names.len() > cfg.max_names {
        return Err(tool_invalid(format!(
            "entityNames length 1..={}",
            cfg.max_names
        )));
    }
    let lock = cfg.tenant_lock(&tenant_hash(cfg, tenant));
    let _g = lock.lock().await;
    let mut g = load(cfg, tenant).await?;
    let targets: HashSet<String> = args.entity_names.into_iter().collect();
    let before_e = g.entities.len();
    let before_r = g.relations.len();
    g.entities.retain(|e| !targets.contains(&e.name));
    g.relations
        .retain(|r| !(targets.contains(&r.from) || targets.contains(&r.to)));
    save(cfg, tenant, &g).await?;
    json_ok(&serde_json::json!({
        "entitiesRemoved": before_e - g.entities.len(),
        "relationsRemoved": before_r - g.relations.len(),
    }))
}

pub async fn delete_observations(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    args: DeleteObservationsArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.deletions.is_empty() || args.deletions.len() > cfg.max_observations {
        return Err(tool_invalid(format!(
            "deletions length 1..={}",
            cfg.max_observations
        )));
    }
    let lock = cfg.tenant_lock(&tenant_hash(cfg, tenant));
    let _g = lock.lock().await;
    let mut g = load(cfg, tenant).await?;
    let mut removed = 0usize;
    for op in &args.deletions {
        check_str_caps(cfg, &op.entity_name, "entityName")?;
        let Some(ent) = g.entities.iter_mut().find(|e| e.name == op.entity_name) else {
            return Err(tool_invalid(format!(
                "entity {:?} does not exist — check spelling with read_graph/search_nodes",
                op.entity_name
            )));
        };
        let drop_set: HashSet<&String> = op.observations.iter().collect();
        let before = ent.observations.len();
        ent.observations.retain(|o| !drop_set.contains(o));
        removed += before - ent.observations.len();
    }
    save(cfg, tenant, &g).await?;
    json_ok(&serde_json::json!({ "observationsRemoved": removed }))
}

pub async fn delete_relations(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    args: DeleteRelationsArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.relations.is_empty() || args.relations.len() > cfg.max_relations {
        return Err(tool_invalid(format!(
            "relations length 1..={}",
            cfg.max_relations
        )));
    }
    let lock = cfg.tenant_lock(&tenant_hash(cfg, tenant));
    let _g = lock.lock().await;
    let mut g = load(cfg, tenant).await?;
    let drop: HashSet<(String, String, String)> = args.relations.iter().map(rel_key).collect();
    let before = g.relations.len();
    g.relations.retain(|r| !drop.contains(&rel_key(r)));
    let removed = before - g.relations.len();
    save(cfg, tenant, &g).await?;
    json_ok(&serde_json::json!({ "relationsRemoved": removed }))
}

pub async fn read_graph(cfg: &Arc<Config>, tenant: &TenantCtx) -> Result<CallToolResult, ErrorData> {
    let g = load(cfg, tenant).await?;
    json_ok(&g)
}

pub async fn search_nodes(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    args: SearchNodesArgs,
) -> Result<CallToolResult, ErrorData> {
    let q = args.query.trim().to_lowercase();
    if q.is_empty() {
        return Err(tool_invalid("query must contain at least one non-whitespace character"));
    }
    if q.len() > cfg.max_query {
        return Err(tool_invalid(format!("query exceeds MCP_MAX_QUERY_CHARS={}", cfg.max_query)));
    }
    let g = load(cfg, tenant).await?;
    let hits: Vec<Entity> = g
        .entities
        .iter()
        .filter(|e| {
            e.name.to_lowercase().contains(&q)
                || e.entity_type.to_lowercase().contains(&q)
                || e.observations.iter().any(|o| o.to_lowercase().contains(&q))
        })
        .cloned()
        .collect();
    let names: HashSet<String> = hits.iter().map(|e| e.name.clone()).collect();
    let rels: Vec<Relation> = g
        .relations
        .iter()
        .filter(|r| names.contains(&r.from) && names.contains(&r.to))
        .cloned()
        .collect();
    json_ok(&Graph {
        entities: hits,
        relations: rels,
    })
}

pub async fn open_nodes(
    cfg: &Arc<Config>,
    tenant: &TenantCtx,
    args: OpenNodesArgs,
) -> Result<CallToolResult, ErrorData> {
    if args.names.is_empty() || args.names.len() > cfg.max_names {
        return Err(tool_invalid(format!("names length 1..={}", cfg.max_names)));
    }
    let g = load(cfg, tenant).await?;
    let wanted: HashSet<String> = args.names.into_iter().collect();
    let ents: Vec<Entity> = g
        .entities
        .iter()
        .filter(|e| wanted.contains(&e.name))
        .cloned()
        .collect();
    let present: HashSet<String> = ents.iter().map(|e| e.name.clone()).collect();
    let rels: Vec<Relation> = g
        .relations
        .iter()
        .filter(|r| present.contains(&r.from) && present.contains(&r.to))
        .cloned()
        .collect();
    json_ok(&Graph {
        entities: ents,
        relations: rels,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn cfg_with(tmp: &std::path::Path) -> Arc<Config> {
        Arc::new(Config {
            salt: b"saltsalt".to_vec(),
            data_root: tmp.to_path_buf(),
            max_graph_bytes: 1024 * 1024,
            max_entities: 64,
            max_relations: 64,
            max_observations: 64,
            max_names: 64,
            max_string: 4096,
            max_query: 512,
            locks: dashmap::DashMap::new(),
        })
    }

    fn tenant(s: &str) -> TenantCtx {
        TenantCtx { api_key: Arc::from(s) }
    }

    #[tokio::test]
    async fn create_then_read() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = cfg_with(dir.path());
        let t = tenant("k1");
        let _ = create_entities(
            &cfg,
            &t,
            CreateEntitiesArgs {
                entities: vec![Entity {
                    name: "alice".into(),
                    entity_type: "person".into(),
                    observations: vec!["loves rust".into()],
                }],
            },
        )
        .await
        .unwrap();
        let g = load(&cfg, &t).await.unwrap();
        assert_eq!(g.entities.len(), 1);
        assert_eq!(g.entities[0].name, "alice");
    }

    #[tokio::test]
    async fn tenants_isolated() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = cfg_with(dir.path());
        let a = tenant("aaa");
        let b = tenant("bbb");
        let _ = create_entities(
            &cfg,
            &a,
            CreateEntitiesArgs {
                entities: vec![Entity {
                    name: "secret".into(),
                    entity_type: "thing".into(),
                    observations: vec![],
                }],
            },
        )
        .await
        .unwrap();
        let g = load(&cfg, &b).await.unwrap();
        assert!(g.entities.is_empty());
    }
}
