//! `EngineClient` implementation for `InProcessEngine` (FFI-facing operations).

use super::{
    AgentRunRecord, AppHealthSnapshot, AppSettings, AssistantPatch, AssistantRecord, BistreError,
    BistreResult, BoxFuture, CORE_VERSION, CharacterCardRecord, CronJobRecord, CursorEventRecord,
    DiagnosticKey, DraftRecord, EngineClient, EngineEvent, InProcessEngine, MemoryEntryRecord,
    MoneyMicros, NodeRecord, NodeRole, Ordering, Path, PathBuf, PowerGuardStatus, PowerLeasePolicy,
    ProviderDialect, ProviderModelInfo, ProviderPatch, ProviderProfile, RegexRuleRecord,
    RunStepRecord, SearchHit, SignedPackManifest, SteeringMessage, StorageStats,
    StoryChapterRecord, StoryEntryRecord, StoryProgressionRecord, StorySceneRecord,
    StorySnapshotRecord, StoryThreadStateRecord, SystemPowerEvent, ThreadMode, ThreadPatch,
    ThreadSummary, ToolRiskTier, UpdateCheckResult, UserPersonaRecord, WorkspaceCheckpointRecord,
    WorkspaceSummary, agent, broadcast, compaction, credentials, cron, hooks, import_policy, mcp,
    ota, providers, skills, story, subagents, tools, verify_signed_pack,
};
use crate::engine_runs::{utc_day_start_unix_ms, utc_now_unix_ms};
use crate::events::{emit, emit_logged, note_write};
use crate::off_worker::off_worker;
use bistre_protocol::lock_or_recover;

impl EngineClient for InProcessEngine {
    fn health(&self) -> BoxFuture<'_, BistreResult<AppHealthSnapshot>> {
        Box::pin(async move {
            let h = self.storage.health()?;
            Ok(AppHealthSnapshot {
                core_version: CORE_VERSION.to_owned(),
                schema_version: h.schema_version,
                wal_mode_active: h.wal_mode_active,
                thread_count: h.thread_count,
                node_count: h.node_count,
                active_runs: self.active_runs.load(Ordering::Relaxed),
                status_key: DiagnosticKey::Ok,
            })
        })
    }

    fn list_workspaces(&self) -> BoxFuture<'_, BistreResult<Vec<WorkspaceSummary>>> {
        Box::pin(async move { self.storage.list_workspaces() })
    }

    fn list_providers(&self) -> BoxFuture<'_, BistreResult<Vec<ProviderProfile>>> {
        Box::pin(async move {
            let list = self.storage.list_providers()?;
            Ok(list.into_iter().map(|p| self.hydrate_provider(p)).collect())
        })
    }

    fn update_provider(
        &self,
        provider_id: String,
        patch: ProviderPatch,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>> {
        Box::pin(async move {
            let updated = self.storage.update_provider(provider_id, patch)?;
            Ok(self.hydrate_provider(updated))
        })
    }

    fn set_provider_api_key(
        &self,
        provider_id: String,
        api_key: String,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>> {
        Box::pin(async move {
            // Several keys may be pasted at once (one per line); each is sanitized of
            // control/zero-width characters and they rotate round-robin per request.
            let keys = credentials::parse_api_keys(&api_key);
            let clean = credentials::encode_api_keys(&keys);
            if clean.is_empty() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "empty_api_key",
                ));
            }
            let _existing = self
                .storage
                .get_provider(&provider_id)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;

            self.vault
                .put(&Self::vault_key(&provider_id), clean.as_bytes())?;
            let hint = credentials::key_hint_for(&keys);
            let updated = self.storage.update_provider(
                provider_id.clone(),
                ProviderPatch {
                    key_hint: Some(hint),
                    is_enabled: Some(true),
                    ..ProviderPatch::default()
                },
            )?;

            // Auto-select this provider if none is currently active.
            let mut settings = self.storage.load_settings()?;
            if settings.active_provider_id.trim().is_empty() {
                settings.active_provider_id = provider_id;
                self.storage.save_settings(settings)?;
            }

            Ok(self.hydrate_provider(updated))
        })
    }

    fn clear_provider_api_key(
        &self,
        provider_id: String,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>> {
        Box::pin(async move {
            self.vault.delete(&Self::vault_key(&provider_id))?;
            let updated = self.storage.update_provider(
                provider_id,
                ProviderPatch {
                    key_hint: Some(String::new()),
                    ..ProviderPatch::default()
                },
            )?;
            Ok(self.hydrate_provider(updated))
        })
    }

    fn create_provider(
        &self,
        name: String,
        dialect: ProviderDialect,
        base_url: String,
        default_model: String,
        icon_slug: String,
        custom_icon_path: String,
        api_key: Option<String>,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>> {
        Box::pin(async move {
            let mut created = self.storage.create_provider(
                &name,
                dialect,
                &base_url,
                &default_model,
                &icon_slug,
                &custom_icon_path,
            )?;
            if let Some(raw_key) = api_key {
                let keys = credentials::parse_api_keys(&raw_key);
                let clean = credentials::encode_api_keys(&keys);
                if !clean.is_empty() {
                    self.vault
                        .put(&Self::vault_key(&created.id), clean.as_bytes())?;
                    let hint = credentials::key_hint_for(&keys);
                    created = self.storage.update_provider(
                        created.id,
                        ProviderPatch {
                            key_hint: Some(hint),
                            ..ProviderPatch::default()
                        },
                    )?;
                }
            }
            let mut settings = self.storage.load_settings()?;
            if settings.active_provider_id.trim().is_empty() {
                settings.active_provider_id.clone_from(&created.id);
                if !created.default_model.is_empty() {
                    settings.active_model_id.clone_from(&created.default_model);
                }
                self.storage.save_settings(settings)?;
            }
            Ok(self.hydrate_provider(created))
        })
    }

    fn create_custom_provider(
        &self,
        name: String,
        base_url: String,
        default_model: String,
        api_key: Option<String>,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>> {
        self.create_provider(
            name,
            ProviderDialect::CustomOpenAi,
            base_url,
            default_model,
            String::new(),
            String::new(),
            api_key,
        )
    }

    fn delete_provider(&self, provider_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.storage.delete_provider(provider_id.clone())?;
            self.vault.delete(&Self::vault_key(&provider_id))?;
            let mut settings = self.storage.load_settings()?;
            if settings.active_provider_id == provider_id {
                settings.active_provider_id.clear();
                settings.active_model_id.clear();
                self.storage.save_settings(settings)?;
            }
            Ok(())
        })
    }

    fn fetch_provider_models(
        &self,
        provider_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<ProviderModelInfo>>> {
        Box::pin(async move {
            let raw = self
                .storage
                .get_provider(&provider_id)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            let profile = self.hydrate_provider(raw);
            let keys = self.load_key_ring(&provider_id)?;
            providers::fetch_models(&self.http, &profile, &keys).await
        })
    }

    fn list_assistants(&self) -> BoxFuture<'_, BistreResult<Vec<AssistantRecord>>> {
        Box::pin(async move { self.storage.list_assistants() })
    }

    fn create_assistant(
        &self,
        name: String,
        role_subtitle: String,
        system_prompt: String,
        default_mode: ThreadMode,
        badge_code: String,
    ) -> BoxFuture<'_, BistreResult<AssistantRecord>> {
        Box::pin(async move {
            self.storage.create_assistant(
                &name,
                &role_subtitle,
                &system_prompt,
                default_mode,
                &badge_code,
            )
        })
    }

    fn update_assistant(
        &self,
        assistant_id: String,
        patch: AssistantPatch,
    ) -> BoxFuture<'_, BistreResult<AssistantRecord>> {
        Box::pin(async move { self.storage.update_assistant(assistant_id, patch) })
    }

    fn delete_assistant(&self, assistant_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_assistant(assistant_id) })
    }

    fn create_thread(
        &self,
        workspace_id: Option<String>,
        title: String,
        mode: ThreadMode,
        topic: Option<String>,
        assistant_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>> {
        Box::pin(async move {
            self.storage.create_thread(
                workspace_id,
                &title,
                mode,
                topic.as_deref(),
                assistant_id.as_deref(),
            )
        })
    }

    fn update_thread(
        &self,
        thread_id: String,
        patch: ThreadPatch,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>> {
        Box::pin(async move { self.storage.update_thread(thread_id, patch) })
    }

    fn delete_thread(&self, thread_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.cancel_active_run(thread_id.clone()).await?;
            self.storage.delete_thread(thread_id)
        })
    }

    fn list_threads(
        &self,
        workspace_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<ThreadSummary>>> {
        Box::pin(async move { self.storage.list_threads(workspace_id.as_deref()) })
    }

    fn append_node(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        role: NodeRole,
        content: String,
        provider_meta_json: Option<String>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move {
            let node = self.storage.append_node(
                thread_id,
                parent_id,
                role,
                content,
                provider_meta_json,
            )?;
            emit(
                &self.events_tx,
                EngineEvent::NodeCommitted { node: node.clone() },
            );
            Ok(node)
        })
    }

    fn send_and_stream_reply(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        user_content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move {
            let trimmed = user_content.trim().to_owned();
            if trimmed.is_empty() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "empty_message",
                ));
            }
            let settings = self.storage.load_settings()?;
            let thread = self
                .storage
                .get_thread(&thread_id)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            let assistant = self
                .storage
                .list_assistants()?
                .into_iter()
                .find(|a| a.id == thread.assistant_id);
            let (provider, api_key, model, gen_params) =
                self.resolve_execution_target(&settings, &thread, assistant.as_ref())?;
            self.enforce_wallet_shield(&settings, &provider)?;

            let system_prompt = thread
                .system_prompt_override
                .clone()
                .unwrap_or_else(|| assistant.map_or_default(|a| a.system_prompt));

            let user_node = self.storage.append_node(
                thread_id.clone(),
                parent_id,
                NodeRole::User,
                trimmed,
                None,
            )?;
            emit(
                &self.events_tx,
                EngineEvent::NodeCommitted {
                    node: user_node.clone(),
                },
            );
            note_write(
                "draft_clear",
                self.storage.save_draft(thread_id, String::new()),
            );
            self.spawn_live_stream(
                &thread,
                user_node.id.clone(),
                provider,
                api_key,
                model,
                system_prompt,
                gen_params,
                settings.provider_stateless_default,
            )?;
            Ok(user_node)
        })
    }

    fn regenerate_reply(
        &self,
        thread_id: String,
        user_node_id: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let settings = self.storage.load_settings()?;
            let thread = self
                .storage
                .get_thread(&thread_id)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            let assistant = self
                .storage
                .list_assistants()?
                .into_iter()
                .find(|a| a.id == thread.assistant_id);
            let (provider, api_key, model, gen_params) =
                self.resolve_execution_target(&settings, &thread, assistant.as_ref())?;
            self.enforce_wallet_shield(&settings, &provider)?;

            let nodes = self.storage.list_nodes(&thread_id)?;
            if !nodes.iter().any(|n| n.id == user_node_id) {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            let system_prompt = thread
                .system_prompt_override
                .clone()
                .unwrap_or_else(|| assistant.map_or_default(|a| a.system_prompt));

            self.spawn_live_stream(
                &thread,
                user_node_id,
                provider,
                api_key,
                model,
                system_prompt,
                gen_params,
                settings.provider_stateless_default,
            )
        })
    }

    fn edit_user_node_and_stream(
        &self,
        thread_id: String,
        node_id: String,
        new_content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move {
            let nodes = self.storage.list_nodes(&thread_id)?;
            let original = nodes
                .into_iter()
                .find(|n| n.id == node_id)
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            self.send_and_stream_reply(thread_id, original.parent_id, new_content)
                .await
        })
    }

    fn delete_node(&self, thread_id: String, node_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_node(thread_id, node_id) })
    }

    fn export_thread(
        &self,
        thread_id: String,
        format: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(off_worker(&self.storage, move |s| {
            s.export_thread(&thread_id, &format)
        }))
    }

    fn backup_database(&self, dest_path: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(off_worker(&self.storage, move |s| {
            s.backup_database(Path::new(&dest_path))
        }))
    }

    fn storage_stats(&self) -> BoxFuture<'_, BistreResult<StorageStats>> {
        Box::pin(async move {
            let h = self.storage.health()?;
            Ok(StorageStats {
                data_dir: self.data_dir.to_string_lossy().into_owned(),
                db_size_bytes: self.storage.storage_file_size_bytes(),
                core_version: CORE_VERSION.to_owned(),
                schema_version: h.schema_version,
                wal_mode_active: h.wal_mode_active,
                thread_count: h.thread_count,
                node_count: h.node_count,
                active_runs: self.active_runs.load(Ordering::Relaxed),
            })
        })
    }

    fn wallet_daily_spend_micros(&self) -> BoxFuture<'_, BistreResult<MoneyMicros>> {
        Box::pin(async move {
            self.storage
                .sum_wallet_spend_since_micros(utc_day_start_unix_ms())
        })
    }

    fn check_for_updates(
        &self,
        feed_url_override: Option<String>,
    ) -> BoxFuture<'_, BistreResult<UpdateCheckResult>> {
        Box::pin(async move {
            let settings = self.storage.load_settings()?;
            let feed_url = feed_url_override
                .map(|u| u.trim().to_owned())
                .filter(|u| !u.is_empty())
                .unwrap_or(settings.ota_feed_url);
            let (summary, verified) = ota::check_for_updates(
                &self.http,
                &feed_url,
                CORE_VERSION,
                self.active_runs.load(Ordering::Relaxed),
                self.ota_release_key.get().map(String::as_str),
            )
            .await?;
            *lock_or_recover(&self.verified_update, "verified_update") = Some(verified);
            Ok(summary)
        })
    }

    fn stage_update(&self, check: UpdateCheckResult) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            // The UI only chooses *which* checked version to stage; every URL, digest, and size
            // comes from the core-held signed manifest.
            let verified = lock_or_recover(&self.verified_update, "verified_update")
                .clone()
                .filter(|m| m.latest_version() == check.latest_version)
                .ok_or_else(|| {
                    BistreError::with_detail(
                        DiagnosticKey::OtaIntegrityFailed,
                        "ota_manifest_unverified",
                    )
                })?;
            ota::stage_update_artifact(
                &self.http,
                &self.data_dir,
                &verified,
                self.active_runs.load(Ordering::Relaxed),
            )
            .await
        })
    }

    fn cancel_active_run(&self, thread_id: String) -> BoxFuture<'_, BistreResult<bool>> {
        Box::pin(async move {
            let guard = lock_or_recover(&self.cancellations, "cancellations");
            if let Some(flag) = guard.get(&thread_id) {
                flag.store(true, Ordering::SeqCst);
                self.wake_run(&thread_id);
                return Ok(true);
            }
            Ok(false)
        })
    }

    fn retry_run_now(&self, thread_id: String) -> BoxFuture<'_, BistreResult<bool>> {
        Box::pin(async move { Ok(self.wake_run(&thread_id)) })
    }

    fn list_nodes(&self, thread_id: String) -> BoxFuture<'_, BistreResult<Vec<NodeRecord>>> {
        Box::pin(off_worker(&self.storage, move |s| s.list_nodes(&thread_id)))
    }

    fn save_draft(
        &self,
        thread_id: String,
        text: String,
    ) -> BoxFuture<'_, BistreResult<DraftRecord>> {
        Box::pin(async move {
            let draft = self.storage.save_draft(thread_id.clone(), text)?;
            emit(
                &self.events_tx,
                EngineEvent::DraftSaved {
                    thread_id,
                    updated_at_ms: draft.updated_at_ms,
                },
            );
            Ok(draft)
        })
    }

    fn load_draft(&self, thread_id: String) -> BoxFuture<'_, BistreResult<Option<DraftRecord>>> {
        Box::pin(async move { self.storage.load_draft(&thread_id) })
    }

    fn load_settings(&self) -> BoxFuture<'_, BistreResult<AppSettings>> {
        Box::pin(async move { self.storage.load_settings() })
    }

    fn save_settings(&self, settings: AppSettings) -> BoxFuture<'_, BistreResult<AppSettings>> {
        Box::pin(async move {
            let saved = self.storage.save_settings(settings)?;
            // Any settings change may alter tool permissions: revoke outstanding permits now.
            self.broker.invalidate();
            let status = self.power.update_policy(PowerLeasePolicy {
                keep_awake_while_running: saved.keep_awake_while_running,
                windows_keep_awake_on_battery: saved.windows_keep_awake_on_battery,
            });
            emit(&self.events_tx, EngineEvent::PowerStatusChanged { status });
            Ok(saved)
        })
    }

    fn wallet_spend_micros(&self) -> BoxFuture<'_, BistreResult<MoneyMicros>> {
        Box::pin(async move { self.storage.sum_wallet_spend_micros() })
    }

    fn search_nodes(
        &self,
        query: String,
        thread_id: Option<String>,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<SearchHit>>> {
        Box::pin(off_worker(&self.storage, move |s| {
            s.search_nodes(&query, thread_id.as_deref(), limit)
        }))
    }

    fn verify_data_pack(
        &self,
        public_key_b64: String,
        manifest_bytes: Vec<u8>,
        manifest_sig_text: String,
        pack_payload: Vec<u8>,
    ) -> BoxFuture<'_, BistreResult<SignedPackManifest>> {
        Box::pin(async move {
            let manifest = verify_signed_pack(
                &public_key_b64,
                &manifest_bytes,
                &manifest_sig_text,
                &pack_payload,
            )?;
            emit(
                &self.events_tx,
                EngineEvent::LocalePackVerified {
                    pack_id: manifest.pack_id.clone(),
                    semver: manifest.semver.clone(),
                },
            );
            Ok(manifest)
        })
    }

    fn list_agent_runs(
        &self,
        thread_id: Option<String>,
        only_active: bool,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<AgentRunRecord>>> {
        Box::pin(async move {
            self.storage
                .list_agent_runs(thread_id.as_deref(), only_active, limit)
        })
    }

    fn list_run_steps(&self, run_id: String) -> BoxFuture<'_, BistreResult<Vec<RunStepRecord>>> {
        Box::pin(async move { self.storage.list_run_steps(&run_id) })
    }

    fn enqueue_steering(
        &self,
        thread_id: String,
        content: String,
    ) -> BoxFuture<'_, BistreResult<SteeringMessage>> {
        Box::pin(async move {
            let active_run_id = self
                .storage
                .list_agent_runs(Some(&thread_id), true, 1)?
                .into_iter()
                .next()
                .map(|r| r.id);
            let msg = self.storage.enqueue_steering_message(
                thread_id.clone(),
                active_run_id,
                &content,
                "[]".to_owned(),
            )?;
            let pending_count =
                u32::try_from(self.storage.list_pending_steering(&thread_id)?.len())
                    .unwrap_or(u32::MAX);
            let ev = EngineEvent::SteeringQueueChanged {
                thread_id: thread_id.clone(),
                pending_count,
            };
            emit_logged(&self.storage, &self.events_tx, Some(thread_id), ev);
            Ok(msg)
        })
    }

    fn list_pending_steering(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<SteeringMessage>>> {
        Box::pin(async move { self.storage.list_pending_steering(&thread_id) })
    }

    fn delete_steering(&self, steering_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_steering_message(steering_id) })
    }

    fn power_guard_status(&self) -> BoxFuture<'_, BistreResult<PowerGuardStatus>> {
        Box::pin(async move { Ok(self.power.status()) })
    }

    fn notify_power_event(&self, event: SystemPowerEvent) -> BoxFuture<'_, BistreResult<u32>> {
        Box::pin(async move {
            self.power.notify_system_event(event);
            let settings = self.storage.load_settings()?;
            let spent = self
                .storage
                .sum_wallet_spend_since_micros(utc_day_start_unix_ms())?;
            let actions =
                agent::handle_power_event(&self.storage, &settings, &self.events_tx, event, spent)?;
            emit(
                &self.events_tx,
                EngineEvent::PowerStatusChanged {
                    status: self.power.status(),
                },
            );
            Ok(u32::try_from(actions.len()).unwrap_or(u32::MAX))
        })
    }

    fn set_android_power_state(
        &self,
        fgs_active: bool,
        battery_unrestricted: bool,
    ) -> BoxFuture<'_, BistreResult<PowerGuardStatus>> {
        Box::pin(async move {
            self.power
                .set_android_power_state(fgs_active, battery_unrestricted);
            let status = self.power.status();
            emit(
                &self.events_tx,
                EngineEvent::PowerStatusChanged {
                    status: status.clone(),
                },
            );
            Ok(status)
        })
    }

    fn resolve_indeterminate_run(
        &self,
        run_id: String,
        confirm_completed: bool,
    ) -> BoxFuture<'_, BistreResult<AgentRunRecord>> {
        Box::pin(async move {
            agent::resolve_indeterminate_run(
                &self.storage,
                &self.events_tx,
                run_id,
                confirm_completed,
            )
        })
    }

    fn replay_events_after(
        &self,
        after_cursor: u64,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<CursorEventRecord>>> {
        Box::pin(async move { self.storage.read_engine_events_after(after_cursor, limit) })
    }

    fn latest_event_cursor(&self) -> BoxFuture<'_, BistreResult<u64>> {
        Box::pin(async move { self.storage.latest_event_cursor() })
    }

    fn model_context_tokens(&self, model: String) -> BoxFuture<'_, BistreResult<Option<u32>>> {
        Box::pin(async move {
            Ok(self
                .pricing
                .snapshot()
                .lookup(&model)
                .and_then(|r| r.context_tokens))
        })
    }

    fn refresh_prices(&self) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.pricing.force_refresh(&self.web);
            Ok(())
        })
    }

    fn approve_tool_call(
        &self,
        thread_id: String,
        tool_name: String,
        arguments_json: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let args = parse_tool_args(&arguments_json)?;
            if tools::classify_tool_risk(&tool_name, &args) == ToolRiskTier::Tier3Blocked {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ToolTierBlocked,
                    "tier3_blocked",
                ));
            }
            self.broker.approve(&thread_id, &tool_name, &args)
        })
    }

    fn execute_workspace_tool(
        &self,
        workspace_root: String,
        thread_id: String,
        tool_name: String,
        arguments_json: String,
        permit_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<tools::ToolExecutionOutput>> {
        Box::pin(async move {
            let args = parse_tool_args(&arguments_json)?;
            let risk = tools::classify_tool_risk(&tool_name, &args);
            if risk == ToolRiskTier::Tier3Blocked {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ToolTierBlocked,
                    "tier3_blocked",
                ));
            }
            // Tier 0 is auto-approved by core policy; anything else must present the permit the
            // user's approval produced, for exactly these arguments and this policy revision.
            let permit = if risk == ToolRiskTier::Tier0ReadOnly {
                self.broker.issue(&thread_id, &tool_name, &args)
            } else {
                let id = permit_id.ok_or_else(|| {
                    BistreError::with_detail(DiagnosticKey::ToolApprovalRequired, "permit_missing")
                })?;
                self.broker.take_approved(&id)?
            };
            self.broker.claim(&permit, &thread_id, &tool_name, &args)?;
            let root_path = PathBuf::from(&workspace_root);
            match tool_name.as_str() {
                "read" => {
                    let rel = args
                        .get("path")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                    let start = args
                        .get("start_line")
                        .and_then(serde_json::Value::as_u64)
                        .and_then(|v| usize::try_from(v).ok());
                    let end = args
                        .get("end_line")
                        .and_then(serde_json::Value::as_u64)
                        .and_then(|v| usize::try_from(v).ok());
                    let out = tools::tool_read(&root_path, rel, start, end)?;
                    if let Ok(digest) = tools::file_digest(&root_path, rel) {
                        self.read_ledger.record(&thread_id, rel, &digest);
                    }
                    Ok(out)
                }
                "edit" => {
                    let rel = args
                        .get("path")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                    let target = args
                        .get("target")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                    let replacement = args
                        .get("replacement")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                    let expected_hash = args
                        .get("expected_hash")
                        .and_then(serde_json::Value::as_str);
                    let current = tools::file_digest(&root_path, rel)?;
                    self.read_ledger.check_fresh(&thread_id, rel, &current)?;
                    let out = tools::tool_edit(
                        &self.storage,
                        &root_path,
                        &thread_id,
                        None,
                        rel,
                        target,
                        replacement,
                        expected_hash,
                    )?;
                    if let Ok(digest) = tools::file_digest(&root_path, rel) {
                        self.read_ledger.record(&thread_id, rel, &digest);
                    }
                    Ok(out)
                }
                "grep" => {
                    let pattern = args
                        .get("pattern")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                    let subpath = args.get("subpath").and_then(serde_json::Value::as_str);
                    tools::tool_grep(&root_path, pattern, subpath)
                }
                "glob" => {
                    let pattern = args
                        .get("pattern")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                    tools::tool_glob(&root_path, pattern)
                }
                "shell" => {
                    let cmd = args
                        .get("command")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                    let timeout_secs = args
                        .get("timeout_secs")
                        .and_then(serde_json::Value::as_u64)
                        .unwrap_or(60);
                    tools::tool_shell(&root_path, cmd, timeout_secs).await
                }
                "web_fetch" => {
                    let url = args
                        .get("url")
                        .and_then(serde_json::Value::as_str)
                        .ok_or_else(|| BistreError::new(DiagnosticKey::InvalidInput))?;
                    tools::tool_web_fetch(&self.web, url).await
                }
                _ => Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "unknown_tool",
                )),
            }
        })
    }

    fn rewind_checkpoint(
        &self,
        workspace_root: String,
        checkpoint_id: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            tools::tool_rewind_checkpoint(&self.storage, Path::new(&workspace_root), &checkpoint_id)
        })
    }

    fn list_checkpoints(
        &self,
        thread_id: String,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<WorkspaceCheckpointRecord>>> {
        Box::pin(async move {
            let mut cps = self.storage.list_workspace_checkpoints(&thread_id)?;
            let max = usize::try_from(limit).unwrap_or(50);
            if cps.len() > max {
                cps.truncate(max);
            }
            Ok(cps)
        })
    }

    fn compact_thread(
        &self,
        thread_id: String,
        keep_recent_turns: u32,
        custom_summary: Option<String>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move {
            let nodes = self.storage.list_nodes(&thread_id)?;
            let keep = usize::try_from(keep_recent_turns).unwrap_or(4);
            let node = compaction::create_reversible_compaction(
                &self.storage,
                &thread_id,
                &nodes,
                keep,
                custom_summary.as_deref(),
            )?;
            let ev = EngineEvent::NodeCommitted { node: node.clone() };
            emit_logged(&self.storage, &self.events_tx, Some(thread_id), ev);
            Ok(node)
        })
    }

    fn undo_compaction(
        &self,
        thread_id: String,
        compaction_node_id: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            compaction::undo_compaction(&self.storage, &thread_id, &compaction_node_id)
        })
    }

    fn set_context_start_pin(
        &self,
        thread_id: String,
        node_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Option<String>>> {
        Box::pin(async move {
            let key = format!("thread_context_start:{thread_id}");
            if let Some(id) = node_id
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty())
            {
                self.storage.set_kv_meta(key, id.clone())?;
                Ok(Some(id))
            } else {
                self.storage.delete_kv_meta(key)?;
                Ok(None)
            }
        })
    }

    fn get_context_start_pin(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<String>>> {
        Box::pin(async move {
            let key = format!("thread_context_start:{thread_id}");
            self.storage.get_kv_meta(&key)
        })
    }

    fn discover_local_servers(
        &self,
    ) -> BoxFuture<'_, BistreResult<Vec<providers::LocalServerDiscovery>>> {
        Box::pin(async move { Ok(providers::discover_local_servers().await) })
    }

    fn discover_mcp_server(
        &self,
        server: mcp::McpServerConfig,
    ) -> BoxFuture<'_, BistreResult<mcp::McpDiscoveryReport>> {
        Box::pin(async move { mcp::discover_http_mcp_server(&self.mcp_http, &server).await })
    }

    fn call_mcp_tool(
        &self,
        server: mcp::McpServerConfig,
        tool_name: String,
        arguments_json: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let args: serde_json::Value = serde_json::from_str(&arguments_json)
                .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "mcp_args"))?;
            mcp::call_http_mcp_tool(&self.mcp_http, &server, &tool_name, &args).await
        })
    }

    fn get_kv_meta(&self, key: String) -> BoxFuture<'_, BistreResult<Option<String>>> {
        Box::pin(async move { self.storage.get_kv_meta(&key) })
    }

    fn set_kv_meta(&self, key: String, value: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.set_kv_meta(key, value) })
    }

    fn list_memory_entries(
        &self,
        scope: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<MemoryEntryRecord>>> {
        Box::pin(async move { self.storage.list_memory_entries(scope.as_deref()) })
    }

    fn upsert_memory_entry(
        &self,
        id: Option<String>,
        scope: String,
        scope_id: String,
        key: String,
        content: String,
        pinned: bool,
    ) -> BoxFuture<'_, BistreResult<MemoryEntryRecord>> {
        Box::pin(async move {
            self.storage
                .upsert_memory_entry(id, scope, scope_id, key, content, None, pinned)
        })
    }

    fn delete_memory_entry(&self, entry_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_memory_entry(entry_id) })
    }

    fn discover_workspace_skills(
        &self,
        workspace_root: String,
    ) -> BoxFuture<'_, BistreResult<Vec<skills::SkillIndexEntry>>> {
        Box::pin(async move {
            Ok(skills::discover_workspace_skills(Path::new(
                &workspace_root,
            )))
        })
    }

    fn load_skill_body(
        &self,
        workspace_root: String,
        skill_path: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            skills::load_skill_body(Path::new(&workspace_root), Path::new(&skill_path))
        })
    }

    fn list_workspace_hooks(
        &self,
        workspace_root: String,
    ) -> BoxFuture<'_, BistreResult<Vec<hooks::WorkspaceHookConfig>>> {
        Box::pin(async move { hooks::load_workspace_hooks(Path::new(&workspace_root)) })
    }

    fn list_cron_jobs(&self) -> BoxFuture<'_, BistreResult<Vec<CronJobRecord>>> {
        Box::pin(async move { self.storage.list_cron_jobs() })
    }

    fn upsert_cron_job(
        &self,
        mut job: CronJobRecord,
    ) -> BoxFuture<'_, BistreResult<CronJobRecord>> {
        Box::pin(async move {
            if job.next_run_ms <= 0 {
                job.next_run_ms =
                    cron::compute_next_run_unix_ms(&job.schedule_expr, utc_now_unix_ms())?;
            }
            self.storage.upsert_cron_job(job)
        })
    }

    fn delete_cron_job(&self, job_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_cron_job(job_id) })
    }

    fn prepare_subagent_sandbox(
        &self,
        workspace_root: String,
    ) -> BoxFuture<'_, BistreResult<subagents::SubagentSandbox>> {
        Box::pin(async move {
            let scratch = self.data_dir.join("worktrees");
            subagents::prepare_worktree_sandbox(Path::new(&workspace_root), &scratch).await
        })
    }

    fn list_character_cards(&self) -> BoxFuture<'_, BistreResult<Vec<CharacterCardRecord>>> {
        Box::pin(async move { self.storage.list_character_cards() })
    }

    fn upsert_character_card(
        &self,
        card: CharacterCardRecord,
    ) -> BoxFuture<'_, BistreResult<CharacterCardRecord>> {
        Box::pin(async move { self.storage.upsert_character_card(card) })
    }

    fn delete_character_card(&self, card_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_character_card(card_id) })
    }

    fn import_character_card_file(
        &self,
        file_path: String,
    ) -> BoxFuture<'_, BistreResult<CharacterCardRecord>> {
        Box::pin(async move {
            let path = Path::new(&file_path);
            let raw = std::fs::read(path).map_err(|_| {
                BistreError::with_detail(DiagnosticKey::StorageNotFound, "card_read")
            })?;
            let bundle = if path
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("png"))
            {
                story::card_io::import_card_png(&raw)?
            } else if path.extension().is_some_and(|ext| {
                ext.eq_ignore_ascii_case("charx") || ext.eq_ignore_ascii_case("zip")
            }) {
                story::card_io::import_card_charx(&raw)?
            } else {
                let text = String::from_utf8(raw).map_err(|_| {
                    BistreError::with_detail(DiagnosticKey::InvalidInput, "card_utf8")
                })?;
                story::card_io::import_card_json(&text)?
            };

            // Imported cards are data, never authority (Spec 06 import policy).
            let (bundle, policy) = import_policy::with_imported_permissions(bundle);
            if !policy.is_clean() {
                tracing::info!(
                    grants = policy.stripped_grants,
                    network_paths = policy.stripped_network_paths,
                    media_paths = policy.stripped_media_paths,
                    "import policy stripped untrusted card permissions"
                );
            }
            let saved_card = self.storage.upsert_character_card(bundle.card)?;
            for entry in bundle.lore_entries {
                self.storage.upsert_story_entry(entry)?;
            }
            Ok(saved_card)
        })
    }

    fn export_character_card_ccv3(&self, card_id: String) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let cards = self.storage.list_character_cards()?;
            let card = cards
                .into_iter()
                .find(|c| c.id == card_id)
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            let entries = self.storage.list_story_entries(None)?;
            Ok(story::card_io::export_card_ccv3_json(&card, &entries))
        })
    }

    fn list_user_personas(&self) -> BoxFuture<'_, BistreResult<Vec<UserPersonaRecord>>> {
        Box::pin(async move { self.storage.list_user_personas() })
    }

    fn upsert_user_persona(
        &self,
        persona: UserPersonaRecord,
    ) -> BoxFuture<'_, BistreResult<UserPersonaRecord>> {
        Box::pin(async move { self.storage.upsert_user_persona(persona) })
    }

    fn list_story_entries(
        &self,
        book_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<StoryEntryRecord>>> {
        Box::pin(async move { self.storage.list_story_entries(book_id.as_deref()) })
    }

    fn upsert_story_entry(
        &self,
        entry: StoryEntryRecord,
    ) -> BoxFuture<'_, BistreResult<StoryEntryRecord>> {
        Box::pin(async move { self.storage.upsert_story_entry(entry) })
    }

    fn delete_story_entry(&self, entry_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_story_entry(entry_id) })
    }

    fn list_story_progressions(
        &self,
        entry_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<StoryProgressionRecord>>> {
        Box::pin(async move { self.storage.list_story_progressions(entry_id.as_deref()) })
    }

    fn add_story_progression(
        &self,
        prog: StoryProgressionRecord,
    ) -> BoxFuture<'_, BistreResult<StoryProgressionRecord>> {
        Box::pin(async move { self.storage.add_story_progression(prog) })
    }

    fn list_story_chapters(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<StoryChapterRecord>>> {
        Box::pin(async move { self.storage.list_story_chapters(&thread_id) })
    }

    fn upsert_story_chapter(
        &self,
        chapter: StoryChapterRecord,
    ) -> BoxFuture<'_, BistreResult<StoryChapterRecord>> {
        Box::pin(async move { self.storage.upsert_story_chapter(chapter) })
    }

    fn list_story_scenes(
        &self,
        chapter_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<StorySceneRecord>>> {
        Box::pin(async move { self.storage.list_story_scenes(&chapter_id) })
    }

    fn upsert_story_scene(
        &self,
        scene: StorySceneRecord,
    ) -> BoxFuture<'_, BistreResult<StorySceneRecord>> {
        Box::pin(async move { self.storage.upsert_story_scene(scene) })
    }

    fn load_story_thread_state(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<StoryThreadStateRecord>> {
        Box::pin(async move { self.storage.load_story_thread_state(&thread_id) })
    }

    fn save_story_thread_state(
        &self,
        state: StoryThreadStateRecord,
    ) -> BoxFuture<'_, BistreResult<StoryThreadStateRecord>> {
        Box::pin(async move { self.storage.save_story_thread_state(state) })
    }

    fn list_regex_rules(&self) -> BoxFuture<'_, BistreResult<Vec<RegexRuleRecord>>> {
        Box::pin(async move { self.storage.list_regex_rules() })
    }

    fn upsert_regex_rule(
        &self,
        rule: RegexRuleRecord,
    ) -> BoxFuture<'_, BistreResult<RegexRuleRecord>> {
        Box::pin(async move { self.storage.upsert_regex_rule(rule) })
    }

    fn list_story_snapshots(
        &self,
        entity_type: String,
        entity_id: String,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<StorySnapshotRecord>>> {
        Box::pin(async move {
            self.storage
                .list_story_snapshots(&entity_type, &entity_id, limit)
        })
    }

    fn inspect_story_prompt(
        &self,
        thread_id: String,
        active_scene_beats: Option<String>,
    ) -> BoxFuture<'_, BistreResult<story::prompt_assembler::CompiledPromptReport>> {
        Box::pin(async move {
            let state = self.storage.load_story_thread_state(&thread_id)?;
            let all_cards = self.storage.list_character_cards()?;
            let active_cards: Vec<CharacterCardRecord> = if state.active_character_ids.is_empty() {
                all_cards.into_iter().take(1).collect()
            } else {
                all_cards
                    .into_iter()
                    .filter(|c| state.active_character_ids.contains(&c.id))
                    .collect()
            };
            let personas = self.storage.list_user_personas()?;
            let active_persona = state
                .user_persona_id
                .as_deref()
                .and_then(|pid| personas.iter().find(|p| p.id == pid))
                .or_else(|| personas.iter().find(|p| p.is_default))
                .or_else(|| personas.first());
            let entries = self.storage.list_story_entries(None)?;
            let progressions = self.storage.list_story_progressions(None)?;
            let chapters = self.storage.list_story_chapters(&thread_id)?;
            let nodes = self.storage.list_nodes(&thread_id)?;

            let base_system = self
                .storage
                .get_thread(&thread_id)?
                .and_then(|t| t.system_prompt_override)
                .unwrap_or_default();

            Ok(story::prompt_assembler::assemble_story_prompt(
                &base_system,
                &state,
                &active_cards,
                active_persona,
                &entries,
                &progressions,
                &chapters,
                &nodes,
                active_scene_beats.as_deref(),
                16_384,
            ))
        })
    }

    fn subscribe_events(&self) -> broadcast::Receiver<EngineEvent> {
        self.events_tx.subscribe()
    }

    fn shutdown(&self) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            {
                let guard = lock_or_recover(&self.cancellations, "cancellations");
                for flag in guard.values() {
                    flag.store(true, Ordering::SeqCst);
                }
            }
            // Let cancelled runs record their final state before storage closes (bounded).
            let mut runs = std::mem::take(&mut *lock_or_recover(&self.run_tasks, "run_tasks"));
            let drained = tokio::time::timeout(RUN_DRAIN_TIMEOUT, async {
                while runs.join_next().await.is_some() {}
            })
            .await;
            if drained.is_err() {
                tracing::warn!(
                    remaining = runs.len(),
                    "runs did not stop in time; aborting"
                );
                runs.abort_all();
            }
            self.storage.shutdown()?;
            Ok(())
        })
    }
}

/// Upper bound on how long shutdown waits for cancelled runs to finish.
const RUN_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

fn parse_tool_args(arguments_json: &str) -> BistreResult<serde_json::Value> {
    serde_json::from_str(arguments_json)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "tool_args_json"))
}
