//! Safe OS power, sleep-inhibition, and connectivity guard abstractions (`crates/bistre-core`).
//!
//! Invariants:
//! - `#![deny(unsafe_code)]` holds strictly inside `bistre-core`; platform Win32 / Linux / Android
//!   inhibitors plug into the `PowerGuardBackend` trait from `bistre-daemon` or platform shims.
//! - Sleep inhibition leases are strictly run-scoped (`active_runs > 0` acquires, `0` releases).

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bistre_protocol::{BistreResult, PowerGuardStatus, SystemPowerEvent};
use tokio::sync::broadcast;

const POWER_EVENT_CAP: usize = 64;
/// Minimum delay before re-attempting a failed OS sleep inhibitor (no idle polling: retries ride on
/// the next lease, policy update, or run step).
pub const POWER_RETRY_BACKOFF: Duration = Duration::from_secs(5);

/// Configuration applied when acquiring a run-scoped OS sleep inhibitor lease.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PowerLeasePolicy {
    pub keep_awake_while_running: bool,
    /// Opt-in Windows Modern Standby (S0ix) battery override (`PowerRequestDisplayRequired`).
    pub windows_keep_awake_on_battery: bool,
}

impl Default for PowerLeasePolicy {
    fn default() -> Self {
        Self {
            keep_awake_while_running: true,
            windows_keep_awake_on_battery: false,
        }
    }
}

/// Platform-specific backend implementing OS sleep/idle inhibition (Win32 / Linux logind / Android FGS).
pub trait PowerGuardBackend: Send + Sync + std::fmt::Debug {
    /// Human-readable platform identifier (`windows`, `linux`, `android`, `noop`).
    fn platform_name(&self) -> &'static str;

    /// Acquires or updates the OS sleep/execution inhibitor for active agent runs.
    fn acquire(&self, policy: PowerLeasePolicy, reason: &str) -> BistreResult<bool>;

    /// Releases the OS sleep/execution inhibitor once `active_runs` returns to `0`.
    fn release(&self);

    /// Queries whether the host is currently on AC power (`true` if unknown/desktop).
    fn is_on_ac_power(&self) -> bool {
        true
    }
}

/// Safe fallback backend used in tests and embedded builds before platform hooks register.
#[derive(Debug, Default)]
pub struct NoopPowerGuardBackend;

impl PowerGuardBackend for NoopPowerGuardBackend {
    fn platform_name(&self) -> &'static str {
        std::env::consts::OS
    }

    fn acquire(&self, policy: PowerLeasePolicy, _reason: &str) -> BistreResult<bool> {
        Ok(policy.keep_awake_while_running)
    }

    fn release(&self) {}
}

/// Reference-counted run-scoped coordinator managing OS sleep leases and power events.
#[derive(Debug)]
pub struct PowerCoordinator {
    backend: Arc<dyn PowerGuardBackend>,
    active_leases: AtomicU32,
    keep_awake_active: AtomicBool,
    battery_override_active: AtomicBool,
    daemon_connected: AtomicBool,
    on_ac_power: AtomicBool,
    android_fgs_active: AtomicBool,
    android_battery_unrestricted: AtomicBool,
    reason: Mutex<String>,
    policy: Mutex<PowerLeasePolicy>,
    /// Set when the backend failed to inhibit sleep; cleared on the next successful acquire.
    last_failure: Mutex<Option<Instant>>,
    events_tx: broadcast::Sender<SystemPowerEvent>,
}

impl PowerCoordinator {
    /// Creates a new coordinator backed by a concrete platform `PowerGuardBackend`.
    pub fn new(backend: Arc<dyn PowerGuardBackend>) -> Arc<Self> {
        let on_ac = backend.is_on_ac_power();
        let (events_tx, _) = broadcast::channel(POWER_EVENT_CAP);
        Arc::new(Self {
            backend,
            active_leases: AtomicU32::new(0),
            keep_awake_active: AtomicBool::new(false),
            battery_override_active: AtomicBool::new(false),
            daemon_connected: AtomicBool::new(false),
            on_ac_power: AtomicBool::new(on_ac),
            android_fgs_active: AtomicBool::new(false),
            android_battery_unrestricted: AtomicBool::new(false),
            reason: Mutex::new(String::new()),
            policy: Mutex::new(PowerLeasePolicy::default()),
            last_failure: Mutex::new(None),
            events_tx,
        })
    }

    /// Calls the backend and records success/failure for the retry backoff and `Unavailable` state.
    fn try_acquire(&self, policy: PowerLeasePolicy, reason: &str) {
        let acquired = self.backend.acquire(policy, reason).unwrap_or(false);
        self.keep_awake_active.store(acquired, Ordering::SeqCst);
        self.battery_override_active.store(
            acquired && policy.windows_keep_awake_on_battery,
            Ordering::SeqCst,
        );
        if let Ok(mut failure) = self.last_failure.lock() {
            *failure = if acquired { None } else { Some(Instant::now()) };
        }
    }

    /// `true` while runs want sleep inhibition but the OS refused it (UI shows "Unavailable").
    pub fn is_unavailable(&self) -> bool {
        self.active_leases.load(Ordering::SeqCst) > 0
            && self.policy.lock().is_ok_and(|p| p.keep_awake_while_running)
            && !self.keep_awake_active.load(Ordering::SeqCst)
            && self.last_failure.lock().is_ok_and(|f| f.is_some())
    }

    /// Re-attempts a failed inhibitor once [`POWER_RETRY_BACKOFF`] has elapsed. Event-driven:
    /// called from run steps, never from a timer. Returns `true` when a retry was attempted.
    pub fn retry_if_due(&self) -> bool {
        let due = self
            .last_failure
            .lock()
            .is_ok_and(|f| f.is_some_and(|at| at.elapsed() >= POWER_RETRY_BACKOFF));
        if !due || self.active_leases.load(Ordering::SeqCst) == 0 {
            return false;
        }
        let policy = self.policy.lock().map_or_default(|g| *g);
        if !policy.keep_awake_while_running {
            return false;
        }
        let reason = self.reason.lock().map_or_default(|g| g.clone());
        self.try_acquire(policy, &reason);
        true
    }

    /// Updates active sleep-guard preferences and re-applies immediately if runs are in flight.
    pub fn update_policy(&self, next: PowerLeasePolicy) -> PowerGuardStatus {
        if let Ok(mut guard) = self.policy.lock() {
            *guard = next;
        }
        let count = self.active_leases.load(Ordering::SeqCst);
        if count > 0 {
            if next.keep_awake_while_running {
                let reason = self
                    .reason
                    .lock()
                    .map_or_else(|_| "Active Bistre agent run".to_owned(), |g| g.clone());
                self.try_acquire(next, &reason);
            } else {
                self.backend.release();
                self.keep_awake_active.store(false, Ordering::SeqCst);
                self.battery_override_active.store(false, Ordering::SeqCst);
            }
        }
        self.status()
    }

    /// Acquires a run-scoped sleep lease. Drops release automatically when the final run ends.
    pub fn acquire_run_lease(self: &Arc<Self>, reason: impl Into<String>) -> PowerRunLease {
        let prev = self.active_leases.fetch_add(1, Ordering::SeqCst);
        let reason_str = reason.into();
        if let Ok(mut guard) = self.reason.lock() {
            guard.clone_from(&reason_str);
        }
        if prev == 0 {
            let policy = self.policy.lock().map_or_default(|g| *g);
            if policy.keep_awake_while_running {
                self.try_acquire(policy, &reason_str);
            }
        } else {
            self.retry_if_due();
        }
        PowerRunLease {
            coordinator: Arc::clone(self),
        }
    }

    fn release_one(&self) {
        let prev = self.active_leases.fetch_sub(1, Ordering::SeqCst);
        if prev <= 1 {
            self.backend.release();
            self.keep_awake_active.store(false, Ordering::SeqCst);
            self.battery_override_active.store(false, Ordering::SeqCst);
            if let Ok(mut guard) = self.reason.lock() {
                guard.clear();
            }
            if let Ok(mut failure) = self.last_failure.lock() {
                *failure = None;
            }
        }
    }

    /// Records whether desktop IPC is currently backed by persistent `bistre-daemon`.
    pub fn set_daemon_connected(&self, connected: bool) {
        self.daemon_connected.store(connected, Ordering::SeqCst);
    }

    /// Records live Android `specialUse` FGS and unrestricted battery exemption state from Kotlin.
    pub fn set_android_power_state(&self, fgs_active: bool, battery_unrestricted: bool) {
        self.android_fgs_active.store(fgs_active, Ordering::SeqCst);
        self.android_battery_unrestricted
            .store(battery_unrestricted, Ordering::SeqCst);
    }

    /// Publishes an OS suspend/resume/network/timeout event to subscribers.
    pub fn notify_system_event(&self, event: SystemPowerEvent) {
        if let SystemPowerEvent::PowerSourceChanged { on_ac } = event {
            self.on_ac_power.store(on_ac, Ordering::SeqCst);
        }
        if self.events_tx.send(event).is_err() {
            tracing::trace!("power event had no subscribers");
        }
    }

    /// Subscribes to OS power & connectivity transitions.
    pub fn subscribe(&self) -> broadcast::Receiver<SystemPowerEvent> {
        self.events_tx.subscribe()
    }

    /// Returns a live status snapshot for UI telemetry-free indicators.
    pub fn status(&self) -> PowerGuardStatus {
        let reason = self.reason.lock().map_or_default(|g| g.clone());
        PowerGuardStatus {
            platform: self.backend.platform_name().to_owned(),
            keep_awake_active: self.keep_awake_active.load(Ordering::SeqCst),
            battery_override_active: self.battery_override_active.load(Ordering::SeqCst),
            daemon_connected: self.daemon_connected.load(Ordering::SeqCst),
            on_ac_power: self.on_ac_power.load(Ordering::SeqCst),
            sleep_prevented_reason: reason,
            android_fgs_active: self.android_fgs_active.load(Ordering::SeqCst),
            android_battery_unrestricted: self.android_battery_unrestricted.load(Ordering::SeqCst),
            active_run_count: self.active_leases.load(Ordering::SeqCst),
        }
    }
}

/// RAII lease releasing OS sleep inhibition automatically when an agent run finishes or drops.
#[derive(Debug)]
pub struct PowerRunLease {
    coordinator: Arc<PowerCoordinator>,
}

impl Drop for PowerRunLease {
    fn drop(&mut self) {
        self.coordinator.release_one();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU32 as Counter;

    #[derive(Debug, Default)]
    struct FlakyBackend {
        attempts: Counter,
        fail_first: u32,
    }

    impl PowerGuardBackend for FlakyBackend {
        fn platform_name(&self) -> &'static str {
            "test"
        }

        fn acquire(&self, _policy: PowerLeasePolicy, _reason: &str) -> BistreResult<bool> {
            let n = self.attempts.fetch_add(1, Ordering::SeqCst);
            Ok(n >= self.fail_first)
        }

        fn release(&self) {}
    }

    #[test]
    fn failed_inhibitor_reports_unavailable_and_retries_only_after_backoff() {
        let backend = Arc::new(FlakyBackend {
            attempts: Counter::new(0),
            fail_first: 1,
        });
        let coord = PowerCoordinator::new(backend.clone());
        let lease = coord.acquire_run_lease("run");
        assert!(coord.is_unavailable());
        assert!(!coord.retry_if_due(), "must wait for the 5 s backoff");
        assert_eq!(backend.attempts.load(Ordering::SeqCst), 1);

        if let Ok(mut f) = coord.last_failure.lock() {
            *f = Instant::now().checked_sub(POWER_RETRY_BACKOFF);
        }
        assert!(coord.retry_if_due());
        assert!(!coord.is_unavailable());
        assert!(coord.status().keep_awake_active);
        drop(lease);
        assert!(!coord.is_unavailable());
    }
}
