use std::collections::HashSet;
use std::env;
use std::str::FromStr;

use crate::errors::McpError;

pub fn env_int(name: &str, default: i64) -> Result<i64, McpError> {
    parse_env(name, default)
}

pub fn env_usize(name: &str, default: usize) -> Result<usize, McpError> {
    parse_env(name, default)
}

pub fn env_f64(name: &str, default: f64) -> Result<f64, McpError> {
    parse_env(name, default)
}

pub fn env_bool(name: &str) -> bool {
    match env::var(name) {
        Ok(v) => matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes"),
        Err(_) => false,
    }
}

pub fn env_str(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_string())
}

pub fn env_opt(name: &str) -> Option<String> {
    env::var(name).ok().filter(|s| !s.is_empty())
}

pub fn env_required(name: &str) -> Result<String, McpError> {
    env::var(name)
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| McpError::Boot(format!("{name} must be set")))
}

pub fn env_csv_set(name: &str) -> HashSet<String> {
    env::var(name)
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

fn parse_env<T>(name: &str, default: T) -> Result<T, McpError>
where
    T: FromStr,
{
    match env::var(name) {
        Ok(raw) => raw
            .parse::<T>()
            .map_err(|_| McpError::Boot(format!("{name} could not be parsed: {raw:?}"))),
        Err(_) => Ok(default),
    }
}
