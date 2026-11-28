//! `EngineClient` implementation for `InProcessEngine` (FFI-facing operations).

use super::{
    AgentRunRecord, AppHealthSnapshot, AppSettings, AssistantPatch, AssistantRecord, BistreError,
    BistreResult, BoxFuture, CORE_VERSION, CharacterCardRecord, CronJobRecord, CursorEventRecord,
    DiagnosticKey, DraftRecord, EngineClient, EngineEvent, InProcessEngine, MemoryEntryRecord,
    MoneyMicros, NodeRecord, NodeRole, Ordering, Path, PowerGuardStatus, PowerLeasePolicy,
    ProjectRecord, ProviderDialect, ProviderModelInfo, ProviderPatch, ProviderProfile,
    RegexRuleRecord, RunStepRecord, SearchHit, SignedPackManifest, SteeringMessage, StorageStats,
    StoryChapterRecord, StoryEntryRecord, StoryProgressionRecord, StorySceneRecord,
    StorySnapshotRecord, StoryThreadStateRecord, SystemPowerEvent, ThreadMode, ThreadPatch,
    ThreadSummary, UpdateCheckResult, UserPersonaRecord, WorkspaceCheckpointRecord, broadcast,
    credentials, hooks, mcp, ota, providers, skills, story, subagents, tools, verify_signed_pack,
};
use super::{AttachmentInput, ModelCatalogInfo, StorageFileEntry};
use crate::engine_runs::utc_day_start_unix_ms;
use crate::events::emit;
use crate::off_worker::off_worker;
use bistre_protocol::lock_or_recover;

/// Longest direction a guided Regenerate sends, in characters.
pub(crate) const MAX_REPLY_GUIDANCE_CHARS: usize = 2_000;

impl InProcessEngine {
    pub fn health(&self) -> BoxFuture<'_, BistreResult<AppHealthSnapshot>> {
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

    pub fn list_providers(&self) -> BoxFuture<'_, BistreResult<Vec<ProviderProfile>>> {
        Box::pin(async move {
            let list = self.storage.list_providers()?;
            Ok(list.into_iter().map(|p| self.hydrate_provider(p)).collect())
        })
    }

    pub fn update_provider(
        &self,
        provider_id: String,
        patch: ProviderPatch,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>> {
        Box::pin(async move {
            let updated = self.storage.update_provider(provider_id, patch)?;
            // Saved custom headers belong to one server: a new origin clears them.
            if crate::provider_prefs::drop_headers_if_origin_changed(
                &self.storage,
                &updated.id,
                &updated.base_url,
            )? {
                emit(
                    &self.events_tx,
                    EngineEvent::DiagnosticRaised {
                        key: DiagnosticKey::ProviderHeadersCleared,
                        detail_code: None,
                    },
                );
            }
            Ok(self.hydrate_provider(updated))
        })
    }

    pub fn set_provider_api_key(
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

            // Auto-select this provider if none is currently active, and trigger pricing
            // refresh now that a real provider is configured.
            let mut settings = self.storage.load_settings()?;
            if settings.pricing_auto_refresh {
                self.pricing.ensure_fresh(&self.web);
            }
            if settings.active_provider_id.trim().is_empty() {
                settings.active_provider_id = provider_id;
                self.storage.save_settings(settings)?;
            }

            Ok(self.hydrate_provider(updated))
        })
    }

    pub fn clear_provider_api_key(
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

    pub fn get_provider_api_keys(
        &self,
        provider_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<String>>> {
        Box::pin(async move { self.get_provider_api_keys_inner(&provider_id) })
    }

    pub fn lookup_model_catalog_info(
        &self,
        provider_id: String,
        model_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<ModelCatalogInfo>>> {
        Box::pin(async move {
            self.lookup_model_catalog_info_inner(&provider_id, &model_id)
                .await
        })
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "Explicit provider creation fields map directly across EngineClient implementations."
    )]
    pub fn create_provider(
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

    pub fn create_custom_provider(
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

    pub fn delete_provider(&self, provider_id: String) -> BoxFuture<'_, BistreResult<()>> {
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

    pub fn fetch_provider_models(
        &self,
        provider_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<ProviderModelInfo>>> {
        Box::pin(async move {
            let raw = self
                .storage
                .get_provider(&provider_id)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            let adv = crate::provider_prefs::load_provider_advanced(&self.storage, &provider_id);
            let profile = adv.speaking(&self.hydrate_provider(raw));
            let keys = self.load_key_ring(&provider_id)?;
            providers::fetch_models_with_auth(&self.http, &profile, &keys, adv.auth_mode).await
        })
    }

    pub fn list_assistants(&self) -> BoxFuture<'_, BistreResult<Vec<AssistantRecord>>> {
        Box::pin(async move { self.storage.list_assistants() })
    }

    pub fn create_assistant(
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

    pub fn update_assistant(
        &self,
        assistant_id: String,
        patch: AssistantPatch,
    ) -> BoxFuture<'_, BistreResult<AssistantRecord>> {
        Box::pin(async move { self.storage.update_assistant(assistant_id, patch) })
    }

    pub fn delete_assistant(&self, assistant_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.storage.delete_assistant(assistant_id.clone())?;
            self.storage.delete_kv_meta(format!(
                "{}{assistant_id}",
                crate::chat_extras::GREETING_KEY_PREFIX
            ))
        })
    }

    pub fn create_thread(
        &self,
        workspace_id: Option<String>,
        title: String,
        mode: ThreadMode,
        topic: Option<String>,
        assistant_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>> {
        Box::pin(async move {
            let thread = self.storage.create_thread(
                workspace_id,
                &title,
                mode,
                topic.as_deref(),
                assistant_id.as_deref(),
            )?;
            crate::chat_extras::open_with_greeting(&self.storage, thread)
        })
    }

    pub fn update_thread(
        &self,
        thread_id: String,
        patch: ThreadPatch,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>> {
        Box::pin(async move { self.storage.update_thread(thread_id, patch) })
    }

    pub fn delete_thread(&self, thread_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.cancel_active_run(thread_id.clone()).await?;
            lock_or_recover(&self.thread_auto_approvals, "approval_memory")
                .forget_thread(&thread_id);
            self.storage.delete_thread(thread_id)
        })
    }

    pub fn list_threads(
        &self,
        workspace_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<ThreadSummary>>> {
        Box::pin(async move { self.storage.list_threads(workspace_id.as_deref()) })
    }

    pub fn append_node(
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

    pub fn send_and_stream_reply(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        user_content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move {
            self.refresh_stale_mcp_tools();
            self.stop_previous_run(&thread_id).await;
            self.send_with_attachments_inner(thread_id, parent_id, &user_content, &[])
        })
    }

    pub fn send_and_stream_reply_with_attachments(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        user_content: String,
        attachments: Vec<AttachmentInput>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move {
            self.refresh_stale_mcp_tools();
            self.stop_previous_run(&thread_id).await;
            self.send_with_attachments_inner(thread_id, parent_id, &user_content, &attachments)
        })
    }

    pub fn steer_active_run_now(
        &self,
        thread_id: String,
        content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move { self.steer_active_run_now_inner(thread_id, &content) })
    }

    pub fn import_threads_json(&self, raw_json: String) -> BoxFuture<'_, BistreResult<u32>> {
        Box::pin(async move { self.import_threads_json_inner(&raw_json) })
    }

    pub fn export_settings_json(&self) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move { self.export_settings_json_inner() })
    }

    pub fn import_settings_json(
        &self,
        raw_json: String,
        allow_loosening: bool,
    ) -> BoxFuture<'_, BistreResult<AppSettings>> {
        Box::pin(async move { self.import_settings_json_inner(&raw_json, allow_loosening) })
    }

    pub fn list_storage_files(&self) -> BoxFuture<'_, BistreResult<Vec<StorageFileEntry>>> {
        Box::pin(async move { self.list_storage_files_inner() })
    }

    pub fn delete_storage_file(&self, rel_path: String) -> BoxFuture<'_, BistreResult<bool>> {
        Box::pin(async move { self.delete_storage_file_inner(&rel_path) })
    }

    pub fn clean_unused_storage_files(&self) -> BoxFuture<'_, BistreResult<u64>> {
        Box::pin(async move { self.clean_unused_storage_files_inner() })
    }

    pub fn synthesize_speech(
        &self,
        provider_id: String,
        model_id: String,
        text: String,
        voice: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<u8>>> {
        Box::pin(async move {
            self.synthesize_speech_inner(&provider_id, &model_id, &text, voice.as_deref())
                .await
        })
    }

    pub fn start_live_voice_session(
        &self,
        provider_id: String,
        model_id: String,
        voice: String,
        system_prompt: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            self.start_live_voice_session_inner(&provider_id, &model_id, voice, system_prompt)
                .await
        })
    }

    pub fn send_live_voice_pcm_chunk(
        &self,
        session_id: String,
        pcm_base64: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.live_voice.send_pcm_chunk(&session_id, pcm_base64) })
    }

    pub fn send_live_voice_text(
        &self,
        session_id: String,
        text: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.live_voice.send_text(&session_id, text) })
    }

    pub fn stop_live_voice_session(&self, session_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.live_voice.stop_session(&session_id);
            Ok(())
        })
    }

    pub fn regenerate_reply(
        &self,
        thread_id: String,
        user_node_id: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        self.regenerate_reply_guided(thread_id, user_node_id, String::new())
    }

    /// Regenerate whose reply follows `guidance` (at most `MAX_REPLY_GUIDANCE_CHARS`), sent
    /// with this reply's instructions only; empty guidance is a plain Regenerate.
    pub fn regenerate_reply_guided(
        &self,
        thread_id: String,
        user_node_id: String,
        guidance: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let guidance = guidance.trim();
            if guidance.chars().count() > MAX_REPLY_GUIDANCE_CHARS {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "guidance_length",
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

            let nodes = self.storage.list_nodes(&thread_id)?;
            if !nodes.iter().any(|n| n.id == user_node_id) {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            let system_prompt = thread
                .system_prompt_override
                .clone()
                .unwrap_or_else(|| assistant.map_or_default(|a| a.system_prompt));
            let mut system_prompt = crate::engine_runs::with_user_name(
                system_prompt,
                &settings.user_display_name,
                thread.mode,
            );
            if !guidance.is_empty() {
                system_prompt.push_str("\n\n[Direction for this reply]\n");
                system_prompt.push_str(guidance);
            }

            self.stop_previous_run(&thread_id).await;
            self.spawn_live_stream(
                &thread,
                user_node_id,
                provider,
                api_key,
                model,
                system_prompt,
                gen_params,
                settings.provider_stateless_default,
                crate::agent::RunApprovalPolicy::INTERACTIVE,
            )
        })
    }

    pub fn edit_user_node_and_stream(
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
            let preserved =
                crate::attachments::parse_node_attachments(original.provider_meta_json.as_deref());
            self.stop_previous_run(&thread_id).await;
            self.send_with_stored_attachments_inner(
                thread_id,
                original.parent_id,
                &new_content,
                &preserved,
                crate::agent::RunApprovalPolicy::INTERACTIVE,
            )
        })
    }

    pub fn delete_node(
        &self,
        thread_id: String,
        node_id: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move { self.storage.delete_node(thread_id, node_id) })
    }

    /// Copies the branch ending at `node_id` into a new chat (`StorageHandle::fork_thread`).
    pub fn fork_thread(
        &self,
        thread_id: String,
        node_id: String,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>> {
        Box::pin(off_worker(&self.storage, move |s| {
            s.fork_thread(
                &thread_id,
                &node_id,
                &[
                    crate::context_exclusion::KEY_PREFIX,
                    crate::goal::KEY_PREFIX,
                ],
            )
        }))
    }

    /// Removes `node_id` and every message after it, stopping the chat's reply first.
    pub fn delete_from_node(
        &self,
        thread_id: String,
        node_id: String,
    ) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.cancel_active_run(thread_id.clone()).await?;
            self.storage.delete_from_node(thread_id, node_id)
        })
    }

    /// Removes every message of a chat and keeps the chat, stopping its reply first.
    pub fn clear_thread_messages(&self, thread_id: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(async move {
            self.cancel_active_run(thread_id.clone()).await?;
            self.storage.clear_thread_messages(thread_id)
        })
    }

    pub fn export_thread(
        &self,
        thread_id: String,
        format: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(off_worker(&self.storage, move |s| {
            s.export_thread(&thread_id, &format)
        }))
    }

    pub fn backup_database(&self, dest_path: String) -> BoxFuture<'_, BistreResult<()>> {
        Box::pin(off_worker(&self.storage, move |s| {
            s.backup_database(Path::new(&dest_path))
        }))
    }

    pub fn storage_stats(&self) -> BoxFuture<'_, BistreResult<StorageStats>> {
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

    pub fn wallet_daily_spend_micros(&self) -> BoxFuture<'_, BistreResult<MoneyMicros>> {
        Box::pin(async move {
            self.storage
                .sum_wallet_spend_since_micros(utc_day_start_unix_ms())
        })
    }

    pub fn search_mcp_registry(
        &self,
        query: String,
        cursor: Option<String>,
    ) -> BoxFuture<'_, BistreResult<crate::mcp_registry::McpRegistryPage>> {
        Box::pin(async move {
            crate::mcp_registry::search_registry(&self.web, &query, cursor.as_deref()).await
        })
    }

    pub fn thread_spend_micros(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<MoneyMicros>> {
        Box::pin(async move { self.storage.thread_spend_micros(&thread_id) })
    }

    pub fn wallet_usage_by_purpose(
        &self,
        since_unix_ms: i64,
    ) -> BoxFuture<'_, BistreResult<Vec<bistre_protocol::PurposeUsage>>> {
        Box::pin(async move { self.storage.wallet_usage_by_purpose(since_unix_ms) })
    }

    pub fn check_for_updates(
        &self,
        feed_url_override: Option<String>,
    ) -> BoxFuture<'_, BistreResult<UpdateCheckResult>> {
        Box::pin(async move {
            let settings = self.storage.load_settings()?;
            let feed_url = feed_url_override
                .map(|u| u.trim().to_owned())
                .filter(|u| !u.is_empty())
                .unwrap_or(settings.ota_feed_url);
            let (summary, verified) = ota::check_for_updates_on_channel(
                &self.ota_http,
                &feed_url,
                CORE_VERSION,
                &settings.ota_channel,
                self.active_runs.load(Ordering::Relaxed),
                self.ota_release_key.get().map(String::as_str),
            )
            .await?;
            *lock_or_recover(&self.verified_update, "verified_update") = Some(verified);
            Ok(summary)
        })
    }

    pub fn stage_update(&self, check: UpdateCheckResult) -> BoxFuture<'_, BistreResult<String>> {
        self.stage_verified_update(check, false)
    }

    pub fn reinstall_update(
        &self,
        check: UpdateCheckResult,
    ) -> BoxFuture<'_, BistreResult<String>> {
        self.stage_verified_update(check, true)
    }

    pub fn cancel_active_run(&self, thread_id: String) -> BoxFuture<'_, BistreResult<bool>> {
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

    pub fn retry_run_now(&self, thread_id: String) -> BoxFuture<'_, BistreResult<bool>> {
        Box::pin(async move { Ok(self.wake_run(&thread_id)) })
    }

    pub fn list_nodes(&self, thread_id: String) -> BoxFuture<'_, BistreResult<Vec<NodeRecord>>> {
        Box::pin(off_worker(&self.storage, move |s| s.list_nodes(&thread_id)))
    }

    pub fn save_draft(
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

    pub fn load_draft(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<DraftRecord>>> {
        Box::pin(async move { self.storage.load_draft(&thread_id) })
    }

    pub fn load_settings(&self) -> BoxFuture<'_, BistreResult<AppSettings>> {
        Box::pin(async move { self.storage.load_settings() })
    }

    pub fn save_settings(&self, settings: AppSettings) -> BoxFuture<'_, BistreResult<AppSettings>> {
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

    pub fn wallet_spend_micros(&self) -> BoxFuture<'_, BistreResult<MoneyMicros>> {
        Box::pin(async move { self.storage.sum_wallet_spend_micros() })
    }

    pub fn search_nodes(
        &self,
        query: String,
        thread_id: Option<String>,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<SearchHit>>> {
        Box::pin(off_worker(&self.storage, move |s| {
            s.search_nodes(&query, thread_id.as_deref(), limit)
        }))
    }

    pub fn verify_data_pack(
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
}

/// Each `EngineClient` method runs the inherent method of the same name. The table in
/// `engine_rpc.rs` lists them all, so none can be missed: a missing one would call itself,
/// which the `unconditional_recursion` lint rejects.
macro_rules! in_process_methods {
    ($($wait:ident fn $name:ident ($($arg:ident : $ty:ty),* $(,)?) -> $ret:ty;)*) => {
        $(fn $name(&self, $($arg: $ty),*) -> BoxFuture<'_, BistreResult<$ret>> {
            InProcessEngine::$name(self, $($arg),*)
        })*
    };
}

impl EngineClient for InProcessEngine {
    crate::engine_rpc::with_engine_rpc_table!(in_process_methods);

    fn synthesize_speech(
        &self,
        provider_id: String,
        model_id: String,
        text: String,
        voice: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<u8>>> {
        InProcessEngine::synthesize_speech(self, provider_id, model_id, text, voice)
    }

    fn verify_data_pack(
        &self,
        public_key_b64: String,
        manifest_bytes: Vec<u8>,
        manifest_sig_text: String,
        pack_payload: Vec<u8>,
    ) -> BoxFuture<'_, BistreResult<SignedPackManifest>> {
        InProcessEngine::verify_data_pack(
            self,
            public_key_b64,
            manifest_bytes,
            manifest_sig_text,
            pack_payload,
        )
    }

    fn subscribe_events(&self) -> broadcast::Receiver<EngineEvent> {
        InProcessEngine::subscribe_events(self)
    }

    fn shutdown(&self) -> BoxFuture<'_, BistreResult<()>> {
        InProcessEngine::shutdown(self)
    }
}

pub(crate) fn parse_tool_args(arguments_json: &str) -> BistreResult<serde_json::Value> {
    serde_json::from_str(arguments_json)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "tool_args_json"))
}
