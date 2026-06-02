const SKIP_TAGS: &[&str] = &[
    "script", "style", "noscript", "head", "nav", "footer", "aside", "svg", "form",
];

/// Strip HTML tags down to text. Walks the bytes manually — `html5ever` would
/// be more correct but pulls a sizable dep tree; the Python original also
/// uses the stdlib forgiving parser, so we match its lossy behavior.
pub fn html_to_text(body: &str) -> String {
    let bytes = body.as_bytes();
    let mut parts: Vec<String> = Vec::new();
    let mut buf: Vec<u8> = Vec::with_capacity(256);
    let mut i = 0;
    let mut skip_depth: u32 = 0;

    while i < bytes.len() {
        if bytes[i] == b'<' {
            if !buf.is_empty() && skip_depth == 0 {
                let s = String::from_utf8_lossy(&buf).trim().to_string();
                if !s.is_empty() {
                    parts.push(decode_entities(&s));
                }
            }
            buf.clear();
            let close = bytes[i..].iter().position(|&b| b == b'>');
            let Some(end) = close else { break };
            let tag = &bytes[i + 1..i + end];
            let (is_close, name) = parse_tag(tag);
            i += end + 1;
            if let Some(n) = name {
                if SKIP_TAGS.contains(&n.as_str()) {
                    if is_close {
                        if skip_depth > 0 {
                            skip_depth -= 1;
                        }
                    } else if !is_self_closing(tag) {
                        skip_depth += 1;
                    }
                }
            }
            continue;
        }
        buf.push(bytes[i]);
        i += 1;
    }
    if !buf.is_empty() && skip_depth == 0 {
        let s = String::from_utf8_lossy(&buf).trim().to_string();
        if !s.is_empty() {
            parts.push(decode_entities(&s));
        }
    }
    parts.join("\n")
}

fn parse_tag(tag: &[u8]) -> (bool, Option<String>) {
    let mut iter = tag.iter().copied();
    let first = iter.next();
    let is_close = matches!(first, Some(b'/'));
    let rest: Vec<u8> = if is_close { iter.collect() } else { tag.to_vec() };
    let name: Vec<u8> = rest
        .iter()
        .copied()
        .take_while(|b| !b.is_ascii_whitespace() && *b != b'/' && *b != b'>')
        .collect();
    if name.is_empty() {
        return (is_close, None);
    }
    Some((is_close, String::from_utf8_lossy(&name).to_ascii_lowercase()))
        .map(|(c, n)| (c, Some(n)))
        .unwrap_or((is_close, None))
}

fn is_self_closing(tag: &[u8]) -> bool {
    tag.last().map(|b| *b == b'/').unwrap_or(false)
}

fn decode_entities(s: &str) -> String {
    // Full HTML5 named-entity + numeric-entity coverage to match Python's
    // `html.unescape`. The native decoder I'd written only handled 7 names —
    // real pages with `&hellip;`/`&mdash;`/`&copy;` came back unrendered.
    html_escape::decode_html_entities(s).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_basic() {
        let html = "<html><body><p>Hello <b>World</b></p></body></html>";
        let out = html_to_text(html);
        assert!(out.contains("Hello"));
        assert!(out.contains("World"));
        assert!(!out.contains("<"));
    }

    #[test]
    fn skips_script() {
        let html = "<p>Keep</p><script>alert(1)</script><p>Also keep</p>";
        let out = html_to_text(html);
        assert!(out.contains("Keep"));
        assert!(out.contains("Also keep"));
        assert!(!out.contains("alert"));
    }

    #[test]
    fn decodes_named_entities_beyond_ampersand_set() {
        let html = "<p>Cost: 5&nbsp;&euro; &mdash; see &hellip;</p>";
        let out = html_to_text(html);
        // None of these should survive as raw entity refs.
        assert!(!out.contains("&hellip;"), "hellip not decoded: {out}");
        assert!(!out.contains("&mdash;"), "mdash not decoded: {out}");
        assert!(!out.contains("&euro;"), "euro not decoded: {out}");
        // Expect the decoded chars present.
        assert!(out.contains("…"));
        assert!(out.contains("—"));
        assert!(out.contains("€"));
    }

    #[test]
    fn decodes_numeric_entities() {
        let html = "<p>&#8230; and &#x2014;</p>";
        let out = html_to_text(html);
        assert!(out.contains("…"));
        assert!(out.contains("—"));
    }
}
