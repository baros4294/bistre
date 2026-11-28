//! Runs one assistant turn's tool calls: approval, permits, hooks, and paired tool results (split out of `agent_tools.rs`).

use crate::agent::{RunApprovalPolicy, UnattendedApproval};
use crate::agent_tools::{
    ActiveToolCatalog, ApprovalKey, ToolPermission, always_asks, commit_tool_result_node,
    dispatch_with_progress, parse_tool_arguments, permission_key, pre_tool_hook_verdict,
    run_post_tool_hooks, wait_for_decision,
};
use crate::engine_runs::StreamServices;
use crate::events::{emit, emit_logged, note_write};
use crate::replay_policy::StoredToolCall;
use crate::tool_spill::spill_off_worker;
use crate::tools::classify_tool_risk;
use bistre_protocol::{
    BistreError, DiagnosticKey, EngineEvent, RunStatus, RunStepKind, ToolApprovalDecision,
    ToolRiskTier, TrustPreset, lock_or_recover,
};
use bistre_storage::{AgentRunUpdate, StorageHandle};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;
use tokio::sync::{broadcast, oneshot};

/// Outcome of executing all tool calls emitted in one assistant turn.
#[expect(
    clippy::struct_excessive_bools,
    reason = "Independent batch results the run loop reads one by one."
)]
#[derive(Debug)]
pub struct ToolBatchOutcome {
    pub last_node_id: String,
    pub any_succeeded: bool,
    pub all_failed: bool,
    pub cancelled: bool,
    /// `ask_user` ran: the run ends here and the user's next message is the answer.
    pub waiting_for_user: bool,
}

/// Executes every tool call emitted by an assistant turn, enforcing `TrustPreset`,
/// `ToolApprovalBroker` permits, `ReadLedger`, lifecycle hooks, output spilling, and guaranteed
/// `NodeRole::Tool` pairing (even on denial, cancellation, or error).
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable handles keep tool-loop dispatch deterministic and testable."
)]
#[expect(
    clippy::too_many_lines,
    reason = "Linear approval, hook, dispatch, and paired node commit sequence for one tool batch."
)]
pub(crate) async fn execute_tool_batch(
    storage: &Arc<StorageHandle>,
    services: &StreamServices,
    events_tx: &broadcast::Sender<EngineEvent>,
    cancel_flag: &Arc<AtomicBool>,
    catalog: &ActiveToolCatalog,
    thread_id: &str,
    run_id: &str,
    assistant_node_id: &str,
    step_index: &mut u32,
    calls: &[StoredToolCall],
    helper: &crate::delegate::HelperContext<'_>,
    run_policy: &RunApprovalPolicy,
) -> ToolBatchOutcome {
    let mut parent_id = assistant_node_id.to_owned();
    let mut any_succeeded = false;
    let mut all_failed = true;
    let mut cancelled = false;
    let mut waiting_for_user = false;

    for call in calls {
        *step_index = step_index.saturating_add(1);
        // Arguments are parsed once; anything but a JSON object (an empty string means
        // no arguments) is an error result with no permit, never an empty `{}` call.
        let parsed_args: Value = if let Some(args) = parse_tool_arguments(&call.arguments_json) {
            args
        } else {
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                ToolRiskTier::Tier0ReadOnly,
                "Tool arguments are not valid JSON; the call was not run.",
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        };
        let risk = if call.name == "mcp_schema" {
            ToolRiskTier::Tier0ReadOnly
        } else {
            classify_tool_risk(&call.name, &parsed_args)
        };

        // Fail-closed checks: cancelled, Tier 3, TrustPreset::Off, or explicit tool Off.
        if waiting_for_user || cancel_flag.load(Ordering::SeqCst) {
            cancelled |= !waiting_for_user;
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                risk,
                if waiting_for_user {
                    "Not run: the run stopped to wait for the user's answer."
                } else {
                    "Cancelled by user before tool execution."
                },
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        }
        if catalog.read_only && risk != ToolRiskTier::Tier0ReadOnly {
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                risk,
                "Refused: this chat is in read-only Plan mode, so only tools that read may run.",
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        }
        let is_mcp_call = catalog.mcp_dispatch.contains_key(&call.name);
        let explicit_perm = catalog
            .permissions
            .get(permission_key(&call.name))
            .or_else(|| {
                is_mcp_call
                    .then(|| catalog.permissions.get("mcp"))
                    .flatten()
            })
            .copied();
        if risk == ToolRiskTier::Tier3Blocked
            || catalog.trust_preset == TrustPreset::Off
            || explicit_perm == Some(ToolPermission::Off)
            || (catalog.policy_unreadable && risk != ToolRiskTier::Tier0ReadOnly)
        {
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                risk,
                "Tool execution blocked by security policy or trust preset.",
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        }

        // Determine whether this call needs interactive user approval.
        let (chat_granted, denied_earlier) = {
            let memory = lock_or_recover(&services.thread_auto_approvals, "approval_memory");
            (
                memory.is_granted(thread_id, &call.name, &parsed_args),
                memory.was_denied(run_id, &call.name, &parsed_args),
            )
        };
        if denied_earlier {
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                risk,
                "Tool call already denied by user earlier in this run.",
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        }
        // Every `computer_use` call requires fresh per-call user approval (never auto-approved).
        let auto_approve = if call.name == "computer_use" {
            false
        } else if call.name == "ask_user" {
            true
        } else {
            match explicit_perm {
                Some(ToolPermission::Allow) if always_asks(&call.name) => {
                    chat_granted || catalog.trust_preset == TrustPreset::UnchainedSandbox
                }
                Some(ToolPermission::Allow) => catalog.trust_preset != TrustPreset::Strict,
                Some(ToolPermission::Ask) => chat_granted,
                Some(ToolPermission::Off) => false,
                None => {
                    chat_granted
                        || (risk == ToolRiskTier::Tier0ReadOnly
                            && catalog.trust_preset != TrustPreset::Strict)
                        || (risk == ToolRiskTier::Tier1ReversibleEdit
                            && catalog.trust_preset == TrustPreset::UnchainedSandbox)
                }
            }
        };

        // A scheduled run follows its job's policy for a call that would wait for approval.
        let unattended = (!auto_approve).then(|| run_policy.decide(&call.name));
        if unattended == Some(UnattendedApproval::Skip) {
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                risk,
                "Not run: this scheduled run skips actions that need approval.",
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        }
        let permit = if auto_approve || unattended == Some(UnattendedApproval::RunInSandbox) {
            services.broker.issue(thread_id, &call.name, &parsed_args)
        } else {
            // Pause and request explicit user approval via EngineEvent::ToolApprovalRequested.
            let key = ApprovalKey {
                thread_id: thread_id.to_owned(),
                run_id: run_id.to_owned(),
                call_id: call.call_id.clone(),
            };
            let (tx, rx) = oneshot::channel();
            let request = EngineEvent::ToolApprovalRequested {
                thread_id: thread_id.to_owned(),
                run_id: run_id.to_owned(),
                call_id: call.call_id.clone(),
                tool_name: call.name.clone(),
                arguments_json: call.arguments_json.clone(),
                risk_tier: risk,
            };
            lock_or_recover(&services.pending_approvals, "pending_approvals").insert(
                key.clone(),
                crate::agent_approvals::PendingApproval {
                    reply: tx,
                    request: request.clone(),
                },
            );
            note_write(
                "agent_run_waiting_approval",
                storage.update_agent_run(
                    run_id.to_owned(),
                    AgentRunUpdate {
                        status: Some(RunStatus::WaitingApproval),
                        ..AgentRunUpdate::default()
                    },
                ),
            );
            emit_logged(storage, events_tx, Some(thread_id.to_owned()), request);
            let (decision, cancelled_while_waiting) = {
                let _paused = services.power.pause_for_user();
                emit(
                    events_tx,
                    EngineEvent::PowerStatusChanged {
                        status: services.power.status(),
                    },
                );
                wait_for_decision(rx, cancel_flag, &services.wake).await
            };
            cancelled |= cancelled_while_waiting;
            lock_or_recover(&services.pending_approvals, "pending_approvals").remove(&key);
            note_write(
                "agent_run_resume_running",
                storage.update_agent_run(
                    run_id.to_owned(),
                    AgentRunUpdate {
                        status: Some(RunStatus::Running),
                        ..AgentRunUpdate::default()
                    },
                ),
            );
            emit(
                events_tx,
                EngineEvent::PowerStatusChanged {
                    status: services.power.status(),
                },
            );
            match decision {
                ToolApprovalDecision::ApproveOnce => {
                    if let Ok(p) = services
                        .broker
                        .approve(thread_id, &call.name, &parsed_args)
                        .and_then(|id| services.broker.take_approved(&id))
                    {
                        p
                    } else {
                        parent_id = commit_tool_result_node(
                            storage,
                            events_tx,
                            thread_id,
                            run_id,
                            &parent_id,
                            call,
                            risk,
                            "Tool approval permit could not be issued.",
                            true,
                            Vec::new(),
                            None,
                            None,
                            0,
                        );
                        continue;
                    }
                }
                ToolApprovalDecision::ApproveForThread => {
                    if call.name != "computer_use"
                        && !lock_or_recover(&services.thread_auto_approvals, "approval_memory")
                            .grant(thread_id, &call.name, &parsed_args, risk)
                    {
                        tracing::warn!(
                            key = ?DiagnosticKey::ToolApprovalRequired,
                            detail = "approval_memory_full",
                            "chat grant not remembered; the next identical call asks again"
                        );
                    }
                    services.broker.issue(thread_id, &call.name, &parsed_args)
                }
                ToolApprovalDecision::Deny | ToolApprovalDecision::Stop => {
                    let msg =
                        if decision == ToolApprovalDecision::Stop {
                            cancel_flag.store(true, Ordering::SeqCst);
                            cancelled = true;
                            "Run stopped by user at this tool call."
                        } else if cancelled {
                            "Cancelled by user while awaiting approval."
                        } else {
                            lock_or_recover(&services.thread_auto_approvals, "approval_memory")
                                .deny(run_id, &call.name, &parsed_args);
                            "Tool execution denied by user."
                        };
                    parent_id = commit_tool_result_node(
                        storage,
                        events_tx,
                        thread_id,
                        run_id,
                        &parent_id,
                        call,
                        risk,
                        msg,
                        true,
                        Vec::new(),
                        None,
                        None,
                        0,
                    );
                    continue;
                }
            }
        };
        // Claim the one-use, argument-bound permit immediately before dispatch.
        if let Err(err) = services
            .broker
            .claim(&permit, thread_id, &call.name, &parsed_args)
        {
            parent_id = commit_tool_result_node(
                storage,
                events_tx,
                thread_id,
                run_id,
                &parent_id,
                call,
                risk,
                &format!("Approval permit rejected: {err}"),
                true,
                Vec::new(),
                None,
                None,
                0,
            );
            continue;
        }

        // Emit live running status to the UI ToolTimelineView.
        emit(
            events_tx,
            EngineEvent::ToolExecutionUpdated {
                thread_id: thread_id.to_owned(),
                run_id: run_id.to_owned(),
                call_id: call.call_id.clone(),
                tool_name: call.name.clone(),
                risk_tier: risk,
                status: "running".to_owned(),
                summary: format!("Running {}", call.name),
                output_text: String::new(),
                diff_text: None,
                checkpoint_id: None,
                duration_ms: 0,
            },
        );
        let step_rec = note_write(
            "run_step_tool_call",
            storage.record_run_step(
                run_id.to_owned(),
                *step_index,
                RunStepKind::ToolCall,
                call.name.clone(),
                risk,
                format!("{run_id}:tool:{}", call.call_id),
                "running".to_owned(),
                call.arguments_json.clone(),
                "{}".to_owned(),
                0,
                None,
            ),
        );

        let started = Instant::now();
        // Pre-tool hooks gate the call: unapproved, failing, or unrunnable hooks block it.
        if let Some(ws) = &catalog.workspace_root {
            let blocked = tokio::select! {
                biased;
                () = crate::providers::until_cancelled(cancel_flag) => {
                    cancelled = true;
                    Some("Cancelled by user before tool execution.".to_owned())
                }
                verdict = pre_tool_hook_verdict(storage, events_tx, ws, &call.name) => verdict,
            };
            if let Some(msg) = blocked {
                parent_id = commit_tool_result_node(
                    storage,
                    events_tx,
                    thread_id,
                    run_id,
                    &parent_id,
                    call,
                    risk,
                    &msg,
                    true,
                    Vec::new(),
                    None,
                    None,
                    0,
                );
                continue;
            }
        }

        let exec_res = tokio::select! {
            biased;
            () = crate::providers::until_cancelled(cancel_flag) => {
                cancelled = true;
                Err(BistreError::with_detail(DiagnosticKey::ProviderStreamInterrupted, "cancelled"))
            }
            r = async {
                if call.name == "computer_use" {
                    services
                        .host_actions
                        .execute(events_tx, cancel_flag, thread_id, run_id, &parsed_args)
                        .await
                } else {
                    dispatch_with_progress(
                        storage,
                        services,
                        catalog,
                        helper,
                        events_tx,
                        thread_id,
                        run_id,
                        call,
                        risk,
                        &parsed_args,
                    )
                    .await
                }
            } => r,
        };
        let duration_ms = i64::try_from(started.elapsed().as_millis()).unwrap_or(0);

        match exec_res {
            Ok(out) => {
                let spilled =
                    spill_off_worker(&services.data_dir, &call.call_id, &out.output_text).await;
                if out.ok {
                    any_succeeded = true;
                    all_failed = false;
                    waiting_for_user |= call.name == "ask_user";
                }
                if let Some(ws) = &catalog.workspace_root {
                    run_post_tool_hooks(storage, ws, &call.name, cancel_flag).await;
                }
                if let Some(ref st) = step_rec {
                    note_write(
                        "run_step_tool_complete",
                        storage.complete_run_step(
                            st.id.clone(),
                            if out.ok { "completed" } else { "failed" }.to_owned(),
                            json!({ "summary": out.summary, "ok": out.ok }).to_string(),
                            duration_ms,
                        ),
                    );
                }
                emit(
                    events_tx,
                    EngineEvent::ToolExecutionUpdated {
                        thread_id: thread_id.to_owned(),
                        run_id: run_id.to_owned(),
                        call_id: call.call_id.clone(),
                        tool_name: call.name.clone(),
                        risk_tier: out.risk_tier,
                        status: if out.ok { "completed" } else { "failed" }.to_owned(),
                        summary: out.summary.clone(),
                        output_text: spilled.clone(),
                        diff_text: out.diff_text.clone(),
                        checkpoint_id: out.checkpoint_id.clone(),
                        duration_ms,
                    },
                );
                parent_id = commit_tool_result_node(
                    storage,
                    events_tx,
                    thread_id,
                    run_id,
                    &parent_id,
                    call,
                    out.risk_tier,
                    &spilled,
                    !out.ok,
                    out.media_attachments,
                    out.diff_text,
                    out.checkpoint_id,
                    duration_ms,
                );
            }
            Err(err) => {
                let err_text = format!("Tool `{}` failed: {err}", call.name);
                if let Some(ref st) = step_rec {
                    note_write(
                        "run_step_tool_failed",
                        storage.complete_run_step(
                            st.id.clone(),
                            "failed".to_owned(),
                            json!({ "error": err.key.as_key(), "detail": err.detail_code })
                                .to_string(),
                            duration_ms,
                        ),
                    );
                }
                emit(
                    events_tx,
                    EngineEvent::ToolExecutionUpdated {
                        thread_id: thread_id.to_owned(),
                        run_id: run_id.to_owned(),
                        call_id: call.call_id.clone(),
                        tool_name: call.name.clone(),
                        risk_tier: risk,
                        status: "failed".to_owned(),
                        summary: err_text.clone(),
                        output_text: err_text.clone(),
                        diff_text: None,
                        checkpoint_id: None,
                        duration_ms,
                    },
                );
                parent_id = commit_tool_result_node(
                    storage,
                    events_tx,
                    thread_id,
                    run_id,
                    &parent_id,
                    call,
                    risk,
                    &err_text,
                    true,
                    Vec::new(),
                    None,
                    None,
                    duration_ms,
                );
            }
        }
    }

    ToolBatchOutcome {
        last_node_id: parent_id,
        any_succeeded,
        all_failed: !calls.is_empty() && all_failed,
        cancelled,
        waiting_for_user,
    }
}
