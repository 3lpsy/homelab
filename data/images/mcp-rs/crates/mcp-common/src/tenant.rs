use std::path::PathBuf;
use std::sync::Arc;

use sha2::{Digest, Sha256};

use crate::errors::McpError;

#[derive(Clone, Debug)]
pub struct TenantHash(pub Arc<str>);

impl TenantHash {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub fn sha256_hex(input: &str) -> String {
    let mut h = Sha256::new();
    h.update(input.as_bytes());
    hex::encode(h.finalize())
}

pub fn hash_tenant(salt: &[u8], value: &str) -> TenantHash {
    let mut h = Sha256::new();
    h.update(salt);
    h.update(value.as_bytes());
    let digest = hex::encode(h.finalize());
    // 32 hex chars (128 bits) — same truncation as the Python `hash_tenant`.
    TenantHash(Arc::from(&digest[..32]))
}

pub struct TenantRoot {
    pub salt: Vec<u8>,
    pub root: PathBuf,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_known_vector() {
        assert_eq!(
            sha256_hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn hash_tenant_truncates_to_32_hex_chars() {
        let h = hash_tenant(b"salt", "k1");
        assert_eq!(h.as_str().len(), 32);
        assert!(h.as_str().chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn hash_tenant_changes_with_salt() {
        let a = hash_tenant(b"saltA", "k1").as_str().to_string();
        let b = hash_tenant(b"saltB", "k1").as_str().to_string();
        assert_ne!(a, b);
    }

    #[test]
    fn hash_tenant_changes_with_value() {
        let a = hash_tenant(b"salt", "k1").as_str().to_string();
        let b = hash_tenant(b"salt", "k2").as_str().to_string();
        assert_ne!(a, b);
    }
}

pub fn init_tenant_root() -> Result<TenantRoot, McpError> {
    let salt_env = std::env::var("MCP_PATH_SALT").unwrap_or_default();
    if salt_env.is_empty() {
        return Err(McpError::Boot("MCP_PATH_SALT must be set".into()));
    }
    let root = std::env::var("MCP_DATA_ROOT").unwrap_or_else(|_| "/data".into());
    let root = PathBuf::from(root);
    std::fs::create_dir_all(&root)?;
    let root = std::fs::canonicalize(&root)?;
    Ok(TenantRoot {
        salt: salt_env.into_bytes(),
        root,
    })
}
