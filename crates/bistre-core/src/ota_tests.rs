//! Unit tests for `ota.rs`.

use super::*;

pub(crate) type TestResult = Result<(), Box<dyn std::error::Error>>;

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
    // Loopback is decided by the parsed host, never a string prefix.
    assert!(require_secure_url("http://localhost.evil.com/m.json", "x").is_err());
    assert!(require_secure_url("http://127.0.0.1.evil.com/m.json", "x").is_err());
    assert!(require_secure_url("http://localhost:8080/m.json", "x").is_ok());
    assert!(require_secure_url("http://[::1]:9/m.json", "x").is_ok());
}

/// A signed manifest that is not strictly newer than the running version is never
/// staged (replayed older manifests are downgrades).
#[tokio::test]
async fn staging_refuses_a_version_that_is_not_newer() -> TestResult {
    let dir = tempfile::tempdir()?;
    let http = crate::http_clients::ota_client()?;
    for version in ["0.1.2", "0.1.1", "0.1.2-rc.1"] {
        let check = VerifiedManifest {
            latest_version: version.to_owned(),
            track: "track_a".to_owned(),
            ownership_mode: "self_managed".to_owned(),
            download_url: "https://example.invalid/payload.bin".to_owned(),
            sha256_hex: "a".repeat(64),
            download_size_bytes: 1,
        };
        let staged = stage_update_artifact(&http, dir.path(), &check, "0.1.2", 0).await;
        assert_eq!(
            staged.err().and_then(|e| e.detail_code),
            Some("ota_not_newer".to_owned()),
            "{version}"
        );
    }
    Ok(())
}

#[tokio::test]
async fn staging_requires_digest_and_rejects_mismatch() -> TestResult {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let dir = tempfile::tempdir()?;
    let http = crate::providers::build_http_client()?;
    let mut check = VerifiedManifest {
        latest_version: "0.2.0".to_owned(),
        track: "track_a".to_owned(),
        ownership_mode: "self_managed".to_owned(),
        download_url: "https://example.invalid/payload.bin".to_owned(),
        sha256_hex: String::new(),
        download_size_bytes: 0,
    };
    let missing = stage_update_artifact(&http, dir.path(), &check, "0.1.0", 0).await;
    assert_eq!(
        missing.err().and_then(|e| e.detail_code),
        Some("ota_sha256_missing".to_owned())
    );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let Ok(addr) = listener.local_addr() else {
        return Ok(());
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
    let mismatch = stage_update_artifact(&http, dir.path(), &check, "0.1.0", 0).await;
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
    Ok(())
}

// Test-only minisign fixtures: "ED" (prehashed) signatures made with a throwaway key that
// exists only for these tests (never a release key). They offer 99.0.0, newer than any
// release, so a version bump never makes the offered update the installed one.
pub(crate) const FIXTURE_PK: &str = "RWT7IrOCLc/O0aoKBhyVUd83g63ULp8gQabCBrFwRgSPIMa6w7TMOWVP";
/// A v2 manifest with an asset for every target.
pub(crate) const FIXTURE_MANIFEST: &str = r#"{"format":2,"semver":"99.0.0","track":"track_b","release_notes":"Faster startup","targets":{"android-arm64":{"url":"https://example.invalid/bistre-v99.0.0-android-arm64.apk","sha256":"0000000000000000000000000000000000000000000000000000000000000000","size_bytes":1024},"linux-x64":{"url":"https://example.invalid/bistre-v99.0.0-linux-x64.AppImage","sha256":"0000000000000000000000000000000000000000000000000000000000000000","size_bytes":1024},"windows-x64":{"url":"https://example.invalid/bistre-v99.0.0-windows-x64-setup.exe","sha256":"0000000000000000000000000000000000000000000000000000000000000000","size_bytes":1024}}}"#;
pub(crate) const FIXTURE_SIG: &str = "untrusted comment: bistre test fixture\n\
RUT7IrOCLc/O0VmBhWBkOvW3BV2hFT5kUUzPdc7pRimVjy8PAHOIFsxmVupJ3dN261JY6VDj5/jVuyyTjtykOb99MQQo8RVJ4wE=\n\
trusted comment: timestamp:0\tfile:manifest.json\tprehashed\n\
AZFwmNfXINpllUnF4ucGp0iCNmp31j+tUDko4Oaix23neCx5qsDB28C/UNNmqAV6eX2OX847CM0sYoqbX4sxDg==\n";
/// The old (v1) shape, correctly signed: a v0.1.2 feed.
pub(crate) const FIXTURE_MANIFEST_V1: &str = r#"{"semver":"99.0.0","track":"track_b","assets":[]}"#;
pub(crate) const FIXTURE_SIG_V1: &str = "untrusted comment: bistre test fixture\n\
RUT7IrOCLc/O0ZGGki4DlWdOTpo341O3IB9GjQMrh2fVv7c1byjqvMslpEgB1aLpACU1iLN21TcmcyOiTcIDEeV9BiQfU3COagg=\n\
trusted comment: timestamp:0\tfile:manifest.json\tprehashed\n\
H/n8tE70kDTPHS2aWFR/PfJ3mGi1+CHgSDfxRb41+/eb888FEkmoEgVL+8jcpzrl6RslOsqOtjuWQ6N4XmpnAQ==\n";
/// A v2 manifest with no targets at all.
pub(crate) const FIXTURE_MANIFEST_NO_TARGETS: &str =
    r#"{"format":2,"semver":"99.0.0","track":"track_b","release_notes":"","targets":{}}"#;
pub(crate) const FIXTURE_SIG_NO_TARGETS: &str = "untrusted comment: bistre test fixture\n\
RUT7IrOCLc/O0UVNLx9n5n1sJJWkZzdm9ZZJweoXqpXeMiKuhE7ul23jf99k2ppK5qBs1VsQR5sVOiusrEK3TfjzPD/eZ8SYGQY=\n\
trusted comment: timestamp:0\tfile:manifest.json\tprehashed\n\
0kOkUCpICZCJehN5Zu0k2Xhx4bQaIWgB/hlpKfzu56zIgNZxGyBMkYtbB9EONFFoNEHAcWXhEUk27658ov82Cg==\n";

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
            let body = if req.contains(".minisig") {
                sig
            } else {
                Some(manifest)
            };
            let resp = match body {
                Some(b) => format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{b}",
                    b.len()
                ),
                None => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    .to_owned(),
            };
            if sock.write_all(resp.as_bytes()).await.is_err() {
                return;
            }
        }
    });
    Ok((addr, handle))
}

#[tokio::test]
async fn missing_release_key_disables_ota_before_any_request()
-> Result<(), Box<dyn std::error::Error>> {
    assert_eq!(
        resolve_release_key_with(None, "").err().map(|e| e.key),
        Some(DiagnosticKey::OtaSigningKeyMissing)
    );
    let http = crate::providers::build_http_client()?;
    // Port 9 (discard) is never contacted: the key check runs first.
    let res = check_for_updates(
        &http,
        "http://127.0.0.1:9/manifest.json",
        "0.1.0",
        0,
        Some(""),
    )
    .await;
    assert_eq!(
        res.err().map(|e| e.key),
        Some(DiagnosticKey::OtaSigningKeyMissing)
    );
    Ok(())
}

#[test]
fn official_release_pubkey_verifies_minisign_012_signature_and_rejects_tampering()
-> Result<(), Box<dyn std::error::Error>> {
    const SAMPLE_MANIFEST: &[u8] = br#"{"semver":"1.0.0","track":"track_b","assets":[]}"#;
    const SAMPLE_SIG: &str = "untrusted comment: signature from minisign secret key\n\
RUSzNjkoCQGmhLJKWuxwCQ5EJuNVJQndPRi11XbQ61SbTH3mjth6e0ML+bNWiLjjargHeRPWWpsjccwlZgXdIUx7R6vs+3px5Qo=\n\
trusted comment: bistre v1.0.0\n\
fgsYLnenA1gdfE3Qca40F0ZfGmgfjF6sYP6BkmoLf+vN0UwGF+ThF99aEy3Gk5XDViORhA2BwS4QcSXGHsHBBQ==\n";

    let resolved = resolve_release_key(None)?;
    assert_eq!(resolved, OFFICIAL_RELEASE_PUBKEY_B64);
    verify_minisign_bytes(resolved, SAMPLE_MANIFEST, SAMPLE_SIG)?;

    let tampered = br#"{"semver":"1.0.1","track":"track_b","assets":[]}"#;
    assert_eq!(
        verify_minisign_bytes(resolved, tampered, SAMPLE_SIG)
            .err()
            .map(|e| e.key),
        Some(DiagnosticKey::CryptoSignatureInvalid)
    );
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
    assert_eq!(verified.latest_version(), "99.0.0");
    let expected = crate::ota_manifest::OtaTarget::current()
        .map(|t| format!("https://example.invalid/{}", t.asset_file_name("v99.0.0")));
    assert_eq!(Some(verified.download_url.clone()), expected);
    Ok(())
}

/// A correctly signed manifest in the old shape is "unsupported" (reinstall once),
/// and a release without this platform says so, instead of "integrity failed".
#[tokio::test]
async fn old_or_incomplete_manifests_fail_with_their_own_reason() -> TestResult {
    let http = crate::providers::build_http_client()?;
    for (manifest, sig, key) in [
        (
            FIXTURE_MANIFEST_V1,
            FIXTURE_SIG_V1,
            DiagnosticKey::OtaManifestUnsupported,
        ),
        (
            FIXTURE_MANIFEST_NO_TARGETS,
            FIXTURE_SIG_NO_TARGETS,
            DiagnosticKey::OtaNoAssetForPlatform,
        ),
    ] {
        let (addr, server) = serve_feed(manifest, Some(sig), 2).await?;
        let res = check_for_updates(
            &http,
            &format!("http://{addr}/manifest.json"),
            "0.1.0",
            0,
            Some(FIXTURE_PK),
        )
        .await;
        server.await?;
        assert_eq!(res.err().map(|e| e.key), Some(key));
    }
    Ok(())
}

#[tokio::test]
async fn tampered_or_unsigned_manifest_is_rejected() -> Result<(), Box<dyn std::error::Error>> {
    let http = crate::providers::build_http_client()?;
    let tampered: &'static str =
        r#"{"format":2,"semver":"9.9.9","track":"track_b","release_notes":"","targets":{}}"#;
    let (addr, server) = serve_feed(tampered, Some(FIXTURE_SIG), 2).await?;
    let res = check_for_updates(
        &http,
        &format!("http://{addr}/m.json"),
        "0.1.0",
        0,
        Some(FIXTURE_PK),
    )
    .await;
    server.await?;
    assert_eq!(
        res.err().map(|e| e.key),
        Some(DiagnosticKey::CryptoSignatureInvalid)
    );

    let (addr, server) = serve_feed(FIXTURE_MANIFEST, None, 2).await?;
    let res = check_for_updates(
        &http,
        &format!("http://{addr}/m.json"),
        "0.1.0",
        0,
        Some(FIXTURE_PK),
    )
    .await;
    server.await?;
    assert_eq!(
        res.err().map(|e| e.key),
        Some(DiagnosticKey::CryptoSignatureInvalid)
    );
    Ok(())
}

#[test]
fn stable_channel_skips_prerelease_updates_while_beta_accepts_them() {
    assert!(!is_update_available_for_channel(
        "0.2.0-beta.1",
        "0.1.2",
        "stable"
    ));
    assert!(is_update_available_for_channel(
        "0.2.0-beta.1",
        "0.1.2",
        "beta"
    ));
    assert!(is_update_available_for_channel("0.2.0", "0.1.2", "stable"));
    assert!(!is_update_available_for_channel("0.1.2", "0.1.2", "beta"));
}

#[tokio::test]
async fn reinstall_allows_same_version_and_writes_receipt_but_refuses_downgrade() -> TestResult {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let dir = tempfile::tempdir()?;
    let http = crate::providers::build_http_client()?;
    let payload = b"bistre-reinstall-payload";
    let mut h = Sha256Stream::new();
    h.update(payload);
    let digest = h.finalize_hex();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let server = tokio::spawn(async move {
        if let Ok((mut s, _)) = listener.accept().await {
            let mut buf = [0_u8; 512];
            if s.read(&mut buf).await.is_err() {
                return;
            }
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                payload.len()
            );
            if s.write_all(resp.as_bytes()).await.is_ok() {
                let ok = s.write_all(payload).await.is_ok();
                assert!(ok);
            }
        }
    });

    let downgrade = VerifiedManifest {
        latest_version: "0.1.1".to_owned(),
        track: "track_b".to_owned(),
        ownership_mode: "self_managed".to_owned(),
        download_url: format!("http://{addr}/payload.bin"),
        sha256_hex: digest.clone(),
        download_size_bytes: payload.len() as u64,
    };
    let err = stage_update_artifact_with_mode(&http, dir.path(), &downgrade, "0.1.2", 0, true)
        .await
        .err()
        .ok_or("downgrade must fail even when reinstalling")?;
    assert_eq!(err.detail_code.as_deref(), Some("ota_not_newer"));

    let same = VerifiedManifest {
        latest_version: "0.1.2".to_owned(),
        ..downgrade
    };
    let staged =
        stage_update_artifact_with_mode(&http, dir.path(), &same, "0.1.2", 0, true).await?;
    server.await?;
    assert!(Path::new(&staged).is_file());
    let receipt_path = dir.path().join("ota_staging").join("staged.json");
    let receipt: StagedUpdateReceipt =
        serde_json::from_str(&std::fs::read_to_string(&receipt_path)?)?;
    assert_eq!(receipt.version, "0.1.2");
    assert_eq!(receipt.sha256, digest);
    assert!(receipt.reinstall);
    Ok(())
}

#[test]
fn normalizes_owner_repo_and_github_release_urls() {
    assert_eq!(normalize_ota_feed_url(""), DEFAULT_OTA_FEED_URL);
    assert_eq!(
        normalize_ota_feed_url("baros4294/bistre"),
        "https://github.com/baros4294/bistre/releases/latest/download/manifest.json"
    );
    assert_eq!(
        normalize_ota_feed_url("https://github.com/baros4294/bistre/releases/latest"),
        "https://github.com/baros4294/bistre/releases/latest/download/manifest.json"
    );
    assert_eq!(
        normalize_ota_feed_url("https://example.com/custom/manifest.json"),
        "https://example.com/custom/manifest.json"
    );
}
