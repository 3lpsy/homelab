use std::sync::Arc;

use mcp_common::errors::tool_invalid;
use rmcp::ErrorData;

use crate::server::Config;

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
pub struct EditOp {
    #[serde(rename = "oldText")]
    pub old_text: String,
    #[serde(rename = "newText")]
    pub new_text: String,
}

pub fn validate_edits(cfg: &Arc<Config>, edits: &[EditOp]) -> Result<(), ErrorData> {
    if edits.len() > cfg.max_edits {
        return Err(tool_invalid(format!(
            "too many edits ({} > MCP_MAX_EDITS={})",
            edits.len(),
            cfg.max_edits
        )));
    }
    for (i, e) in edits.iter().enumerate() {
        if e.old_text.len() > cfg.max_edit_bytes {
            return Err(tool_invalid(format!(
                "edits[{i}].oldText exceeds MCP_MAX_EDIT_BYTES ({} > {})",
                e.old_text.len(),
                cfg.max_edit_bytes
            )));
        }
        if e.new_text.len() > cfg.max_edit_bytes {
            return Err(tool_invalid(format!(
                "edits[{i}].newText exceeds MCP_MAX_EDIT_BYTES ({} > {})",
                e.new_text.len(),
                cfg.max_edit_bytes
            )));
        }
    }
    Ok(())
}

pub fn normalize_line_endings(s: &str) -> String {
    s.replace("\r\n", "\n")
}

/// Apply one edit. Try literal replace first; if that fails, line-by-line
/// whitespace-normalized matching with indent rewriting. Returns the modified
/// content or `None` if the edit didn't match.
pub fn apply_one(modified: &str, edit: &EditOp) -> Option<String> {
    let old = normalize_line_endings(&edit.old_text);
    let new = normalize_line_endings(&edit.new_text);

    if let Some(pos) = modified.find(&old) {
        let mut out = String::with_capacity(modified.len());
        out.push_str(&modified[..pos]);
        out.push_str(&new);
        out.push_str(&modified[pos + old.len()..]);
        return Some(out);
    }

    let old_lines: Vec<&str> = old.split('\n').collect();
    let content_lines: Vec<&str> = modified.split('\n').collect();
    if old_lines.len() > content_lines.len() {
        return None;
    }
    for i in 0..=(content_lines.len() - old_lines.len()) {
        let window = &content_lines[i..i + old_lines.len()];
        if old_lines
            .iter()
            .zip(window.iter())
            .all(|(o, c)| o.trim() == c.trim())
        {
            let original_indent = leading_ws(content_lines[i]);
            let new_src: Vec<&str> = new.split('\n').collect();
            let mut rebuilt: Vec<String> = Vec::with_capacity(new_src.len());
            for (j, line) in new_src.iter().enumerate() {
                if j == 0 {
                    rebuilt.push(format!("{}{}", original_indent, line.trim_start()));
                } else if j < old_lines.len() {
                    let old_indent = leading_ws(old_lines[j]);
                    let new_indent = leading_ws(line);
                    if !old_indent.is_empty() && !new_indent.is_empty() {
                        let rel = new_indent.len().saturating_sub(old_indent.len());
                        rebuilt.push(format!(
                            "{}{}{}",
                            original_indent,
                            " ".repeat(rel),
                            line.trim_start()
                        ));
                    } else {
                        rebuilt.push((*line).to_string());
                    }
                } else {
                    rebuilt.push((*line).to_string());
                }
            }
            let mut out: Vec<String> = Vec::with_capacity(content_lines.len());
            out.extend(content_lines[..i].iter().map(|s| (*s).to_string()));
            out.extend(rebuilt);
            out.extend(content_lines[i + old_lines.len()..].iter().map(|s| (*s).to_string()));
            return Some(out.join("\n"));
        }
    }
    None
}

fn leading_ws(s: &str) -> String {
    s.chars().take_while(|c| c.is_whitespace() && *c != '\n').collect()
}

/// Standard unified diff with context=3. Empty result when inputs match.
pub fn unified_diff(old: &str, new: &str, file: &str) -> String {
    if old == new {
        return String::new();
    }
    similar::TextDiff::from_lines(old, new)
        .unified_diff()
        .context_radius(3)
        .header(file, file)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_replace() {
        let r = apply_one(
            "hello world\n",
            &EditOp {
                old_text: "world".into(),
                new_text: "there".into(),
            },
        )
        .unwrap();
        assert_eq!(r, "hello there\n");
    }

    #[test]
    fn whitespace_normalized() {
        let src = "    foo()\n    bar()\n";
        let r = apply_one(
            src,
            &EditOp {
                old_text: "foo()\nbar()".into(),
                new_text: "foo()\nbaz()".into(),
            },
        )
        .unwrap();
        assert!(r.contains("baz()"));
    }
}
