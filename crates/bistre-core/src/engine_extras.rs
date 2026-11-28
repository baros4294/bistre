//! Extended `InProcessEngine` use cases (multi-key reveal, catalog lookup, multimodal attachments,
//! immediate steering, storage file manager, export/import, and live voice/TTS).

use std::path::Path;
use std::sync::atomic::Ordering;

use bistre_protocol::{
    AppSettings, AttachmentInput, BistreError, BistreResult, DiagnosticKey, EngineEvent,
    ModelCatalogInfo, MoneyMicros, NodeRecord, NodeRole, StorageFileEntry, UsageMetrics,
    lock_or_recover,
};

use crate::events::{emit, note_write};
use crate::{InProcessEngine, attachments, providers, storage_files, voice, wallet};

/// `unpriced_allowed` key for "Allow once" on read aloud and live voice, which are not chat runs.
pub(crate) const MEDIA_ALLOWANCE: &str = "media";

impl InProcessEngine {
    pub(crate) fn get_provider_api_keys_inner(
        &self,
        provider_id: &str,
    ) -> BistreResult<Vec<String>> {
        let ring = self.load_key_ring(provider_id)?;
        Ok(ring.all_keys())
    }

    /// The catalog's entry for `model_id` as `provider_id` serves it.
    pub(crate) async fn lookup_model_catalog_info_inner(
        &self,
        provider_id: &str,
        model_id: &str,
    ) -> BistreResult<Option<ModelCatalogInfo>> {
        let clean = model_id.trim();
        if clean.is_empty() {
            return Ok(None);
        }
        let scope = self.catalog_scope(provider_id)?;
        let rates = self.pricing.rates_for(&scope, clean).await;
        let extras = self
            .pricing
            .snapshot()
            .extras(clean)
            .cloned()
            .unwrap_or_default();
        // A model that writes no text has no token prices to fill in.
        Ok(rates.map(|r| {
            let tokens = r.writes_text();
            ModelCatalogInfo {
                context_window: r.context_tokens,
                max_output_tokens: r.max_output_tokens,
                input_per_mtok_micros: tokens.then_some(r.input_per_mtok),
                output_per_mtok_micros: tokens.then_some(r.output_per_mtok),
                cached_input_per_mtok_micros: r.cached_input_per_mtok,
                cache_write_per_mtok_micros: r.cache_write_per_mtok,
                cache_write_1h_per_mtok_micros: r.cache_write_1h_per_mtok,
                reasoning: r.reasoning,
                writes_text: tokens,
                aspect_ratios: extras.aspect_ratios,
                resolutions: extras.resolutions,
                durations_s: extras.durations_s,
            }
        }))
    }

    /// The catalog scope of a saved provider; an unknown id is an error.
    pub(crate) fn catalog_scope(
        &self,
        provider_id: &str,
    ) -> BistreResult<crate::registry::CatalogScope> {
        self.storage
            .list_providers()?
            .iter()
            .find(|p| p.id == provider_id)
            .map(crate::registry::CatalogScope::of)
            .ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::StorageNotFound, "provider_missing")
            })
    }

    pub(crate) fn send_with_attachments_inner(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        user_content: &str,
        attachment_inputs: &[AttachmentInput],
    ) -> BistreResult<NodeRecord> {
        let trimmed = user_content.trim();
        if trimmed.is_empty() && attachment_inputs.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "empty_prompt",
            ));
        }
        let mut stored_attachments = Vec::with_capacity(attachment_inputs.len());
        for input in attachment_inputs {
            stored_attachments.push(attachments::ingest_attachment(&self.data_dir, input)?);
        }
        self.send_with_stored_attachments_inner(
            thread_id,
            parent_id,
            trimmed,
            &stored_attachments,
            crate::agent::RunApprovalPolicy::INTERACTIVE,
        )
    }

    pub(crate) fn send_with_stored_attachments_inner(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        trimmed_content: &str,
        stored_attachments: &[bistre_protocol::StoredAttachment],
        origin: crate::agent::RunApprovalPolicy,
    ) -> BistreResult<NodeRecord> {
        let trimmed = trimmed_content.trim().to_owned();
        if trimmed.is_empty() && stored_attachments.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "empty_prompt",
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

        let meta_json = if stored_attachments.is_empty() {
            None
        } else {
            Some(serde_json::json!({ "attachments": stored_attachments }).to_string())
        };

        let system_prompt = thread
            .system_prompt_override
            .clone()
            .unwrap_or_else(|| assistant.map_or_default(|a| a.system_prompt));
        let system_prompt = crate::engine_runs::with_user_name(
            system_prompt,
            &settings.user_display_name,
            thread.mode,
        );

        let effective_text = if trimmed.is_empty() {
            stored_attachments
                .iter()
                .map(|a| format!("[Attachment: {} ({})]", a.name, a.mime_type))
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            trimmed
        };

        let user_node = self.storage.append_node(
            thread_id.clone(),
            parent_id,
            NodeRole::User,
            effective_text,
            meta_json,
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
            origin,
        )?;
        Ok(user_node)
    }

    pub(crate) fn steer_active_run_now_inner(
        &self,
        thread_id: String,
        content: &str,
    ) -> BistreResult<NodeRecord> {
        let clean = content.trim();
        if clean.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "empty_steer",
            ));
        }
        // Cancel the current in-flight run immediately and wake any backoff timer.
        if let Some(flag) = lock_or_recover(&self.cancellations, "cancellations").get(&thread_id) {
            flag.store(true, Ordering::SeqCst);
        }
        self.wake_run(&thread_id);

        // Attach the steering prompt directly at the thread's active head and start streaming now.
        let thread = self
            .storage
            .get_thread(&thread_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        let parent_id = thread.active_head_node_id;
        self.send_with_attachments_inner(thread_id, parent_id, clean, &[])
    }

    pub(crate) fn import_threads_json_inner(&self, raw_json: &str) -> BistreResult<u32> {
        storage_files::import_threads_json(&self.storage, raw_json)
    }

    pub(crate) fn export_settings_json_inner(&self) -> BistreResult<String> {
        storage_files::export_settings_json(&self.storage)
    }

    pub(crate) fn import_settings_json_inner(
        &self,
        raw_json: &str,
        allow_loosening: bool,
    ) -> BistreResult<AppSettings> {
        let imported =
            storage_files::import_settings_json(&self.storage, raw_json, allow_loosening)?;
        // Imported trust and tool settings revoke every outstanding permit at once.
        self.broker.invalidate();
        Ok(imported)
    }

    pub(crate) fn list_storage_files_inner(&self) -> BistreResult<Vec<StorageFileEntry>> {
        storage_files::list_storage_files(&self.data_dir)
    }

    pub(crate) fn delete_storage_file_inner(&self, rel_path: &str) -> BistreResult<bool> {
        storage_files::delete_storage_file(&self.data_dir, rel_path)
    }

    pub(crate) fn clean_unused_storage_files_inner(&self) -> BistreResult<u64> {
        storage_files::clean_unused_storage_files(&self.data_dir, &self.storage)
    }

    pub(crate) async fn synthesize_speech_inner(
        &self,
        provider_id: &str,
        model_id: &str,
        text: &str,
        voice_name: Option<&str>,
    ) -> BistreResult<Vec<u8>> {
        let raw = self
            .storage
            .get_provider(provider_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        let profile = self.hydrate_provider(raw);
        let keys = self.load_key_ring(provider_id)?;
        let reservation = self.reserve_media_spend(&profile, model_id, text).await?;
        // No voice chosen: the catalog's first voice for the model, else the dialect's own.
        let catalog_voice = self
            .pricing
            .snapshot()
            .voice(model_id)
            .map(ToOwned::to_owned);
        let voice_name = voice_name
            .filter(|v| !v.trim().is_empty())
            .or(catalog_voice.as_deref());
        let audio =
            voice::synthesize_speech(&self.http, &profile, &keys, model_id, text, voice_name)
                .await?;
        if let Some((reservation, input_tokens, estimate)) = reservation {
            // Speech endpoints return no usage: settle the reserved input estimate.
            reservation.settle(estimate, input_tokens, 0, "estimated".to_owned())?;
        }
        Ok(audio)
    }

    /// The Wallet Shield gate for paid requests outside chat runs (read aloud, live
    /// voice). A reached daily cap blocks them; under a cap an unknown price blocks unless
    /// "Allow once" was granted for media; a loopback provider is free. Returns the
    /// reservation, the counted input tokens, and the reserved estimate.
    async fn reserve_media_spend(
        &self,
        profile: &bistre_protocol::ProviderProfile,
        model_id: &str,
        input_text: &str,
    ) -> BistreResult<Option<(wallet::SpendReservation, u64, MoneyMicros)>> {
        if crate::net::is_loopback_url(&profile.base_url) {
            return Ok(None);
        }
        let settings = self.storage.load_settings().map_err(|err| {
            BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, err.key.as_key())
        })?;
        let input_tokens = crate::compaction::estimate_tokens_for_model(input_text, Some(model_id));
        let adv = crate::provider_prefs::load_provider_advanced(&self.storage, &profile.id);
        let rates = adv.resolve_rates(
            model_id,
            self.pricing
                .rates_for(&crate::registry::CatalogScope::of(profile), model_id)
                .await,
        );
        if rates.is_none()
            && settings.wallet_daily_ceiling_micros.is_some()
            && !lock_or_recover(&self.unpriced_allowed, "unpriced_allowed").remove(MEDIA_ALLOWANCE)
        {
            return Err(BistreError::with_detail(
                DiagnosticKey::WalletPriceUnknown,
                "price_unknown",
            ));
        }
        let usage = UsageMetrics {
            input_tokens,
            ..UsageMetrics::default()
        };
        let estimate =
            providers::estimate_cost_micros(profile, rates, &usage).unwrap_or(MoneyMicros::ZERO);
        let reservation = wallet::SpendReservation::reserve_with_chat_cap(
            &self.storage,
            None,
            profile.id.clone(),
            model_id.to_owned(),
            estimate,
            settings.wallet_daily_ceiling_micros,
            crate::engine_runs::utc_day_start_unix_ms(),
            None,
            bistre_protocol::SpendPurpose::Voice,
        )
        .map_err(|err| match err.key {
            DiagnosticKey::WalletCeilingExceeded => err,
            other => {
                BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, other.as_key())
            }
        })?;
        Ok(Some((reservation, input_tokens, estimate)))
    }

    pub(crate) async fn start_live_voice_session_inner(
        &self,
        provider_id: &str,
        model_id: &str,
        voice_name: String,
        system_prompt: String,
    ) -> BistreResult<String> {
        let raw = self
            .storage
            .get_provider(provider_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        let profile = self.hydrate_provider(raw);
        let keys = self.load_key_ring(provider_id)?;
        // Gate only: a live session is open-ended, so the reservation is released at once.
        drop(
            self.reserve_media_spend(&profile, model_id, &system_prompt)
                .await?,
        );
        self.live_voice.start_session(
            profile,
            keys,
            model_id,
            voice_name,
            system_prompt,
            self.events_tx.clone(),
        )
    }

    /// The workspace's hooks, their digest, and whether exactly this file is approved.
    pub(crate) fn workspace_hooks_status_inner(
        &self,
        root: &Path,
    ) -> BistreResult<Option<crate::hooks::WorkspaceHooksStatus>> {
        let Some(file) = crate::hooks::load_workspace_hooks(root)? else {
            return Ok(None);
        };
        let approved = self
            .storage
            .get_kv_meta(&crate::hooks::hooks_approval_key(root))?;
        Ok(Some(crate::hooks::WorkspaceHooksStatus {
            approved: approved.as_deref() == Some(file.digest.as_str()),
            hooks: file.hooks,
            digest: file.digest,
        }))
    }

    /// Approves the hooks file the user reviewed; a file changed since is refused.
    pub(crate) fn approve_workspace_hooks_inner(
        &self,
        root: &Path,
        digest: &str,
    ) -> BistreResult<()> {
        let current = crate::hooks::load_workspace_hooks(root)?.map(|f| f.digest);
        if current.as_deref() != Some(digest) {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "hooks_changed",
            ));
        }
        self.storage
            .set_kv_meta(crate::hooks::hooks_approval_key(root), digest.to_owned())
    }

    /// Validates and saves a provider's custom headers and body, bound to its origin.
    pub(crate) fn save_provider_overrides_inner(
        &self,
        provider_id: &str,
        headers_json: &str,
        body_json: &str,
    ) -> BistreResult<()> {
        let provider = self
            .storage
            .get_provider(provider_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        crate::provider_prefs::save_provider_overrides(
            &self.storage,
            provider_id,
            &provider.base_url,
            headers_json,
            body_json,
        )
    }

    /// Encodes a provider profile and its advanced settings as an `ai-provider:v1:` share code.
    /// API keys are excluded unless `include_api_key` is explicitly `true`.
    pub(crate) fn export_provider_share_code_inner(
        &self,
        provider_id: &str,
        include_api_key: bool,
    ) -> BistreResult<String> {
        let raw = self
            .storage
            .get_provider(provider_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        let profile = self.hydrate_provider(raw);
        let adv = crate::provider_prefs::load_provider_advanced(&self.storage, provider_id);
        let key_opt = if include_api_key {
            self.load_key_ring(provider_id)?
                .rotation()
                .first()
                .copied()
                .filter(|k| !k.is_empty())
                .map(str::to_owned)
        } else {
            None
        };
        crate::provider_prefs::export_provider_share_code(&profile, &adv, key_opt.as_deref())
    }

    /// Imports an `ai-provider:v1:` share code as a brand-new provider profile (fresh UUID,
    /// HTTP(S)-validated base URL, advanced settings preserved).
    pub(crate) fn import_provider_share_code_inner(
        &self,
        code: &str,
    ) -> BistreResult<bistre_protocol::ProviderProfile> {
        let payload = crate::provider_prefs::import_provider_share_code(code)?;
        let dialect = bistre_protocol::ProviderDialect::parse(&payload.dialect);
        let created = self.storage.create_provider(
            payload.name.trim(),
            dialect,
            payload.base_url.trim(),
            payload.default_model.trim(),
            "",
            "",
        )?;
        let adv_json = serde_json::json!({
            "customDialect": payload.custom_dialect,
            "endpointPathOverride": payload.endpoint_path,
            "authHeaderMode": match payload.auth_mode.as_str() {
                "bearer" | "bearer_only" => "bearer_only",
                "query" | "query_param" => "query_param",
                _ => "native",
            },
        })
        .to_string();
        self.storage
            .set_kv_meta(format!("provider.adv:{}", created.id), adv_json)?;
        if let Some(key) = payload
            .api_key
            .as_deref()
            .map(str::trim)
            .filter(|k| !k.is_empty())
        {
            let keys = crate::credentials::parse_api_keys(key);
            let clean = crate::credentials::encode_api_keys(&keys);
            if !clean.is_empty() {
                self.vault
                    .put(&Self::vault_key(&created.id), clean.as_bytes())?;
                let hint = crate::credentials::key_hint_for(&keys);
                let _updated = self.storage.update_provider(
                    created.id.clone(),
                    bistre_protocol::ProviderPatch {
                        key_hint: Some(hint),
                        is_enabled: Some(true),
                        ..bistre_protocol::ProviderPatch::default()
                    },
                )?;
            }
        }
        let refreshed = self.storage.get_provider(&created.id)?.unwrap_or(created);
        Ok(self.hydrate_provider(refreshed))
    }

    /// A page of `thread_id`'s nodes before `before_node_id`, oldest first (see storage).
    pub(crate) fn list_nodes_window_inner(
        &self,
        thread_id: &str,
        before_node_id: Option<&str>,
        limit: usize,
    ) -> BistreResult<Vec<NodeRecord>> {
        self.storage
            .list_nodes_window(thread_id, before_node_id, limit)
    }

    /// Returns a monotonic history revision for `thread_id`.
    pub(crate) fn thread_history_rev_inner(&self, thread_id: &str) -> BistreResult<i64> {
        self.storage.thread_history_rev(thread_id)
    }

    pub(crate) async fn shutdown_inner(&self) -> BistreResult<()> {
        const RUN_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
        self.live_voice.stop_all();
        {
            let guard = lock_or_recover(&self.cancellations, "cancellations");
            for flag in guard.values() {
                flag.store(true, Ordering::SeqCst);
            }
        }
        for wake in lock_or_recover(&self.wakers, "wakers").values() {
            wake.notify_one();
        }
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
        crate::mcp_stdio::close_all_stdio_sessions();
        crate::mcp_listen::stop_all();
        self.pricing.stop_sync().await;
        self.storage.shutdown()?;
        Ok(())
    }
}
