//! Linux `systemd-logind` sleep/idle inhibitor & `systemd --user` linger helper (`bistre-daemon`).
//!
//! 100% safe pure-Rust implementation (zero `unsafe` code): holds a run-scoped `systemd-inhibit`
//! lock for `"sleep:idle"` (`--mode=block`) strictly while `active_runs > 0`, and provides helpers
//! for generating a user-scoped `systemd --user` service unit and checking `loginctl enable-linger`.

#![cfg(target_os = "linux")]

use bistre_protocol::lock_or_recover;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

use bistre_core::power::{PowerGuardBackend, PowerLeasePolicy};
use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};

/// Pure-safe Linux `systemd-logind` sleep & idle inhibitor.
#[derive(Debug, Default)]
pub(crate) struct LinuxPowerGuard {
    holder: Mutex<Option<Child>>,
}

impl LinuxPowerGuard {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
}

impl Drop for LinuxPowerGuard {
    fn drop(&mut self) {
        self.release();
    }
}

impl PowerGuardBackend for LinuxPowerGuard {
    fn platform_name(&self) -> &'static str {
        "linux"
    }

    fn acquire(&self, policy: PowerLeasePolicy, reason: &str) -> BistreResult<bool> {
        self.release();
        if !policy.keep_awake_while_running {
            return Ok(false);
        }
        // Uses `systemd-inhibit` (standard systemd-logind D-Bus client) holding an inhibitor FD
        // until the child is terminated on `release()`. Zero C dependencies and works across Wayland/X11/headless.
        // Linux-only inhibitor holder: no console window exists to suppress, and the child must
        // keep the inherited stdin pipe as its lifetime FD, so the shared helper is not used here.
        #[expect(
            clippy::disallowed_methods,
            reason = "Audited Linux-only systemd-inhibit holder (guard allowlist: power_linux.rs)."
        )]
        let mut cmd = Command::new("systemd-inhibit");
        cmd.arg("--what=sleep:idle")
            .arg("--mode=block")
            .arg("--who=Bistre")
            .arg(format!("--why={reason}"))
            .arg("cat")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // A crashed daemon must not leave the inhibitor holding sleep (`PR_SET_PDEATHSIG`).
        bistre_core::process_util::contain_with_parent(&mut cmd);
        let child = cmd
            .spawn()
            .map_err(|_| BistreError::new(DiagnosticKey::PowerGuardDegraded))?;

        {
            let mut guard = lock_or_recover(&self.holder, "holder");
            *guard = Some(child);
        }
        Ok(true)
    }

    fn release(&self) {
        let taken = lock_or_recover(&self.holder, "holder").take();
        if let Some(mut child) = taken {
            // `kill` fails only when the inhibitor already exited; `wait` then reaps it.
            if child.kill().is_err() {
                tracing::debug!("systemd-inhibit already exited");
            }
            if child.wait().is_err() {
                tracing::debug!("systemd-inhibit could not be reaped");
            }
        }
    }

    fn is_on_ac_power(&self) -> bool {
        let Ok(entries) = std::fs::read_dir("/sys/class/power_supply") else {
            return true;
        };
        for entry in entries.flatten() {
            let kind = std::fs::read_to_string(entry.path().join("type")).unwrap_or_default();
            if kind.trim().eq_ignore_ascii_case("Mains") {
                let online =
                    std::fs::read_to_string(entry.path().join("online")).unwrap_or_default();
                return online.trim() == "1";
            }
        }
        true
    }
}

/// Renders a clean `systemd --user` service unit for headless / `loginctl enable-linger` survival.
#[expect(
    dead_code,
    reason = "Exposed for Linux systemd unit installation workflow."
)]
pub(crate) fn render_systemd_user_unit(binary_path: &str, data_dir: &str) -> String {
    format!(
        "[Unit]\n\
         Description=Bistre Local AI Agent Daemon\n\
         After=network-online.target\n\
         \n\
         [Service]\n\
         Type=simple\n\
         ExecStart={binary_path} --data-dir {data_dir}\n\
         Restart=on-failure\n\
         RestartSec=3\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n"
    )
}
