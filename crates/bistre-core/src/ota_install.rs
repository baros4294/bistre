//! Installs a staged update (Spec 10 §3). The payload's SHA-256 is checked again against its
//! receipt, then the platform's own installer takes over: on Windows the per-user setup runs
//! silently and reopens Bistre, an `AppImage` replaces itself and relaunches, and on Android
//! the app hands the APK to the system installer. A desktop receipt is removed at hand-over,
//! so an update is offered once.

use std::io::Read as _;
use std::path::{Path, PathBuf};

use bistre_crypto::Sha256Stream;
use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};

use crate::ota::{StagedUpdateReceipt, is_semver_newer, normalize_sha256};

/// What happens after core hands an update over.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct StagedInstall {
    pub version: String,
    /// Android: the verified APK the app hands to the system installer. Empty on desktop,
    /// where core already started the installer and the app quits.
    pub android_apk_path: String,
}

const RECEIPT: &str = "staged.json";

#[cfg(windows)]
/// The Windows installer's switches: no window or prompts, close Bistre if it still runs, and
/// never restart the computer. The setup reopens Bistre itself (`bistre.iss`).
const WINDOWS_SETUP_ARGS: [&str; 4] = [
    "/VERYSILENT",
    "/SUPPRESSMSGBOXES",
    "/NORESTART",
    "/FORCECLOSEAPPLICATIONS",
];

fn staging_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("ota_staging")
}

fn integrity(detail: &'static str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::OtaIntegrityFailed, detail)
}

fn io_error(detail: &'static str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::InternalError, detail)
}

/// Whether `receipt` still installs over `running`: a newer version, or the same version
/// staged as a reinstall.
fn applies(receipt: &StagedUpdateReceipt, running: &str) -> bool {
    let same =
        !is_semver_newer(&receipt.version, running) && !is_semver_newer(running, &receipt.version);
    is_semver_newer(&receipt.version, running) || (receipt.reinstall && same)
}

/// The staged update that still installs over `running`, if any.
pub fn pending_staged_update(
    data_dir: &Path,
    running: &str,
) -> BistreResult<Option<StagedUpdateReceipt>> {
    let bytes = match std::fs::read(staging_dir(data_dir).join(RECEIPT)) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(io_error("ota_receipt_read")),
    };
    let receipt: StagedUpdateReceipt =
        serde_json::from_slice(&bytes).map_err(|_| integrity("ota_receipt_invalid"))?;
    Ok(applies(&receipt, running).then_some(receipt))
}

/// Removes staged files that will never install: everything when no receipt applies to
/// `running` (an update that installed, or one handed over earlier).
pub fn clear_finished_updates(data_dir: &Path, running: &str) -> BistreResult<()> {
    let dir = staging_dir(data_dir);
    if !dir.exists() || pending_staged_update(data_dir, running)?.is_some() {
        return Ok(());
    }
    std::fs::remove_dir_all(&dir).map_err(|_| io_error("ota_staging_clear"))
}

fn sha256_file(path: &Path) -> BistreResult<String> {
    let mut file = std::fs::File::open(path).map_err(|_| integrity("ota_payload_missing"))?;
    let mut hasher = Sha256Stream::new();
    let mut buf = vec![0_u8; 64 * 1024];
    loop {
        let n = file
            .read(&mut buf)
            .map_err(|_| io_error("ota_payload_read"))?;
        if n == 0 {
            return Ok(hasher.finalize_hex());
        }
        hasher.update(&buf[..n]);
    }
}

/// Checks the staged payload again and hands it to the platform installer. Blocking file
/// work: call it off the async workers. Refused while any run is active.
pub fn install_staged_update(
    data_dir: &Path,
    running: &str,
    active_runs: u32,
) -> BistreResult<StagedInstall> {
    if active_runs > 0 {
        return Err(BistreError::new(DiagnosticKey::OtaActiveRunsDeferred));
    }
    let receipt =
        pending_staged_update(data_dir, running)?.ok_or_else(|| integrity("ota_nothing_staged"))?;
    let payload = PathBuf::from(&receipt.payload_path);
    let dir = staging_dir(data_dir);
    if !payload.starts_with(&dir) {
        return Err(integrity("ota_payload_outside_staging"));
    }
    let expected =
        normalize_sha256(&receipt.sha256).ok_or_else(|| integrity("ota_sha256_missing"))?;
    if sha256_file(&payload)? != expected {
        return Err(integrity("ota_payload_changed"));
    }
    let installer = payload.with_file_name(installer_name());
    std::fs::rename(&payload, &installer).map_err(|_| io_error("ota_installer_rename"))?;
    if let Err(err) = hand_over(&installer) {
        // Put it back so a later Install update finds it again.
        return match std::fs::rename(&installer, &payload) {
            Ok(()) => Err(err),
            Err(_) => Err(io_error("ota_installer_restore")),
        };
    }
    let android_apk_path = if cfg!(target_os = "android") {
        // Android's installer can be dismissed, so a newer version stays offered until it
        // runs; the next start clears it. A reinstall is offered once.
        let apk = installer.to_string_lossy().into_owned();
        crate::ota::write_staged_receipt(data_dir, &receipt.version, &apk, expected, false)?;
        apk
    } else {
        std::fs::remove_file(dir.join(RECEIPT)).map_err(|_| io_error("ota_receipt_remove"))?;
        String::new()
    };
    Ok(StagedInstall {
        version: receipt.version,
        android_apk_path,
    })
}

/// The installer's file name; apt and the package tools read the type from the extension.
fn installer_name() -> &'static str {
    use crate::ota_manifest::OtaTarget;
    match OtaTarget::current() {
        Some(OtaTarget::WindowsX64) => "bistre-setup.exe",
        Some(OtaTarget::AndroidArm64) => "bistre.apk",
        Some(OtaTarget::LinuxX64Deb) => "bistre.deb",
        Some(OtaTarget::LinuxX64Rpm) => "bistre.rpm",
        Some(OtaTarget::LinuxX64) | None => "bistre.AppImage",
    }
}

#[cfg(windows)]
fn hand_over(installer: &Path) -> BistreResult<()> {
    let args: Vec<&std::ffi::OsStr> = WINDOWS_SETUP_ARGS
        .iter()
        .map(std::ffi::OsStr::new)
        .collect();
    crate::process_util::spawn_detached(installer, &args)
        .map_err(|_| io_error("ota_installer_start"))
}

#[cfg(target_os = "android")]
fn hand_over(_installer: &Path) -> BistreResult<()> {
    // The app opens the system installer with the APK; Android asks the user to confirm.
    Ok(())
}

/// Installs the Linux update for how Bistre was installed, then starts the new build: the
/// `AppImage` replaces itself through a same-folder rename; Bistre's `.deb` or `.rpm` goes
/// through the system's password prompt (`pkexec`). A Flatpak, Snap, or the portable archive
/// has no target, so nothing reaches here for it.
#[cfg(not(any(windows, target_os = "android")))]
fn hand_over(installer: &Path) -> BistreResult<()> {
    use crate::ota_manifest::{LINUX_PACKAGE_DIR, OtaTarget};
    match OtaTarget::current() {
        Some(OtaTarget::LinuxX64) => replace_appimage(installer),
        Some(target @ (OtaTarget::LinuxX64Deb | OtaTarget::LinuxX64Rpm)) => {
            install_package(target, installer)?;
            let app = Path::new(LINUX_PACKAGE_DIR).join("bistre_app");
            crate::process_util::spawn_detached(&app, &[]).map_err(|_| io_error("ota_relaunch"))
        }
        _ => Err(BistreError::new(DiagnosticKey::OtaManagedExternally)),
    }
}

#[cfg(not(any(windows, target_os = "android")))]
fn replace_appimage(installer: &Path) -> BistreResult<()> {
    use std::os::unix::fs::PermissionsExt as _;
    let target = std::env::var_os("APPIMAGE")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute() && p.is_file())
        .ok_or_else(|| BistreError::new(DiagnosticKey::OtaManagedExternally))?;
    let mut next = target.clone().into_os_string();
    next.push(".new");
    let next = PathBuf::from(next);
    std::fs::copy(installer, &next).map_err(|_| io_error("ota_appimage_copy"))?;
    std::fs::set_permissions(&next, std::fs::Permissions::from_mode(0o755))
        .map_err(|_| io_error("ota_appimage_mode"))?;
    std::fs::rename(&next, &target).map_err(|_| io_error("ota_appimage_replace"))?;
    crate::process_util::spawn_detached(&target, &[]).map_err(|_| io_error("ota_relaunch"))
}

/// How long the password prompt and the package install may take together.
#[cfg(not(any(windows, target_os = "android")))]
const PACKAGE_INSTALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(600);

/// The `pkexec` command for a package, by the first package tool found: apt for a `.deb`
/// (it installs new dependencies too); dnf, then zypper, then plain rpm for a `.rpm`.
#[cfg(not(any(windows, target_os = "android")))]
fn package_command(
    target: crate::ota_manifest::OtaTarget,
    package: &Path,
    has_tool: impl Fn(&str) -> bool,
) -> Option<Vec<std::ffi::OsString>> {
    use crate::ota_manifest::OtaTarget;
    let os = |s: &str| std::ffi::OsString::from(s);
    let tool: &[&str] = match target {
        OtaTarget::LinuxX64Deb if has_tool("apt-get") => &["apt-get", "install", "-y"],
        OtaTarget::LinuxX64Rpm if has_tool("dnf") => &["dnf", "install", "-y"],
        OtaTarget::LinuxX64Rpm if has_tool("zypper") => &[
            "zypper",
            "--non-interactive",
            "install",
            "--allow-unsigned-rpm",
        ],
        OtaTarget::LinuxX64Rpm if has_tool("rpm") => &["rpm", "-U", "--force"],
        _ => return None,
    };
    let mut args: Vec<std::ffi::OsString> = tool.iter().map(|s| os(s)).collect();
    args.push(package.as_os_str().to_owned());
    Some(args)
}

#[cfg(not(any(windows, target_os = "android")))]
fn install_package(target: crate::ota_manifest::OtaTarget, package: &Path) -> BistreResult<()> {
    let has_tool = |name: &str| crate::process_util::find_on_path(name).is_some();
    if !has_tool("pkexec") {
        return Err(BistreError::with_detail(
            DiagnosticKey::OtaInstallFailed,
            "pkexec_missing",
        ));
    }
    let args = package_command(target, package, has_tool).ok_or_else(|| {
        BistreError::with_detail(DiagnosticKey::OtaInstallFailed, "package_tool_missing")
    })?;
    let mut cmd = crate::process_util::no_window_command("pkexec");
    cmd.args(&args);
    let out = tokio::runtime::Handle::current().block_on(crate::process_util::run_bounded(
        cmd,
        PACKAGE_INSTALL_TIMEOUT,
    ))?;
    if out.status.success() {
        Ok(())
    } else {
        // pkexec exits 126 when the user dismissed the password prompt.
        let detail = if out.status.code() == Some(126) {
            "install_cancelled"
        } else {
            "install_failed"
        };
        Err(BistreError::with_detail(
            DiagnosticKey::OtaInstallFailed,
            detail,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type TestResult<T = ()> = Result<T, Box<dyn std::error::Error>>;

    fn stage(dir: &Path, version: &str, reinstall: bool, body: &[u8]) -> TestResult<PathBuf> {
        let slot = staging_dir(dir).join(version);
        std::fs::create_dir_all(&slot)?;
        let payload = slot.join("payload.bin");
        std::fs::write(&payload, body)?;
        let mut hasher = Sha256Stream::new();
        hasher.update(body);
        let receipt = StagedUpdateReceipt {
            version: version.to_owned(),
            payload_path: payload.to_string_lossy().into_owned(),
            sha256: hasher.finalize_hex(),
            reinstall,
        };
        std::fs::write(
            staging_dir(dir).join(RECEIPT),
            serde_json::to_vec(&receipt)?,
        )?;
        Ok(payload)
    }

    #[test]
    fn only_a_newer_or_reinstall_receipt_is_pending() -> TestResult {
        let dir = tempfile::tempdir()?;
        assert_eq!(pending_staged_update(dir.path(), "1.0.0")?, None);
        stage(dir.path(), "1.1.0", false, b"new")?;
        assert!(pending_staged_update(dir.path(), "1.0.0")?.is_some());
        assert_eq!(
            pending_staged_update(dir.path(), "1.1.0")?,
            None,
            "already installed"
        );
        stage(dir.path(), "1.1.0", true, b"same")?;
        assert!(
            pending_staged_update(dir.path(), "1.1.0")?.is_some(),
            "a reinstall"
        );
        clear_finished_updates(dir.path(), "1.2.0")?;
        assert!(
            !staging_dir(dir.path()).exists(),
            "an installed update is cleared"
        );
        Ok(())
    }

    #[test]
    fn a_changed_payload_or_a_busy_app_never_installs() -> TestResult {
        let dir = tempfile::tempdir()?;
        let payload = stage(dir.path(), "2.0.0", false, b"signed bytes")?;
        assert_eq!(
            install_staged_update(dir.path(), "1.0.0", 1)
                .err()
                .map(|e| e.key),
            Some(DiagnosticKey::OtaActiveRunsDeferred)
        );
        std::fs::write(&payload, b"tampered")?;
        let err = install_staged_update(dir.path(), "1.0.0", 0).err();
        assert_eq!(
            err.as_ref().map(|e| e.key),
            Some(DiagnosticKey::OtaIntegrityFailed)
        );
        assert!(
            payload.exists(),
            "a refused payload stays for a fresh download"
        );
        assert!(pending_staged_update(dir.path(), "1.0.0")?.is_some());
        Ok(())
    }

    #[cfg(not(any(windows, target_os = "android")))]
    #[test]
    fn each_package_goes_to_the_first_tool_found() -> TestResult {
        use crate::ota_manifest::OtaTarget::{LinuxX64, LinuxX64Deb, LinuxX64Rpm};
        let pkg = Path::new("/tmp/bistre.rpm");
        let first = |target, tools: &[&str]| {
            package_command(target, pkg, |t| tools.contains(&t))
                .and_then(|a| a.first().map(|s| s.to_string_lossy().into_owned()))
        };
        assert_eq!(
            first(LinuxX64Deb, &["apt-get", "rpm"]).as_deref(),
            Some("apt-get")
        );
        assert_eq!(
            first(LinuxX64Rpm, &["zypper", "rpm"]).as_deref(),
            Some("zypper")
        );
        assert_eq!(
            first(LinuxX64Rpm, &["dnf", "zypper"]).as_deref(),
            Some("dnf")
        );
        assert_eq!(first(LinuxX64Rpm, &["apt-get"]), None);
        assert_eq!(
            first(LinuxX64, &["apt-get"]),
            None,
            "an AppImage has no package tool"
        );
        let args = package_command(LinuxX64Deb, pkg, |_| true).ok_or("no command")?;
        assert_eq!(
            args.last().map(|a| a.as_os_str()),
            Some(pkg.as_os_str()),
            "the package stays one argument"
        );
        Ok(())
    }
}
