pub fn validate_time(s: &str) -> Result<(), String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("must be non-empty".into());
    }
    if let Ok(f) = s.parse::<f64>() {
        if !f.is_finite() {
            return Err(format!("timestamp must be finite: {s:?}"));
        }
        return Ok(());
    }
    let normalized = s.replace('Z', "+00:00");
    if normalized.parse::<jiff::Timestamp>().is_ok() {
        return Ok(());
    }
    if s.parse::<jiff::civil::DateTime>().is_ok() {
        return Ok(());
    }
    Err(format!("not RFC3339 or unix timestamp: {s:?}"))
}

pub fn validate_step(s: &str) -> Result<(), String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("must be non-empty".into());
    }
    if duration_seconds(s).is_ok() {
        Ok(())
    } else {
        Err(format!("not a Prometheus duration or float seconds: {s:?}"))
    }
}

pub fn duration_seconds(s: &str) -> Result<f64, String> {
    let s = s.trim();
    if let Ok(f) = s.parse::<f64>() {
        if !f.is_finite() {
            return Err(format!("not a Prometheus duration: {s:?}"));
        }
        return Ok(f);
    }
    let mut total: f64 = 0.0;
    let mut i = 0;
    let bytes = s.as_bytes();
    while i < bytes.len() {
        let num_start = i;
        while i < bytes.len() && (bytes[i].is_ascii_digit() || bytes[i] == b'.') {
            i += 1;
        }
        if num_start == i {
            return Err(format!("not a Prometheus duration: {s:?}"));
        }
        let num: f64 = std::str::from_utf8(&bytes[num_start..i])
            .map_err(|_| format!("not a Prometheus duration: {s:?}"))?
            .parse()
            .map_err(|_| format!("not a Prometheus duration: {s:?}"))?;
        let unit_start = i;
        while i < bytes.len() && (bytes[i] as char).is_ascii_alphabetic() {
            i += 1;
        }
        let unit = &s[unit_start..i];
        let mult = match unit {
            "ms" => 0.001,
            "s" => 1.0,
            "m" => 60.0,
            "h" => 3600.0,
            "d" => 86400.0,
            "w" => 604_800.0,
            "y" => 31_536_000.0,
            _ => return Err(format!("not a Prometheus duration: {s:?}")),
        };
        total += num * mult;
    }
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duration_units() {
        assert_eq!(duration_seconds("15s").unwrap(), 15.0);
        assert_eq!(duration_seconds("1m").unwrap(), 60.0);
        assert_eq!(duration_seconds("1h30m").unwrap(), 5400.0);
        assert_eq!(duration_seconds("500ms").unwrap(), 0.5);
        assert_eq!(duration_seconds("1.5").unwrap(), 1.5);
    }

    #[test]
    fn duration_rejects_garbage() {
        assert!(duration_seconds("foo").is_err());
        assert!(duration_seconds("1h foo").is_err());
    }

    #[test]
    fn time_unix_ok() {
        assert!(validate_time("1745366400").is_ok());
        assert!(validate_time("1745366400.5").is_ok());
        assert!(validate_time("inf").is_err());
    }

    #[test]
    fn time_rfc3339_ok() {
        assert!(validate_time("2026-04-23T00:00:00Z").is_ok());
    }
}
