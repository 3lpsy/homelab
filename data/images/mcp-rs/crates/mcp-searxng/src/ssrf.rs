use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, ToSocketAddrs};

use ipnet::IpNet;
use url::Url;

#[derive(Debug)]
pub enum SsrfError {
    BadScheme(String),
    MissingHost,
    BlockedHost(String),
    BlockedAddress(String),
    DnsFailure(String),
}

impl std::fmt::Display for SsrfError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SsrfError::BadScheme(s) => write!(f, "scheme not allowed: {s:?}"),
            SsrfError::MissingHost => write!(f, "url missing host"),
            SsrfError::BlockedHost(h) => write!(f, "blocked hostname: {h:?}"),
            SsrfError::BlockedAddress(a) => write!(f, "blocked address: {a}"),
            SsrfError::DnsFailure(s) => write!(f, "dns resolution failed: {s}"),
        }
    }
}

const BLOCKED_HOSTS: &[&str] = &[
    "localhost",
    "ip6-localhost",
    "ip6-loopback",
    "kubernetes",
    "kubernetes.default",
    "metadata",
    "metadata.google.internal",
];

const BLOCKED_SUFFIXES: &[&str] = &[
    ".local",
    ".localhost",
    ".cluster.local",
    ".svc",
    ".internal",
    ".arpa",
];

pub fn parse_cidrs(raw: &str) -> Vec<IpNet> {
    raw.split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .filter_map(|s| s.parse::<IpNet>().ok())
        .collect()
}

pub struct Resolved {
    pub host: String,
    pub ips: Vec<IpAddr>,
    pub port: u16,
    pub scheme: String,
}

pub fn resolve_and_validate(url_str: &str, allowed_cidrs: &[IpNet]) -> Result<Resolved, SsrfError> {
    let u = Url::parse(url_str).map_err(|e| SsrfError::DnsFailure(e.to_string()))?;
    let scheme = u.scheme().to_string();
    if scheme != "http" && scheme != "https" {
        return Err(SsrfError::BadScheme(scheme));
    }
    let host = u.host_str().ok_or(SsrfError::MissingHost)?.to_string();
    let port = u
        .port()
        .unwrap_or_else(|| if scheme == "https" { 443 } else { 80 });

    // IP literal short-circuit.
    if let Ok(addr) = host.parse::<IpAddr>() {
        reject_ip(addr, allowed_cidrs)?;
        return Ok(Resolved {
            host,
            ips: vec![addr],
            port,
            scheme,
        });
    }

    let lookup: Vec<IpAddr> = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| SsrfError::DnsFailure(e.to_string()))?
        .map(|sa| sa.ip())
        .collect();

    if lookup.is_empty() {
        return Err(SsrfError::DnsFailure(format!("no addresses for {host:?}")));
    }

    let all_in_allowlist =
        !allowed_cidrs.is_empty() && lookup.iter().all(|ip| in_allowlist(*ip, allowed_cidrs));

    if !all_in_allowlist {
        reject_hostname(&host)?;
    }

    for ip in &lookup {
        reject_ip(*ip, allowed_cidrs)?;
    }

    Ok(Resolved {
        host,
        ips: lookup,
        port,
        scheme,
    })
}

fn reject_hostname(host: &str) -> Result<(), SsrfError> {
    let h = host.trim_end_matches('.').to_ascii_lowercase();
    if BLOCKED_HOSTS.contains(&h.as_str()) {
        return Err(SsrfError::BlockedHost(host.to_string()));
    }
    for suf in BLOCKED_SUFFIXES {
        if h.ends_with(suf) {
            return Err(SsrfError::BlockedHost(format!("suffix {suf:?}: {host:?}")));
        }
    }
    Ok(())
}

fn reject_ip(ip: IpAddr, allowed_cidrs: &[IpNet]) -> Result<(), SsrfError> {
    if in_allowlist(ip, allowed_cidrs) {
        return Ok(());
    }
    let normalized = match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
        _ => ip,
    };
    let bad = match normalized {
        IpAddr::V4(v) => is_v4_special(v),
        IpAddr::V6(v) => is_v6_special(v),
    };
    if bad {
        return Err(SsrfError::BlockedAddress(ip.to_string()));
    }
    Ok(())
}

/// Reject IPv4 special-purpose ranges. Stable `Ipv4Addr` methods cover most;
/// `is_extra_special_v4` adds the registry entries the stdlib leaves out so
/// the coverage matches Python's `is_private | is_loopback | is_link_local |
/// is_reserved | is_multicast | is_unspecified` on Python 3.12+.
fn is_v4_special(v: Ipv4Addr) -> bool {
    v.is_private()
        || v.is_loopback()
        || v.is_link_local()
        || v.is_broadcast()
        || v.is_documentation()
        || v.is_unspecified()
        || v.is_multicast()
        || is_extra_special_v4(v)
}

fn is_extra_special_v4(v: Ipv4Addr) -> bool {
    let o = v.octets();
    // "this network" 0.0.0.0/8 (broader than the single 0.0.0.0 that
    // `is_unspecified` catches).
    if o[0] == 0 {
        return true;
    }
    // 100.64.0.0/10 — Carrier-Grade NAT (RFC 6598). Only 100.64-127.x; the
    // rest of 100/8 is normal globally-routable space.
    if o[0] == 100 && (o[1] & 0xC0) == 0x40 {
        return true;
    }
    // 192.0.0.0/24 — IETF Protocol Assignments (RFC 6890). Note: 192.0.2.0/24
    // is TEST-NET-1 and already handled by `is_documentation`.
    if o[0] == 192 && o[1] == 0 && o[2] == 0 {
        return true;
    }
    // 198.18.0.0/15 — Benchmarking (RFC 2544). Only 198.18.x.x + 198.19.x.x;
    // 198.51.100/24 (TEST-NET-2) is `is_documentation`.
    if o[0] == 198 && (o[1] & 0xFE) == 18 {
        return true;
    }
    // 240.0.0.0/4 — Class E reserved (RFC 1112). Catches 240-255 first octet.
    if (o[0] & 0xF0) == 0xF0 {
        return true;
    }
    false
}

/// Reject IPv6 special-purpose ranges. Stable `Ipv6Addr` methods cover the
/// common ones; documentation/2001::/32 etc. would require more explicit
/// CIDR checks — homelab traffic is IPv4-only, so coverage is intentionally
/// conservative on v6.
fn is_v6_special(v: Ipv6Addr) -> bool {
    v.is_loopback()
        || v.is_unspecified()
        || v.is_multicast()
        || v.is_unique_local()
        || v.is_unicast_link_local()
        || is_extra_special_v6(v)
}

fn is_extra_special_v6(v: Ipv6Addr) -> bool {
    let seg = v.segments();
    // 2001:db8::/32 — Documentation (RFC 3849).
    if seg[0] == 0x2001 && seg[1] == 0x0db8 {
        return true;
    }
    false
}

pub fn in_allowlist(addr: IpAddr, allowed_cidrs: &[IpNet]) -> bool {
    if allowed_cidrs.is_empty() {
        return false;
    }
    let normalized = match addr {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
        _ => addr,
    };
    allowed_cidrs
        .iter()
        .any(|net| match (net, normalized) {
            (IpNet::V4(n), IpAddr::V4(ip)) => n.contains(&ip),
            (IpNet::V6(n), IpAddr::V6(ip)) => n.contains(&ip),
            _ => false,
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cidrs_parse() {
        let cidrs = parse_cidrs("10.43.0.0/16,fd00::/8");
        assert_eq!(cidrs.len(), 2);
    }

    #[test]
    fn http_scheme_only() {
        let r = resolve_and_validate("ftp://example.com/", &[]);
        assert!(matches!(r, Err(SsrfError::BadScheme(_))));
    }

    #[test]
    fn blocks_localhost() {
        let r = resolve_and_validate("http://localhost/", &[]);
        assert!(r.is_err());
    }

    #[test]
    fn blocks_private_literal() {
        let r = resolve_and_validate("http://10.0.0.1/", &[]);
        assert!(matches!(r, Err(SsrfError::BlockedAddress(_))));
    }

    #[test]
    fn allows_with_cidr_exempt() {
        let cidrs = parse_cidrs("10.0.0.0/8");
        let r = resolve_and_validate("http://10.0.0.1/", &cidrs);
        assert!(r.is_ok());
    }

    #[test]
    fn special_ranges_blocked_precisely() {
        // Inside reserved sub-ranges: rejected.
        for ip in [
            "0.1.2.3",            // 0.0.0.0/8
            "100.64.0.1",         // CGNAT
            "100.127.255.254",    // CGNAT upper edge
            "127.0.0.1",          // loopback
            "169.254.0.1",        // link-local
            "192.0.0.1",          // IETF protocol
            "192.0.2.1",          // TEST-NET-1
            "192.168.1.1",        // RFC1918
            "198.18.0.1",         // benchmark
            "198.19.0.1",         // benchmark
            "198.51.100.1",       // TEST-NET-2
            "203.0.113.1",        // TEST-NET-3
            "224.0.0.1",          // multicast
            "240.0.0.1",          // class E
            "255.255.255.255",    // broadcast
        ] {
            let v: Ipv4Addr = ip.parse().unwrap();
            assert!(is_v4_special(v), "expected {ip} to be blocked");
        }
    }

    #[test]
    fn public_addresses_in_partially_reserved_octets_allowed() {
        // These first-octet values used to be wholesale blocked by the old
        // overly-broad octet match. They are globally-routable public space.
        for ip in [
            "100.50.0.1",         // 100/8 outside CGNAT 100.64-127
            "100.128.0.1",        // ditto
            "169.50.100.1",       // 169/8 outside link-local 169.254
            "169.255.0.1",        // ditto
            "198.0.0.1",          // 198/8 outside 198.18/15 and 198.51.100/24
            "198.20.0.1",         // ditto
            "198.52.0.1",         // ditto
            "203.0.0.1",          // 203/8 outside 203.0.113/24
            "203.1.0.1",          // ditto
        ] {
            let v: Ipv4Addr = ip.parse().unwrap();
            assert!(
                !is_v4_special(v),
                "{ip} is public space and should NOT be blocked"
            );
        }
    }

    #[test]
    fn v6_documentation_blocked() {
        let v: Ipv6Addr = "2001:db8::1".parse().unwrap();
        assert!(is_v6_special(v));
    }

    #[test]
    fn v6_global_unicast_allowed() {
        let v: Ipv6Addr = "2606:4700:4700::1111".parse().unwrap();
        assert!(!is_v6_special(v));
    }
}
