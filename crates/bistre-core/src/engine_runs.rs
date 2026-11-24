//! Durable streaming run loop, retry/backoff, and write-mode prompt assembly for `InProcessEngine`.

use super::{
    AgentRunUpdate, Arc, AtomicBool, BistreError, DiagnosticKey, EngineEvent, GenerationParams,
    HashMap, KeyRing, MoneyMicros, NodeRecord, NodeRole, Notify, Ordering, ProviderProfile,
    RunStatus, RunStepKind, StorageHandle, StreamChunk, SystemTime, ThreadMode, ToolRiskTier,
    UNIX_EPOCH, Uuid, agent, approval, broadcast, compaction, error_policy, providers, registry,
    story,
};
use crate::events::{emit, emit_logged, note_write};
use crate::wallet;
use bistre_protocol::{BistreResult, UsageMetrics};

/// Shared network services for one streaming run.
#[derive(Debug)]
pub(crate) struct StreamServices {
    pub(crate) http: reqwest::Client,
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
    let is_local = crate::net::is_loopback_url(&provider.base_url);

    loop {
        // A storage failure here stops the run before any request: never send a paid request
        // with a silently empty or partial history.
        let (history, is_write_mode, effective_system_prompt) =
            match load_turn_context(storage, thread_id, &current_parent_id, system_prompt) {
                Ok(ctx) => ctx,
                Err(err) => {
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
            };
        // Wallet Shield: reserve spend for this paid request before it is sent (fail closed).
        let mut reservation = if is_local {
            None
        } else {
            match reserve_paid_request(
                storage,
                services,
                thread_id,
                provider,
                model,
                &effective_system_prompt,
                &history,
            )
            .await
            {
                Ok(r) => Some(r),
                Err(err) => {
                    failed_key = Some(err.key.as_key().to_owned());
                    emit(
                        events_tx,
                        EngineEvent::DiagnosticRaised {
                            key: err.key,
                            detail_code: Some(run_id.to_owned()),
                        },
                    );
                    break;
                }
            }
        };
        let mut activity = approval::RunActivity::start();
        let step_rec = note_write(
            "run_step_record",
            storage.record_run_step(
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
            ),
        );

        let delta_tx = events_tx.clone();
        let delta_thread = thread_id.to_owned();
        let delta_node = current_stream_node_id.clone();
        let think_tx = events_tx.clone();
        let think_thread = thread_id.to_owned();
        let think_node = current_stream_node_id.clone();
        let buf_storage = Arc::clone(storage);
        let buf_run_id = run_id.to_owned();
        // Checkpoint only the new suffix, at most every CHECKPOINT_INTERVAL and once at least
        // CHECKPOINT_MIN_BYTES arrived (whole-buffer rewrites per chunk were quadratic).
        let mut unsaved_suffix = String::new();
        let mut last_checkpoint = std::time::Instant::now();
        // Coalesce deltas to one event per frame (DELTA_FRAME) so a fast stream cannot overrun
        // the bounded event bus.
        let mut pending_delta = String::new();
        let mut last_delta_emit = std::time::Instant::now();

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
                unsaved_suffix.push_str(chunk);
                if unsaved_suffix.len() >= CHECKPOINT_MIN_BYTES
                    && last_checkpoint.elapsed() >= CHECKPOINT_INTERVAL
                {
                    note_write(
                        "agent_run_checkpoint",
                        buf_storage.append_agent_run_partial_text(
                            buf_run_id.clone(),
                            std::mem::take(&mut unsaved_suffix),
                        ),
                    );
                    last_checkpoint = std::time::Instant::now();
                }
                pending_delta.push_str(chunk);
                if last_delta_emit.elapsed() >= DELTA_FRAME {
                    emit_delta(&delta_tx, &delta_thread, &delta_node, &mut pending_delta);
                    last_delta_emit = std::time::Instant::now();
                }
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
        // Flush the last partial frame and checkpoint.
        emit_delta(&delta_tx, &delta_thread, &delta_node, &mut pending_delta);
        if !unsaved_suffix.is_empty() {
            note_write(
                "agent_run_checkpoint",
                storage.append_agent_run_partial_text(run_id.to_owned(), unsaved_suffix),
            );
        }

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
                let request_id = format!("{run_id}:llm:{step_index}");
                if !res.full_text.trim().is_empty() || !res.thinking_text.trim().is_empty() {
                    let mut meta_obj = serde_json::json!({
                        "provider_id": provider.id,
                        "provider_name": provider.name,
                        "icon_slug": provider.icon_slug,
                        "model_id": model,
                        "input_tokens": res.usage.input_tokens,
                        "output_tokens": res.usage.output_tokens,
                        "cached_input_tokens": res.usage.cached_input_tokens,
                        "cache_creation_input_tokens": res.usage.cache_creation_input_tokens,
                        "reasoning_tokens": res.usage.reasoning_tokens,
                        "first_token_ms": res.usage.first_token_ms,
                        "cost_micros": res.usage.estimated_cost_micros.as_micros(),
                        "cost_known": cost.is_some(),
                        "elapsed_ms": elapsed_ms,
                        "request_id": request_id,
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
                        let rules = match storage.list_regex_rules() {
                            Ok(rules) => rules,
                            Err(err) => {
                                // Commit the unfiltered reply rather than lose it; say so.
                                emit(
                                    events_tx,
                                    EngineEvent::DiagnosticRaised {
                                        key: err.key,
                                        detail_code: Some("regex_rules_unavailable".to_owned()),
                                    },
                                );
                                Vec::new()
                            }
                        };
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
                            let status = if res.cancelled {
                                "cancelled".to_owned()
                            } else {
                                "settled".to_owned()
                            };
                            let recorded = match reservation.take() {
                                Some(r) => r.settle_for_request(
                                    Some(request_id.clone()),
                                    res.usage.estimated_cost_micros,
                                    res.usage.input_tokens,
                                    res.usage.output_tokens,
                                    status,
                                ),
                                None => storage.record_wallet_entry_with_usage(
                                    Some(thread_id.to_owned()),
                                    provider.id.clone(),
                                    model.to_owned(),
                                    res.usage.estimated_cost_micros,
                                    res.usage.input_tokens,
                                    res.usage.output_tokens,
                                    status,
                                ),
                            };
                            if let Err(err) = recorded {
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
                let branch = match storage.list_nodes(thread_id) {
                    Ok(nodes) => collect_branch_ancestry(&nodes, &current_parent_id),
                    Err(read_err) => {
                        failed_key = Some(read_err.key.as_key().to_owned());
                        emit(
                            events_tx,
                            EngineEvent::DiagnosticRaised {
                                key: read_err.key,
                                detail_code: read_err.detail_code,
                            },
                        );
                        break;
                    }
                };
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

        if cancelled || step_index >= MAX_RUN_STEPS {
            break;
        }

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
                break;
            }
        };
        if pending_steers.is_empty() {
            break;
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
        let appended = storage.append_node(
            thread_id.to_owned(),
            committed_assistant_id.or(Some(current_parent_id.clone())),
            NodeRole::User,
            steer_text.clone(),
            Some(serde_json::json!({ "steered_mid_run": true, "run_id": run_id }).to_string()),
        );
        let steer_user_node = match appended {
            Ok(node) => node,
            Err(err) => {
                // The queued message was drained but could not be saved: stop and say so.
                failed_key = Some(err.key.as_key().to_owned());
                emit(
                    events_tx,
                    EngineEvent::DiagnosticRaised {
                        key: err.key,
                        detail_code: Some("steering_append_failed".to_owned()),
                    },
                );
                break;
            }
        };
        {
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
        }
    }

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
            // The run's final state was not saved; startup reconciliation will repair it.
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

    (current_stream_node_id, cancelled)
}

pub(crate) fn compile_write_mode_system_prompt(
    storage: &StorageHandle,
    thread_id: &str,
    base_system_prompt: &str,
    history: &[NodeRecord],
) -> BistreResult<String> {
    let state = storage.load_story_thread_state(thread_id)?;
    let all_cards = storage.list_character_cards()?;
    let active_cards: Vec<_> = if state.active_character_ids.is_empty() {
        all_cards.into_iter().take(1).collect()
    } else {
        all_cards
            .into_iter()
            .filter(|c| state.active_character_ids.contains(&c.id))
            .collect()
    };
    let personas = storage.list_user_personas()?;
    let active_persona = state
        .user_persona_id
        .as_deref()
        .and_then(|pid| personas.iter().find(|p| p.id == pid))
        .or_else(|| personas.iter().find(|p| p.is_default));
    let entries = storage.list_story_entries(None)?;
    let progressions = storage.list_story_progressions(None)?;
    let chapters = storage.list_story_chapters(thread_id)?;
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
const CHECKPOINT_INTERVAL: std::time::Duration = std::time::Duration::from_millis(250);
/// Minimum new text before a checkpoint is written.
const CHECKPOINT_MIN_BYTES: usize = 4 * 1024;
/// One display frame: deltas inside it are sent as one event.
const DELTA_FRAME: std::time::Duration = std::time::Duration::from_millis(16);

fn emit_delta(
    tx: &broadcast::Sender<EngineEvent>,
    thread_id: &str,
    node_id: &str,
    pending: &mut String,
) {
    if pending.is_empty() {
        return;
    }
    emit(
        tx,
        EngineEvent::DeltaBatch {
            thread_id: thread_id.to_owned(),
            chunks: vec![StreamChunk {
                node_id: node_id.to_owned(),
                text_delta: std::mem::take(pending),
            }],
        },
    );
}

/// Loads everything one model turn needs: the branch history (respecting the context pin),
/// whether the thread is in Write mode, and the effective system prompt.
fn load_turn_context(
    storage: &Arc<StorageHandle>,
    thread_id: &str,
    parent_id: &str,
    system_prompt: &str,
) -> BistreResult<(Vec<NodeRecord>, bool, String)> {
    let history = project_turn_history(storage, thread_id, parent_id)?;
    let is_write_mode = storage
        .get_thread(thread_id)?
        .is_some_and(|t| t.mode == ThreadMode::Write);
    let prompt = if is_write_mode {
        compile_write_mode_system_prompt(storage, thread_id, system_prompt, &history)?
    } else {
        system_prompt.to_owned()
    };
    Ok((history, is_write_mode, prompt))
}

/// The history the next request sends for the branch ending at `leaf_id`: its ancestry from
/// the context-start pin or the latest compaction summary onward, with roles alternating.
fn project_turn_history(
    storage: &StorageHandle,
    thread_id: &str,
    leaf_id: &str,
) -> BistreResult<Vec<NodeRecord>> {
    let all_nodes = storage.list_nodes(thread_id)?;
    let raw_history = collect_branch_ancestry(&all_nodes, leaf_id);
    let pinned_start = storage.get_kv_meta(&format!("thread_context_start:{thread_id}"))?;
    let effective = compaction::project_effective_history(&raw_history, pinned_start.as_deref());
    let quantized = compaction::compact_tool_outputs_quantized(&effective, 2_000);
    Ok(compaction::enforce_role_alternation(quantized))
}

/// Longest user name told to the model, in characters.
const MAX_USER_NAME_CHARS: usize = 64;

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

/// What the next request sends for this branch, by category (the composer's context gauge
/// and breakdown). Uses the same system prompt, Write-mode story prompt, and history projection
/// as a run, so a compaction or a context pin lowers it exactly as it lowers the real request.
pub(crate) fn branch_context_usage(
    storage: &StorageHandle,
    thread_id: &str,
    leaf_id: &str,
    draft: &str,
) -> BistreResult<crate::ContextUsage> {
    let thread = storage
        .get_thread(thread_id)?
        .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
    let settings = storage.load_settings()?;
    let assistant = storage
        .list_assistants()?
        .into_iter()
        .find(|a| a.id == thread.assistant_id);
    let base_prompt = match thread.system_prompt_override.clone() {
        Some(prompt) => prompt,
        None => assistant
            .as_ref()
            .map_or_default(|a| a.system_prompt.clone()),
    };
    let active_model = thread
        .model_id_override
        .as_deref()
        .filter(|m| !m.trim().is_empty())
        .or_else(|| {
            assistant
                .as_ref()
                .map(|a| a.default_model_id.as_str())
                .filter(|m| !m.trim().is_empty())
        })
        .or_else(|| {
            let m = settings.active_model_id.as_str();
            (!m.trim().is_empty()).then_some(m)
        });
    let base_prompt = with_user_name(base_prompt, &settings.user_display_name, thread.mode);
    let history = project_turn_history(storage, thread_id, leaf_id)?;
    let system_tokens = compaction::estimate_tokens_for_model(&base_prompt, active_model);
    let story_tokens = if thread.mode == ThreadMode::Write {
        let compiled =
            compile_write_mode_system_prompt(storage, thread_id, &base_prompt, &history)?;
        compaction::estimate_tokens_for_model(&compiled, active_model).saturating_sub(system_tokens)
    } else {
        0
    };
    Ok(crate::ContextUsage {
        system_tokens,
        story_tokens,
        history_tokens: compaction::estimate_branch_tokens_for_model("", &history, active_model),
        history_turns: u32::try_from(history.len()).unwrap_or(u32::MAX),
        draft_tokens: compaction::estimate_tokens_for_model(draft.trim(), active_model),
    })
}

/// Reserves Wallet Shield spend for one paid request. Prices the prompt's model-matched BPE
/// input tokens when live rates are known; output is settled afterwards.
async fn reserve_paid_request(
    storage: &Arc<StorageHandle>,
    services: &StreamServices,
    thread_id: &str,
    provider: &ProviderProfile,
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
) -> BistreResult<wallet::SpendReservation> {
    let settings = storage.load_settings().map_err(|err| {
        BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, err.key.as_key())
    })?;
    let estimate_usage = UsageMetrics {
        input_tokens: compaction::estimate_branch_tokens_for_model(
            system_prompt,
            history,
            Some(model),
        ),
        ..UsageMetrics::default()
    };
    let rates = services.pricing.rates_for(model).await;
    let estimate = providers::estimate_cost_micros(provider, rates, &estimate_usage)
        .unwrap_or(MoneyMicros::ZERO);
    wallet::SpendReservation::reserve(
        storage,
        Some(thread_id.to_owned()),
        provider.id.clone(),
        model.to_owned(),
        estimate,
        settings.wallet_daily_ceiling_micros,
        utc_day_start_unix_ms(),
    )
    .map_err(|err| match err.key {
        DiagnosticKey::WalletCeilingExceeded => err,
        other => BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, other.as_key()),
    })
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
