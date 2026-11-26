//! `ToolApprovalBroker`: the single dispatch gate for workspace tool execution (Spec 04 / 06).
//!
//! - A `ToolExecutionPermit` is bound to the exact `(scope, tool, arguments, policy revision)`,
//!   is neither `Clone` nor serializable, and is claimed at most once (`AtomicBool` CAS).
//! - `invalidate()` bumps the policy revision synchronously: every outstanding permit becomes
//!   unclaimable the moment permissions or the workspace change.
//! - `RunActivity` measures active run time on a monotonic clock, skipping gaps longer than
//!   5 s (OS sleep / suspended app) so elapsed-time budgets never jump after a laptop wakes.

use bistre_protocol::lock_or_recover;
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use serde_json::Value;

/// Gap above which time between activity ticks is treated as sleep and not counted.
pub const SLEEP_GAP_THRESHOLD: Duration = Duration::from_secs(5);

/// How long an approval stays claimable.
pub const APPROVAL_TTL: Duration = Duration::from_secs(60);
/// Maximum outstanding approvals; the oldest is evicted beyond this.
pub const MAX_PENDING_APPROVALS: usize = 64;

/// One-use permission for one exact tool call.
#[derive(Debug)]
pub struct ToolExecutionPermit {
    scope: String,
    tool: String,
    args_digest: String,
    revision: u64,
    claimed: AtomicBool,
}

/// Canonical digest of tool arguments (sorted-key JSON, `blake3`).
pub(crate) fn args_digest(args: &Value) -> String {
    blake3::hash(args.to_string().as_bytes())
        .to_hex()
        .as_str()
        .to_owned()
}

/// Issues and verifies permits; owns the policy revision and the approved-permit store.
#[derive(Debug, Default)]
pub struct ToolApprovalBroker {
    revision: AtomicU64,
    approved: Mutex<HashMap<String, (Instant, ToolExecutionPermit)>>,
}

impl ToolApprovalBroker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Issues a permit for an approved (or auto-approved Tier 0) call.
    pub fn issue(&self, scope: &str, tool: &str, args: &Value) -> ToolExecutionPermit {
        ToolExecutionPermit {
            scope: scope.to_owned(),
            tool: tool.to_owned(),
            args_digest: args_digest(args),
            revision: self.revision.load(Ordering::Acquire),
            claimed: AtomicBool::new(false),
        }
    }

    /// Claims `permit` for exactly this call. Fails if the call differs in any way, the policy
    /// changed since issue, or the permit was already used.
    pub fn claim(
        &self,
        permit: &ToolExecutionPermit,
        scope: &str,
        tool: &str,
        args: &Value,
    ) -> BistreResult<()> {
        let mismatch = permit.scope != scope
            || permit.tool != tool
            || permit.args_digest != args_digest(args)
            || permit.revision != self.revision.load(Ordering::Acquire);
        if mismatch
            || permit
                .claimed
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
        {
            return Err(BistreError::with_detail(
                DiagnosticKey::ToolApprovalRequired,
                "permit_invalid",
            ));
        }
        Ok(())
    }

    /// Records the user's approval of one exact call and returns its permit id.
    pub fn approve(&self, scope: &str, tool: &str, args: &Value) -> BistreResult<String> {
        let id = uuid::Uuid::now_v7().to_string();
        let permit = self.issue(scope, tool, args);
        let mut map = self.lock_approved();
        let now = Instant::now();
        map.retain(|_, (at, _)| now.duration_since(*at) < APPROVAL_TTL);
        while map.len() >= MAX_PENDING_APPROVALS {
            let oldest = map
                .iter()
                .min_by_key(|(_, (at, _))| *at)
                .map(|(k, _)| k.clone());
            let Some(oldest) = oldest else { break };
            map.remove(&oldest);
        }
        map.insert(id.clone(), (now, permit));
        Ok(id)
    }

    /// Removes and returns an approved, unexpired permit. Each id works at most once.
    pub fn take_approved(&self, permit_id: &str) -> BistreResult<ToolExecutionPermit> {
        let (at, permit) = self.lock_approved().remove(permit_id).ok_or_else(|| {
            BistreError::with_detail(DiagnosticKey::ToolApprovalRequired, "permit_missing")
        })?;
        if at.elapsed() >= APPROVAL_TTL {
            return Err(BistreError::with_detail(
                DiagnosticKey::ToolApprovalRequired,
                "permit_expired",
            ));
        }
        Ok(permit)
    }

    fn lock_approved(
        &self,
    ) -> std::sync::MutexGuard<'_, HashMap<String, (Instant, ToolExecutionPermit)>> {
        lock_or_recover(&self.approved, "approved")
    }

    /// Synchronously revokes every outstanding permit (permission, mode, or workspace change).
    pub fn invalidate(&self) {
        self.revision.fetch_add(1, Ordering::AcqRel);
    }

    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::Acquire)
    }
}

/// Monotonic active-time accumulator that skips sleep gaps.
#[derive(Debug, Clone, Copy)]
pub struct RunActivity {
    last: Instant,
    active: Duration,
}

impl RunActivity {
    pub fn start() -> Self {
        Self {
            last: Instant::now(),
            active: Duration::ZERO,
        }
    }

    /// Records activity now; a gap longer than [`SLEEP_GAP_THRESHOLD`] counts as zero.
    pub fn tick(&mut self) {
        self.tick_at(Instant::now());
    }

    fn tick_at(&mut self, now: Instant) {
        let gap = now.saturating_duration_since(self.last);
        if gap <= SLEEP_GAP_THRESHOLD {
            self.active += gap;
        }
        self.last = now;
    }

    /// Active milliseconds including the final segment up to now.
    pub fn finish_ms(mut self) -> i64 {
        self.tick();
        i64::try_from(self.active.as_millis()).unwrap_or(i64::MAX)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn permits_are_exact_one_use_and_revoked_synchronously() {
        let broker = ToolApprovalBroker::new();
        let args = json!({"command": "cargo test"});
        let permit = broker.issue("thread-1", "shell", &args);
        assert!(
            broker
                .claim(
                    &permit,
                    "thread-1",
                    "shell",
                    &json!({"command": "rm -rf /"})
                )
                .is_err()
        );
        assert!(broker.claim(&permit, "thread-2", "shell", &args).is_err());
        assert!(broker.claim(&permit, "thread-1", "shell", &args).is_ok());
        assert!(
            broker.claim(&permit, "thread-1", "shell", &args).is_err(),
            "second claim must fail"
        );

        let stale = broker.issue("thread-1", "shell", &args);
        broker.invalidate();
        assert_eq!(
            broker
                .claim(&stale, "thread-1", "shell", &args)
                .err()
                .map(|e| e.key),
            Some(DiagnosticKey::ToolApprovalRequired)
        );
        let fresh = broker.issue("thread-1", "shell", &args);
        assert!(broker.claim(&fresh, "thread-1", "shell", &args).is_ok());
    }

    #[test]
    fn approved_permits_are_single_use_exact_and_revocable() -> BistreResult<()> {
        let broker = ToolApprovalBroker::new();
        let args = json!({"path": "a.txt"});
        // No approval: nothing to take.
        assert!(broker.take_approved("nope").is_err());
        let id = broker.approve("t", "edit", &args)?;
        let permit = broker.take_approved(&id)?;
        // Arguments changed after approval: the claim fails.
        assert!(
            broker
                .claim(&permit, "t", "edit", &json!({"path": "b.txt"}))
                .is_err()
        );
        // The id was consumed by the first take.
        assert!(broker.take_approved(&id).is_err());
        // A policy change between approval and dispatch revokes it.
        let id = broker.approve("t", "edit", &args)?;
        broker.invalidate();
        let permit = broker.take_approved(&id)?;
        assert!(broker.claim(&permit, "t", "edit", &args).is_err());
        Ok(())
    }

    #[test]
    fn run_activity_skips_sleep_gaps() {
        let mut activity = RunActivity::start();
        let t0 = activity.last;
        activity.tick_at(t0 + Duration::from_secs(2));
        activity.tick_at(t0 + Duration::from_secs(2) + Duration::from_secs(3600));
        activity.tick_at(t0 + Duration::from_secs(3603));
        assert_eq!(activity.active, Duration::from_secs(3));
    }
}
