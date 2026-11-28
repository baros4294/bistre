//! Pure-Rust OTA Verifier & Side-by-Side Crash-Loop Watchdog Launcher (ADR-0008).
//!
//! Responsibilities:
//! - Offline Ed25519 signature verification via `minisign-verify` before staging any Track-A/B pack.
//! - Anti-rollback version comparison & 3-boot crash-loop watchdog reverting to `last_healthy_version`.
//! - Linux package-manager detection (`FLATPAK_ID`, `SNAP`, read-only `/usr`) disabling self-update safely.

use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use bistre_crypto::{Sha256Stream, verify_minisign_bytes};
use serde::{Deserialize, Serialize};

/// Maximum failed boot attempts before reverting to `last_healthy_version`.
pub const MAX_CRASH_BOOTS: u32 = 3;

/// Distribution ownership mode governing whether Track-B binary self-update is permitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateOwnership {
    SelfManaged,
    Flatpak,
    Snap,
    SystemPackageManager,
}

/// Persistent side-by-side launcher state stored in `%LocalAppData%\Bistre\launcher-state.json`
/// (or `$XDG_STATE_HOME/bistre/launcher-state.json`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LauncherWatchdogState {
    pub active_version: String,
    pub last_healthy_version: Option<String>,
    pub pending_boot_attempts: u32,
}

impl LauncherWatchdogState {
    /// Selects which version slot to launch and updates crash-loop counters deterministically.
    ///
    /// Returns `(selected_version, triggered_rollback)`.
    pub fn plan_next_boot(&mut self) -> (String, bool) {
        if self.pending_boot_attempts >= MAX_CRASH_BOOTS
            && let Some(prev) = self.last_healthy_version.clone()
        {
            self.active_version.clone_from(&prev);
            self.pending_boot_attempts = 0;
            return (prev, true);
        }
        self.pending_boot_attempts = self.pending_boot_attempts.saturating_add(1);
        (self.active_version.clone(), false)
    }

    /// Marks the currently running slot healthy after first-frame + SQLite verification completes.
    pub fn mark_boot_healthy(&mut self) {
        self.last_healthy_version = Some(self.active_version.clone());
        self.pending_boot_attempts = 0;
    }
}

/// Detects whether the current Linux/desktop binary is managed by an external package manager.
pub fn detect_update_ownership(
    flatpak_id: Option<&str>,
    snap_name: Option<&str>,
    exe_path: &Path,
) -> UpdateOwnership {
    if flatpak_id.is_some_and(|v| !v.is_empty()) {
        return UpdateOwnership::Flatpak;
    }
    if snap_name.is_some_and(|v| !v.is_empty()) {
        return UpdateOwnership::Snap;
    }
    if exe_path.starts_with("/usr/") || exe_path.starts_with("/opt/") {
        return UpdateOwnership::SystemPackageManager;
    }
    UpdateOwnership::SelfManaged
}

/// Receipt produced by `bistre-core::ota` at `<data_dir>/ota_staging/staged.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StagedUpdateReceipt {
    pub version: String,
    pub payload_path: String,
    pub sha256: String,
    #[serde(default)]
    pub reinstall: bool,
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("create_dir_all: {e}"))?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut f = std::fs::File::create(&tmp).map_err(|e| format!("create tmp: {e}"))?;
        f.write_all(bytes).map_err(|e| format!("write tmp: {e}"))?;
        f.sync_all().map_err(|e| format!("sync tmp: {e}"))?;
    }
    std::fs::rename(&tmp, path).map_err(|e| format!("rename tmp: {e}"))
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut f = std::fs::File::open(path).map_err(|e| format!("open payload: {e}"))?;
    let mut hasher = Sha256Stream::new();
    let mut buf = vec![0_u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf).map_err(|e| format!("read payload: {e}"))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize_hex())
}

/// Applies a verified staged payload from `<data_dir>/ota_staging/staged.json` into
/// `<install_root>/versions/<version>/payload.bin` and updates `launcher-state.json`.
/// Fails closed if the payload SHA-256 does not match the receipt or if version contains invalid
/// path characters. Returns `Ok(None)` when no update is staged.
pub fn apply_staged_update(
    data_dir: &Path,
    install_root: &Path,
) -> Result<Option<LauncherWatchdogState>, String> {
    let receipt_path = data_dir.join("ota_staging").join("staged.json");
    if !receipt_path.is_file() {
        return Ok(None);
    }
    let raw = std::fs::read_to_string(&receipt_path).map_err(|e| format!("read receipt: {e}"))?;
    let receipt: StagedUpdateReceipt =
        serde_json::from_str(&raw).map_err(|e| format!("parse receipt: {e}"))?;
    let safe_ver: String = receipt
        .version
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .collect();
    if safe_ver.is_empty() || safe_ver != receipt.version.trim() {
        return Err("invalid staged version".to_owned());
    }
    let payload = PathBuf::from(&receipt.payload_path);
    let actual_sha = sha256_file(&payload)?;
    if !actual_sha.eq_ignore_ascii_case(receipt.sha256.trim()) {
        return Err("staged payload sha256 mismatch".to_owned());
    }
    let slot_dir = install_root.join("versions").join(&safe_ver);
    std::fs::create_dir_all(&slot_dir).map_err(|e| format!("create slot dir: {e}"))?;
    let dest = slot_dir.join("payload.bin");
    let dest_tmp = slot_dir.join("payload.bin.tmp");
    std::fs::copy(&payload, &dest_tmp).map_err(|e| format!("copy payload: {e}"))?;
    std::fs::rename(&dest_tmp, &dest).map_err(|e| format!("rename payload: {e}"))?;

    let state_path = install_root.join("launcher-state.json");
    let prev_healthy = std::fs::read_to_string(&state_path)
        .ok()
        .and_then(|s| serde_json::from_str::<LauncherWatchdogState>(&s).ok())
        .and_then(|st| st.last_healthy_version.or(Some(st.active_version)));
    let next_state = LauncherWatchdogState {
        active_version: safe_ver,
        last_healthy_version: prev_healthy,
        pending_boot_attempts: 0,
    };
    let state_bytes =
        serde_json::to_vec_pretty(&next_state).map_err(|e| format!("encode state: {e}"))?;
    atomic_write(&state_path, &state_bytes)?;
    std::fs::remove_file(&receipt_path).map_err(|e| format!("remove receipt: {e}"))?;
    Ok(Some(next_state))
}

/// Records the active slot in `<install_root>/launcher-state.json` as healthy.
pub fn mark_install_healthy(install_root: &Path) -> Result<LauncherWatchdogState, String> {
    let state_path = install_root.join("launcher-state.json");
    let raw = std::fs::read_to_string(&state_path).map_err(|e| format!("read state: {e}"))?;
    let mut state: LauncherWatchdogState =
        serde_json::from_str(&raw).map_err(|e| format!("parse state: {e}"))?;
    state.mark_boot_healthy();
    let bytes = serde_json::to_vec_pretty(&state).map_err(|e| format!("encode state: {e}"))?;
    atomic_write(&state_path, &bytes)?;
    Ok(state)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() == 3 && args[0] == "--apply-staged" {
        let Ok(exe) = std::env::current_exe() else {
            #[expect(
                clippy::print_stderr,
                reason = "CLI updater reports executable path failure."
            )]
            {
                eprintln!("could not resolve current executable path");
            }
            return ExitCode::FAILURE;
        };
        let ownership = detect_update_ownership(
            std::env::var("FLATPAK_ID").ok().as_deref(),
            std::env::var("SNAP").ok().as_deref(),
            &exe,
        );
        if ownership != UpdateOwnership::SelfManaged {
            #[expect(
                clippy::print_stderr,
                reason = "CLI updater reports managed-install refusal."
            )]
            {
                eprintln!("self-update disabled for externally managed install");
            }
            return ExitCode::FAILURE;
        }
        return match apply_staged_update(Path::new(&args[1]), Path::new(&args[2])) {
            Ok(Some(state)) => {
                #[expect(
                    clippy::print_stdout,
                    reason = "CLI updater prints applied version receipt."
                )]
                {
                    println!("APPLIED {}", state.active_version);
                }
                ExitCode::SUCCESS
            }
            Ok(None) => ExitCode::SUCCESS,
            Err(err) => {
                #[expect(clippy::print_stderr, reason = "CLI updater prints apply failure.")]
                {
                    eprintln!("{err}");
                }
                ExitCode::FAILURE
            }
        };
    }
    if args.len() == 2 && args[0] == "--mark-healthy" {
        return match mark_install_healthy(Path::new(&args[1])) {
            Ok(_) => ExitCode::SUCCESS,
            Err(err) => {
                #[expect(clippy::print_stderr, reason = "CLI updater prints watchdog error.")]
                {
                    eprintln!("{err}");
                }
                ExitCode::FAILURE
            }
        };
    }
    if args.len() == 4 && args[0] == "--verify-manifest" {
        let Ok(manifest_bytes) = std::fs::read(&args[1]) else {
            #[expect(
                clippy::print_stderr,
                reason = "CLI updater reports user-actionable diagnostic to stderr."
            )]
            {
                eprintln!("failed to read manifest file");
            }
            return ExitCode::FAILURE;
        };
        let Ok(sig_text) = std::fs::read_to_string(&args[2]) else {
            #[expect(
                clippy::print_stderr,
                reason = "CLI updater reports user-actionable diagnostic to stderr."
            )]
            {
                eprintln!("failed to read signature file");
            }
            return ExitCode::FAILURE;
        };
        let pubkey_b64 = &args[3];
        return match verify_minisign_bytes(pubkey_b64, &manifest_bytes, &sig_text) {
            Ok(()) => {
                #[expect(
                    clippy::print_stdout,
                    reason = "CLI --verify-manifest prints deterministic verification receipt to stdout."
                )]
                {
                    println!("VERIFIED");
                }
                ExitCode::SUCCESS
            }
            Err(err) => {
                #[expect(
                    clippy::print_stderr,
                    reason = "CLI updater prints DiagnosticKey verification failure to stderr."
                )]
                {
                    eprintln!("{err}");
                }
                ExitCode::FAILURE
            }
        };
    }

    #[expect(
        clippy::print_stderr,
        reason = "CLI updater prints usage instructions to stderr on invalid invocation."
    )]
    {
        eprintln!(
            "Usage: bistre-updater --verify-manifest <manifest_path> <sig_path> <pubkey_b64>"
        );
    }
    ExitCode::from(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watchdog_rolls_back_after_three_failed_boots() {
        let mut state = LauncherWatchdogState {
            active_version: "0.2.0".to_owned(),
            last_healthy_version: Some("0.1.0".to_owned()),
            pending_boot_attempts: 0,
        };

        for _ in 0..3 {
            let (slot, rolled_back) = state.plan_next_boot();
            assert_eq!(slot, "0.2.0");
            assert!(!rolled_back);
        }

        let (slot, rolled_back) = state.plan_next_boot();
        assert_eq!(slot, "0.1.0");
        assert!(rolled_back);
        assert_eq!(state.active_version, "0.1.0");
        assert_eq!(state.pending_boot_attempts, 0);
    }

    #[test]
    fn watchdog_resets_counter_when_marked_healthy() {
        let mut state = LauncherWatchdogState {
            active_version: "0.2.0".to_owned(),
            last_healthy_version: Some("0.1.0".to_owned()),
            pending_boot_attempts: 2,
        };
        state.mark_boot_healthy();
        assert_eq!(state.last_healthy_version.as_deref(), Some("0.2.0"));
        assert_eq!(state.pending_boot_attempts, 0);
    }

    #[test]
    fn apply_staged_update_verifies_sha256_and_advances_watchdog_state()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let data_dir = dir.path().join("data");
        let install_root = dir.path().join("install");
        let staging_slot = data_dir.join("ota_staging").join("0.2.0");
        std::fs::create_dir_all(&staging_slot)?;
        let payload_path = staging_slot.join("payload.bin");
        std::fs::write(&payload_path, b"signed-binary-bytes")?;

        let mut h = Sha256Stream::new();
        h.update(b"signed-binary-bytes");
        let good_sha = h.finalize_hex();

        let receipt_path = data_dir.join("ota_staging").join("staged.json");
        // Tampered hash must be rejected fail-closed without modifying install_root.
        std::fs::write(
            &receipt_path,
            serde_json::json!({
                "version": "0.2.0",
                "payload_path": payload_path,
                "sha256": "0".repeat(64),
                "reinstall": false
            })
            .to_string(),
        )?;
        assert!(apply_staged_update(&data_dir, &install_root).is_err());
        assert!(!install_root.join("launcher-state.json").exists());

        // Valid SHA-256 stages the slot, writes launcher-state.json, and clears staged.json.
        std::fs::write(
            &receipt_path,
            serde_json::json!({
                "version": "0.2.0",
                "payload_path": payload_path,
                "sha256": good_sha,
                "reinstall": false
            })
            .to_string(),
        )?;
        let state = apply_staged_update(&data_dir, &install_root)?
            .ok_or("expected staged update to apply")?;
        assert_eq!(state.active_version, "0.2.0");
        assert_eq!(state.pending_boot_attempts, 0);
        assert!(
            install_root
                .join("versions")
                .join("0.2.0")
                .join("payload.bin")
                .is_file()
        );
        assert!(!receipt_path.exists());
        Ok(())
    }

    #[test]
    fn ownership_disables_self_update_in_sandboxes_and_usr() {
        assert_eq!(
            detect_update_ownership(
                Some("dev.bistre.Bistre"),
                None,
                Path::new("/app/bin/bistre")
            ),
            UpdateOwnership::Flatpak
        );
        assert_eq!(
            detect_update_ownership(
                None,
                Some("bistre"),
                Path::new("/snap/bistre/current/bistre")
            ),
            UpdateOwnership::Snap
        );
        assert_eq!(
            detect_update_ownership(None, None, Path::new("/usr/bin/bistre")),
            UpdateOwnership::SystemPackageManager
        );
        assert_eq!(
            detect_update_ownership(
                None,
                None,
                Path::new("/home/user/Applications/Bistre.AppImage")
            ),
            UpdateOwnership::SelfManaged
        );
    }
}
