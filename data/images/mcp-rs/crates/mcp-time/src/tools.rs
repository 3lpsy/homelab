use jiff::civil::Time;
use jiff::tz::TimeZone;
use jiff::{Zoned, ZonedRound};
use rmcp::model::{CallToolResult, Content};
use rmcp::ErrorData;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use mcp_common::errors::tool_invalid;

const BARE_ZONE_OK: &[&str] = &["UTC", "GMT", "Zulu"];

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetCurrentTime {
    #[schemars(description = "IANA timezone name (e.g. 'America/New_York', 'Europe/London', 'UTC'). Omit to use the server default.")]
    #[serde(default)]
    pub timezone: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ConvertTime {
    #[schemars(description = "Time to convert in 24-hour HH:MM format (e.g. '14:30').")]
    pub time: String,
    #[schemars(description = "Source IANA timezone. Omit to use the server default.")]
    #[serde(default)]
    pub source_timezone: Option<String>,
    #[schemars(description = "Target IANA timezone. Omit to use the server default.")]
    #[serde(default)]
    pub target_timezone: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct TimeResult {
    pub timezone: String,
    pub datetime: String,
    pub day_of_week: String,
    pub is_dst: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub warning: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct TimeConversionResult {
    pub source: TimeResult,
    pub target: TimeResult,
    pub time_difference: String,
}

pub async fn get_current_time(default_tz: &str, args: GetCurrentTime) -> Result<CallToolResult, ErrorData> {
    let tz_name = resolve_tz(default_tz, args.timezone.as_deref());
    let tz = zone(&tz_name, "timezone")?;
    let now = Zoned::now().with_time_zone(tz);
    tracing::info!(tz = %tz_name, "get_current_time");
    json_result(&time_result(&tz_name, &now))
}

pub async fn convert_time(default_tz: &str, args: ConvertTime) -> Result<CallToolResult, ErrorData> {
    let src_name = resolve_tz(default_tz, args.source_timezone.as_deref());
    let tgt_name = resolve_tz(default_tz, args.target_timezone.as_deref());
    let src = zone(&src_name, "source_timezone")?;
    let tgt = zone(&tgt_name, "target_timezone")?;

    let parsed: Time = args.time.parse().map_err(|_| {
        tool_invalid(format!(
            "time {:?} is not valid HH:MM (24-hour, e.g. '09:05', '17:30')",
            args.time
        ))
    })?;

    let now = Zoned::now().with_time_zone(src.clone());
    let date = now.date();
    let civil = date.at(parsed.hour(), parsed.minute(), 0, 0);
    let source = civil
        .to_zoned(src)
        .map_err(|e| tool_invalid(format!("source_timezone conversion failed: {e}")))?
        .round(ZonedRound::new().smallest(jiff::Unit::Second))
        .map_err(|e| tool_invalid(format!("source round failed: {e}")))?;
    let target = source.with_time_zone(tgt);

    let src_off = source.offset().seconds() as f64;
    let tgt_off = target.offset().seconds() as f64;
    let hours = (tgt_off - src_off) / 3600.0;
    let diff = format!("{}h", format_hours(hours));

    tracing::info!(
        time = %args.time,
        src = %src_name,
        tgt = %tgt_name,
        diff = %diff,
        "convert_time"
    );

    let result = TimeConversionResult {
        source: time_result(&src_name, &source),
        target: time_result(&tgt_name, &target),
        time_difference: diff,
    };
    json_result(&result)
}

fn resolve_tz(default_tz: &str, raw: Option<&str>) -> String {
    match raw {
        Some(s) => {
            let t = s.trim();
            if t.is_empty() { default_tz.to_string() } else { t.to_string() }
        }
        None => default_tz.to_string(),
    }
}

fn zone(tz_name: &str, label: &str) -> Result<TimeZone, ErrorData> {
    TimeZone::get(tz_name).map_err(|_| {
        tool_invalid(format!(
            "{label} {tz_name:?} is not a valid IANA timezone (e.g. 'America/New_York', 'Europe/London', 'UTC')"
        ))
    })
}

fn time_result(tz_name: &str, z: &Zoned) -> TimeResult {
    let datetime = z
        .strftime("%Y-%m-%dT%H:%M:%S%:z")
        .to_string();
    let day_of_week = weekday_name(z.weekday());
    let is_dst = z.time_zone().to_offset_info(z.timestamp()).dst().is_dst();
    TimeResult {
        timezone: tz_name.to_string(),
        datetime,
        day_of_week,
        is_dst,
        warning: zone_warning(tz_name),
    }
}

fn weekday_name(w: jiff::civil::Weekday) -> String {
    use jiff::civil::Weekday::*;
    match w {
        Monday => "Monday",
        Tuesday => "Tuesday",
        Wednesday => "Wednesday",
        Thursday => "Thursday",
        Friday => "Friday",
        Saturday => "Saturday",
        Sunday => "Sunday",
    }
    .to_string()
}

fn zone_warning(tz_name: &str) -> Option<String> {
    if tz_name.contains('/') {
        return None;
    }
    if BARE_ZONE_OK.contains(&tz_name) {
        return None;
    }
    Some(format!(
        "zone {tz_name:?} is a fixed-offset legacy alias without full DST support — \
         it will not shift for summer/winter time. For DST-aware behavior use an \
         Area/Location zone like 'America/New_York', 'Europe/London', 'Asia/Kolkata'."
    ))
}

fn format_hours(hours: f64) -> String {
    let one = format!("{hours:+.1}");
    if one.parse::<f64>().map(|f| (f - hours).abs() < 1e-9).unwrap_or(false) {
        return one;
    }
    format!("{hours:+.2}")
}

fn json_result<T: Serialize>(v: &T) -> Result<CallToolResult, ErrorData> {
    let text = serde_json::to_string(v).map_err(|e| {
        ErrorData::internal_error(format!("serialize: {e}"), None)
    })?;
    Ok(CallToolResult::success(vec![Content::text(text)]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_hours_basic() {
        assert_eq!(format_hours(5.0), "+5.0");
        assert_eq!(format_hours(-5.0), "-5.0");
        assert_eq!(format_hours(5.5), "+5.5");
        assert_eq!(format_hours(5.75), "+5.75");
        assert_eq!(format_hours(-5.75), "-5.75");
    }

    #[test]
    fn jiff_parses_hh_mm() {
        // mcp-time's convert_time depends on `args.time.parse::<Time>()` accepting
        // bare "HH:MM" — `strptime("%H:%M")` accepts it in Python. Pin the behavior.
        let r: Result<Time, _> = "14:30".parse();
        assert!(r.is_ok(), "HH:MM should parse: {:?}", r);
        let t = r.unwrap();
        assert_eq!(t.hour(), 14);
        assert_eq!(t.minute(), 30);
    }

    #[test]
    fn warning_only_for_bare_legacy() {
        assert!(zone_warning("America/New_York").is_none());
        assert!(zone_warning("UTC").is_none());
        assert!(zone_warning("GMT").is_none());
        assert!(zone_warning("EST").is_some());
        assert!(zone_warning("PST").is_some());
    }
}
