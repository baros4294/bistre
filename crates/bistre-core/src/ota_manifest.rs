//! OTA manifest v2 (Spec 10): one typed shape, written by the release builder
//! (`examples/ota_manifest.rs`) and read by the app with the same types, so the two can never
//! drift. Unknown fields are refused, every digest is 64 hex characters, every size is
//! non-zero, and each platform names exactly the file it can install.

use std::collections::BTreeMap;
use std::io::Read as _;
use std::num::NonZeroU64;
use std::path::Path;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use serde::{Deserialize, Serialize};

/// The only manifest format this build reads and writes.
pub const MANIFEST_FORMAT: u32 = 2;

/// A platform build that can update itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum OtaTarget {
    WindowsX64,
    /// The `AppImage`.
    LinuxX64,
    LinuxX64Deb,
    LinuxX64Rpm,
    AndroidArm64,
}

/// Where the Linux `.deb` and `.rpm` install the app.
pub const LINUX_PACKAGE_DIR: &str = "/opt/bistre";
/// The file list dpkg keeps for an installed `bistre` package.
const DPKG_FILE_LIST: &str = "/var/lib/dpkg/info/bistre.list";

impl OtaTarget {
    pub const ALL: [Self; 5] = [
        Self::WindowsX64,
        Self::LinuxX64,
        Self::LinuxX64Deb,
        Self::LinuxX64Rpm,
        Self::AndroidArm64,
    ];

    /// The target of the running build; `None` where updates are not offered (another OS, a
    /// Flatpak or Snap, or the portable archive). On Linux the install decides: `$APPIMAGE`
    /// is the `AppImage`, and a build in [`LINUX_PACKAGE_DIR`] is the `.deb` when dpkg lists
    /// it, else the `.rpm`.
    pub fn current() -> Option<Self> {
        if cfg!(all(target_os = "windows", target_arch = "x86_64")) {
            Some(Self::WindowsX64)
        } else if cfg!(all(target_os = "android", target_arch = "aarch64")) {
            Some(Self::AndroidArm64)
        } else if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
            Self::linux_install()
        } else {
            None
        }
    }

    fn linux_install() -> Option<Self> {
        if crate::ota::detect_ownership_mode() != "self_managed" {
            return None;
        }
        if std::env::var_os("APPIMAGE").is_some_and(|p| !p.is_empty()) {
            return Some(Self::LinuxX64);
        }
        // An unreadable path means the install cannot be told apart: no update is offered.
        let in_package_dir =
            std::env::current_exe().is_ok_and(|exe| exe.starts_with(LINUX_PACKAGE_DIR));
        if !in_package_dir {
            return None;
        }
        Some(if Path::new(DPKG_FILE_LIST).is_file() {
            Self::LinuxX64Deb
        } else {
            Self::LinuxX64Rpm
        })
    }

    /// The target a manifest names (`linux-x64-deb`); `None` for a name this build does not know.
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|t| t.name() == name)
    }

    /// The manifest's name for this target.
    pub const fn name(self) -> &'static str {
        match self {
            Self::WindowsX64 => "windows-x64",
            Self::LinuxX64 => "linux-x64",
            Self::LinuxX64Deb => "linux-x64-deb",
            Self::LinuxX64Rpm => "linux-x64-rpm",
            Self::AndroidArm64 => "android-arm64",
        }
    }

    /// The release file this target installs: the Windows installer, the `AppImage`, the
    /// `.deb`, the `.rpm`, and the APK.
    pub fn asset_file_name(self, tag: &str) -> String {
        match self {
            Self::WindowsX64 => format!("bistre-{tag}-windows-x64-setup.exe"),
            Self::LinuxX64 => format!("bistre-{tag}-linux-x64.AppImage"),
            Self::LinuxX64Deb => format!("bistre-{tag}-linux-x64.deb"),
            Self::LinuxX64Rpm => format!("bistre-{tag}-linux-x64.rpm"),
            Self::AndroidArm64 => format!("bistre-{tag}-android-arm64.apk"),
        }
    }
}

/// A SHA-256 digest: exactly 64 lowercase hex characters.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Sha256Hex(String);

impl Sha256Hex {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for Sha256Hex {
    type Error = &'static str;
    fn try_from(raw: String) -> Result<Self, Self::Error> {
        if raw.len() == 64 && raw.bytes().all(|b| b.is_ascii_hexdigit()) {
            Ok(Self(raw.to_ascii_lowercase()))
        } else {
            Err("sha256 must be 64 hex characters")
        }
    }
}

impl From<Sha256Hex> for String {
    fn from(value: Sha256Hex) -> Self {
        value.0
    }
}

/// One installable file of a release.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OtaAsset {
    pub url: String,
    pub sha256: Sha256Hex,
    pub size_bytes: NonZeroU64,
}

/// The signed release manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OtaManifestV2 {
    pub format: u32,
    pub semver: String,
    pub track: String,
    #[serde(default)]
    pub release_notes: String,
    /// A target this build does not know is skipped, so a later release may add one.
    #[serde(deserialize_with = "known_targets")]
    pub targets: BTreeMap<OtaTarget, OtaAsset>,
}

fn known_targets<'de, D: serde::Deserializer<'de>>(
    de: D,
) -> Result<BTreeMap<OtaTarget, OtaAsset>, D::Error> {
    let raw = BTreeMap::<String, OtaAsset>::deserialize(de)?;
    Ok(raw
        .into_iter()
        .filter_map(|(name, asset)| OtaTarget::from_name(&name).map(|target| (target, asset)))
        .collect())
}

impl OtaManifestV2 {
    /// Parses manifest bytes (after their signature verified). Another `format` is
    /// `diag.ota.manifest_unsupported`; anything malformed is `diag.ota.check_failed`.
    pub fn parse(bytes: &[u8]) -> BistreResult<Self> {
        let probe: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "manifest_json")
        })?;
        let format = probe.get("format").and_then(serde_json::Value::as_u64);
        if format != Some(u64::from(MANIFEST_FORMAT)) {
            return Err(BistreError::with_detail(
                DiagnosticKey::OtaManifestUnsupported,
                format.map_or_else(|| "format_missing".to_owned(), |f| format!("format_{f}")),
            ));
        }
        let manifest: Self = serde_json::from_value(probe).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "manifest_fields")
        })?;
        if manifest.semver.trim().is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::OtaCheckFailed,
                "manifest_semver",
            ));
        }
        Ok(manifest)
    }

    /// The asset for `target`, or `diag.ota.no_asset_for_platform`.
    pub fn asset_for(&self, target: Option<OtaTarget>) -> BistreResult<&OtaAsset> {
        target
            .and_then(|t| self.targets.get(&t))
            .ok_or_else(|| BistreError::new(DiagnosticKey::OtaNoAssetForPlatform))
    }
}

/// Hashes a file in 64 KiB chunks: `(sha256 hex, size)`.
fn hash_file(path: &Path) -> BistreResult<(String, u64)> {
    let mut file = std::fs::File::open(path)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "asset_missing"))?;
    let mut hasher = bistre_crypto::Sha256Stream::new();
    let mut buf = vec![0_u8; 64 * 1024];
    let mut size = 0_u64;
    loop {
        let n = file
            .read(&mut buf)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "asset_read"))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        size += u64::try_from(n).unwrap_or(u64::MAX);
    }
    Ok((hasher.finalize_hex(), size))
}

/// Release side (`examples/ota_manifest.rs build`): the manifest for the files in `dist`,
/// with URLs pinned to `https://github.com/<repo>/releases/download/<tag>/<file>`. Only
/// installable files are listed (the SBOM and system packages are not). Every target must be
/// present, so a release can never silently drop a platform.
///
/// `built_version` is the version the released binaries report (`CORE_VERSION` from
/// `Cargo.toml`). A tag that differs is refused: the installed app would still report the
/// old version and offer the same update again after every install.
pub fn build_release_manifest(
    dist: &Path,
    tag: &str,
    built_version: &str,
    repo: &str,
    release_notes: &str,
) -> BistreResult<OtaManifestV2> {
    let semver = tag.strip_prefix('v').unwrap_or(tag).to_owned();
    if semver != built_version {
        return Err(BistreError::with_detail(
            DiagnosticKey::OtaCheckFailed,
            "tag_version_mismatch",
        ));
    }
    let mut targets = BTreeMap::new();
    for target in OtaTarget::ALL {
        let name = target.asset_file_name(tag);
        let (sha256, size) = hash_file(&dist.join(&name))?;
        let size_bytes = NonZeroU64::new(size).ok_or_else(|| {
            BistreError::with_detail(DiagnosticKey::OtaCheckFailed, "asset_empty")
        })?;
        targets.insert(
            target,
            OtaAsset {
                url: format!("https://github.com/{repo}/releases/download/{tag}/{name}"),
                sha256: Sha256Hex::try_from(sha256)
                    .map_err(|_| BistreError::new(DiagnosticKey::InternalError))?,
                size_bytes,
            },
        );
    }
    Ok(OtaManifestV2 {
        format: MANIFEST_FORMAT,
        semver,
        track: "track_b".to_owned(),
        release_notes: release_notes.to_owned(),
        targets,
    })
}

/// Release side (`examples/ota_manifest.rs verify`), run before publishing (fail closed): the
/// signature verifies with `public_key_b64`, the app's own parser accepts the manifest, every
/// target has an asset, and each listed file in `dist` matches its digest and size.
pub fn verify_release_dir(
    dist: &Path,
    manifest_bytes: &[u8],
    signature_text: &str,
    public_key_b64: &str,
) -> BistreResult<OtaManifestV2> {
    bistre_crypto::verify_minisign_bytes(public_key_b64, manifest_bytes, signature_text)?;
    let manifest = OtaManifestV2::parse(manifest_bytes)?;
    for target in OtaTarget::ALL {
        let asset = manifest.asset_for(Some(target))?;
        let name = asset.url.rsplit('/').next().unwrap_or_default();
        if name.is_empty() || name.contains("..") || name.contains('\\') {
            return Err(BistreError::with_detail(
                DiagnosticKey::OtaCheckFailed,
                "asset_name",
            ));
        }
        let (sha256, size) = hash_file(&dist.join(name))?;
        if sha256 != asset.sha256.as_str() || size != asset.size_bytes.get() {
            return Err(BistreError::with_detail(
                DiagnosticKey::OtaIntegrityFailed,
                "asset_mismatch",
            ));
        }
    }
    Ok(manifest)
}

#[cfg(test)]
mod tests {
    use super::*;

    const Z: &str = "0000000000000000000000000000000000000000000000000000000000000000";

    #[test]
    fn a_v2_manifest_round_trips_and_picks_each_platform() -> BistreResult<()> {
        let raw = format!(
            r#"{{"format":2,"semver":"0.2.0","track":"track_b","release_notes":"","targets":{{"windows-x64":{{"url":"https://x.invalid/w.exe","sha256":"{Z}","size_bytes":5}}}}}}"#
        );
        let m = OtaManifestV2::parse(raw.as_bytes())?;
        assert_eq!(
            m.asset_for(Some(OtaTarget::WindowsX64))?.url,
            "https://x.invalid/w.exe"
        );
        assert_eq!(
            m.asset_for(Some(OtaTarget::LinuxX64)).err().map(|e| e.key),
            Some(DiagnosticKey::OtaNoAssetForPlatform)
        );
        assert_eq!(
            m.asset_for(None).err().map(|e| e.key),
            Some(DiagnosticKey::OtaNoAssetForPlatform)
        );
        let again =
            serde_json::to_vec(&m).map_err(|_| BistreError::new(DiagnosticKey::InternalError))?;
        assert_eq!(OtaManifestV2::parse(&again)?, m);
        Ok(())
    }

    #[test]
    fn the_v1_shape_and_malformed_fields_are_refused() {
        let v1 = br#"{"semver":"0.2.0","track":"track_b","assets":[]}"#;
        assert_eq!(
            OtaManifestV2::parse(v1)
                .err()
                .map(|e| (e.key, e.detail_code)),
            Some((
                DiagnosticKey::OtaManifestUnsupported,
                Some("format_missing".to_owned())
            ))
        );
        let bad_digest = br#"{"format":2,"semver":"1.0.0","track":"track_b","targets":{"linux-x64":{"url":"https://x/a","sha256":"abc","size_bytes":1}}}"#;
        assert_eq!(
            OtaManifestV2::parse(bad_digest).err().map(|e| e.key),
            Some(DiagnosticKey::OtaCheckFailed)
        );
        let zero_size = format!(
            r#"{{"format":2,"semver":"1.0.0","track":"track_b","targets":{{"linux-x64":{{"url":"https://x/a","sha256":"{Z}","size_bytes":0}}}}}}"#
        );
        assert!(OtaManifestV2::parse(zero_size.as_bytes()).is_err());
        let unknown = br#"{"format":2,"semver":"1.0.0","track":"track_b","targets":{},"download_url":"https://evil/x"}"#;
        assert!(OtaManifestV2::parse(unknown).is_err());
    }

    #[test]
    fn the_release_builder_lists_every_target_and_the_verifier_checks_each_file()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        for target in OtaTarget::ALL {
            std::fs::write(
                dir.path().join(target.asset_file_name("v0.3.0")),
                b"payload",
            )?;
        }
        std::fs::write(dir.path().join("bistre-v0.3.0-engine.cdx.json"), b"{}")?;
        assert!(
            build_release_manifest(dir.path(), "v0.3.0", "0.2.0", "owner/repo", "").is_err(),
            "a tag other than the built version is refused"
        );
        let m = build_release_manifest(dir.path(), "v0.3.0", "0.3.0", "owner/repo", "notes")?;
        assert_eq!(m.semver, "0.3.0");
        assert_eq!(
            m.targets.len(),
            OtaTarget::ALL.len(),
            "the SBOM is never an asset"
        );
        for target in OtaTarget::ALL {
            assert_eq!(
                serde_json::to_value(target)?,
                target.name(),
                "one name per target"
            );
        }
        assert_eq!(
            m.asset_for(Some(OtaTarget::LinuxX64))?.url,
            "https://github.com/owner/repo/releases/download/v0.3.0/bistre-v0.3.0-linux-x64.AppImage"
        );
        // The verifier needs a valid signature first: a wrong one fails closed.
        let bytes = serde_json::to_vec(&m)?;
        assert!(verify_release_dir(dir.path(), &bytes, "not a signature", "RWQx").is_err());

        std::fs::remove_file(
            dir.path()
                .join(OtaTarget::AndroidArm64.asset_file_name("v0.3.0")),
        )?;
        assert!(
            build_release_manifest(dir.path(), "v0.3.0", "0.3.0", "owner/repo", "").is_err(),
            "a release missing a platform is refused"
        );
        Ok(())
    }

    #[test]
    fn each_target_names_the_file_it_installs() {
        assert_eq!(
            OtaTarget::WindowsX64.asset_file_name("v1.0.0"),
            "bistre-v1.0.0-windows-x64-setup.exe"
        );
        assert_eq!(
            OtaTarget::LinuxX64.asset_file_name("v1.0.0"),
            "bistre-v1.0.0-linux-x64.AppImage"
        );
        assert_eq!(
            OtaTarget::AndroidArm64.asset_file_name("v1.0.0"),
            "bistre-v1.0.0-android-arm64.apk"
        );
    }

    #[test]
    fn a_target_this_build_does_not_know_is_skipped() -> Result<(), Box<dyn std::error::Error>> {
        let asset = serde_json::json!({"url": "https://example.com/a", "sha256": "a".repeat(64), "size_bytes": 1});
        let raw = serde_json::json!({
            "format": MANIFEST_FORMAT, "semver": "9.0.0", "track": "track_b",
            "targets": {"linux-x64-deb": asset, "plan9-x64": asset}
        });
        let m = OtaManifestV2::parse(&serde_json::to_vec(&raw)?)?;
        assert_eq!(
            m.targets.keys().copied().collect::<Vec<_>>(),
            vec![OtaTarget::LinuxX64Deb]
        );
        Ok(())
    }
}
