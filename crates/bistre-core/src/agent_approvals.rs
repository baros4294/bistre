//! Live tool-approval state shared by every run and the
//! workspace-hook gate around tool calls.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use bistre_protocol::{
    BistreResult, DiagnosticKey, EngineEvent, ToolApprovalDecision, ToolRiskTier, lock_or_recover,
};
use bistre_storage::StorageHandle;
use serde_json::Value;
use tokio::sync::{broadcast, oneshot};

use crate::events::emit;
use crate::hooks::HookEventKind;

/// Pending live tool-approval waiters. Keyed by thread, run, and call id: the same provider
/// call id appears in many runs (an empty id becomes `call_0` everywhere).
pub type PendingApprovalMap = Arc<Mutex<HashMap<ApprovalKey, PendingApproval>>>;

/// One paused tool call: where the decision goes, and the `ToolApprovalRequested` event that
/// asked for it, so an app that missed the event (lagged events, a reopened window) can show
/// it again.
#[derive(Debug)]
pub struct PendingApproval {
    pub(crate) reply: oneshot::Sender<ToolApprovalDecision>,
    pub(crate) request: EngineEvent,
}

/// The approval requests still waiting for the user, oldest run first.
pub fn pending_approval_requests(pending: &PendingApprovalMap) -> Vec<EngineEvent> {
    let map = lock_or_recover(pending, "pending_approvals");
    let mut waiting: Vec<(&ApprovalKey, &EngineEvent)> =
        map.iter().map(|(key, p)| (key, &p.request)).collect();
    waiting.sort_by(|a, b| (&a.0.run_id, &a.0.call_id).cmp(&(&b.0.run_id, &b.0.call_id)));
    waiting.into_iter().map(|(_, ev)| ev.clone()).collect()
}
/// Chat grants and per-run denials remembered across tool calls.
pub type ThreadAutoApprovals = Arc<Mutex<ApprovalMemory>>;

/// Most chat grants plus run denials remembered at once; beyond this, calls simply ask again.
pub const MAX_APPROVAL_MEMORY: usize = 1024;

/// What "Approve for this chat" and "Deny" leave behind.
///
/// A chat grant covers the exact call (tool + canonical arguments) for the whole chat; only a
/// Tier-0 read tool is granted for any arguments. A denial covers the exact call for the rest
/// of its run, so the model cannot ask the same thing again and again.
#[derive(Debug, Default)]
pub struct ApprovalMemory {
    grants: HashSet<ChatGrant>,
    denials: HashSet<RunDenial>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum ChatGrant {
    ExactCall {
        thread_id: String,
        tool: String,
        args_digest: String,
    },
    AnyArguments {
        thread_id: String,
        tool: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct RunDenial {
    run_id: String,
    tool: String,
    args_digest: String,
}

impl ApprovalMemory {
    fn is_full(&self) -> bool {
        self.grants.len() + self.denials.len() >= MAX_APPROVAL_MEMORY
    }

    /// Remembers "Approve for this chat". Returns `false` when memory is full (the call is
    /// still approved once; the next identical call asks again).
    pub fn grant(&mut self, thread_id: &str, tool: &str, args: &Value, risk: ToolRiskTier) -> bool {
        if self.is_full() {
            return false;
        }
        let grant = if risk == ToolRiskTier::Tier0ReadOnly {
            ChatGrant::AnyArguments {
                thread_id: thread_id.to_owned(),
                tool: tool.to_owned(),
            }
        } else {
            ChatGrant::ExactCall {
                thread_id: thread_id.to_owned(),
                tool: tool.to_owned(),
                args_digest: crate::approval::args_digest(args),
            }
        };
        self.grants.insert(grant);
        true
    }

    /// Whether a chat grant covers this exact call.
    pub fn is_granted(&self, thread_id: &str, tool: &str, args: &Value) -> bool {
        self.grants.contains(&ChatGrant::AnyArguments {
            thread_id: thread_id.to_owned(),
            tool: tool.to_owned(),
        }) || self.grants.contains(&ChatGrant::ExactCall {
            thread_id: thread_id.to_owned(),
            tool: tool.to_owned(),
            args_digest: crate::approval::args_digest(args),
        })
    }

    /// Remembers a denial of this exact call for the rest of `run_id`.
    pub fn deny(&mut self, run_id: &str, tool: &str, args: &Value) {
        if self.is_full() {
            return;
        }
        self.denials.insert(RunDenial {
            run_id: run_id.to_owned(),
            tool: tool.to_owned(),
            args_digest: crate::approval::args_digest(args),
        });
    }

    /// Whether this exact call was already denied in `run_id`.
    pub fn was_denied(&self, run_id: &str, tool: &str, args: &Value) -> bool {
        self.denials.contains(&RunDenial {
            run_id: run_id.to_owned(),
            tool: tool.to_owned(),
            args_digest: crate::approval::args_digest(args),
        })
    }

    /// Forgets the denials of a finished run.
    pub fn end_run(&mut self, run_id: &str) {
        self.denials.retain(|d| d.run_id != run_id);
    }

    /// Forgets every grant of a deleted chat.
    pub fn forget_thread(&mut self, thread_id: &str) {
        self.grants.retain(|g| match g {
            ChatGrant::ExactCall { thread_id: t, .. }
            | ChatGrant::AnyArguments { thread_id: t, .. } => t != thread_id,
        });
    }
}

/// Waits for the user's decision with no time limit and without polling: the
/// run's `wake` is notified on cancel, so only cancel or a dropped responder ends the wait.
/// A dropped responder means nobody can answer: deny. Returns `(decision, cancelled)`.
pub(crate) async fn wait_for_decision(
    mut rx: oneshot::Receiver<ToolApprovalDecision>,
    cancel_flag: &AtomicBool,
    wake: &tokio::sync::Notify,
) -> (ToolApprovalDecision, bool) {
    loop {
        if cancel_flag.load(Ordering::SeqCst) {
            return (ToolApprovalDecision::Deny, true);
        }
        tokio::select! {
            biased;
            res = &mut rx => {
                return match res {
                    Ok(d) => (d, false),
                    Err(_) => (ToolApprovalDecision::Deny, false),
                };
            }
            // "Retry now" also wakes the run; the loop re-checks the cancel flag.
            () = wake.notified() => {}
        }
    }
}

/// The approved hooks digest for `ws`, or `None` when nothing is approved.
fn approved_hooks_digest(storage: &StorageHandle, ws: &Path) -> BistreResult<Option<String>> {
    storage.get_kv_meta(&crate::hooks::hooks_approval_key(ws))
}

/// Runs the pre-tool hooks for `tool` and returns why the call must not run, if it must not.
pub(crate) async fn pre_tool_hook_verdict(
    storage: &StorageHandle,
    events_tx: &broadcast::Sender<EngineEvent>,
    ws: &Path,
    tool: &str,
) -> Option<String> {
    let approved = match approved_hooks_digest(storage, ws) {
        Ok(d) => d,
        Err(err) => {
            return Some(format!(
                "Workspace hooks could not be checked ({}); the call was not run.",
                err.key.as_key()
            ));
        }
    };
    match crate::hooks::run_lifecycle_hooks(
        ws,
        HookEventKind::PreToolUse,
        Some(tool),
        approved.as_deref(),
    )
    .await
    {
        Ok(crate::hooks::HookRun::None) => None,
        Ok(crate::hooks::HookRun::NotApproved) => {
            emit(
                events_tx,
                EngineEvent::DiagnosticRaised {
                    key: DiagnosticKey::HooksApprovalRequired,
                    detail_code: None,
                },
            );
            Some(
                "Workspace hooks in .bistre/hooks.json are not approved yet, so this call was not run."
                    .to_owned(),
            )
        }
        Ok(crate::hooks::HookRun::Ran(results)) => results.iter().find(|r| !r.ok).map(|r| {
            let detail: String = r.output.chars().take(500).collect();
            format!(
                "Pre-tool hook `{}` failed (exit {}), so the call was not run.\n{detail}",
                r.command, r.exit_code
            )
        }),
        Err(err) => Some(format!(
            "Pre-tool hook could not run ({}), so the call was not run.",
            err.detail_code.as_deref().unwrap_or(err.key.as_key())
        )),
    }
}

/// Runs the approved post-tool hooks; failures are logged, never silently dropped.
pub(crate) async fn run_post_tool_hooks(
    storage: &StorageHandle,
    ws: &Path,
    tool: &str,
    cancel_flag: &AtomicBool,
) {
    let approved = match approved_hooks_digest(storage, ws) {
        Ok(d) => d,
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "post-tool hooks skipped: approval unreadable"
            );
            return;
        }
    };
    let outcome = tokio::select! {
        biased;
        () = crate::providers::until_cancelled(cancel_flag) => return,
        r = crate::hooks::run_lifecycle_hooks(ws, HookEventKind::PostToolUse, Some(tool), approved.as_deref()) => r,
    };
    match outcome {
        Ok(crate::hooks::HookRun::Ran(results)) => {
            for r in results.iter().filter(|r| !r.ok) {
                tracing::warn!(exit = r.exit_code, command = %r.command, "post-tool hook failed");
            }
        }
        Ok(crate::hooks::HookRun::None | crate::hooks::HookRun::NotApproved) => {}
        Err(err) => tracing::warn!(
            key = err.key.as_key(),
            detail = err.detail_code.as_deref().unwrap_or_default(),
            "post-tool hook could not run"
        ),
    }
}

/// Identifies one paused tool call.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ApprovalKey {
    pub thread_id: String,
    pub run_id: String,
    pub call_id: String,
}

/// Delivers a user approval decision to a paused tool call waiter. Returns `true` if a waiter existed.
pub fn deliver_tool_approval(
    pending: &PendingApprovalMap,
    key: &ApprovalKey,
    decision: ToolApprovalDecision,
) -> bool {
    let waiter = lock_or_recover(pending, "pending_approvals").remove(key);
    match waiter {
        Some(p) => p.reply.send(decision).is_ok(),
        None => false,
    }
}
