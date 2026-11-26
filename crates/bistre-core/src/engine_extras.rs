//! Extended `InProcessEngine` use cases (multi-key reveal, catalog lookup, multimodal attachments,
//! immediate steering, storage file manager, export/import, and live voice/TTS).
//! Kept separate from `engine_impl.rs` so every module stays focused and well under 1,500 lines.

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

    pub(crate) async fn lookup_model_catalog_info_inner(
        &self,
        model_id: &str,
    ) -> BistreResult<Option<ModelCatalogInfo>> {
        let clean = model_id.trim();
        if clean.is_empty() {
            return Ok(None);
        }
        let rates = match self.pricing.snapshot().lookup(clean) {
            Some(found) => Some(found),
            None => self.pricing.rates_for(clean).await,
        };
        Ok(rates.map(|r| ModelCatalogInfo {
            context_window: r.context_tokens,
            max_output_tokens: None,
            input_per_mtok_micros: Some(r.input_per_mtok),
            output_per_mtok_micros: Some(r.output_per_mtok),
            cached_input_per_mtok_micros: r.cached_input_per_mtok,
            reasoning: r.reasoning,
        }))
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
        self.send_with_stored_attachments_inner(thread_id, parent_id, trimmed, &stored_attachments)
    }

    pub(crate) fn send_with_stored_attachments_inner(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        trimmed_content: &str,
        stored_attachments: &[bistre_protocol::StoredAttachment],
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

    pub(crate) fn export_all_threads_json_inner(&self) -> BistreResult<String> {
        storage_files::export_all_threads_json(&self.storage)
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
        // A-S3: imported trust and tool settings revoke every outstanding permit at once.
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
        let audio =
            voice::synthesize_speech(&self.http, &profile, &keys, model_id, text, voice_name)
                .await?;
        if let Some((reservation, input_tokens, estimate)) = reservation {
            // Speech endpoints return no usage: settle the reserved input estimate.
            reservation.settle(estimate, input_tokens, 0, "estimated".to_owned())?;
        }
        Ok(audio)
    }

    /// A-S4: the Wallet Shield gate for paid requests outside chat runs (read aloud, live
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
        let rates = self.pricing.rates_for(model_id).await;
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
        let reservation = wallet::SpendReservation::reserve(
            &self.storage,
            None,
            profile.id.clone(),
            model_id.to_owned(),
            estimate,
            settings.wallet_daily_ceiling_micros,
            crate::engine_runs::utc_day_start_unix_ms(),
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

    /// The workspace's hooks, their digest, and whether exactly this file is approved (A-S5).
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

    /// Validates and saves a provider's custom headers and body, bound to its origin (A-S8).
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
}
