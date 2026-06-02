use std::path::{Path, PathBuf};
use std::sync::Arc;

use dashmap::DashMap;
use tokio::io::AsyncWriteExt;
use tokio::sync::Mutex;

use crate::errors::McpError;

/// Per-tenant exclusion. Two concurrent tools on the same tenant must
/// serialize their load → mutate → save cycle.
#[derive(Clone, Default)]
pub struct TenantLocks {
    map: Arc<DashMap<String, Arc<Mutex<()>>>>,
}

impl TenantLocks {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn for_tenant(&self, hash: &str) -> Arc<Mutex<()>> {
        if let Some(l) = self.map.get(hash) {
            return l.clone();
        }
        let entry = self.map.entry(hash.to_string()).or_insert_with(|| Arc::new(Mutex::new(())));
        entry.clone()
    }
}

/// Append/replace NDJSON files at `<root>/<tenant_hash>/<name>` atomically.
pub struct NdjsonStore {
    pub root: PathBuf,
}

impl NdjsonStore {
    pub fn open(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn tenant_dir(&self, tenant_hash: &str) -> PathBuf {
        self.root.join(tenant_hash)
    }

    pub fn file_path(&self, tenant_hash: &str, name: &str) -> PathBuf {
        self.tenant_dir(tenant_hash).join(name)
    }

    pub async fn read(&self, tenant_hash: &str, name: &str) -> Result<Option<String>, McpError> {
        let path = self.file_path(tenant_hash, name);
        match tokio::fs::read_to_string(&path).await {
            Ok(s) => Ok(Some(s)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Atomic write: stage to a sibling tempfile, fsync, rename.
    pub async fn write(&self, tenant_hash: &str, name: &str, body: &[u8]) -> Result<(), McpError> {
        let dir = self.tenant_dir(tenant_hash);
        tokio::fs::create_dir_all(&dir).await?;
        let target = dir.join(name);
        let nonce = nonce_hex(8);
        let pid = std::process::id();
        let tmp = dir.join(format!("{name}.{pid}.{nonce}.tmp"));
        {
            let mut f = tokio::fs::File::create(&tmp).await?;
            f.write_all(body).await?;
            f.flush().await?;
            f.sync_all().await?;
        }
        match tokio::fs::rename(&tmp, &target).await {
            Ok(()) => Ok(()),
            Err(e) => {
                let _ = tokio::fs::remove_file(&tmp).await;
                Err(e.into())
            }
        }
    }
}

pub fn ensure_dir_sync(path: &Path) -> std::io::Result<()> {
    if !path.exists() {
        std::fs::create_dir_all(path)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn write_then_read_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let store = NdjsonStore::open(tmp.path());
        store
            .write("tenant-a", "memory.jsonl", b"line1\nline2\n")
            .await
            .unwrap();
        let body = store
            .read("tenant-a", "memory.jsonl")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(body, "line1\nline2\n");
    }

    #[tokio::test]
    async fn read_missing_returns_none() {
        let tmp = tempfile::tempdir().unwrap();
        let store = NdjsonStore::open(tmp.path());
        let v = store.read("tenant-x", "missing.jsonl").await.unwrap();
        assert!(v.is_none());
    }

    #[tokio::test]
    async fn write_replaces_atomically() {
        let tmp = tempfile::tempdir().unwrap();
        let store = NdjsonStore::open(tmp.path());
        store.write("t", "f.jsonl", b"v1").await.unwrap();
        store.write("t", "f.jsonl", b"v2-longer").await.unwrap();
        let body = store.read("t", "f.jsonl").await.unwrap().unwrap();
        assert_eq!(body, "v2-longer");
    }

    #[tokio::test]
    async fn tenants_isolated_on_disk() {
        let tmp = tempfile::tempdir().unwrap();
        let store = NdjsonStore::open(tmp.path());
        store.write("a", "f", b"alpha").await.unwrap();
        store.write("b", "f", b"beta").await.unwrap();
        assert_eq!(
            store.read("a", "f").await.unwrap().unwrap(),
            "alpha"
        );
        assert_eq!(
            store.read("b", "f").await.unwrap().unwrap(),
            "beta"
        );
    }

    #[test]
    fn locks_per_tenant_reused() {
        let locks = TenantLocks::new();
        let a1 = locks.for_tenant("alice");
        let a2 = locks.for_tenant("alice");
        assert!(Arc::ptr_eq(&a1, &a2));
        let b1 = locks.for_tenant("bob");
        assert!(!Arc::ptr_eq(&a1, &b1));
    }
}

fn nonce_hex(bytes: usize) -> String {
    use sha2::Digest;
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut h = sha2::Sha256::new();
    h.update(nanos.to_le_bytes());
    h.update(std::process::id().to_le_bytes());
    let digest = hex::encode(h.finalize());
    digest[..bytes * 2].to_string()
}
