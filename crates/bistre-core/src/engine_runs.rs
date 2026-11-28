//! Durable streaming run loop, retry/backoff, and write-mode prompt assembly for `InProcessEngine`.

use super::{
    AgentRunUpdate, Arc, AtomicBool, BistreError, DiagnosticKey, EngineEvent, GenerationParams,
    KeyRing, MoneyMicros, NodeRole, Ordering, ProviderProfile, RunStepKind, StorageHandle,
    ThreadMode, ToolRiskTier, Uuid, agent, approval, broadcast, compaction, error_policy,
    providers, registry, story,
};
use crate::events::{emit, emit_logged, note_write};
use crate::turn_context::{
    CHECKPOINT_INTERVAL, CHECKPOINT_MIN_BYTES, DELTA_FRAME, Steering, compact_before_send,
    emit_delta, finish_run, near_context_limit, take_steering,
};
pub(crate) use crate::turn_context::{
    MAX_RUN_STEPS, StreamServices, UnpricedAllowances, collect_branch_ancestry, load_turn_context,
    load_turn_context_with, reserve_paid_request, utc_day_start_unix_ms, utc_now_unix_ms,
    with_user_name,
};
use crate::wallet;

/// Rate limits, transient server failures (including transient HTTP 400), and streams that died
/// before any output retry automatically; auth, quota/billing, spend caps, and bad requests never do.
pub(crate) fn is_auto_retryable(err: &BistreError) -> bool {
    match err.key {
        DiagnosticKey::ProviderRateLimited | DiagnosticKey::ProviderStreamInterrupted => true,
        DiagnosticKey::ProviderRequestFailed => err.detail_code.as_deref().is_some_and(|d| {
            d == "connect"
                || d.contains("transient")
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
    clippy::too_many_lines,
    reason = "One linear state loop: stream commit, Wallet Shield re-check, and steering."
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
    // When the current streak of retryable failures began (the retry budget is wall-clock).
    let mut retry_started: Option<std::time::Instant> = None;
    let mut overflow_compacted = false;
    let mut consecutive_tool_failures: u32 = 0;
    let is_local = crate::net::is_loopback_url(&provider.base_url);
    // A Custom provider speaks the API format chosen in its Advanced settings.
    let initial_adv = crate::provider_prefs::load_provider_advanced(storage, &provider.id);
    let wired = initial_adv.speaking(provider);
    let scope = registry::CatalogScope::of(&wired);
    let model_rates = services.pricing.rates_for(&scope, model).await;
    let wired = crate::media_gen::chat_wire_for(wired, model_rates.as_ref());
    let provider = &wired;
    // A model that writes no text answers through its media API instead of chat.
    if let Some(rates) = model_rates
        && let Some(route) = crate::media_gen::MediaRoute::of(provider.dialect, Some(&rates))
    {
        let turn = crate::media_gen::MediaTurn {
            storage,
            services,
            events_tx,
            cancel_flag,
            thread_id,
            run_id,
            parent_id: &current_parent_id,
            provider,
            keys,
            model,
            rates,
        };
        let (cancelled, failed_key, cost) = crate::media_gen::run(&turn, route).await;
        finish_run(
            storage, events_tx, thread_id, run_id, cancelled, failed_key, 0, cost,
        );
        return (current_stream_node_id, cancelled);
    }
    let media_out = model_rates
        .and_then(|r| r.output_modalities)
        .unwrap_or_default();
    let reads = model_rates.and_then(|r| r.input_modalities);
    let catalog_voice = services
        .pricing
        .snapshot()
        .voice(model)
        .map(ToOwned::to_owned);
    let media_pick = crate::media_gen::load_media_pick(storage)
        .for_model(services.pricing.snapshot().extras(model));

    let run_policy = agent::RunApprovalPolicy::load(storage, run_id);
    // Set when the next step resumes a paused turn (its reply is sent back as-is).
    let mut resume_paused = false;
    loop {
        let prov_adv = crate::provider_prefs::load_provider_advanced(storage, &provider.id);
        let ctx_window = prov_adv
            .context_tokens(model, services.pricing.snapshot().lookup(&scope, model))
            .map(u64::from);
        // A storage failure here stops the run before any request: never send a paid request
        // with a silently empty or partial history.
        let (history, thread_mode, effective_system_prompt) = match load_turn_context_with(
            storage,
            thread_id,
            &current_parent_id,
            system_prompt,
            core::mem::take(&mut resume_paused),
            ctx_window,
        ) {
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
        let mut history = history;
        crate::media_wire::carry_generated_media(&mut history, reads);
        let is_write_mode = thread_mode == ThreadMode::Write;
        let mut tool_catalog = match crate::agent_tools::resolve_active_tool_catalog(
            storage,
            Some(thread_id),
            thread_mode,
        ) {
            Ok(cat) => cat,
            Err(err) => {
                tracing::warn!(
                    key = err.key.as_key(),
                    "active tool catalog unavailable; continuing without tools"
                );
                crate::agent_tools::ActiveToolCatalog::default()
            }
        };
        // A run in its own worktree works there, never in the folders the app has open.
        if let Some(root) = &run_policy.sandbox {
            tool_catalog.workspace_root = Some(root.clone());
            tool_catalog.workspace_roots = vec![root.clone()];
        }
        crate::agent_tools::offer_turn_tools(
            &mut tool_catalog,
            storage,
            thread_id,
            thread_mode,
            &history,
        );
        let tools_wire = tool_catalog.wire_tools_for_dialect(provider.dialect);
        let tools_canonical = tool_catalog.canonical_json();
        // Custom headers/body are validated before anything is reserved or sent.
        let prov_overrides =
            match crate::provider_prefs::load_provider_overrides(storage, &provider.id) {
                Ok(o) => o,
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
        let mut estimated_input_tokens = 0_u64;
        let mut reservation = if is_local {
            None
        } else {
            match reserve_paid_request(
                storage,
                services,
                thread_id,
                provider,
                &prov_adv,
                model,
                &effective_system_prompt,
                &history,
                bistre_protocol::SpendPurpose::Chat,
            )
            .await
            {
                Ok((r, input_estimate)) => {
                    estimated_input_tokens = input_estimate;
                    Some(r)
                }
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
        // Coalesce text and thinking deltas to one event each per frame (DELTA_FRAME) so a fast
        // stream cannot overrun the bounded event bus. A frame ticker beside the stream flushes
        // them, so the last text of a burst is shown within a frame even when the provider then
        // pauses.
        let pending_delta = std::sync::Mutex::new(String::new());
        let pending_thinking = std::sync::Mutex::new(String::new());

        let replay_ctx = crate::replay_policy::ReplayContext::new(
            provider.dialect,
            &provider.id,
            model,
            &effective_system_prompt,
            &tools_canonical,
            Some(thread_id),
        );
        let reply_prefill = crate::provider_prefs::load_thread_reply_prefill(storage, thread_id);
        let store_enabled = crate::provider_prefs::stores_on_server(
            stateless_default,
            provider.use_server_state_cache,
        );
        // Chain only when this request stores, and then send only the new items.
        let chain = if prov_adv.use_stateful_chaining {
            crate::replay_policy::chain_plan(&history, &replay_ctx, store_enabled)
        } else {
            None
        };
        // Proactive auto-compaction before sending when context approaches the model's window.
        if !overflow_compacted && let Some(ctx_limit) = ctx_window {
            // The tool schemas are part of every request too.
            let est_tokens = compaction::estimate_branch_tokens_for_model(
                &effective_system_prompt,
                &history,
                Some(model),
            )
            .saturating_add(tool_catalog.schema_tokens(Some(model)));
            if near_context_limit(storage, est_tokens, ctx_limit) {
                overflow_compacted = true;
                if let Some(summary_id) =
                    compact_before_send(storage, events_tx, thread_id, &current_parent_id)
                {
                    current_parent_id = summary_id;
                    continue;
                }
            }
        }
        // A wait another run was told about for this provider holds this run too; `Retry now`
        // (the wake) sends at once.
        if let Some(wait) = services
            .provider_backoff
            .remaining(&provider.id, std::time::Instant::now())
        {
            tokio::select! {
                () = tokio::time::sleep(wait) => {}
                () = services.wake.notified() => services.provider_backoff.clear(&provider.id),
            }
            if cancel_flag.load(Ordering::SeqCst) {
                cancelled = true;
                break;
            }
        }
        let request_id = format!("{run_id}:llm:{step_index}");
        let stream_opts = providers::StreamRequestOptions {
            replay_ctx: Some(&replay_ctx),
            tools_wire: (!tools_wire.is_empty()).then_some(tools_wire.as_slice()),
            previous_server_id: chain.as_ref().map(|c| c.previous_id.as_str()),
            chain_first_new_index: chain.as_ref().map_or(0, |c| c.first_new_index),
            store: store_enabled,
            anthropic_cache_1h: prov_adv.anthropic_cache_1h,
            anthropic_server_compaction: prov_adv.enable_server_compaction,
            endpoint_path: prov_adv.endpoint_path.as_deref(),
            auth_mode: prov_adv.auth_mode,
            disable_legacy_fallback: !prov_adv.use_legacy_fallback,
            reply_prefill,
            anthropic_beta_headers: Vec::new(),
            extra_headers: prov_overrides.headers,
            extra_body_fields: prov_overrides.body_fields,
            media_out,
            reads,
            voice: catalog_voice.as_deref(),
            media_pick: media_pick.clone(),
            provider_tools: crate::turn_context::provider_tools_on(
                storage,
                thread_id,
                &prov_adv,
                !tools_wire.is_empty(),
            ),
            paid_tools: crate::paid_tools::paid_tools(
                &prov_adv,
                provider.dialect,
                model_rates.as_ref(),
                !tools_wire.is_empty(),
            ),
            raw_request_id: Some(&request_id),
        };
        let flush_frame = || {
            let text = core::mem::take(&mut *bistre_protocol::lock_or_recover(
                &pending_delta,
                "pending_delta",
            ));
            emit_delta(&delta_tx, &delta_thread, &delta_node, text);
            let thinking = core::mem::take(&mut *bistre_protocol::lock_or_recover(
                &pending_thinking,
                "pending_thinking",
            ));
            if !thinking.is_empty() {
                emit(
                    &think_tx,
                    EngineEvent::ThinkingDelta {
                        thread_id: think_thread.clone(),
                        node_id: think_node.clone(),
                        delta: thinking,
                    },
                );
            }
        };
        let outcome = {
            let stream = providers::stream_completion_with_options(
                &services.http,
                provider,
                keys,
                model,
                &effective_system_prompt,
                &history,
                gen_params,
                Some(&services.data_dir),
                &stream_opts,
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
                    bistre_protocol::lock_or_recover(&pending_delta, "pending_delta")
                        .push_str(chunk);
                },
                |thinking_chunk| {
                    bistre_protocol::lock_or_recover(&pending_thinking, "pending_thinking")
                        .push_str(thinking_chunk);
                },
            );
            tokio::pin!(stream);
            let mut frame = tokio::time::interval(DELTA_FRAME);
            frame.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    out = &mut stream => break out,
                    _ = frame.tick() => flush_frame(),
                }
            }
        };
        // Flush the last partial frame and checkpoint.
        flush_frame();
        if !unsaved_suffix.is_empty() {
            note_write(
                "agent_run_checkpoint",
                storage.append_agent_run_partial_text(run_id.to_owned(), unsaved_suffix),
            );
        }

        let elapsed_ms = activity.finish_ms();
        let mut committed_assistant_id: Option<String> = None;
        let mut pending_tool_calls: Vec<crate::replay_policy::StoredToolCall> = Vec::new();
        let mut paused_turn = false;

        match outcome {
            Ok(mut res) => {
                retry_attempt = 0;
                retry_started = None;
                pending_tool_calls.clone_from(&res.tool_calls);
                if !is_local {
                    let counted_output = [res.full_text.as_str(), res.thinking_text.as_str()]
                        .into_iter()
                        .chain(res.tool_calls.iter().map(|c| c.arguments_json.as_str()))
                        .map(|t| compaction::estimate_tokens_for_model(t, Some(model)))
                        .fold(0_u64, u64::saturating_add);
                    let (billable, estimated) =
                        wallet::billable_usage(&res.usage, estimated_input_tokens, counted_output);
                    if estimated {
                        emit(
                            events_tx,
                            EngineEvent::DiagnosticRaised {
                                key: DiagnosticKey::WalletUsageEstimated,
                                detail_code: Some(run_id.to_owned()),
                            },
                        );
                    }
                    res.usage = billable;
                }
                // The run already waited once for an in-flight price sync (`model_rates`);
                // each step reads the newest table without waiting again.
                let rates = prov_adv
                    .resolve_rates(model, services.pricing.snapshot().lookup(&scope, model));
                let cost = providers::estimate_cost_micros(provider, rates, &res.usage);
                res.usage.estimated_cost_micros = cost.unwrap_or(MoneyMicros::ZERO);
                for (key, detail) in core::mem::take(&mut res.notices) {
                    if key == DiagnosticKey::ProviderRequestHealed
                        && detail == "heal_drop_reasoning"
                    {
                        bistre_protocol::lock_or_recover(
                            &services.reasoning_unsupported,
                            "reasoning_unsupported",
                        )
                        .insert((provider.id.clone(), model.to_owned()));
                    }
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
                // How the reply ended is never a silent "complete".
                let finish_notice = match res.finish {
                    Some(crate::finish::FinishKind::Length) => {
                        Some(DiagnosticKey::ProviderReplyTruncated)
                    }
                    Some(crate::finish::FinishKind::Refusal) => {
                        Some(DiagnosticKey::ProviderReplyRefused)
                    }
                    Some(crate::finish::FinishKind::PauseTurn) => {
                        paused_turn = true;
                        None
                    }
                    _ => None,
                };
                if let Some(key) = finish_notice {
                    let ev = EngineEvent::DiagnosticRaised {
                        key,
                        detail_code: None,
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
                let has_billed_usage = res.usage.input_tokens > 0
                    || res.usage.output_tokens > 0
                    || res.usage.reasoning_tokens > 0
                    || res.usage.cached_input_tokens > 0
                    || res.usage.cache_creation_input_tokens > 0;
                let settle_status = if res.cancelled {
                    "cancelled".to_owned()
                } else {
                    "settled".to_owned()
                };
                if !res.full_text.trim().is_empty()
                    || !res.thinking_text.trim().is_empty()
                    || !res.tool_calls.is_empty()
                    || !res.media.is_empty()
                {
                    let origin = crate::replay_policy::TurnOriginMeta {
                        dialect: provider.dialect,
                        provider_id: provider.id.clone(),
                        model_id: model.to_owned(),
                        system_hash: replay_ctx.system_hash.clone(),
                        tools_hash: replay_ctx.tools_hash.clone(),
                    };
                    let server_state = res.provider_response_id.as_ref().map(|rid| {
                        crate::replay_policy::ServerStateMeta {
                            response_id: (provider.dialect
                                != bistre_protocol::ProviderDialect::GoogleGemini)
                                .then(|| rid.clone()),
                            interaction_id: (provider.dialect
                                == bistre_protocol::ProviderDialect::GoogleGemini)
                                .then(|| rid.clone()),
                            store_enabled,
                        }
                    });
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
                        "origin": origin,
                    });
                    if let Some(map) = meta_obj.as_object_mut() {
                        if let Some(ss) = server_state
                            && let Ok(v) = serde_json::to_value(ss)
                        {
                            map.insert("server_state".to_owned(), v);
                        }
                        if !res.reasoning_blocks.is_empty()
                            && let Ok(v) = serde_json::to_value(&res.reasoning_blocks)
                        {
                            map.insert("reasoning_blocks".to_owned(), v);
                        }
                        if !res.tool_calls.is_empty()
                            && let Ok(v) = serde_json::to_value(&res.tool_calls)
                        {
                            map.insert("tool_calls".to_owned(), v);
                        }
                        // Images and audio the reply carried become its attachments.
                        let media = core::mem::take(&mut res.media);
                        if !media.is_empty() {
                            match crate::media_gen::store_generated(&services.data_dir, media) {
                                Ok(atts) => {
                                    map.insert("attachments".to_owned(), serde_json::json!(atts));
                                }
                                Err(err) => emit(
                                    events_tx,
                                    EngineEvent::DiagnosticRaised {
                                        key: err.key,
                                        detail_code: err.detail_code,
                                    },
                                ),
                            }
                        }
                        // Web sources stay with the reply (UI only, never replayed).
                        if !res.grounding.is_empty() {
                            map.insert(
                                "grounding".to_owned(),
                                crate::grounding::grounding_meta(&res.grounding),
                            );
                        }
                        if !res.thinking_text.trim().is_empty() {
                            map.insert(
                                "thinking_text".to_owned(),
                                serde_json::Value::String(res.thinking_text),
                            );
                            map.insert(
                                "thinking_duration_ms".to_owned(),
                                serde_json::Value::from(res.thinking_duration_ms),
                            );
                        }
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
                            let ev = EngineEvent::NodeCommitted { node: committed };
                            emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
                        }
                    }
                }
                // Always settle Wallet Shield whenever the provider processed tokens (even on
                // cancel, empty-text response, or local node-write failure).
                if has_billed_usage || committed_assistant_id.is_some() {
                    let recorded = match reservation.take() {
                        Some(r) => r.settle_for_request(
                            Some(request_id),
                            res.usage.estimated_cost_micros,
                            res.usage.input_tokens,
                            res.usage.output_tokens,
                            settle_status,
                        ),
                        None => storage.record_wallet_entry_with_usage(
                            Some(thread_id.to_owned()),
                            provider.id.clone(),
                            model.to_owned(),
                            res.usage.estimated_cost_micros,
                            res.usage.input_tokens,
                            res.usage.output_tokens,
                            settle_status,
                            bistre_protocol::SpendPurpose::Chat,
                        ),
                    };
                    if let Err(err) = recorded {
                        tracing::error!(key = err.key.as_key(), "wallet spend record failed");
                        emit(
                            events_tx,
                            EngineEvent::DiagnosticRaised {
                                key: err.key,
                                detail_code: err.detail_code,
                            },
                        );
                    }
                }
            }
            Err(err)
                if err.key == DiagnosticKey::ProviderContextOverflow && !overflow_compacted =>
            {
                // Release pre-compaction spend reservation before compacting & retrying.
                drop(reservation);
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
                let branch = match storage.list_branch(thread_id, &current_parent_id) {
                    Ok(nodes) => nodes,
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
                // Never hold Wallet Shield budget locked across a multi-minute backoff sleep.
                drop(reservation);
                let budget = storage
                    .load_settings()
                    .map_or(300, |s| s.retry_watchdog_max_wait_secs);
                let hint_secs = error_policy::retry_after_from_detail(err.detail_code.as_deref())
                    .map(|ms| ms.div_ceil(1000));
                // Wall-clock since the first failure (oh-my-pi): `Retry now` and early wakes
                // spend only the time that actually passed.
                let first_failure = *retry_started.get_or_insert_with(std::time::Instant::now);
                let waited_secs = first_failure.elapsed().as_secs();
                let Some(wait_ms) = agent::compute_backoff_wait_ms(
                    retry_attempt,
                    hint_secs,
                    waited_secs,
                    budget,
                    agent::jitter_seed(run_id),
                ) else {
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
                if let Some(ref st) = step_rec {
                    note_write("run_step_complete", storage.complete_run_step(
                        st.id.clone(),
                        "retrying".to_owned(),
                        serde_json::json!({ "error": err.key.as_key(), "retry_in_ms": wait_ms })
                            .to_string(),
                        elapsed_ms,
                    ));
                }
                let detail_suffix = err
                    .detail_code
                    .as_deref()
                    .filter(|d| !d.trim().is_empty())
                    .map_or_default(|d| format!(";detail={d}"));
                let ev = EngineEvent::DiagnosticRaised {
                    key: DiagnosticKey::RunBackoffWaiting,
                    detail_code: Some(format!(
                        "retry_in_ms={wait_ms};attempt={retry_attempt};reason={}{detail_suffix}",
                        err.key.as_key()
                    )),
                };
                emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
                services.provider_backoff.note(
                    &provider.id,
                    std::time::Instant::now(),
                    std::time::Duration::from_millis(wait_ms),
                );
                // `Retry now` and cancel both notify `wake`, ending the wait immediately.
                tokio::select! {
                    () = tokio::time::sleep(std::time::Duration::from_millis(wait_ms)) => {}
                    () = services.wake.notified() => services.provider_backoff.clear(&provider.id),
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

        if cancelled {
            break;
        }
        if step_index >= MAX_RUN_STEPS {
            // The model still wanted to go on; the run says why it stopped.
            if !pending_tool_calls.is_empty() || paused_turn {
                failed_key = Some(DiagnosticKey::RunStepLimitReached.as_key().to_owned());
                let ev = EngineEvent::DiagnosticRaised {
                    key: DiagnosticKey::RunStepLimitReached,
                    detail_code: Some(format!("max_steps={MAX_RUN_STEPS}")),
                };
                emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
            }
            break;
        }

        // A paused server-side turn (Anthropic `pause_turn`) continues by itself: the
        // paused reply goes back as the last assistant turn, bounded by the step limit.
        if pending_tool_calls.is_empty()
            && paused_turn
            && let Some(asst_id) = committed_assistant_id.clone()
        {
            current_parent_id = asst_id;
            resume_paused = true;
            step_index = step_index.saturating_add(1);
            current_stream_node_id = Uuid::now_v7().to_string();
            let next_start = EngineEvent::RunStarted {
                thread_id: thread_id.to_owned(),
                node_id: current_stream_node_id.clone(),
            };
            emit_logged(storage, events_tx, Some(thread_id.to_owned()), next_start);
            continue;
        }

        // If the model emitted tool calls, execute the full tool batch (with approval pausing,
        // permit binding, hooks, blob spilling, and guaranteed paired `NodeRole::Tool` commits)
        // BEFORE checking queued steering so we never split `tool_use` / `tool_result`.
        if !pending_tool_calls.is_empty()
            && let Some(asst_id) = committed_assistant_id.as_deref()
        {
            let batch = crate::agent_tools::execute_tool_batch(
                storage,
                services,
                events_tx,
                cancel_flag,
                &tool_catalog,
                thread_id,
                run_id,
                asst_id,
                &mut step_index,
                &pending_tool_calls,
                &crate::delegate::HelperContext {
                    provider,
                    keys,
                    model,
                    cancel_flag,
                },
                &run_policy,
            )
            .await;
            current_parent_id = batch.last_node_id;
            cancelled |= batch.cancelled;
            if batch.any_succeeded {
                consecutive_tool_failures = 0;
            } else if batch.all_failed {
                consecutive_tool_failures = consecutive_tool_failures.saturating_add(1);
            }
            if cancelled
                || batch.waiting_for_user
                || step_index >= MAX_RUN_STEPS
                || consecutive_tool_failures >= crate::agent_tools::MAX_CONSECUTIVE_TOOL_FAILURES
            {
                if consecutive_tool_failures >= crate::agent_tools::MAX_CONSECUTIVE_TOOL_FAILURES {
                    failed_key = Some(DiagnosticKey::InternalError.as_key().to_owned());
                    emit(
                        events_tx,
                        EngineEvent::DiagnosticRaised {
                            key: DiagnosticKey::InternalError,
                            detail_code: Some("tool_failure_breaker".to_owned()),
                        },
                    );
                } else if !cancelled && !batch.waiting_for_user && step_index >= MAX_RUN_STEPS {
                    // Tools ran but no step is left for the model to use their results.
                    failed_key = Some(DiagnosticKey::RunStepLimitReached.as_key().to_owned());
                    let ev = EngineEvent::DiagnosticRaised {
                        key: DiagnosticKey::RunStepLimitReached,
                        detail_code: Some(format!("max_steps={MAX_RUN_STEPS}")),
                    };
                    emit_logged(storage, events_tx, Some(thread_id.to_owned()), ev);
                }
                break;
            }
            // Start the follow-up model step with a fresh leaf stream node ID.
            step_index = step_index.saturating_add(1);
            current_stream_node_id = Uuid::now_v7().to_string();
            let next_start = EngineEvent::RunStarted {
                thread_id: thread_id.to_owned(),
                node_id: current_stream_node_id.clone(),
            };
            emit_logged(storage, events_tx, Some(thread_id.to_owned()), next_start);
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
            continue;
        }

        match take_steering(
            storage,
            events_tx,
            thread_id,
            run_id,
            committed_assistant_id.unwrap_or_else(|| current_parent_id.clone()),
            &mut step_index,
            total_cost,
        ) {
            Steering::Continue {
                parent_id,
                stream_node_id,
            } => {
                current_parent_id = parent_id;
                current_stream_node_id = stream_node_id;
            }
            Steering::Done => break,
            Steering::Failed(key) => {
                failed_key = key;
                break;
            }
        }
    }

    finish_run(
        storage, events_tx, thread_id, run_id, cancelled, failed_key, step_index, total_cost,
    );
    (current_stream_node_id, cancelled)
}
