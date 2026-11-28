//! What each run step sends (history, system prompt, user name), clocks, the paid-request
//! reservation, and the run loop bookkeeping: auto compaction, queued follow-ups, final state.

use super::{
    AgentRunUpdate, Arc, BistreError, DiagnosticKey, EngineEvent, HashMap, MoneyMicros, NodeRecord,
    NodeRole, ProviderProfile, RunStatus, RunStepKind, StorageHandle, StreamChunk, SystemTime,
    ThreadMode, ToolRiskTier, UNIX_EPOCH, Uuid, broadcast, compaction, providers, story,
};
use crate::events::{emit, emit_logged, note_write};
use crate::wallet;
use bistre_protocol::{AppSettings, BistreResult, UsageMetrics};

/// Shared network and tool-execution services for one streaming run.
pub(crate) struct StreamServices {
    pub(crate) http: reqwest::Client,
    pub(crate) web: crate::ssrf::PublicWebTransport,
    pub(crate) mcp_http: crate::mcp::McpHttpTransport,
    pub(crate) vault: Arc<dyn bistre_crypto::SecretVault>,
    pub(crate) pricing: Arc<crate::registry::PricingRegistry>,
    pub(crate) wake: Arc<tokio::sync::Notify>,
    pub(crate) data_dir: std::path::PathBuf,
    pub(crate) reasoning_unsupported:
        Arc<std::sync::Mutex<std::collections::HashSet<(String, String)>>>,
    pub(crate) provider_backoff: Arc<crate::provider_backoff::ProviderBackoff>,
    pub(crate) read_ledger: Arc<crate::tools::ReadLedger>,
    pub(crate) broker: Arc<crate::approval::ToolApprovalBroker>,
    pub(crate) pending_approvals: crate::agent_tools::PendingApprovalMap,
    pub(crate) thread_auto_approvals: crate::agent_tools::ThreadAutoApprovals,
    /// Released while the run waits for the user (`PowerCoordinator::pause_for_user`).
    pub(crate) power: Arc<crate::power::PowerCoordinator>,
    /// Chats whose next run may send unpriced requests while a cap is active.
    pub(crate) unpriced_allowed: UnpricedAllowances,
    /// Host-bridge action coordinator and ephemeral screenshot buffer (`computer_use`).
    pub(crate) host_actions: Arc<crate::computer_use::HostActionBroker>,
}

/// Chat ids allowed one run of unpriced requests (`allow_unpriced_once`); cleared when the run ends.
pub(crate) type UnpricedAllowances = Arc<std::sync::Mutex<std::collections::HashSet<String>>>;

pub(crate) fn compile_write_mode_system_prompt(
    storage: &StorageHandle,
    thread_id: &str,
    base_system_prompt: &str,
    history: &[NodeRecord],
    context_window: Option<u64>,
) -> BistreResult<String> {
    let report = crate::engine_story::story_prompt_report(
        storage,
        thread_id,
        base_system_prompt,
        history,
        None,
        context_window,
    )?;
    let combined = report
        .blocks
        .iter()
        .map(|b| format!("[{}]\n{}", b.label, b.content))
        .collect::<Vec<_>>()
        .join("\n\n");
    let rules = storage.list_regex_rules()?;
    Ok(if combined.trim().is_empty() {
        base_system_prompt.to_owned()
    } else {
        story::regex_pipeline::apply_regex_pipeline(&combined, &rules, "prompt_outgoing")
    })
}

/// Returns the current Unix timestamp in milliseconds.
pub(crate) fn utc_now_unix_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}

/// Returns the Unix timestamp in milliseconds for `00:00:00 UTC` of the current day.
pub(crate) fn utc_day_start_unix_ms() -> i64 {
    const MS_PER_DAY: i64 = 86_400_000;
    let now_ms = utc_now_unix_ms();
    now_ms - now_ms.rem_euclid(MS_PER_DAY)
}

/// Walks parent pointers backward from `leaf_id` to root so branching threads send
/// only the active conversation branch (never sibling branches) to the LLM provider.
/// Upper bound on model and steering steps in one run (also stored as the run's `max_steps`).
pub(crate) const MAX_RUN_STEPS: u32 = 24;

/// Minimum interval between partial-text checkpoints of a streaming reply.
pub(crate) const CHECKPOINT_INTERVAL: std::time::Duration = std::time::Duration::from_millis(250);
/// Minimum new text before a checkpoint is written.
pub(crate) const CHECKPOINT_MIN_BYTES: usize = 4 * 1024;
/// One display frame: deltas inside it are sent as one event.
pub(crate) const DELTA_FRAME: std::time::Duration = std::time::Duration::from_millis(16);

pub(crate) fn emit_delta(
    tx: &broadcast::Sender<EngineEvent>,
    thread_id: &str,
    node_id: &str,
    text: String,
) {
    if text.is_empty() {
        return;
    }
    emit(
        tx,
        EngineEvent::DeltaBatch {
            thread_id: thread_id.to_owned(),
            chunks: vec![StreamChunk {
                node_id: node_id.to_owned(),
                text_delta: text,
            }],
        },
    );
}

/// Loads everything one model turn needs: the branch history (respecting the context pin),
/// the thread's `ThreadMode`, and the effective system prompt (including workspace `AGENTS.md`
/// in `Code` / `Plan` modes).
pub(crate) fn load_turn_context(
    storage: &StorageHandle,
    thread_id: &str,
    parent_id: &str,
    system_prompt: &str,
    context_window: Option<u64>,
) -> BistreResult<(Vec<NodeRecord>, ThreadMode, String)> {
    load_turn_context_with(
        storage,
        thread_id,
        parent_id,
        system_prompt,
        false,
        context_window,
    )
}

/// [`load_turn_context`]; `resume_paused` keeps the trailing assistant turn.
pub(crate) fn load_turn_context_with(
    storage: &StorageHandle,
    thread_id: &str,
    parent_id: &str,
    system_prompt: &str,
    resume_paused: bool,
    context_window: Option<u64>,
) -> BistreResult<(Vec<NodeRecord>, ThreadMode, String)> {
    let history = project_turn_history(storage, thread_id, parent_id, resume_paused)?;
    let mode = storage
        .get_thread(thread_id)?
        .map_or(ThreadMode::Chat, |t| t.mode);
    let mut prompt = if mode == ThreadMode::Write {
        compile_write_mode_system_prompt(
            storage,
            thread_id,
            system_prompt,
            &history,
            context_window,
        )?
    } else {
        system_prompt.to_owned()
    };
    crate::projects::append_project_instructions(storage, thread_id, &mut prompt)?;
    // Reads AGENTS.md and walks SKILL.md files: off the worker a reply may stream on.
    crate::off_worker::in_place(|| {
        crate::agent_context::append_agent_prompt_context(storage, thread_id, mode, &mut prompt);
    });
    crate::goal::append_prompt(storage, thread_id, mode, &mut prompt);
    Ok((history, mode, prompt))
}

/// The history the next request sends for the branch ending at `leaf_id`: its ancestry from
/// the context-start pin or the latest compaction summary onward, without the messages the
/// user left out, cut to the history limit, with roles alternating.
pub(crate) fn project_turn_history(
    storage: &StorageHandle,
    thread_id: &str,
    leaf_id: &str,
    keep_assistant_tail: bool,
) -> BistreResult<Vec<NodeRecord>> {
    // Only this branch is read, not every node of the thread.
    let raw_history = storage.list_branch(thread_id, leaf_id)?;
    let pinned_start = storage.get_kv_meta(&format!("thread_context_start:{thread_id}"))?;
    let effective = crate::history_limit::apply(
        crate::context_exclusion::apply(
            compaction::project_effective_history(&raw_history, pinned_start.as_deref()),
            &crate::context_exclusion::load(storage, thread_id)?,
        ),
        crate::history_limit::load(storage),
    );
    let quantized = compaction::compact_tool_outputs_quantized(&effective, 2_000);
    // An assistant turn with no text and no tool call (a stopped reply that only
    // thought) is never sent back: providers reject an empty assistant message.
    let sendable: Vec<NodeRecord> = crate::replay_policy::answer_dangling_tool_calls(quantized)
        .into_iter()
        .filter(|n| {
            n.role != NodeRole::Assistant
                || !n.content.trim().is_empty()
                || !crate::replay_policy::parse_turn_wire_meta(n.provider_meta_json.as_deref())
                    .tool_calls
                    .is_empty()
        })
        .collect();
    Ok(compaction::enforce_role_alternation_with(
        sendable,
        keep_assistant_tail,
    ))
}

/// Longest user name told to the model, in characters.
pub(crate) const MAX_USER_NAME_CHARS: usize = 64;

/// Tells the model the user's name (Settings > Profile) in chats without their own persona:
/// Write mode brings a persona, so it is left alone. Control characters are dropped and the
/// name is capped, so a pasted name cannot inject prompt structure.
pub(crate) fn with_user_name(system_prompt: String, name: &str, mode: ThreadMode) -> String {
    let clean: String = name
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_USER_NAME_CHARS)
        .collect();
    let clean = clean.trim();
    if clean.is_empty() || mode == ThreadMode::Write {
        return system_prompt;
    }
    let line = format!("The user's name is {clean}.");
    if system_prompt.trim().is_empty() {
        line
    } else {
        format!("{system_prompt}\n\n{line}")
    }
}

/// Reserves Wallet Shield spend for one paid request. Prices the prompt's model-matched BPE
/// input tokens when live rates are known; output is settled afterwards.
#[expect(
    clippy::too_many_arguments,
    reason = "Reservation needs storage, services, thread, provider, advanced overrides, model, prompt, history, and purpose."
)]
pub(crate) async fn reserve_paid_request(
    storage: &Arc<StorageHandle>,
    services: &StreamServices,
    thread_id: &str,
    provider: &ProviderProfile,
    prov_adv: &crate::provider_prefs::ProviderAdvancedPrefs,
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    purpose: bistre_protocol::SpendPurpose,
) -> BistreResult<(wallet::SpendReservation, u64)> {
    let settings = storage.load_settings().map_err(|err| {
        BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, err.key.as_key())
    })?;
    // Per-chat cap: fails closed on a storage error or a malformed value; checked in the
    // reservation transaction against the chat's ledger spend.
    let chat_cap = crate::provider_prefs::load_thread_spend_limit(storage, thread_id)?;
    // Counting a text attachment reads its file.
    let attachment_tokens = crate::off_worker::in_place(|| {
        history
            .iter()
            .flat_map(|n| {
                crate::attachments::parse_node_attachments(n.provider_meta_json.as_deref())
            })
            .map(|att| crate::attachments::estimate_attachment_tokens(&services.data_dir, &att))
            .fold(0_u64, u64::saturating_add)
    });
    let estimate_usage = UsageMetrics {
        input_tokens: compaction::estimate_branch_tokens_for_model(
            system_prompt,
            history,
            Some(model),
        )
        .saturating_add(attachment_tokens),
        ..UsageMetrics::default()
    };
    // The run waited once for an in-flight price sync before its first step; each
    // reservation reads the newest table without waiting again.
    let rates = prov_adv.resolve_rates(
        model,
        services
            .pricing
            .snapshot()
            .lookup(&crate::registry::CatalogScope::of(provider), model),
    );
    let capped = settings.wallet_daily_ceiling_micros.is_some() || chat_cap.is_some();
    let estimate = match providers::estimate_cost_micros(provider, rates, &estimate_usage) {
        Some(cost) => cost,
        // An unpriced request cannot be checked against a cap, so it is blocked while
        // any cap is active, unless the user allowed this chat's next run once.
        None if capped && !unpriced_allowed(services, thread_id) => {
            return Err(BistreError::with_detail(
                DiagnosticKey::WalletPriceUnknown,
                "price_unknown",
            ));
        }
        None => MoneyMicros::ZERO,
    };
    wallet::SpendReservation::reserve_with_chat_cap(
        storage,
        Some(thread_id.to_owned()),
        provider.id.clone(),
        model.to_owned(),
        estimate,
        settings.wallet_daily_ceiling_micros,
        utc_day_start_unix_ms(),
        chat_cap,
        purpose,
    )
    .map(|r| (r, estimate_usage.input_tokens))
    .map_err(|err| match err.key {
        DiagnosticKey::WalletCeilingExceeded => err,
        other => BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, other.as_key()),
    })
}

/// Whether a request sends the provider's own tools: turned on, beside Bistre's tools, and
/// with no spending limit, since they pull pages into one request the reservation cannot
/// foresee.
pub(crate) fn provider_tools_on(
    storage: &StorageHandle,
    thread_id: &str,
    prov_adv: &crate::provider_prefs::ProviderAdvancedPrefs,
    bistre_tools_sent: bool,
) -> bool {
    prov_adv.provider_tools && bistre_tools_sent && !spending_capped(storage, thread_id)
}

/// Whether a spending limit (daily or this chat's) applies; one that cannot be read counts
/// as set.
pub(crate) fn spending_capped(storage: &StorageHandle, thread_id: &str) -> bool {
    let daily = storage
        .load_settings()
        .map(|s| s.wallet_daily_ceiling_micros.is_some());
    let chat =
        crate::provider_prefs::load_thread_spend_limit(storage, thread_id).map(|c| c.is_some());
    match (daily, chat) {
        (Ok(daily), Ok(chat)) => daily || chat,
        (Err(err), _) | (_, Err(err)) => {
            tracing::warn!(
                key = err.key.as_key(),
                "spending limit unreadable; counted as set"
            );
            true
        }
    }
}

/// Whether the user allowed this chat's current run to send requests whose price is unknown.
pub(crate) fn unpriced_allowed(services: &StreamServices, thread_id: &str) -> bool {
    bistre_protocol::lock_or_recover(&services.unpriced_allowed, "unpriced_allowed")
        .contains(thread_id)
}

pub(crate) fn collect_branch_ancestry(nodes: &[NodeRecord], leaf_id: &str) -> Vec<NodeRecord> {
    let by_id: HashMap<&str, &NodeRecord> = nodes.iter().map(|n| (n.id.as_str(), n)).collect();
    let mut chain = Vec::new();
    let mut cursor = Some(leaf_id);
    let mut guard = 0_usize;
    while let Some(id) = cursor {
        if guard > nodes.len() {
            break;
        }
        guard += 1;
        let Some(node) = by_id.get(id) else {
            break;
        };
        chain.push((*node).clone());
        cursor = node.parent_id.as_deref();
    }
    chain.reverse();
    chain
}

/// Whether `tokens` reach the auto-compaction point (Settings > Default models) of a window of
/// `ctx_limit` tokens. Unreadable settings use the default point.
pub(crate) fn near_context_limit(storage: &StorageHandle, tokens: u64, ctx_limit: u64) -> bool {
    let at_percent = match storage.load_settings() {
        Ok(s) => s.auto_compact_at_percent,
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "settings unreadable; auto compaction uses its default point"
            );
            AppSettings::default().auto_compact_at_percent
        }
    };
    compaction::should_auto_compact(
        tokens,
        ctx_limit,
        compaction::auto_compact_reserve_percent(at_percent),
    )
}

/// Condenses the branch ending at `parent_id` before the next request and returns the summary
/// id the run continues from, or `None` when it could not (the request is sent as it is).
pub(crate) fn compact_before_send(
    storage: &StorageHandle,
    events_tx: &broadcast::Sender<EngineEvent>,
    thread_id: &str,
    parent_id: &str,
) -> Option<String> {
    let branch = match storage.list_branch(thread_id, parent_id) {
        Ok(branch) => branch,
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "proactive compaction list_nodes failed"
            );
            return None;
        }
    };
    match compaction::create_reversible_compaction(storage, thread_id, &branch, 4, None) {
        Ok(summary) => {
            let id = summary.id.clone();
            let ev = EngineEvent::NodeCommitted { node: summary };
            emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
            Some(id)
        }
        Err(err) => {
            tracing::warn!(key = err.key.as_key(), "proactive compaction skipped");
            None
        }
    }
}

/// What the run does after a reply: go on with the follow-up the user queued meanwhile, stop,
/// or stop as failed (with the key, when one applies).
pub(crate) enum Steering {
    Continue {
        parent_id: String,
        stream_node_id: String,
    },
    Done,
    Failed(Option<String>),
}

/// Saves the messages the user queued while the reply was written as the next user turn under
/// `parent_id`, and starts the next streamed turn. With nothing queued, a chat with an open
/// goal gets a work check instead (`goal::check_due`).
pub(crate) fn take_steering(
    storage: &StorageHandle,
    events_tx: &broadcast::Sender<EngineEvent>,
    thread_id: &str,
    run_id: &str,
    parent_id: String,
    step_index: &mut u32,
    total_cost: MoneyMicros,
) -> Steering {
    let pending_steers = match storage.drain_pending_steering(thread_id.to_owned()) {
        Ok(steers) => steers,
        Err(err) => {
            // The reply is committed; the queued follow-up could not be read. Surface it.
            emit(
                events_tx,
                EngineEvent::DiagnosticRaised {
                    key: err.key,
                    detail_code: Some("steering_queue_unavailable".to_owned()),
                },
            );
            return Steering::Failed(None);
        }
    };
    let run = RunTurn {
        storage,
        events_tx,
        thread_id,
        run_id,
        total_cost,
    };
    if pending_steers.is_empty() {
        return match crate::goal::check_due(storage, thread_id, &parent_id) {
            Ok(true) => run.continue_with(
                parent_id,
                crate::goal::GOAL_CHECK_PROMPT,
                crate::goal::check_meta(run_id),
                crate::goal::GOAL_CHECK_MARK,
                step_index,
            ),
            Ok(false) => Steering::Done,
            Err(err) => {
                tracing::warn!(key = err.key.as_key(), "goal check skipped; the run ends");
                Steering::Done
            }
        };
    }
    let steer_text = pending_steers
        .iter()
        .map(|m| m.content.as_str())
        .collect::<Vec<_>>()
        .join("\n\n");
    emit(
        events_tx,
        EngineEvent::SteeringQueueChanged {
            thread_id: thread_id.to_owned(),
            pending_count: 0,
        },
    );
    let meta = serde_json::json!({ "steered_mid_run": true, "run_id": run_id }).to_string();
    run.continue_with(parent_id, &steer_text, meta, "steering", step_index)
}

/// The run that goes on with a user turn it adds itself (queued steering or a work check).
struct RunTurn<'a> {
    storage: &'a StorageHandle,
    events_tx: &'a broadcast::Sender<EngineEvent>,
    thread_id: &'a str,
    run_id: &'a str,
    total_cost: MoneyMicros,
}

impl RunTurn<'_> {
    /// Saves `text` as the next user turn under `parent_id` (its step named `step_name`) and
    /// starts the next streamed turn.
    fn continue_with(
        &self,
        parent_id: String,
        text: &str,
        meta: String,
        step_name: &str,
        step_index: &mut u32,
    ) -> Steering {
        let Self {
            storage,
            events_tx,
            thread_id,
            run_id,
            total_cost,
        } = *self;
        let appended = storage.append_node(
            thread_id.to_owned(),
            Some(parent_id),
            NodeRole::User,
            text.to_owned(),
            Some(meta),
        );
        let steer_user_node = match appended {
            Ok(node) => node,
            Err(err) => {
                // The turn (a drained queue, or a work check) could not be saved: stop, say so.
                let key = err.key.as_key().to_owned();
                emit(
                    events_tx,
                    EngineEvent::DiagnosticRaised {
                        key: err.key,
                        detail_code: Some("steering_append_failed".to_owned()),
                    },
                );
                return Steering::Failed(Some(key));
            }
        };
        *step_index = step_index.saturating_add(1);
        note_write(
            "run_step_record",
            storage.record_run_step(
                run_id.to_owned(),
                *step_index,
                RunStepKind::SteeringInjected,
                step_name.to_owned(),
                ToolRiskTier::Tier0ReadOnly,
                format!("{run_id}:steer:{step_index}"),
                "completed".to_owned(),
                serde_json::json!({ "content": text }).to_string(),
                "{}".to_owned(),
                0,
                Some(utc_now_unix_ms()),
            ),
        );
        let parent_id = steer_user_node.id.clone();
        let stream_node_id = Uuid::now_v7().to_string();
        let ev = EngineEvent::NodeCommitted {
            node: steer_user_node,
        };
        emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
        // Reset the app's streaming buffer for the new turn so its deltas never join the
        // previous, already committed reply.
        let next_start = EngineEvent::RunStarted {
            thread_id: thread_id.to_owned(),
            node_id: stream_node_id.clone(),
        };
        emit_logged(storage, events_tx, Some(thread_id.to_owned()), next_start);
        note_write(
            "agent_run_update",
            storage.update_agent_run(
                run_id.to_owned(),
                AgentRunUpdate {
                    step_index: Some(*step_index),
                    partial_text_buffer: Some(String::new()),
                    cost_micros: Some(total_cost),
                    ..AgentRunUpdate::default()
                },
            ),
        );
        Steering::Continue {
            parent_id,
            stream_node_id,
        }
    }
}

/// Saves the run's final state (cancelled, failed with `failed_key`, or completed) and tells
/// the app; a failed write is reported, and startup reconciliation repairs it.
#[expect(
    clippy::too_many_arguments,
    reason = "The run loop's final state, handed over as it ends."
)]
pub(crate) fn finish_run(
    storage: &StorageHandle,
    events_tx: &broadcast::Sender<EngineEvent>,
    thread_id: &str,
    run_id: &str,
    cancelled: bool,
    failed_key: Option<String>,
    step_index: u32,
    total_cost: MoneyMicros,
) {
    let final_status = if cancelled {
        RunStatus::Cancelled
    } else if failed_key.is_some() {
        RunStatus::Failed
    } else {
        RunStatus::Completed
    };
    let final_update = storage.update_agent_run(
        run_id.to_owned(),
        AgentRunUpdate {
            status: Some(final_status),
            step_index: Some(step_index),
            partial_text_buffer: Some(String::new()),
            cost_micros: Some(total_cost),
            error_key: Some(failed_key),
            ..AgentRunUpdate::default()
        },
    );
    match final_update {
        Ok(final_run) => {
            let ev = EngineEvent::RunStateChanged { run: final_run };
            emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
        }
        Err(err) => {
            tracing::error!(key = err.key.as_key(), "final run state write failed");
            emit(
                events_tx,
                EngineEvent::DiagnosticRaised {
                    key: err.key,
                    detail_code: Some("run_final_state_write_failed".to_owned()),
                },
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A daily or per-chat limit, or one that cannot be read, holds back the provider's
    /// tools.
    #[test]
    fn any_spending_limit_counts_and_an_unreadable_one_counts_too()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("cap.sqlite"))?;
        assert!(
            spending_capped(&storage, "t1"),
            "the default daily limit counts"
        );
        let mut settings = storage.load_settings()?;
        settings.wallet_daily_ceiling_micros = None;
        storage.save_settings(settings)?;
        assert!(!spending_capped(&storage, "t1"));
        storage.set_kv_meta("thread_spend_limit:t1".to_owned(), "500000".to_owned())?;
        assert!(spending_capped(&storage, "t1"));
        assert!(!spending_capped(&storage, "t2"));
        storage.set_kv_meta("thread_spend_limit:t2".to_owned(), "lots".to_owned())?;
        assert!(
            spending_capped(&storage, "t2"),
            "a malformed limit fails closed"
        );
        settings = storage.load_settings()?;
        settings.wallet_daily_ceiling_micros = Some(MoneyMicros::from_micros(1_000_000));
        storage.save_settings(settings)?;
        assert!(spending_capped(&storage, "t3"));
        Ok(())
    }
}
