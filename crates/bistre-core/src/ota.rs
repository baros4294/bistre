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

/// Hard cap on a staged OTA payload.
pub const MAX_OTA_PAYLOAD_BYTES: u64 = 256 * 1024 * 1024;
/// Hard cap on a manifest or signature document.
const MAX_OTA_MANIFEST_BYTES: usize = 1024 * 1024;

/// Public Ed25519 Minisign verification key for official Bistre releases (key id `84A60109283936B3`).
pub const OFFICIAL_RELEASE_PUBKEY_B64: &str =
    "RWSzNjkoCQGmhPhmWgUEVRju0AEHELP3evLMpoKRKRvhlpCZAL43T2Yb";

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

/// Resolves the release key: an explicit override wins (an explicit empty key fails closed),
/// otherwise uses `embedded_default`. No key means OTA is disabled; the check is never skipped.
fn resolve_release_key_with<'a>(
    release_key: Option<&'a str>,
    embedded_default: &'a str,
) -> BistreResult<&'a str> {
    let selected = match release_key {
        Some(explicit) => explicit.trim(),
        None => embedded_default.trim(),
    };
    if selected.is_empty() {
        return Err(BistreError::new(DiagnosticKey::OtaSigningKeyMissing));
    }
    Ok(selected)
}

fn resolve_release_key(release_key: Option<&str>) -> BistreResult<&str> {
    resolve_release_key_with(release_key, OFFICIAL_RELEASE_PUBKEY_B64)
}

/// Default official GitHub Releases OTA manifest URL.
pub const DEFAULT_OTA_FEED_URL: &str =
    "https://github.com/baros4294/bistre/releases/latest/download/manifest.json";

/// Normalizes user-supplied update feed strings into a canonical HTTPS `manifest.json` URL.
///
/// Accepts:
/// - empty string → official `baros4294/bistre` manifest URL
/// - `owner/repo` shorthand (e.g. `baros4294/bistre`)
/// - GitHub repo or releases URL (`https://github.com/owner/repo`, `.../releases`, `.../releases/latest`)
/// - direct HTTPS (or loopback HTTP for tests) manifest URL
pub fn normalize_ota_feed_url(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return DEFAULT_OTA_FEED_URL.to_owned();
    }
    if !trimmed.contains("://") {
        let slug = trimmed.trim_matches('/');
        if let Some((owner, repo)) = slug.split_once('/')
            && !owner.is_empty()
            && !repo.is_empty()
            && !repo.contains('/')
            && owner
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
            && repo
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        {
            return format!(
                "https://github.com/{owner}/{repo}/releases/latest/download/manifest.json"
            );
        }
        return trimmed.to_owned();
    }
    if let Ok(parsed) = reqwest::Url::parse(trimmed)
        && parsed
            .host_str()
            .is_some_and(|h| h.eq_ignore_ascii_case("github.com"))
    {
        let segs: Vec<&str> = parsed
            .path()
            .trim_matches('/')
            .split('/')
            .filter(|s| !s.is_empty())
            .collect();
        if segs.len() == 2
            || (segs.len() == 3 && segs[2].eq_ignore_ascii_case("releases"))
            || (segs.len() == 4
                && segs[2].eq_ignore_ascii_case("releases")
                && segs[3].eq_ignore_ascii_case("latest"))
        {
            return format!(
                "https://github.com/{}/{}/releases/latest/download/manifest.json",
                segs[0], segs[1]
            );
        }
    }
    trimmed.to_owned()
}

/// Receipt written atomically to `<data_dir>/ota_staging/staged.json` once a payload passes
/// SHA-256 verification, consumed by `bistre-updater --apply-staged` on the next launch.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct StagedUpdateReceipt {
    pub version: String,
    pub payload_path: String,
    pub sha256: String,
    pub reinstall: bool,
}

/// Performs a zero-telemetry check against `feed_url` on the `stable` channel.
pub async fn check_for_updates(
    http: &reqwest::Client,
    feed_url: &str,
    current_version: &str,
    active_runs: u32,
    release_key: Option<&str>,
) -> BistreResult<(UpdateCheckResult, VerifiedManifest)> {
    check_for_updates_on_channel(
        http,
        feed_url,
        current_version,
        "stable",
        active_runs,
        release_key,
    )
    .await
}

/// Performs a zero-telemetry check against `feed_url` (static JSON manifest + mandatory `.minisig`),
/// applying `channel` (`"stable"` filters out prereleases; `"beta"` accepts them).
pub async fn check_for_updates_on_channel(
    http: &reqwest::Client,
    feed_url: &str,
    current_version: &str,
    channel: &str,
    active_runs: u32,
    release_key: Option<&str>,
) -> BistreResult<(UpdateCheckResult, VerifiedManifest)> {
    let pk = resolve_release_key(release_key)?;
    let ownership = detect_ownership_mode();
    let normalized = normalize_ota_feed_url(feed_url);
    let trimmed = require_secure_url(&normalized, "invalid_feed_url")?;

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

    // The same typed manifest the release builder writes (format 2).
    let parsed = crate::ota_manifest::OtaManifestV2::parse(&manifest_bytes)?;
    let asset = parsed
        .asset_for(crate::ota_manifest::OtaTarget::current())?
        .clone();
    let latest_version = parsed.semver.trim().to_owned();
    let update_available =
        is_update_available_for_channel(&latest_version, current_version, channel);
    let sha256_hex = asset.sha256.as_str().to_owned();
    let download_size_bytes = asset.size_bytes.get();

    let verified = VerifiedManifest {
        latest_version: latest_version.clone(),
        track: parsed.track.clone(),
        ownership_mode: ownership.to_owned(),
        download_url: asset.url.clone(),
        sha256_hex: sha256_hex.clone(),
        download_size_bytes,
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
        download_url: asset.url.clone(),
        sha256_hex,
        download_size_bytes,
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
    current_version: &str,
    active_runs: u32,
) -> BistreResult<String> {
    stage_update_artifact_with_mode(http, data_dir, check, current_version, active_runs, false)
        .await
}

/// [`stage_update_artifact`] with explicit opt-in for reinstalling the exact running version.
/// Older versions (downgrades) are always refused.
pub async fn stage_update_artifact_with_mode(
    http: &reqwest::Client,
    data_dir: &Path,
    check: &VerifiedManifest,
    current_version: &str,
    active_runs: u32,
    allow_reinstall: bool,
) -> BistreResult<String> {
    // Only a strictly newer version (or exact same version on explicit reinstall) is ever staged.
    let version_ok = is_semver_newer(&check.latest_version, current_version)
        || (allow_reinstall
            && parse_semver(&check.latest_version) == parse_semver(current_version));
    if !version_ok {
        return Err(BistreError::with_detail(
            DiagnosticKey::OtaIntegrityFailed,
            "ota_not_newer",
        ));
    }
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

    let staging_dir = data_dir
        .join("ota_staging")
        .join(safe_ota_slot_name(&check.latest_version));
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
    let artifact_str = artifact_path.to_string_lossy().into_owned();
    write_staged_receipt(
        data_dir,
        &check.latest_version,
        &artifact_str,
        expected_sha,
        allow_reinstall,
    )?;
    Ok(artifact_str)
}

fn safe_ota_slot_name(version: &str) -> String {
    let safe_ver: String = version
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .collect();
    if safe_ver.is_empty() {
        "staged".to_owned()
    } else {
        safe_ver
    }
}

fn write_staged_receipt(
    data_dir: &Path,
    version: &str,
    payload_path: &str,
    sha256: String,
    reinstall: bool,
) -> BistreResult<()> {
    let receipt = StagedUpdateReceipt {
        version: version.to_owned(),
        payload_path: payload_path.to_owned(),
        sha256,
        reinstall,
    };
    let receipt_bytes = serde_json::to_vec_pretty(&receipt)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_write"))?;
    let receipt_tmp = data_dir.join("ota_staging").join("staged.json.tmp");
    let receipt_path = data_dir.join("ota_staging").join("staged.json");
    {
        let mut rf = std::fs::File::create(&receipt_tmp).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_write")
        })?;
        rf.write_all(&receipt_bytes).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_write")
        })?;
        rf.sync_all().map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_write")
        })?;
    }
    std::fs::rename(&receipt_tmp, &receipt_path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "ota_staging_write"))
}

/// Requires `https://` (or `http://` strictly for loopback test feeds) and returns the trimmed URL.
/// `https`, or `http` to a loopback host decided by the parsed URL (never a string
/// prefix, so `http://localhost.evil.com` is plain http to a public host and refused).
fn require_secure_url<'a>(raw: &'a str, detail: &'static str) -> BistreResult<&'a str> {
    let url = raw.trim();
    let https = reqwest::Url::parse(url).is_ok_and(|u| u.scheme() == "https");
    if https || crate::net::is_loopback_url(url) {
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
    resp: reqwest::Response,
    max: usize,
    detail: &'static str,
) -> BistreResult<Vec<u8>> {
    let err = BistreError::with_detail(DiagnosticKey::OtaCheckFailed, detail);
    crate::http_clients::read_body_capped(resp, max, err.clone(), err).await
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

/// Returns `true` when `version` carries a `SemVer` prerelease suffix (e.g. `0.2.0-beta.1`).
pub fn is_prerelease(version: &str) -> bool {
    !parse_semver(version).pre.is_empty()
}

/// Channel-aware update availability check: `"stable"` ignores prereleases while `"beta"` accepts
/// them, always enforcing strict `SemVer` 2.0 monotonicity.
pub fn is_update_available_for_channel(candidate: &str, current: &str, channel: &str) -> bool {
    if channel.eq_ignore_ascii_case("stable") && is_prerelease(candidate) {
        return false;
    }
    is_semver_newer(candidate, current)
}

fn now_unix_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}

#[cfg(test)]
#[path = "ota_tests.rs"]
pub(crate) mod tests;
