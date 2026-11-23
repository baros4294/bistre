//! Network address predicates shared by Wallet Shield, providers, and MCP.

use std::net::IpAddr;

/// Returns `true` only for `http(s)` URLs whose *parsed* host is `localhost` or a loopback IP.
///
/// Never decide by string prefix: `http://localhost.evil.com` and `http://127.0.0.1.nip.io`
/// are remote hosts and must stay subject to Wallet Shield and pricing.
pub fn is_loopback_url(url: &str) -> bool {
    let Ok(parsed) = reqwest::Url::parse(url.trim()) else {
        return false;
    };
    if !matches!(parsed.scheme(), "http" | "https") {
        return false;
    }
    if let Some(domain) = parsed.domain() {
        return domain.eq_ignore_ascii_case("localhost");
    }
    parsed
        .host_str()
        .map(|h| h.trim_start_matches('[').trim_end_matches(']'))
        .and_then(|h| h.parse::<IpAddr>().ok())
        .is_some_and(|ip| ip.is_loopback())
}

#[cfg(test)]
mod tests {
    use super::is_loopback_url;

    #[test]
    fn loopback_is_decided_by_parsed_host() {
        for ok in [
            "http://localhost:11434/v1",
            "http://LOCALHOST",
            "https://127.0.0.1:8080",
            "http://127.9.9.9",
            "http://[::1]:8080/v1",
            "http://user:pw@localhost:1234",
        ] {
            assert!(is_loopback_url(ok), "{ok}");
        }
        for bad in [
            "http://localhost.evil.com/v1",
            "http://127.0.0.1.nip.io",
            "https://localhost@evil.com",
            "http://evil.com/?localhost",
            "ftp://127.0.0.1",
            "file:///localhost",
            "localhost:8080",
            "",
        ] {
            assert!(!is_loopback_url(bad), "{bad}");
        }
    }
}
