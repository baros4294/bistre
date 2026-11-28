//! Durable WAL agent run recovery, rate-limit backoff watchdog, and suspension reconciliation.
//!
//! Guarantees zero lost state across forced sleep, lid-close, Wi-Fi->5G handoff, app crash,
//! or Android OEM kills while strictly enforcing Wallet Shield precedence and idempotency.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::events::{emit, emit_logged};
use bistre_protocol::{
    AgentRunRecord, AppSettings, BistreResult, DiagnosticKey, EngineEvent, MoneyMicros, RunStatus,
    RunStepKind, RunStepRecord, SystemPowerEvent, ToolRiskTier, UnattendedPolicy,
};
use bistre_storage::{AgentRunUpdate, StorageHandle};
use tokio::sync::broadcast;

/// Outcome of reconciling an interrupted durable run after wake, reconnect, or cold launch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecoveryAction {
    /// Safe to resume execution automatically (LLM call, Tier-0 read, or verified Tier-1 edit).
    AutoResume { run_id: String, thread_id: String },
    /// Blocked by Wallet Shield daily spending ceiling (Wallet Shield unconditionally overrides recovery).
    BlockedByWalletShield { run_id: String },
    /// A Tier-2 external/side-effecting tool was in-flight during disruption; requires explicit user choice.
    IndeterminateHalt {
        run_id: String,
        tool_name: String,
        idempotency_key: String,
    },
    /// Run is still inside a bounded `Retry-After` backoff window.
    WaitUntil { run_id: String, retry_after_ms: i64 },
}

/// Computes jittered exponential backoff (in milliseconds) honoring `Retry-After` within the
/// user's `retry_watchdog_max_wait_secs` budget. `None` means give up: the budget is spent, or
/// the provider asked for longer than what is left (an early retry hits the same limit).
/// `jitter_seed` differs per run, so runs that failed together do not retry together.
pub fn compute_backoff_wait_ms(
    attempt: u32,
    retry_after_header_secs: Option<u64>,
    elapsed_wait_secs: u64,
    max_total_wait_secs: u32,
    jitter_seed: u64,
) -> Option<u64> {
    let budget = u64::from(max_total_wait_secs);
    if elapsed_wait_secs >= budget {
        return None;
    }
    let remaining_secs = budget.saturating_sub(elapsed_wait_secs);
    if retry_after_header_secs.is_some_and(|hint| hint > remaining_secs) {
        return None;
    }
    let exp_secs = 2_u64
        .saturating_pow(attempt.min(6))
        .saturating_mul(2)
        .min(180);
    let base_secs = retry_after_header_secs.map_or(exp_secs, |hdr| hdr.max(1));
    // Sub-second jitter from a per-run seed (splitmix64; no RNG crate needed).
    let mut z = jitter_seed
        .wrapping_add(u64::from(attempt).wrapping_mul(0x9E37_79B9_7F4A_7C15))
        .wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    let jitter_ms = (z ^ (z >> 31)) % 750;
    let clamped_secs = base_secs.min(remaining_secs);
    Some(clamped_secs.saturating_mul(1000).saturating_add(jitter_ms))
}

/// A stable per-run jitter seed (FNV-1a of the run id).
pub fn jitter_seed(run_id: &str) -> u64 {
    run_id.bytes().fold(0xCBF2_9CE4_8422_2325, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01B3)
    })
}

/// What a run does with a tool call that needs approval. An interactive run records
/// `PauseAndNotify`, so it waits for the user; a scheduled run follows its job's policy.
/// `SandboxWorktreeAuto` runs the call only when `contained_in_sandbox` (the run works in its
/// own worktree and the tool's effects stay inside it); any other call waits.
pub const fn unattended_approval(
    policy: UnattendedPolicy,
    contained_in_sandbox: bool,
) -> UnattendedApproval {
    match policy {
        UnattendedPolicy::PauseAndNotify => UnattendedApproval::Wait,
        UnattendedPolicy::DenyTier2AndContinue => UnattendedApproval::Skip,
        UnattendedPolicy::SandboxWorktreeAuto => {
            if contained_in_sandbox {
                UnattendedApproval::RunInSandbox
            } else {
                UnattendedApproval::Wait
            }
        }
    }
}

/// [`unattended_approval`]'s answer for one tool call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnattendedApproval {
    /// Wait in the chat for the user's decision.
    Wait,
    /// Refuse the call and let the run go on.
    Skip,
    /// Run the call in the run's worktree.
    RunInSandbox,
}

/// A run's approval policy and worktree, read once from its run record. An unreadable or
/// missing record, or a worktree folder that is gone, waits for the user (fail closed).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunApprovalPolicy {
    pub policy: UnattendedPolicy,
    pub sandbox: Option<std::path::PathBuf>,
}

impl RunApprovalPolicy {
    /// Waits for the user on every call that needs approval, with no worktree.
    pub const INTERACTIVE: Self = Self {
        policy: UnattendedPolicy::PauseAndNotify,
        sandbox: None,
    };

    pub fn load(storage: &StorageHandle, run_id: &str) -> Self {
        let run = match storage.get_agent_run(run_id) {
            Ok(Some(run)) => run,
            Ok(None) => {
                tracing::warn!(
                    key = DiagnosticKey::StorageNotFound.as_key(),
                    "run record missing; approvals wait for the user"
                );
                return Self::INTERACTIVE;
            }
            Err(err) => {
                tracing::warn!(
                    key = err.key.as_key(),
                    "run record unreadable; approvals wait for the user"
                );
                return Self::INTERACTIVE;
            }
        };
        let sandbox = run
            .worktree_path
            .map(std::path::PathBuf::from)
            .filter(|p| p.is_dir());
        Self {
            policy: run.unattended_policy,
            sandbox,
        }
    }

    /// The decision for `tool_name`. Only the workspace file and shell tools work in the
    /// worktree; MCP, web, paid tools, and computer use act outside it, so they wait.
    pub fn decide(&self, tool_name: &str) -> UnattendedApproval {
        unattended_approval(
            self.policy,
            self.sandbox.is_some() && crate::tools::works_in_workspace(tool_name),
        )
    }
}

/// Handles a live `SystemPowerEvent` by flushing active runs cleanly on suspend/timeout
/// or reconciling recoverable runs immediately upon resume / network restoration.
pub fn handle_power_event(
    storage: &StorageHandle,
    settings: &AppSettings,
    events_tx: &broadcast::Sender<EngineEvent>,
    event: SystemPowerEvent,
    spent_today: MoneyMicros,
) -> BistreResult<Vec<RecoveryAction>> {
    match event {
        SystemPowerEvent::WillSuspend | SystemPowerEvent::OsTimeoutImminent => {
            let paused = storage.mark_active_runs_sleep_paused()?;
            if paused > 0 {
                tracing::info!(
                    paused_runs = paused,
                    "checkpointed active runs to sleep_paused before OS suspend/timeout"
                );
                match storage.list_agent_runs(None, true, 50) {
                    Ok(runs) => {
                        for run in runs {
                            let ev = EngineEvent::RunStateChanged { run };
                            emit_logged(storage, events_tx, None, ev);
                        }
                    }
                    // The runs are checkpointed; only the UI refresh is lost, and it reloads runs
                    // on resume.
                    Err(err) => tracing::warn!(
                        key = err.key.as_key(),
                        "listing runs after suspend checkpoint failed"
                    ),
                }
            }
            Ok(Vec::new())
        }
        SystemPowerEvent::DidResume | SystemPowerEvent::NetworkRestored => {
            crate::providers::note_app_resumed();
            reconcile_interrupted_runs(storage, settings, events_tx, spent_today)
        }
        SystemPowerEvent::AppResumed => {
            crate::providers::note_app_resumed();
            Ok(Vec::new())
        }
        SystemPowerEvent::NetworkLost | SystemPowerEvent::PowerSourceChanged { .. } => {
            Ok(Vec::new())
        }
    }
}

/// Inspects unfinished SQLite WAL runs after wake/restart and computes deterministic safe recovery actions.
///
/// Safety invariants:
/// 1. Wallet Shield daily cap unconditionally overrides auto-resume.
/// 2. Any in-flight Tier-2 side-effecting tool transitions to `RunStatus::IndeterminateHalt`
///    and emits `DiagnosticKey::RunIndeterminateHalt` so paid/destructive actions NEVER double-run.
/// 3. Tier-0 reads, verified Tier-1 edits, and stateless LLM calls resume safely.
pub fn reconcile_interrupted_runs(
    storage: &StorageHandle,
    settings: &AppSettings,
    events_tx: &broadcast::Sender<EngineEvent>,
    spent_today: MoneyMicros,
) -> BistreResult<Vec<RecoveryAction>> {
    let active_runs = storage.list_agent_runs(None, true, 100)?;
    let now_ms = now_unix_ms();
    let wallet_blocked = settings
        .wallet_daily_ceiling_micros
        .is_some_and(|cap| spent_today >= cap);

    let mut actions = Vec::new();
    for run in active_runs {
        if matches!(
            run.status,
            RunStatus::WaitingApproval | RunStatus::IndeterminateHalt
        ) {
            continue;
        }

        if wallet_blocked {
            let updated = storage.update_agent_run(
                run.id.clone(),
                AgentRunUpdate {
                    status: Some(RunStatus::Failed),
                    error_key: Some(Some(
                        DiagnosticKey::WalletCeilingExceeded.as_key().to_owned(),
                    )),
                    ..AgentRunUpdate::default()
                },
            )?;
            emit_run_event(storage, events_tx, updated);
            emit(
                events_tx,
                EngineEvent::DiagnosticRaised {
                    key: DiagnosticKey::WalletCeilingExceeded,
                    detail_code: Some(run.id.clone()),
                },
            );
            actions.push(RecoveryAction::BlockedByWalletShield { run_id: run.id });
            continue;
        }

        if let Some(retry_until) = run.retry_after_ms
            && run.status == RunStatus::BackoffWait
            && retry_until > now_ms
        {
            actions.push(RecoveryAction::WaitUntil {
                run_id: run.id,
                retry_after_ms: retry_until,
            });
            continue;
        }

        let steps = storage.list_run_steps(&run.id)?;
        if let Some(in_flight_tier2) = find_indeterminate_tier2_step(&steps) {
            let updated = storage.update_agent_run(
                run.id.clone(),
                AgentRunUpdate {
                    status: Some(RunStatus::IndeterminateHalt),
                    error_key: Some(Some(
                        DiagnosticKey::RunIndeterminateHalt.as_key().to_owned(),
                    )),
                    ..AgentRunUpdate::default()
                },
            )?;
            emit_run_event(storage, events_tx, updated);
            emit(
                events_tx,
                EngineEvent::DiagnosticRaised {
                    key: DiagnosticKey::RunIndeterminateHalt,
                    detail_code: Some(in_flight_tier2.tool_name.clone()),
                },
            );
            actions.push(RecoveryAction::IndeterminateHalt {
                run_id: run.id,
                tool_name: in_flight_tier2.tool_name.clone(),
                idempotency_key: in_flight_tier2.idempotency_key.clone(),
            });
            continue;
        }

        let resumed = storage.update_agent_run(
            run.id.clone(),
            AgentRunUpdate {
                status: Some(RunStatus::Running),
                retry_after_ms: Some(None),
                error_key: Some(None),
                ..AgentRunUpdate::default()
            },
        )?;
        emit_run_event(storage, events_tx, resumed);
        actions.push(RecoveryAction::AutoResume {
            run_id: run.id,
            thread_id: run.thread_id,
        });
    }

    Ok(actions)
}

/// Resolves an `INDETERMINATE_HALT` run after explicit user reconciliation (`confirm_completed` or `retry`).
pub fn resolve_indeterminate_run(
    storage: &StorageHandle,
    events_tx: &broadcast::Sender<EngineEvent>,
    run_id: String,
    confirm_completed: bool,
) -> BistreResult<AgentRunRecord> {
    let steps = storage.list_run_steps(&run_id)?;
    if let Some(step) = find_indeterminate_tier2_step(&steps) {
        let next_step_status = if confirm_completed {
            "confirmed_by_user"
        } else {
            "retry_authorized"
        };
        storage.complete_run_step(
            step.id.clone(),
            next_step_status.to_owned(),
            if confirm_completed {
                "{\"reconciled\":\"confirmed_completed\"}".to_owned()
            } else {
                "{\"reconciled\":\"retry_authorized\"}".to_owned()
            },
            0,
        )?;
    }

    let updated = storage.update_agent_run(
        run_id,
        AgentRunUpdate {
            status: Some(RunStatus::Running),
            error_key: Some(None),
            ..AgentRunUpdate::default()
        },
    )?;
    emit_run_event(storage, events_tx, updated.clone());
    Ok(updated)
}

fn find_indeterminate_tier2_step(steps: &[RunStepRecord]) -> Option<&RunStepRecord> {
    steps.iter().rev().find(|s| {
        s.kind == RunStepKind::ToolCall
            && s.completed_at_ms.is_none()
            && matches!(
                s.risk_tier,
                ToolRiskTier::Tier2ExternalSideEffect | ToolRiskTier::Tier3Blocked
            )
    })
}

fn emit_run_event(
    storage: &StorageHandle,
    events_tx: &broadcast::Sender<EngineEvent>,
    run: AgentRunRecord,
) {
    let tid = Some(run.thread_id.clone());
    let ev = EngineEvent::RunStateChanged { run };
    emit_logged(storage, events_tx, tid, ev);
}

fn now_unix_ms() -> i64 {
    let dur = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO);
    i64::try_from(dur.as_millis()).unwrap_or(i64::MAX)
}
