//! Zero-telemetry Track-A & Track-B Signed OTA Update Client (Spec 10, ADR-0008).
//!
//! Invariants:
//! - Plain HTTPS GET of static `manifest.json` (+ optional `.minisig`), zero telemetry/device IDs.
//! - Offline Ed25519 signature verification via `bistre_crypto::verify_minisign_bytes` + SHA-256 check.
//! - HTTPS-only feeds and downloads (plain `http://` only for loopback test feeds).
//! - Mandatory SHA-256 (`hex` or GitHub `asset.digest` `sha256:<hex>`), streamed in 64 KiB chunks
//!   with a hard 256 MiB cap; never buffered whole in RAM.
//! - Full `SemVer` 2.0 precedence including prereleases (`1.0.0 > 1.0.0-rc.10 > 1.0.0-rc.2`).
//! - Track B never interrupts active runs (`active_runs > 0` returns `OtaActiveRunsDeferred`).
//! - Automatically detects Linux Flatpak/Snap/system-managed installs and disables self-update.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use std::io::Write as _;

use bistre_crypto::{Sha256Stream, verify_minisign_bytes};
use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, UpdateCheckResult};
use serde::Deserialize;

/// Hard cap on a staged OTA payload.
pub const MAX_OTA_PAYLOAD_BYTES: u64 = 256 * 1024 * 1024;
/// Hard cap on a manifest or signature document.
const MAX_OTA_MANIFEST_BYTES: usize = 1024 * 1024;

/// Public Ed25519 Minisign verification key for official Bistre releases (empty until release signing key is provisioned).
pub const OFFICIAL_RELEASE_PUBKEY_B64: &str = "";

#[derive(Debug, Deserialize)]
struct RemoteUpdateManifest {
    #[serde(default)]
    version: String,
    #[serde(default)]
    semver: String,
    #[serde(default = "default_track")]
    track: String,
    #[serde(default)]
    release_notes: String,
    #[serde(default)]
    download_url: String,
    #[serde(default)]
    sha256_hex: String,
    #[serde(default)]
    download_size_bytes: u64,
}

/// A manifest whose minisign signature verified against the release key.
///
/// Only [`check_for_updates`] constructs it (private fields, no `Deserialize`), so staging can
/// never act on a URL or digest that did not come from a signed manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedManifest {
    latest_version: String,
    track: String,
    ownership_mode: String,
    download_url: String,
    sha256_hex: String,
    download_size_bytes: u64,
}

impl VerifiedManifest {
    /// The version this signed manifest offers.
    pub fn latest_version(&self) -> &str {
        &self.latest_version
    }
}

fn default_track() -> String {
    "track_b".to_owned()
}

/// Detects whether the current executable is owned by an external package manager (Spec 10).
pub fn detect_ownership_mode() -> &'static str {
    if std::env::var_os("FLATPAK_ID").is_some_and(|v| !v.is_empty()) {
        return "flatpak";
    }
    if std::env::var_os("SNAP").is_some_and(|v| !v.is_empty()) {
        return "snap";
    }
    if let Ok(exe) = std::env::current_exe() {
        let s = exe.to_string_lossy();
        if s.starts_with("/usr/") || s.starts_with("/opt/") {
            return "system_package_manager";
        }
    }
    "self_managed"
}

/// Resolves the release key: an explicit key wins, then the embedded official key.
/// No key means OTA is disabled (fail closed); the signature check is never skipped.
fn resolve_release_key(release_key: Option<&str>) -> BistreResult<&str> {
    release_key
        .map(str::trim)
        .filter(|k| !k.is_empty())
        .or_else(|| Some(OFFICIAL_RELEASE_PUBKEY_B64.trim()).filter(|k| !k.is_empty()))
        .ok_or_else(|| BistreError::new(DiagnosticKey::OtaSigningKeyMissing))
}

/// Performs a zero-telemetry check against `feed_url` (static JSON manifest + mandatory `.minisig`).
pub async fn check_for_updates(
    http: &reqwest::Client,
    feed_url: &str,
    current_version: &str,
    active_runs: u32,
    release_key: Option<&str>,
) -> BistreResult<(UpdateCheckResult, VerifiedManifest)> {
    let pk = resolve_release_key(release_key)?;
    let ownership = detect_ownership_mode();
    let trimmed = require_secure_url(feed_url, "invalid_feed_url")?;

    let resp = http
        .get(trimmed)
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .await
        .map_err(|_| BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "connect"))?;
    if !resp.status().is_success() {
        return Err(BistreError::with_detail(
            DiagnosticKey::OtaCheckFailed,
            format!("http_{}", resp.status().as_u16()),
        ));
    }
    let manifest_bytes = read_bounded(resp, MAX_OTA_MANIFEST_BYTES, "read_manifest").await?;

    let sig_url = format!("{trimmed}.minisig");
    let sig_resp = http
        .get(&sig_url)
        .send()
        .await
        .map_err(|_| BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "sig_fetch"))?;
    if !sig_resp.status().is_success() {
        return Err(BistreError::new(DiagnosticKey::CryptoSignatureInvalid));
    }
    let sig_bytes = read_bounded(sig_resp, MAX_OTA_MANIFEST_BYTES, "read_signature").await?;
    let sig_text = String::from_utf8(sig_bytes)
        .map_err(|_| BistreError::new(DiagnosticKey::CryptoSignatureInvalid))?;
    verify_minisign_bytes(pk, &manifest_bytes, &sig_text)?;

    let parsed: RemoteUpdateManifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "manifest_json"))?;
    let latest_version = if !parsed.semver.trim().is_empty() {
        parsed.semver.trim().to_owned()
    } else if !parsed.version.trim().is_empty() {
        parsed.version.trim().to_owned()
    } else {
        current_version.to_owned()
    };

    let update_available = is_semver_newer(&latest_version, current_version);
    // A signed manifest without a valid digest is unusable; refuse it at check time.
    let sha256_hex = normalize_sha256(&parsed.sha256_hex).ok_or_else(|| {
        BistreError::with_detail(DiagnosticKey::OtaIntegrityFailed, "ota_sha256_missing")
    })?;

    let verified = VerifiedManifest {
        latest_version: latest_version.clone(),
        track: parsed.track.clone(),
        ownership_mode: ownership.to_owned(),
        download_url: parsed.download_url.clone(),
        sha256_hex: sha256_hex.clone(),
        download_size_bytes: parsed.download_size_bytes,
    };
    let summary = UpdateCheckResult {
        current_version: current_version.to_owned(),
        latest_version,
        update_available,
        track: parsed.track,
        ownership_mode: ownership.to_owned(),
        signature_verified: true,
        active_runs_blocking: active_runs > 0,
        release_notes: parsed.release_notes,
        download_url: parsed.download_url,
        sha256_hex,
        download_size_bytes: parsed.download_size_bytes,
        checked_at_ms: now_unix_ms(),
    };
    Ok((summary, verified))
}

/// Downloads and verifies an OTA payload offline via SHA-256 before staging into `<data_dir>/ota_staging/`.
/// Never overwrites active running binaries and defers Track-B staging when `active_runs > 0`.
pub async fn stage_update_artifact(
    http: &reqwest::Client,
    data_dir: &Path,
    check: &VerifiedManifest,
    active_runs: u32,
) -> BistreResult<String> {
    if check.ownership_mode != "self_managed" && check.track == "track_b" {
        return Err(BistreError::new(DiagnosticKey::OtaManagedExternally));
    }
    if check.track == "track_b" && active_runs > 0 {
        return Err(BistreError::new(DiagnosticKey::OtaActiveRunsDeferred));
    }
    let url = require_secure_url(&check.download_url, "invalid_download_url")?;
    // A payload without a digest can never be staged (no silent "skip verification").
    let expected_sha = normalize_sha256(&check.sha256_hex).ok_or_else(|| {
        BistreError::with_detail(DiagnosticKey::OtaIntegrityFailed, "ota_sha256_missing")
    })?;
    if check.download_size_bytes > MAX_OTA_PAYLOAD_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::OtaIntegrityFailed,
            "ota_payload_too_large",
        ));
    }

    let mut resp =
        http.get(url).send().await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "download_connect")
        })?;
    if !resp.status().is_success() {
        return Err(BistreError::with_detail(
            DiagnosticKey::OtaCheckFailed,
            format!("download_http_{}", resp.status().as_u16()),
        ));
    }
    if resp
        .content_length()
        .is_some_and(|len| len > MAX_OTA_PAYLOAD_BYTES)
    {
        return Err(BistreError::with_detail(
            DiagnosticKey::OtaIntegrityFailed,
            "ota_payload_too_large",
        ));
    }

    let safe_ver: String = check
        .latest_version
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .collect();
    let slot_name = if safe_ver.is_empty() {
        "staged".to_owned()
    } else {
        safe_ver
    };
    let staging_dir = data_dir.join("ota_staging").join(&slot_name);
    std::fs::create_dir_all(&staging_dir)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_dir"))?;
    let artifact_path = staging_dir.join("payload.bin");
    let partial_path = staging_dir.join("payload.bin.partial");

    // Stream chunks (reqwest yields <= 64 KiB frames) into the hasher and a partial file.
    let mut file = std::fs::File::create(&partial_path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_write"))?;
    let mut hasher = Sha256Stream::new();
    let mut written: u64 = 0;
    let streamed: BistreResult<()> =
        async {
            while let Some(chunk) = resp.chunk().await.map_err(|_| {
                BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "download_read")
            })? {
                written = written.saturating_add(u64::try_from(chunk.len()).unwrap_or(u64::MAX));
                if written > MAX_OTA_PAYLOAD_BYTES {
                    return Err(BistreError::with_detail(
                        DiagnosticKey::OtaIntegrityFailed,
                        "ota_payload_too_large",
                    ));
                }
                hasher.update(&chunk);
                file.write_all(&chunk).map_err(|_| {
                    BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_write")
                })?;
            }
            file.sync_all().map_err(|_| {
                BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_write")
            })
        }
        .await;
    drop(file);
    let verified = streamed.and_then(|()| {
        if check.download_size_bytes > 0 && written != check.download_size_bytes {
            return Err(BistreError::with_detail(
                DiagnosticKey::OtaIntegrityFailed,
                "ota_size_mismatch",
            ));
        }
        if hasher.finalize_hex() == expected_sha {
            Ok(())
        } else {
            Err(BistreError::with_detail(
                DiagnosticKey::OtaIntegrityFailed,
                "ota_sha256_mismatch",
            ))
        }
    });
    if let Err(err) = verified {
        if std::fs::remove_file(&partial_path).is_err() {
            tracing::debug!("could not remove unverified OTA partial payload");
        }
        return Err(err);
    }
    std::fs::rename(&partial_path, &artifact_path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_write"))?;

    Ok(artifact_path.to_string_lossy().into_owned())
}

/// Requires `https://` (or `http://` strictly for loopback test feeds) and returns the trimmed URL.
fn require_secure_url<'a>(raw: &'a str, detail: &'static str) -> BistreResult<&'a str> {
    let url = raw.trim();
    let lower = url.to_ascii_lowercase();
    let loopback_http = lower.starts_with("http://127.0.0.1")
        || lower.starts_with("http://localhost")
        || lower.starts_with("http://[::1]");
    if lower.starts_with("https://") || loopback_http {
        Ok(url)
    } else {
        Err(BistreError::with_detail(
            DiagnosticKey::OtaCheckFailed,
            detail,
        ))
    }
}

/// Accepts `<64 hex>` or GitHub's `sha256:<64 hex>` digest form; returns lowercase hex.
pub fn normalize_sha256(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let hex_part = trimmed
        .strip_prefix("sha256:")
        .or_else(|| trimmed.strip_prefix("SHA256:"))
        .unwrap_or(trimmed);
    (hex_part.len() == 64 && hex_part.bytes().all(|b| b.is_ascii_hexdigit()))
        .then(|| hex_part.to_ascii_lowercase())
}

async fn read_bounded(
    mut resp: reqwest::Response,
    max: usize,
    detail: &'static str,
) -> BistreResult<Vec<u8>> {
    let mut out = Vec::new();
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|_| BistreError::with_detail(DiagnosticKey::OtaCheckFailed, detail))?
    {
        if out.len() + chunk.len() > max {
            return Err(BistreError::with_detail(
                DiagnosticKey::OtaCheckFailed,
                detail,
            ));
        }
        out.extend_from_slice(&chunk);
    }
    Ok(out)
}

/// Parsed `SemVer` 2.0 version (build metadata ignored for precedence).
#[derive(Debug, Clone, PartialEq, Eq)]
struct SemVer {
    core: (u64, u64, u64),
    pre: Vec<PreId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum PreId {
    Num(u64),
    Alpha(String),
}

impl PartialOrd for PreId {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for PreId {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        match (self, other) {
            (Self::Num(a), Self::Num(b)) => a.cmp(b),
            (Self::Num(_), Self::Alpha(_)) => Ordering::Less,
            (Self::Alpha(_), Self::Num(_)) => Ordering::Greater,
            (Self::Alpha(a), Self::Alpha(b)) => a.cmp(b),
        }
    }
}

impl PartialOrd for SemVer {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for SemVer {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        self.core.cmp(&other.core).then_with(|| {
            match (self.pre.is_empty(), other.pre.is_empty()) {
                (true, true) => Ordering::Equal,
                // A release outranks any of its prereleases.
                (true, false) => Ordering::Greater,
                (false, true) => Ordering::Less,
                (false, false) => self.pre.cmp(&other.pre),
            }
        })
    }
}

fn parse_semver(raw: &str) -> SemVer {
    let trimmed = raw.trim().trim_start_matches('v');
    let no_build = trimmed.split('+').next().unwrap_or("");
    let (core_str, pre_str) = no_build.split_once('-').unwrap_or((no_build, ""));
    let mut parts = core_str.split('.').map(|s| s.parse::<u64>().unwrap_or(0));
    let core = (
        parts.next().unwrap_or(0),
        parts.next().unwrap_or(0),
        parts.next().unwrap_or(0),
    );
    let pre = if pre_str.is_empty() {
        Vec::new()
    } else {
        pre_str
            .split('.')
            .map(|id| {
                if !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()) {
                    id.parse::<u64>()
                        .map_or_else(|_| PreId::Alpha(id.to_owned()), PreId::Num)
                } else {
                    PreId::Alpha(id.to_owned())
                }
            })
            .collect()
    };
    SemVer { core, pre }
}

/// `SemVer` 2.0 precedence check guarding against downgrade attacks (prereleases included).
pub fn is_semver_newer(candidate: &str, current: &str) -> bool {
    parse_semver(candidate) > parse_semver(current)
}

fn now_unix_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    #[test]
    fn semver_anti_rollback_compares_triples_monotonically() {
        assert!(is_semver_newer("0.2.0", "0.1.0"));
        assert!(is_semver_newer("v1.0.1", "1.0.0"));
        assert!(!is_semver_newer("0.1.0", "0.1.0"));
        assert!(!is_semver_newer("0.0.9", "0.1.0"));
    }

    #[test]
    fn semver_prerelease_precedence_follows_semver_2() {
        assert!(is_semver_newer("1.0.0", "1.0.0-rc.1"));
        assert!(is_semver_newer("1.0.0-rc.10", "1.0.0-rc.2"));
        assert!(is_semver_newer("1.0.0-rc.1", "1.0.0-beta.11"));
        assert!(is_semver_newer("1.0.0-alpha.1", "1.0.0-alpha"));
        assert!(is_semver_newer("1.0.0-alpha.beta", "1.0.0-alpha.1"));
        assert!(!is_semver_newer("1.0.0-rc.1", "1.0.0"));
        assert!(!is_semver_newer("1.0.0+build.9", "1.0.0+build.1"));
    }

    #[test]
    fn digest_and_url_policy() {
        let hex = "a".repeat(64);
        assert_eq!(
            normalize_sha256(&format!("sha256:{}", hex.to_uppercase())),
            Some(hex.clone())
        );
        assert_eq!(normalize_sha256(&hex), Some(hex));
        assert_eq!(normalize_sha256(""), None);
        assert_eq!(normalize_sha256("sha256:abc"), None);
        assert!(require_secure_url("https://example.com/m.json", "x").is_ok());
        assert!(require_secure_url("http://127.0.0.1:8080/m.json", "x").is_ok());
        assert!(require_secure_url("http://example.com/m.json", "x").is_err());
        assert!(require_secure_url("file:///m.json", "x").is_err());
    }

    #[tokio::test]
    async fn staging_requires_digest_and_rejects_mismatch() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let dir = tempfile::tempdir().ok();
        let Some(dir) = dir else { return };
        let http = crate::providers::build_http_client().ok();
        let Some(http) = http else { return };
        let mut check = VerifiedManifest {
            latest_version: "0.2.0".to_owned(),
            track: "track_a".to_owned(),
            ownership_mode: "self_managed".to_owned(),
            download_url: "https://example.invalid/payload.bin".to_owned(),
            sha256_hex: String::new(),
            download_size_bytes: 0,
        };
        let missing = stage_update_artifact(&http, dir.path(), &check, 0).await;
        assert_eq!(
            missing.err().and_then(|e| e.detail_code),
            Some("ota_sha256_missing".to_owned())
        );

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.ok();
        let Some(listener) = listener else { return };
        let Ok(addr) = listener.local_addr() else {
            return;
        };
        let server = tokio::spawn(async move {
            if let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = [0_u8; 2048];
                assert!(sock.read(&mut buf).await.is_ok());
                let body = b"tampered payload";
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                assert!(sock.write_all(head.as_bytes()).await.is_ok());
                assert!(sock.write_all(body).await.is_ok());
            }
        });
        check.download_url = format!("http://{addr}/payload.bin");
        check.sha256_hex = format!("sha256:{}", "0".repeat(64));
        let mismatch = stage_update_artifact(&http, dir.path(), &check, 0).await;
        assert!(server.await.is_ok());
        assert_eq!(
            mismatch.err().and_then(|e| e.detail_code),
            Some("ota_sha256_mismatch".to_owned())
        );
        assert!(!dir.path().join("ota_staging/0.2.0/payload.bin").exists());
        assert!(
            !dir.path()
                .join("ota_staging/0.2.0/payload.bin.partial")
                .exists()
        );
    }

    // Test-only minisign fixture: an "ED" (prehashed) signature over FIXTURE_MANIFEST made with a
    // throwaway key (never a release key).
    pub(crate) const FIXTURE_PK: &str = "RWRCSVNUUkV0MWEBxHXSIGJ4C8G3ReVjuabeBd/WF2rozJyuOTRnJouN";
    pub(crate) const FIXTURE_MANIFEST: &str = r#"{"semver":"0.2.0","track":"track_b","release_notes":"Faster startup","download_url":"https://example.invalid/bistre.zip","sha256_hex":"sha256:0000000000000000000000000000000000000000000000000000000000000000","download_size_bytes":1024}"#;
    pub(crate) const FIXTURE_SIG: &str = "untrusted comment: bistre test fixture\n\
RURCSVNUUkV0MXBQ7FNd/i7zyRjC8EbgpoSjpHWzuDE/kRmraKDhHaoV4RzqQKa4vgc4wgBM9R8n+kIGu6m2daOYReIjleFdjgc=\n\
trusted comment: timestamp:0\tfile:manifest.json\tprehashed\n\
AcVYMmpeIXCzgxq42h3Z3qKtmljay0AsdPqX+qkYbcHmmZxkYR/OZWqy1u7S4gT4X4e+aTVNH15wDFXG4biqCA==\n";

    /// Serves `manifest` at any path and `sig` (or 404 when `None`) at `*.minisig`, for up to
    /// `max_requests` connections.
    pub(crate) async fn serve_feed(
        manifest: &'static str,
        sig: Option<&'static str>,
        max_requests: usize,
    ) -> Result<(std::net::SocketAddr, tokio::task::JoinHandle<()>), std::io::Error> {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        let handle = tokio::spawn(async move {
            for _ in 0..max_requests {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let mut buf = [0_u8; 2048];
                let Ok(n) = sock.read(&mut buf).await else {
                    return;
                };
                let req = String::from_utf8_lossy(&buf[..n]);
                let body = if req.contains(".minisig") { sig } else { Some(manifest) };
                let resp = match body {
                    Some(b) => format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{b}",
                        b.len()
                    ),
                    None => {
                        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            .to_owned()
                    }
                };
                if sock.write_all(resp.as_bytes()).await.is_err() {
                    return;
                }
            }
        });
        Ok((addr, handle))
    }

    #[tokio::test]
    async fn missing_release_key_disables_ota_before_any_request() -> Result<(), Box<dyn std::error::Error>> {
        let http = crate::providers::build_http_client()?;
        // Port 9 (discard) is never contacted: the key check runs first.
        let res = check_for_updates(&http, "http://127.0.0.1:9/manifest.json", "0.1.0", 0, None).await;
        assert_eq!(res.err().map(|e| e.key), Some(DiagnosticKey::OtaSigningKeyMissing));
        Ok(())
    }

    #[tokio::test]
    async fn signed_manifest_yields_verified_manifest() -> Result<(), Box<dyn std::error::Error>> {
        let http = crate::providers::build_http_client()?;
        let (addr, server) = serve_feed(FIXTURE_MANIFEST, Some(FIXTURE_SIG), 2).await?;
        let (summary, verified) = check_for_updates(
            &http,
            &format!("http://{addr}/manifest.json"),
            "0.1.0",
            0,
            Some(FIXTURE_PK),
        )
        .await?;
        server.await?;
        assert!(summary.signature_verified);
        assert!(summary.update_available);
        assert_eq!(verified.latest_version(), "0.2.0");
        assert_eq!(verified.download_url, "https://example.invalid/bistre.zip");
        Ok(())
    }

    #[tokio::test]
    async fn tampered_or_unsigned_manifest_is_rejected() -> Result<(), Box<dyn std::error::Error>> {
        let http = crate::providers::build_http_client()?;
        let tampered: &'static str = r#"{"semver":"9.9.9","track":"track_b","release_notes":"","download_url":"https://evil.invalid/x","sha256_hex":"sha256:0000000000000000000000000000000000000000000000000000000000000000","download_size_bytes":1}"#;
        let (addr, server) = serve_feed(tampered, Some(FIXTURE_SIG), 2).await?;
        let res = check_for_updates(&http, &format!("http://{addr}/m.json"), "0.1.0", 0, Some(FIXTURE_PK)).await;
        server.await?;
        assert_eq!(res.err().map(|e| e.key), Some(DiagnosticKey::CryptoSignatureInvalid));

        let (addr, server) = serve_feed(FIXTURE_MANIFEST, None, 2).await?;
        let res = check_for_updates(&http, &format!("http://{addr}/m.json"), "0.1.0", 0, Some(FIXTURE_PK)).await;
        server.await?;
        assert_eq!(res.err().map(|e| e.key), Some(DiagnosticKey::CryptoSignatureInvalid));
        Ok(())
    }
}
