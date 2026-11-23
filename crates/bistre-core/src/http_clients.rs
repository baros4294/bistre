//! The only place that builds `reqwest` clients (`clippy.toml` bans the builders elsewhere).
//!
//! Three policies exist, each built once per engine:
//! - **provider**: the shared provider client (OS verifier, keepalive, 300 s first-token read).
//! - **loopback**: local MCP servers and local-server discovery (no proxy, no redirects).
//! - **public web**: model-directed fetches through `PublicWebTransport` (public-IP pinning).
#![expect(
    clippy::disallowed_methods,
    reason = "the single sanctioned module for constructing reqwest clients"
)]

use std::sync::Arc;
use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};

use crate::providers::ensure_tls_provider;
use crate::sse::INITIAL_LINE_TIMEOUT;

const USER_AGENT: &str = concat!("Bistre/", env!("CARGO_PKG_VERSION"));

/// Builds the shared provider client. The socket read timeout equals the 300 s first-token
/// budget; the tighter 90 s idle budget between chunks is enforced by the stream loop.
pub fn provider_client() -> BistreResult<reqwest::Client> {
    ensure_tls_provider();
    reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .connect_timeout(Duration::from_secs(15))
        .read_timeout(INITIAL_LINE_TIMEOUT)
        .tcp_keepalive(Duration::from_secs(15))
        .build()
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "http_client_init"))
}

/// Builds a loopback-only client: no proxy, redirects refused, `timeout` per request.
pub fn loopback_client(connect: Duration, timeout: Duration) -> BistreResult<reqwest::Client> {
    ensure_tls_provider();
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(connect)
        .timeout(timeout)
        .build()
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "loopback_client_init"))
}

/// Builds the public-web client around a DNS resolver that admits only public addresses.
pub fn public_web_client(
    resolver: Arc<dyn reqwest::dns::Resolve>,
) -> Result<reqwest::Client, reqwest::Error> {
    ensure_tls_provider();
    reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .dns_resolver(resolver)
        .connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(30))
        .timeout(Duration::from_secs(60))
        .build()
}
