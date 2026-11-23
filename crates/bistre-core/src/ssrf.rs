//! `PublicWebTransport`: the only HTTP client allowed for model-directed fetches (Spec 04 / 06).
//!
//! - Public-IP pinning at connect time: a custom DNS resolver drops every non-public address,
//!   so DNS rebinding cannot swap a validated name for `127.0.0.1` between check and connect.
//! - `.no_proxy()` (proxy env vars never reroute model traffic) and `Policy::none()` redirects;
//!   up to [`MAX_REDIRECT_HOPS`] redirects are followed manually and each hop is re-validated.
//! - Full IANA special-purpose IPv4/IPv6 exclusions (incl. CGNAT, ULA, documentation ranges,
//!   6to4/Teredo, NAT64 and IPv4-mapped unwrapping), scoped `%zone` hosts, `*.localhost`, and
//!   URLs with embedded credentials are rejected.
//! - Bodies stream into a hard byte cap instead of buffering the whole response.
//! - Fail-closed: if the hardened client cannot be built, every request errors; it never falls
//!   back to the provider client.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use reqwest::{Method, StatusCode, Url};

/// Maximum manually followed redirects.
pub const MAX_REDIRECT_HOPS: usize = 6;

/// A fetched public page (body truncated at the caller's cap).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicFetch {
    pub final_url: String,
    pub status: u16,
    pub content_type: String,
    pub body: Vec<u8>,
    pub truncated: bool,
}

/// Hardened transport for model-directed web traffic.
#[derive(Debug, Clone)]
pub struct PublicWebTransport {
    client: Result<reqwest::Client, BistreError>,
}

impl Default for PublicWebTransport {
    fn default() -> Self {
        Self::new()
    }
}

fn blocked(detail: &str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::NetworkDestinationBlocked, detail)
}

impl PublicWebTransport {
    /// Builds the hardened client; on failure the transport is permanently fail-closed.
    pub fn new() -> Self {
        crate::providers::ensure_tls_provider();
        let client = reqwest::Client::builder()
            .user_agent(concat!("Bistre/", env!("CARGO_PKG_VERSION")))
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .dns_resolver(Arc::new(PublicOnlyDnsResolver))
            .connect_timeout(Duration::from_secs(10))
            .read_timeout(Duration::from_secs(30))
            .timeout(Duration::from_secs(60))
            .build()
            .map_err(|_| blocked("public_transport_init_failed"));
        Self { client }
    }

    fn client(&self) -> BistreResult<&reqwest::Client> {
        self.client.as_ref().map_err(Clone::clone)
    }

    /// `GET` with manual redirect validation and a streamed `max_bytes` body cap.
    pub async fn get(&self, url: &str, max_bytes: usize) -> BistreResult<PublicFetch> {
        let client = self.client()?;
        let mut current = validate_public_url(url)?;
        for _ in 0..=MAX_REDIRECT_HOPS {
            let resp = client.get(current.clone()).send().await.map_err(|_| {
                BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "web_fetch")
            })?;
            if resp.status().is_redirection() {
                let location = resp
                    .headers()
                    .get(reqwest::header::LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .ok_or_else(|| blocked("redirect_without_location"))?;
                let next = current
                    .join(location)
                    .map_err(|_| blocked("redirect_invalid"))?;
                current = validate_public_url(next.as_str())?;
                continue;
            }
            return read_capped(resp, current.as_str(), max_bytes).await;
        }
        Err(blocked("too_many_redirects"))
    }

    /// Sends a JSON request (e.g. remote MCP) with redirects disabled and a streamed body cap.
    pub async fn send_json(
        &self,
        method: Method,
        url: &str,
        headers: reqwest::header::HeaderMap,
        body: &serde_json::Value,
        max_bytes: usize,
    ) -> BistreResult<(StatusCode, reqwest::header::HeaderMap, Vec<u8>)> {
        let client = self.client()?;
        let target = validate_public_url(url)?;
        let resp = client
            .request(method, target)
            .headers(headers)
            .json(body)
            .send()
            .await
            .map_err(|_| {
                BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_connect")
            })?;
        let status = resp.status();
        if status.is_redirection() {
            return Err(blocked("redirect_refused"));
        }
        let resp_headers = resp.headers().clone();
        let fetched = read_capped(resp, url, max_bytes).await?;
        Ok((status, resp_headers, fetched.body))
    }
}

async fn read_capped(
    mut resp: reqwest::Response,
    final_url: &str,
    max_bytes: usize,
) -> BistreResult<PublicFetch> {
    let status = resp.status().as_u16();
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
        .to_owned();
    let mut body = Vec::new();
    let mut truncated = false;
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|_| BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "body_read"))?
    {
        let room = max_bytes.saturating_sub(body.len());
        if chunk.len() > room {
            body.extend_from_slice(&chunk[..room]);
            truncated = true;
            break;
        }
        body.extend_from_slice(&chunk);
    }
    Ok(PublicFetch {
        final_url: final_url.to_owned(),
        status,
        content_type,
        body,
        truncated,
    })
}

/// Parses and validates a URL for public egress (scheme, credentials, host, literal IPs).
pub fn validate_public_url(raw: &str) -> BistreResult<Url> {
    let url = Url::parse(raw.trim()).map_err(|_| blocked("invalid_url"))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(blocked("scheme"));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(blocked("embedded_credentials"));
    }
    let host = url.host_str().ok_or_else(|| blocked("missing_host"))?;
    if host.contains('%') {
        return Err(blocked("scoped_address"));
    }
    let lower = host.trim_end_matches('.').to_ascii_lowercase();
    if lower == "localhost" || lower.ends_with(".localhost") {
        return Err(blocked("localhost"));
    }
    let literal = lower.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = literal.parse::<IpAddr>()
        && !is_public_ip(ip)
    {
        return Err(blocked("non_public_ip"));
    }
    Ok(url)
}

/// Returns `true` only for globally routable unicast addresses.
pub fn is_public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => is_public_v6(v6),
    }
}

fn in_v4(ip: Ipv4Addr, net: [u8; 4], prefix: u32) -> bool {
    let mask = if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    };
    (u32::from(ip) & mask) == (u32::from(Ipv4Addr::from(net)) & mask)
}

fn is_public_v4(ip: Ipv4Addr) -> bool {
    const BLOCKED: [([u8; 4], u32); 16] = [
        ([0, 0, 0, 0], 8),       // "this network"
        ([10, 0, 0, 0], 8),      // RFC 1918
        ([100, 64, 0, 0], 10),   // CGNAT shared address space
        ([127, 0, 0, 0], 8),     // loopback
        ([169, 254, 0, 0], 16),  // link-local (cloud metadata)
        ([172, 16, 0, 0], 12),   // RFC 1918
        ([192, 0, 0, 0], 24),    // IETF protocol assignments
        ([192, 0, 2, 0], 24),    // TEST-NET-1
        ([192, 31, 196, 0], 24), // AS112-v4
        ([192, 52, 193, 0], 24), // AMT
        ([192, 88, 99, 0], 24),  // deprecated 6to4 relay anycast
        ([192, 168, 0, 0], 16),  // RFC 1918
        ([198, 18, 0, 0], 15),   // benchmarking
        ([198, 51, 100, 0], 24), // TEST-NET-2
        ([203, 0, 113, 0], 24),  // TEST-NET-3
        ([224, 0, 0, 0], 3),     // multicast (224/4) + reserved (240/4) + broadcast
    ];
    !BLOCKED.iter().any(|&(net, prefix)| in_v4(ip, net, prefix))
}

fn in_v6(ip: Ipv6Addr, net: [u16; 8], prefix: u32) -> bool {
    let mask = if prefix == 0 {
        0
    } else {
        u128::MAX << (128 - prefix)
    };
    (u128::from(ip) & mask) == (u128::from(Ipv6Addr::from(net)) & mask)
}

/// IANA special-purpose IPv6 blocks (beyond IPv4-mapped / NAT64 handling).
const BLOCKED_V6: [([u16; 8], u32); 12] = [
    ([0, 0, 0, 0, 0, 0, 0, 0], 96), // unspecified, loopback, IPv4-compatible
    ([0x64, 0xff9b, 1, 0, 0, 0, 0, 0], 48), // local-use NAT64
    ([0x100, 0, 0, 0, 0, 0, 0, 0], 64), // discard-only
    ([0x2001, 0, 0, 0, 0, 0, 0, 0], 23), // IETF protocol assignments (incl. Teredo)
    ([0x2001, 0xdb8, 0, 0, 0, 0, 0, 0], 32), // documentation
    ([0x2002, 0, 0, 0, 0, 0, 0, 0], 16), // 6to4
    ([0x3fff, 0, 0, 0, 0, 0, 0, 0], 20), // documentation (RFC 9637)
    ([0x5f00, 0, 0, 0, 0, 0, 0, 0], 16), // segment routing SIDs
    ([0xfc00, 0, 0, 0, 0, 0, 0, 0], 7), // unique local
    ([0xfe80, 0, 0, 0, 0, 0, 0, 0], 10), // link-local
    ([0xfec0, 0, 0, 0, 0, 0, 0, 0], 10), // deprecated site-local
    ([0xff00, 0, 0, 0, 0, 0, 0, 0], 8), // multicast
];

fn is_public_v6(ip: Ipv6Addr) -> bool {
    if let Some(v4) = ip.to_ipv4_mapped() {
        return is_public_v4(v4);
    }
    // NAT64 well-known prefix embeds an IPv4 destination in the low 32 bits.
    if in_v6(ip, [0x64, 0xff9b, 0, 0, 0, 0, 0, 0], 96) {
        let low = u32::try_from(u128::from(ip) & 0xffff_ffff).unwrap_or(0);
        return is_public_v4(Ipv4Addr::from(low));
    }
    !BLOCKED_V6
        .iter()
        .any(|&(net, prefix)| in_v6(ip, net, prefix))
}

/// DNS resolver that only ever hands public addresses to the connector.
#[derive(Debug, Clone, Copy)]
struct PublicOnlyDnsResolver;

impl Resolve for PublicOnlyDnsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_owned();
        Box::pin(async move {
            let lower = host.trim_end_matches('.').to_ascii_lowercase();
            if lower == "localhost" || lower.ends_with(".localhost") {
                return Err(
                    Box::new(blocked("localhost")) as Box<dyn std::error::Error + Send + Sync>
                );
            }
            let resolved: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), 0))
                .await
                .map_err(|e| Box::new(e) as Box<dyn std::error::Error + Send + Sync>)?
                .filter(|addr| is_public_ip(addr.ip()))
                .collect();
            if resolved.is_empty() {
                return Err(Box::new(blocked("no_public_address"))
                    as Box<dyn std::error::Error + Send + Sync>);
            }
            let addrs: Addrs = Box::new(resolved.into_iter());
            Ok(addrs)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED))
    }

    #[test]
    fn iana_special_purpose_ranges_are_blocked() {
        for blocked_ip in [
            "0.0.0.0",
            "10.1.2.3",
            "100.64.0.1",
            "100.127.255.254",
            "127.0.0.1",
            "169.254.169.254",
            "172.16.0.1",
            "172.31.255.255",
            "192.0.0.8",
            "192.0.2.1",
            "192.168.1.1",
            "198.18.0.1",
            "198.51.100.7",
            "203.0.113.9",
            "224.0.0.1",
            "240.0.0.1",
            "255.255.255.255",
            "::",
            "::1",
            "::ffff:127.0.0.1",
            "::ffff:10.0.0.1",
            "64:ff9b::a00:1",
            "2001:db8::1",
            "2001::1",
            "2002::1",
            "3fff::1",
            "fc00::1",
            "fd12:3456::1",
            "fe80::1",
            "ff02::1",
        ] {
            assert!(
                !is_public_ip(ip(blocked_ip)),
                "{blocked_ip} must be blocked"
            );
        }
        for public_ip in [
            "1.1.1.1",
            "8.8.8.8",
            "100.128.0.1",
            "172.32.0.1",
            "2606:4700::1111",
            "64:ff9b::808:808",
            "::ffff:8.8.8.8",
        ] {
            assert!(is_public_ip(ip(public_ip)), "{public_ip} must be allowed");
        }
    }

    #[test]
    fn url_validation_rejects_local_credential_and_scoped_targets() {
        assert!(validate_public_url("https://example.com/page").is_ok());
        for bad in [
            "file:///etc/passwd",
            "ftp://example.com",
            "http://localhost:8080",
            "http://api.localhost/",
            "http://127.0.0.1/",
            "http://[::1]/",
            "http://[fe80::1%25eth0]/",
            "http://user:pass@example.com/",
            "http://169.254.169.254/latest/meta-data",
            "http://0x7f000001/",
        ] {
            let res = validate_public_url(bad);
            assert!(res.is_err(), "{bad} must be rejected");
        }
    }

    #[tokio::test]
    async fn transport_refuses_loopback_even_via_dns_names() {
        let transport = PublicWebTransport::new();
        let direct = transport.get("http://127.0.0.1:9/", 1024).await;
        assert_eq!(
            direct.err().map(|e| e.key),
            Some(DiagnosticKey::NetworkDestinationBlocked)
        );
        let named = transport.get("http://localhost:9/", 1024).await;
        assert!(named.is_err());
    }
}
