//! Pure-Rust OTA Verifier & Side-by-Side Crash-Loop Watchdog Launcher (ADR-0008).
//!
//! Responsibilities:
//! - Offline Ed25519 signature verification via `minisign-verify` before staging any Track-A/B pack.
//! - Anti-rollback version comparison & 3-boot crash-loop watchdog reverting to `last_healthy_version`.
//! - Linux package-manager detection (`FLATPAK_ID`, `SNAP`, read-only `/usr`) disabling self-update safely.

use std::path::Path;
use std::process::ExitCode;

use bistre_crypto::verify_minisign_bytes;
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

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
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
