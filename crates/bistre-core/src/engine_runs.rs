//! Durable streaming run loop, retry/backoff, and write-mode prompt assembly for `InProcessEngine`.

use super::{
    AgentRunUpdate, Arc, AtomicBool, BistreError, DiagnosticKey, EngineEvent, GenerationParams,
    HashMap, KeyRing, MoneyMicros, NodeRecord, NodeRole, Notify, Ordering, ProviderProfile,
    RunStatus, RunStepKind, StorageHandle, StreamChunk, SystemTime, ThreadMode, ToolRiskTier,
    UNIX_EPOCH, Uuid, agent, approval, broadcast, compaction, error_policy, providers, registry,
    ssrf, story,
};
use crate::events::{emit, emit_logged, note_write};

/// Shared network services for one streaming run.
#[derive(Debug)]
pub(crate) struct StreamServices {
    pub(crate) http: reqwest::Client,
    pub(crate) web: ssrf::PublicWebTransport,
    pub(crate) pricing: Arc<registry::PricingRegistry>,
    pub(crate) wake: Arc<Notify>,
}

/// Rate limits, transient server failures, and streams that died before any output retry
/// automatically; auth, quota/billing, spend caps, and bad requests never do.
pub(crate) fn is_auto_retryable(err: &BistreError) -> bool {
    match err.key {
        DiagnosticKey::ProviderRateLimited | DiagnosticKey::ProviderStreamInterrupted => true,
        DiagnosticKey::ProviderRequestFailed => err.detail_code.as_deref().is_some_and(|d| {
            d == "connect"
                || d.starts_with("http_5")
                || d.starts_with("http_408")
                || d.starts_with("http_409")
                || d.starts_with("http_425")
        }),
        _ => false,
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "Dedicated async streaming and mid-stream steering loop decoupled from spawn setup."
)]
#[expect(
    clippy::too_many_lines,
    reason = "Single linear state loop governing stream commit, Wallet Shield re-check, and steering injection."
)]
pub(crate) async fn execute_durable_stream_loop(
    storage: &Arc<StorageHandle>,
    services: &StreamServices,
    events_tx: &broadcast::Sender<EngineEvent>,
    cancel_flag: &Arc<AtomicBool>,
    thread_id: &str,
    run_id: &str,
    mut current_parent_id: String,
    mut current_stream_node_id: String,
    provider: &ProviderProfile,
    keys: &KeyRing,
    model: &str,
    system_prompt: &str,
    gen_params: GenerationParams,
    stateless_default: bool,
) -> (String, bool) {
    let mut step_index: u32 = 0;
    let mut total_cost = MoneyMicros::ZERO;
    let mut cancelled = false;
    let mut failed_key: Option<String> = None;
    let mut retry_attempt: u32 = 0;
    let mut waited_secs: u64 = 0;
    let mut overflow_compacted = false;
    let is_local = providers::is_local_loopback_url(&provider.base_url);

    loop {
        let all_nodes = storage.list_nodes(thread_id).unwrap_or_default();
        let raw_history = collect_branch_ancestry(&all_nodes, &current_parent_id);
        let pin_key = format!("thread_context_start:{thread_id}");
        let pinned_start = storage.get_kv_meta(&pin_key).ok().flatten();
        let history = compaction::enforce_role_alternation(compaction::project_effective_history(
            &raw_history,
            pinned_start.as_deref(),
        ));
        let is_write_mode = storage
            .get_thread(thread_id)
            .ok()
            .flatten()
            .is_some_and(|t| t.mode == ThreadMode::Write);
        let effective_system_prompt = if is_write_mode {
            compile_write_mode_system_prompt(storage, thread_id, system_prompt, &history)
        } else {
            system_prompt.to_owned()
        };
        let mut activity = approval::RunActivity::start();
        let step_rec = storage
            .record_run_step(
                run_id.to_owned(),
                step_index,
                RunStepKind::LlmCall,
                model.to_owned(),
                ToolRiskTier::Tier0ReadOnly,
                format!("{run_id}:llm:{step_index}"),
                "running".to_owned(),
                serde_json::json!({ "model": model, "provider": provider.id }).to_string(),
                "{}".to_owned(),
                0,
                None,
            )
            .ok();

        let delta_tx = events_tx.clone();
        let delta_thread = thread_id.to_owned();
        let delta_node = current_stream_node_id.clone();
        let think_tx = events_tx.clone();
        let think_thread = thread_id.to_owned();
        let think_node = current_stream_node_id.clone();
        let buf_storage = Arc::clone(storage);
        let buf_run_id = run_id.to_owned();
        let mut buffered_text = String::new();
        let mut chunk_counter: u32 = 0;

        if !is_local {
            services.pricing.ensure_fresh(&services.web);
        }
        let outcome = providers::stream_completion_with_thinking(
            &services.http,
            provider,
            keys,
            model,
            &effective_system_prompt,
            &history,
            gen_params,
            stateless_default,
            cancel_flag,
            |chunk| {
                activity.tick();
                buffered_text.push_str(chunk);
                chunk_counter = chunk_counter.saturating_add(1);
                if chunk_counter.is_multiple_of(24) {
                    note_write(
                        "agent_run_checkpoint",
                        buf_storage.update_agent_run(
                            buf_run_id.clone(),
                            AgentRunUpdate {
                                partial_text_buffer: Some(buffered_text.clone()),
                                ..AgentRunUpdate::default()
                            },
                        ),
                    );
                }
                emit(
                    &delta_tx,
                    EngineEvent::DeltaBatch {
                        thread_id: delta_thread.clone(),
                        chunks: vec![StreamChunk {
                            node_id: delta_node.clone(),
                            text_delta: chunk.to_owned(),
                        }],
                    },
                );
            },
            |thinking_chunk| {
                emit(
                    &think_tx,
                    EngineEvent::ThinkingDelta {
                        thread_id: think_thread.clone(),
                        node_id: think_node.clone(),
                        delta: thinking_chunk.to_owned(),
                    },
                );
            },
        )
        .await;

        let elapsed_ms = activity.finish_ms();
        let mut committed_assistant_id: Option<String> = None;

        match outcome {
            Ok(mut res) => {
                retry_attempt = 0;
                let rates = services.pricing.rates_for(model).await;
                let cost = providers::estimate_cost_micros(provider, rates, &res.usage);
                res.usage.estimated_cost_micros = cost.unwrap_or(MoneyMicros::ZERO);
                for (key, detail) in core::mem::take(&mut res.notices) {
                    emit(
                        events_tx,
                        EngineEvent::DiagnosticRaised {
                            key,
                            detail_code: Some(detail),
                        },
                    );
                }
                if res.interrupted {
                    let ev = EngineEvent::DiagnosticRaised {
                        key: DiagnosticKey::ProviderStreamInterrupted,
                        detail_code: Some("eof_without_finish".to_owned()),
                    };
                    emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
                }
                cancelled = res.cancelled;
                total_cost = total_cost.saturating_add(res.usage.estimated_cost_micros);
                if let Some(ref st) = step_rec {
                    note_write(
                        "run_step_complete",
                        storage.complete_run_step(
                            st.id.clone(),
                            if res.cancelled {
                                "cancelled".to_owned()
                            } else {
                                "completed".to_owned()
                            },
                            serde_json::json!({
                                "input_tokens": res.usage.input_tokens,
                                "output_tokens": res.usage.output_tokens,
                            })
                            .to_string(),
                            elapsed_ms,
                        ),
                    );
                }
                if !res.full_text.trim().is_empty() || !res.thinking_text.trim().is_empty() {
                    let mut meta_obj = serde_json::json!({
                        "provider_id": provider.id,
                        "provider_name": provider.name,
                        "icon_slug": provider.icon_slug,
                        "model_id": model,
                        "input_tokens": res.usage.input_tokens,
                        "output_tokens": res.usage.output_tokens,
                        "cached_input_tokens": res.usage.cached_input_tokens,
                        "cost_micros": res.usage.estimated_cost_micros.as_micros(),
                        "cost_known": cost.is_some(),
                        "cancelled": res.cancelled,
                        "interrupted": res.interrupted,
                        "run_id": run_id,
                    });
                    if !res.thinking_text.trim().is_empty()
                        && let Some(map) = meta_obj.as_object_mut()
                    {
                        map.insert(
                            "thinking_text".to_owned(),
                            serde_json::Value::String(res.thinking_text),
                        );
                        map.insert(
                            "thinking_duration_ms".to_owned(),
                            serde_json::Value::from(res.thinking_duration_ms),
                        );
                    }
                    let meta = meta_obj.to_string();
                    let final_text = if is_write_mode {
                        let rules = storage.list_regex_rules().unwrap_or_default();
                        story::regex_pipeline::apply_regex_pipeline(
                            &res.full_text,
                            &rules,
                            "incoming_commit",
                        )
                    } else {
                        res.full_text
                    };
                    match storage.append_node(
                        thread_id.to_owned(),
                        Some(current_parent_id.clone()),
                        NodeRole::Assistant,
                        final_text,
                        Some(meta),
                    ) {
                        Err(err) => {
                            // The reply could not be persisted: fail the run visibly.
                            failed_key = Some(err.key.as_key().to_owned());
                            emit(
                                events_tx,
                                EngineEvent::DiagnosticRaised {
                                    key: err.key,
                                    detail_code: err.detail_code,
                                },
                            );
                        }
                        Ok(committed) => {
                            committed_assistant_id = Some(committed.id.clone());
                            if let Err(err) = storage.record_wallet_entry_with_usage(
                                Some(thread_id.to_owned()),
                                provider.id.clone(),
                                model.to_owned(),
                                res.usage.estimated_cost_micros,
                                res.usage.input_tokens,
                                res.usage.output_tokens,
                                if res.cancelled {
                                    "cancelled".to_owned()
                                } else {
                                    "settled".to_owned()
                                },
                            ) {
                                // Wallet Shield budgets read these rows; a lost spend record is surfaced.
                                tracing::error!(
                                    key = err.key.as_key(),
                                    "wallet spend record failed"
                                );
                                emit(
                                    events_tx,
                                    EngineEvent::DiagnosticRaised {
                                        key: err.key,
                                        detail_code: err.detail_code,
                                    },
                                );
                            }
                            let ev = EngineEvent::NodeCommitted { node: committed };
                            emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
                        }
                    }
                }
            }
            Err(err)
                if err.key == DiagnosticKey::ProviderContextOverflow && !overflow_compacted =>
            {
                // One-shot in-flight overflow recovery: reversible compaction, then retry once.
                overflow_compacted = true;
                if let Some(ref st) = step_rec {
                    note_write(
                        "run_step_complete",
                        storage.complete_run_step(
                            st.id.clone(),
                            "retrying".to_owned(),
                            serde_json::json!({ "error": err.key.as_key() }).to_string(),
                            elapsed_ms,
                        ),
                    );
                }
                let branch = collect_branch_ancestry(
                    &storage.list_nodes(thread_id).unwrap_or_default(),
                    &current_parent_id,
                );
                if let Ok(summary) =
                    compaction::create_reversible_compaction(storage, thread_id, &branch, 4, None)
                {
                    current_parent_id.clone_from(&summary.id);
                    let ev = EngineEvent::NodeCommitted { node: summary };
                    emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
                    continue;
                }
                failed_key = Some(err.key.as_key().to_owned());
                emit(
                    events_tx,
                    EngineEvent::DiagnosticRaised {
                        key: err.key,
                        detail_code: err.detail_code,
                    },
                );
                break;
            }
            Err(err) if is_auto_retryable(&err) && !cancel_flag.load(Ordering::SeqCst) => {
                let budget = storage
                    .load_settings()
                    .map_or(300, |s| s.retry_watchdog_max_wait_secs);
                let hint_secs = error_policy::retry_after_from_detail(err.detail_code.as_deref())
                    .map(|ms| ms.div_ceil(1000));
                let Some(wait_ms) =
                    agent::compute_backoff_wait_ms(retry_attempt, hint_secs, waited_secs, budget)
                else {
                    failed_key = Some(err.key.as_key().to_owned());
                    emit(
                        events_tx,
                        EngineEvent::DiagnosticRaised {
                            key: err.key,
                            detail_code: err.detail_code,
                        },
                    );
                    break;
                };
                retry_attempt = retry_attempt.saturating_add(1);
                waited_secs = waited_secs.saturating_add(wait_ms.div_ceil(1000));
                if let Some(ref st) = step_rec {
                    note_write("run_step_complete", storage.complete_run_step(
                        st.id.clone(),
                        "retrying".to_owned(),
                        serde_json::json!({ "error": err.key.as_key(), "retry_in_ms": wait_ms })
                            .to_string(),
                        elapsed_ms,
                    ));
                }
                let ev = EngineEvent::DiagnosticRaised {
                    key: DiagnosticKey::RunBackoffWaiting,
                    detail_code: Some(format!("retry_in_ms={wait_ms};reason={}", err.key.as_key())),
                };
                emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
                // `Retry now` and cancel both notify `wake`, ending the wait immediately.
                tokio::select! {
                    () = tokio::time::sleep(std::time::Duration::from_millis(wait_ms)) => {}
                    () = services.wake.notified() => {}
                }
                if cancel_flag.load(Ordering::SeqCst) {
                    cancelled = true;
                    break;
                }
                continue;
            }
            Err(err) => {
                failed_key = Some(err.key.as_key().to_owned());
                if let Some(ref st) = step_rec {
                    note_write(
                        "run_step_complete",
                        storage.complete_run_step(
                            st.id.clone(),
                            "failed".to_owned(),
                            serde_json::json!({ "error": err.key.as_key() }).to_string(),
                            elapsed_ms,
                        ),
                    );
                }
                let ev = EngineEvent::DiagnosticRaised {
                    key: err.key,
                    detail_code: err.detail_code,
                };
                emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
                break;
            }
        }

        if cancelled || step_index >= 16 {
            break;
        }

        let pending_steers = storage
            .drain_pending_steering(thread_id.to_owned())
            .unwrap_or_default();
        if pending_steers.is_empty() {
            break;
        }

        if let Ok(latest_settings) = storage.load_settings()
            && !providers::is_local_loopback_url(&provider.base_url)
            && let Some(cap) = latest_settings.wallet_daily_ceiling_micros
        {
            let spent_today = storage
                .sum_wallet_spend_since_micros(utc_day_start_unix_ms())
                .unwrap_or(MoneyMicros::ZERO);
            if spent_today >= cap {
                failed_key = Some(DiagnosticKey::WalletCeilingExceeded.as_key().to_owned());
                emit(
                    events_tx,
                    EngineEvent::DiagnosticRaised {
                        key: DiagnosticKey::WalletCeilingExceeded,
                        detail_code: Some(run_id.to_owned()),
                    },
                );
                break;
            }
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
        if let Ok(steer_user_node) = storage.append_node(
            thread_id.to_owned(),
            committed_assistant_id.or(Some(current_parent_id.clone())),
            NodeRole::User,
            steer_text.clone(),
            Some(serde_json::json!({ "steered_mid_run": true, "run_id": run_id }).to_string()),
        ) {
            step_index = step_index.saturating_add(1);
            note_write(
                "run_step_record",
                storage.record_run_step(
                    run_id.to_owned(),
                    step_index,
                    RunStepKind::SteeringInjected,
                    "steering".to_owned(),
                    ToolRiskTier::Tier0ReadOnly,
                    format!("{run_id}:steer:{step_index}"),
                    "completed".to_owned(),
                    serde_json::json!({ "content": steer_text }).to_string(),
                    "{}".to_owned(),
                    0,
                    Some(utc_now_unix_ms()),
                ),
            );
            current_parent_id.clone_from(&steer_user_node.id);
            current_stream_node_id = Uuid::now_v7().to_string();
            let ev = EngineEvent::NodeCommitted {
                node: steer_user_node,
            };
            emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
            note_write(
                "agent_run_update",
                storage.update_agent_run(
                    run_id.to_owned(),
                    AgentRunUpdate {
                        step_index: Some(step_index),
                        partial_text_buffer: Some(String::new()),
                        cost_micros: Some(total_cost),
                        ..AgentRunUpdate::default()
                    },
                ),
            );
        } else {
            break;
        }
    }

    let final_status = if cancelled {
        RunStatus::Cancelled
    } else if failed_key.is_some() {
        RunStatus::Failed
    } else {
        RunStatus::Completed
    };
    if let Ok(final_run) = storage.update_agent_run(
        run_id.to_owned(),
        AgentRunUpdate {
            status: Some(final_status),
            step_index: Some(step_index),
            partial_text_buffer: Some(String::new()),
            cost_micros: Some(total_cost),
            error_key: Some(failed_key),
            ..AgentRunUpdate::default()
        },
    ) {
        let ev = EngineEvent::RunStateChanged { run: final_run };
        emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
    }

    (current_stream_node_id, cancelled)
}

pub(crate) fn compile_write_mode_system_prompt(
    storage: &Arc<StorageHandle>,
    thread_id: &str,
    base_system_prompt: &str,
    history: &[NodeRecord],
) -> String {
    let state = storage
        .load_story_thread_state(thread_id)
        .unwrap_or_default();
    let all_cards = storage.list_character_cards().unwrap_or_default();
    let active_cards: Vec<_> = if state.active_character_ids.is_empty() {
        all_cards.into_iter().take(1).collect()
    } else {
        all_cards
            .into_iter()
            .filter(|c| state.active_character_ids.contains(&c.id))
            .collect()
    };
    let personas = storage.list_user_personas().unwrap_or_default();
    let active_persona = state
        .user_persona_id
        .as_deref()
        .and_then(|pid| personas.iter().find(|p| p.id == pid))
        .or_else(|| personas.iter().find(|p| p.is_default));
    let entries = storage.list_story_entries(None).unwrap_or_default();
    let progressions = storage.list_story_progressions(None).unwrap_or_default();
    let chapters = storage.list_story_chapters(thread_id).unwrap_or_default();
    let report = story::prompt_assembler::assemble_story_prompt(
        base_system_prompt,
        &state,
        &active_cards,
        active_persona,
        &entries,
        &progressions,
        &chapters,
        history,
        None,
        32_000,
    );
    let combined = report
        .blocks
        .iter()
        .map(|b| format!("[{}]\n{}", b.label, b.content))
        .collect::<Vec<_>>()
        .join("\n\n");
    let rules = storage.list_regex_rules().unwrap_or_default();
    if combined.trim().is_empty() {
        base_system_prompt.to_owned()
    } else {
        story::regex_pipeline::apply_regex_pipeline(&combined, &rules, "prompt_outgoing")
    }
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
