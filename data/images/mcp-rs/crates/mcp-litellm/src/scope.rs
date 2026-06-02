use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use subtle::ConstantTimeEq;

pub type HashMapPerBearer = HashMap<String, HashSet<String>>;

pub struct ScopeTable {
    map: HashMapPerBearer,
}

impl ScopeTable {
    pub fn new(map: HashMapPerBearer) -> Self {
        Self { map }
    }

    pub fn tenant_count(&self) -> usize {
        self.map.len()
    }

    pub fn total_hashes(&self) -> usize {
        self.map.values().map(|s| s.len()).sum()
    }

    pub fn lookup_for(&self, bearer: &str) -> Arc<HashSet<String>> {
        match self.map.get(bearer) {
            Some(set) => Arc::new(set.clone()),
            None => Arc::new(HashSet::new()),
        }
    }
}

pub fn parse_hash_map(raw: &str) -> Result<HashMapPerBearer, String> {
    let s = raw.trim();
    if s.is_empty() {
        return Ok(HashMap::new());
    }
    let parsed: serde_json::Value = serde_json::from_str(s).map_err(|e| format!("invalid JSON: {e}"))?;
    let obj = parsed.as_object().ok_or("must be a JSON object")?.clone();
    let mut out = HashMap::new();
    for (bearer, hashes) in obj {
        let arr = hashes.as_array().ok_or_else(|| format!("{bearer:?} must be a list"))?;
        let mut set = HashSet::new();
        for h in arr {
            let s = h.as_str().ok_or_else(|| format!("{bearer:?} entry must be string"))?;
            if s.len() != 64 || !s.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
                return Err(format!("{bearer:?} contains non-hash entry: {s:?}"));
            }
            set.insert(s.to_string());
        }
        out.insert(bearer, set);
    }
    Ok(out)
}

pub fn constant_time_contains(set: &HashSet<String>, candidate: &str) -> bool {
    if candidate.len() != 64 || !candidate.chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
        return false;
    }
    let cand = candidate.as_bytes();
    for h in set {
        if h.len() == cand.len() && bool::from(h.as_bytes().ct_eq(cand)) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_ok() {
        assert!(parse_hash_map("").unwrap().is_empty());
    }

    #[test]
    fn good_map() {
        let raw = r#"{"k":["00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"]}"#;
        let m = parse_hash_map(raw).unwrap();
        assert_eq!(m["k"].len(), 1);
    }

    #[test]
    fn bad_hash_rejects() {
        let raw = r#"{"k":["not-a-hash"]}"#;
        assert!(parse_hash_map(raw).is_err());
    }
}
