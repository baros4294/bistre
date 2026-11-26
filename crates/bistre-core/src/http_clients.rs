//! The only place that builds `reqwest` clients (`clippy.toml` bans the builders elsewhere).
//!
//! Four policies exist, each built once per engine:
//! - **provider**: the shared provider client (OS verifier, keepalive, 300 s first-token read).
//!   It follows **no** redirects: a cross-host redirect would carry `x-api-key` /
//!   `x-goog-api-key` and, for 307/308, the request body (R6).
//! - **OTA**: update feeds and artifacts; credential-free, so it follows at most
//!   [`MAX_OTA_REDIRECTS`] redirects, each to `https` (or a loopback test host).
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
    provider_client_builder()
        .build()
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "http_client_init"))
}

/// The provider client for tests, resolving `host` to a loopback mock server so a request is
/// treated as a paid, non-local provider.
#[cfg(test)]
pub(crate) fn provider_client_resolving(
    host: &str,
    addr: std::net::SocketAddr,
) -> BistreResult<reqwest::Client> {
    provider_client_builder()
        .resolve(host, addr)
        .build()
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "http_client_init"))
}

fn provider_client_builder() -> reqwest::ClientBuilder {
    ensure_tls_provider();
    reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(15))
        .read_timeout(INITIAL_LINE_TIMEOUT)
        .tcp_keepalive(Duration::from_secs(15))
}

/// Most redirects an OTA feed or artifact request follows.
pub const MAX_OTA_REDIRECTS: usize = 6;

/// Builds the OTA client: no credentials ever ride on it, so it may follow GitHub's release
/// redirects, but only [`MAX_OTA_REDIRECTS`] of them and only to `https` (a loopback `http`
/// host is allowed for local feeds, decided by `net::is_loopback_url`).
pub fn ota_client() -> BistreResult<reqwest::Client> {
    ensure_tls_provider();
    reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            let secure = attempt.url().scheme() == "https"
                || crate::net::is_loopback_url(attempt.url().as_str());
            if attempt.previous().len() >= MAX_OTA_REDIRECTS {
                attempt.error("too many OTA redirects")
            } else if !secure {
                attempt.error("insecure OTA redirect")
            } else {
                attempt.follow()
            }
        }))
        .connect_timeout(Duration::from_secs(15))
        .read_timeout(Duration::from_secs(60))
        .build()
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "ota_client_init"))
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

#[cfg(test)]
mod tests {
    use crate::test_support::{MockServer, Scripted};

    /// The OTA client follows redirects (GitHub release links) but never to plain `http` on a
    /// public host.
    #[tokio::test]
    async fn ota_redirects_only_to_https_or_loopback() -> Result<(), Box<dyn std::error::Error>> {
        let target = MockServer::start(vec![Scripted::status(200)]).await?;
        let origin = MockServer::start(vec![
            Scripted::status(302).with_header("Location", &format!("{}/asset", target.base())),
            Scripted::status(302).with_header("Location", "http://example.com/asset"),
        ])
        .await?;
        let client = super::ota_client()?;
        let followed = client.get(format!("{}/feed", origin.base())).send().await?;
        assert_eq!(followed.status(), 200, "loopback redirect is followed");
        let insecure = client.get(format!("{}/feed", origin.base())).send().await;
        assert!(insecure.is_err(), "plain http on a public host is refused");
        drop((origin.finish().await, target.finish().await));
        Ok(())
    }
}
