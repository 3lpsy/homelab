/// Parse a Kubernetes quantity (`100m`, `512Mi`, `1.5`, `2Gi`) to a float in
/// base units. CPU callers multiply by 1000 for millicores; memory callers
/// consume the result as bytes.
pub fn parse_quantity(s: &str) -> Result<f64, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("quantity empty".into());
    }
    let (num_end, _) = s
        .char_indices()
        .find(|(_, c)| !(c.is_ascii_digit() || *c == '.' || *c == '-'))
        .unwrap_or((s.len(), ' '));
    let (num, suf) = s.split_at(num_end);
    let n: f64 = num
        .parse()
        .map_err(|_| format!("not a Kubernetes quantity: {s:?}"))?;
    let mult = match suf {
        "" => 1.0,
        "n" => 1e-9,
        "u" => 1e-6,
        "m" => 1e-3,
        "k" => 1e3,
        "K" => 1e3,
        "M" => 1e6,
        "G" => 1e9,
        "T" => 1e12,
        "P" => 1e15,
        "E" => 1e18,
        "Ki" => 1024.0,
        "Mi" => 1024.0_f64.powi(2),
        "Gi" => 1024.0_f64.powi(3),
        "Ti" => 1024.0_f64.powi(4),
        "Pi" => 1024.0_f64.powi(5),
        "Ei" => 1024.0_f64.powi(6),
        other => return Err(format!("unknown quantity suffix {other:?} in {s:?}")),
    };
    Ok(n * mult)
}

pub fn parse_cpu_millicores(s: &str) -> Result<i64, String> {
    Ok((parse_quantity(s)? * 1000.0).round() as i64)
}

pub fn parse_memory_bytes(s: &str) -> Result<i64, String> {
    Ok(parse_quantity(s)?.round() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn millis() {
        assert_eq!(parse_cpu_millicores("100m").unwrap(), 100);
        assert_eq!(parse_cpu_millicores("2").unwrap(), 2000);
        assert_eq!(parse_cpu_millicores("12345n").unwrap(), 0);
    }

    #[test]
    fn memory() {
        assert_eq!(parse_memory_bytes("512Mi").unwrap(), 512 * 1024 * 1024);
        assert_eq!(parse_memory_bytes("1Gi").unwrap(), 1024 * 1024 * 1024);
    }
}
