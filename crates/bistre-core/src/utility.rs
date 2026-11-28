//! Background utility completions driven by Settings > Default models:
//! chat title generation, model-written compaction summaries, and message translation.
//!
//! Every background request:
//! - uses `store: false` (never stored on the provider's server);
//! - honours `wallet_local_first` when the slot follows the global default and an enabled
//!   loopback local provider is configured;
//! - validates custom headers/body and reserves spend through Wallet Shield (fail closed)
//!   before sending, settling exact micro-USD usage into `wallet_ledger`.

use std::sync::atomic::AtomicBool;

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, EngineEvent, GenerationParams, MoneyMicros,
    NodeRecord, NodeRole, ProviderProfile, ReasoningEffort, ThreadPatch, ThreadSummary,
    UsageMetrics,
};
use uuid::Uuid;

use crate::credentials::KeyRing;
use crate::engine_runs::{utc_day_start_unix_ms, utc_now_unix_ms};
use crate::events::emit;
use crate::provider_prefs::{
    DefaultModelsPrefs, ProviderAdvancedPrefs, load_default_models, load_provider_advanced,
    load_provider_overrides, load_thread_spend_limit,
};
use crate::{InProcessEngine, compaction, net, providers, wallet};

/// The built-in title prompt; a non-empty Default models title prompt replaces it.
pub const DEFAULT_TITLE_PROMPT: &str = "Write a 3 to 6 word title for this conversation. Reply with the title alone, with no quotes and no closing punctuation.";
/// The built-in title prompt the app used to store as the setting's value; a stored copy of it
/// means the built-in prompt, so a fix to [`DEFAULT_TITLE_PROMPT`] reaches those installs.
const STORED_OLD_TITLE_PROMPT: &str = "Generate a concise, natural 3 to 6 word title summarizing this conversation. Return ONLY the title text without quotes or trailing punctuation.";
/// Translation prompt; `{lang}` is the target language.
const TRANSLATE_PROMPT: &str = "Translate the message into {lang} as a native speaker of {lang} writes. Keep its Markdown, code blocks, links, and meaning. Reply with the translation alone.";
const SUMMARY_SYSTEM_PROMPT: &str = "Summarize the earlier conversation turns concisely, preserving decisions, open tasks, file paths, code identifiers, and constraints needed to continue accurately. Return only the summary.";

const MAX_TITLE_SOURCE_CHARS: usize = 1_500;
const MAX_TITLE_OUTPUT_CHARS: usize = 60;
const MAX_SUMMARY_SOURCE_CHARS: usize = 24_000;
/// Longest note on what a summary should keep, in characters.
const MAX_COMPACT_INSTRUCTION_CHARS: usize = 1_000;
/// Longest summary a user may write in place of one, in characters.
const MAX_EDITED_SUMMARY_CHARS: usize = 24_000;
const MAX_TRANSLATE_SOURCE_CHARS: usize = 32_000;

/// Which Settings > Default models slot runs a background request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UtilitySlot {
    Title,
    Summary,
    Translation,
    /// A question about the chat asked beside it, answered by the chat's own model.
    SideQuestion,
}

impl UtilitySlot {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Title => "title",
            Self::Summary => "summary",
            Self::Translation => "translation",
            Self::SideQuestion => "side_question",
        }
    }

    /// The ledger purpose this slot's spend is booked under.
    pub const fn purpose(self) -> bistre_protocol::SpendPurpose {
        match self {
            Self::Title => bistre_protocol::SpendPurpose::Title,
            Self::Summary => bistre_protocol::SpendPurpose::Summary,
            Self::Translation => bistre_protocol::SpendPurpose::Translation,
            Self::SideQuestion => bistre_protocol::SpendPurpose::Chat,
        }
    }

    fn slot_override(self, prefs: &DefaultModelsPrefs) -> (bool, &str, &str) {
        match self {
            Self::Title => (
                prefs.title_follow_global,
                prefs.title_provider_id.trim(),
                prefs.title_model_id.trim(),
            ),
            Self::Summary => (
                prefs.summary_follow_global,
                prefs.summary_provider_id.trim(),
                prefs.summary_model_id.trim(),
            ),
            Self::Translation => (
                prefs.translation_follow_global,
                prefs.translation_provider_id.trim(),
                prefs.translation_model_id.trim(),
            ),
            Self::SideQuestion => (true, "", ""),
        }
    }
}

pub(crate) struct UtilityOutcome {
    pub(crate) text: String,
    pub(crate) provider: ProviderProfile,
    pub(crate) model_id: String,
    pub(crate) usage: UsageMetrics,
    pub(crate) cost_known: bool,
}

pub(crate) fn clip_chars(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

/// Cleans a model-generated chat title: first non-empty line, strips markdown heading markers,
/// surrounding quotes, and trailing punctuation, and caps length cleanly at Unicode boundaries.
pub fn sanitize_generated_title(raw: &str) -> String {
    let first_line = raw
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    let no_heading = first_line.trim_start_matches('#').trim();
    let unquoted = no_heading
        .trim_matches(['"', '\'', '`', '“', '”', '‘', '’'])
        .trim();
    let trimmed = unquoted.trim_end_matches(['.', '!', '?', ':', ';']);
    let normalized = trimmed.split_whitespace().collect::<Vec<_>>().join(" ");
    clip_chars(&normalized, MAX_TITLE_OUTPUT_CHARS)
}

impl InProcessEngine {
    /// Resolves `(wired_provider, keys, model_id, adv_prefs)` for a background utility slot.
    fn resolve_utility_target(
        &self,
        slot: UtilitySlot,
        thread_id: Option<&str>,
    ) -> BistreResult<(ProviderProfile, KeyRing, String, ProviderAdvancedPrefs)> {
        let settings = self.storage.load_settings()?;
        if slot == UtilitySlot::SideQuestion {
            return self.resolve_chat_target(&settings, thread_id);
        }
        let defaults = load_default_models(&self.storage);
        let profiles: Vec<ProviderProfile> = self
            .storage
            .list_providers()?
            .into_iter()
            .map(|p| self.hydrate_provider(p))
            .collect();
        let is_usable =
            |p: &ProviderProfile| p.is_enabled && (!p.requires_api_key() || p.has_api_key);
        let (follow_global, slot_pid, slot_model) = slot.slot_override(&defaults);

        let (selected, model_hint) = if !follow_global && !slot_pid.is_empty() {
            let p = profiles
                .iter()
                .find(|p| p.id == slot_pid && is_usable(p))
                .cloned()
                .ok_or_else(|| BistreError::new(DiagnosticKey::ProviderPinnedUnavailable))?;
            (p, slot_model.to_owned())
        } else if follow_global
            && settings.wallet_local_first
            && let Some(local) = profiles.iter().find(|p| {
                is_usable(p)
                    && net::is_loopback_url(&p.base_url)
                    && !p.default_model.trim().is_empty()
            })
        {
            (local.clone(), local.default_model.trim().to_owned())
        } else {
            let thread = match thread_id {
                Some(tid) => self.storage.get_thread(tid)?,
                None => None,
            };
            let requested_pid = (!defaults.global_provider_id.trim().is_empty())
                .then(|| defaults.global_provider_id.trim().to_owned())
                .or_else(|| {
                    (!settings.active_provider_id.trim().is_empty())
                        .then(|| settings.active_provider_id.trim().to_owned())
                })
                .or_else(|| {
                    thread
                        .as_ref()
                        .and_then(|t| t.provider_id_override.clone())
                        .filter(|s| !s.trim().is_empty())
                });
            let selected = requested_pid
                .as_deref()
                .and_then(|pid| {
                    profiles
                        .iter()
                        .find(|p| p.id == pid && is_usable(p))
                        .cloned()
                })
                .or_else(|| profiles.iter().find(|p| is_usable(p)).cloned())
                .ok_or_else(|| BistreError::new(DiagnosticKey::ProviderNotConfigured))?;
            let m = if !follow_global && !slot_model.is_empty() {
                slot_model.to_owned()
            } else if !defaults.global_model_id.trim().is_empty()
                && (defaults.global_provider_id.is_empty()
                    || defaults.global_provider_id == selected.id)
            {
                defaults.global_model_id.trim().to_owned()
            } else if !settings.active_model_id.trim().is_empty()
                && (settings.active_provider_id.is_empty()
                    || settings.active_provider_id == selected.id)
            {
                settings.active_model_id.trim().to_owned()
            } else if let Some(tm) = thread
                .as_ref()
                .and_then(|t| t.model_id_override.as_deref())
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                tm.to_owned()
            } else {
                selected.default_model.trim().to_owned()
            };
            (selected, m)
        };

        let model = if model_hint.trim().is_empty() {
            selected.default_model.trim().to_owned()
        } else {
            model_hint.trim().to_owned()
        };
        if model.is_empty() {
            return Err(BistreError::new(DiagnosticKey::ProviderModelRequired));
        }
        let keys = self.load_key_ring(&selected.id)?;
        if selected.requires_api_key() && keys.is_empty() {
            return Err(BistreError::new(DiagnosticKey::ProviderNotConfigured));
        }
        let adv = load_provider_advanced(&self.storage, &selected.id);
        let wired = adv.speaking(&selected);
        Ok((wired, keys, model, adv))
    }

    fn reserve_utility_spend(
        &self,
        thread_id: Option<&str>,
        provider: &ProviderProfile,
        model: &str,
        rates: Option<crate::registry::ModelRates>,
        est_input: u64,
        slot: UtilitySlot,
    ) -> BistreResult<Option<wallet::SpendReservation>> {
        if net::is_loopback_url(&provider.base_url) {
            return Ok(None);
        }
        let settings = self.storage.load_settings().map_err(|err| {
            BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, err.key.as_key())
        })?;
        let chat_cap = match thread_id {
            Some(tid) => load_thread_spend_limit(&self.storage, tid)?,
            None => None,
        };
        let capped = settings.wallet_daily_ceiling_micros.is_some() || chat_cap.is_some();
        let est_usage = UsageMetrics {
            input_tokens: est_input,
            ..UsageMetrics::default()
        };
        let estimate = match providers::estimate_cost_micros(provider, rates, &est_usage) {
            Some(cost) => cost,
            None if capped => {
                return Err(BistreError::with_detail(
                    DiagnosticKey::WalletPriceUnknown,
                    "price_unknown",
                ));
            }
            None => MoneyMicros::ZERO,
        };
        wallet::SpendReservation::reserve_with_chat_cap(
            &self.storage,
            thread_id.map(str::to_owned),
            provider.id.clone(),
            model.to_owned(),
            estimate,
            settings.wallet_daily_ceiling_micros,
            utc_day_start_unix_ms(),
            chat_cap,
            slot.purpose(),
        )
        .map(Some)
        .map_err(|err| match err.key {
            DiagnosticKey::WalletCeilingExceeded => err,
            other => {
                BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, other.as_key())
            }
        })
    }

    pub(crate) async fn run_utility_completion(
        &self,
        slot: UtilitySlot,
        thread_id: Option<&str>,
        system_prompt: &str,
        user_prompt: &str,
        max_output_tokens: u32,
    ) -> BistreResult<UtilityOutcome> {
        let (provider, keys, model, adv) = self.resolve_utility_target(slot, thread_id)?;
        let overrides = load_provider_overrides(&self.storage, &provider.id)?;
        let is_local = net::is_loopback_url(&provider.base_url);

        let user_node = NodeRecord {
            id: Uuid::now_v7().to_string(),
            thread_id: thread_id.unwrap_or("utility").to_owned(),
            parent_id: None,
            role: NodeRole::User,
            content: user_prompt.to_owned(),
            provider_meta_json: None,
            created_at_ms: utc_now_unix_ms(),
        };
        let history = [user_node];
        let est_input =
            compaction::estimate_branch_tokens_for_model(system_prompt, &history, Some(&model));
        let rates = adv.resolve_rates(
            &model,
            self.pricing
                .rates_for(&crate::registry::CatalogScope::of(&provider), &model)
                .await,
        );
        let reservation =
            self.reserve_utility_spend(thread_id, &provider, &model, rates, est_input, slot)?;

        let gen_params = GenerationParams {
            temperature_milli: None,
            max_output_tokens: Some(max_output_tokens),
            top_p_milli: None,
            reasoning_effort: ReasoningEffort::ModelDefault,
        };
        let opts = providers::StreamRequestOptions {
            store: false,
            endpoint_path: adv.endpoint_path.as_deref(),
            auth_mode: adv.auth_mode,
            disable_legacy_fallback: !adv.use_legacy_fallback,
            extra_headers: overrides.headers,
            extra_body_fields: overrides.body_fields,
            ..providers::StreamRequestOptions::default()
        };
        let cancel = AtomicBool::new(false);
        let mut outcome = providers::stream_completion_with_options(
            &self.http,
            &provider,
            &keys,
            &model,
            system_prompt,
            &history,
            gen_params,
            None,
            &opts,
            &cancel,
            |_| {},
            |_| {},
        )
        .await?;

        if !is_local {
            let counted_out =
                compaction::estimate_tokens_for_model(&outcome.full_text, Some(&model));
            let (billable, _) = wallet::billable_usage(&outcome.usage, est_input, counted_out);
            outcome.usage = billable;
        }
        let cost = providers::estimate_cost_micros(&provider, rates, &outcome.usage);
        outcome.usage.estimated_cost_micros = cost.unwrap_or(MoneyMicros::ZERO);

        let request_id = format!("utility:{}:{}", slot.as_str(), Uuid::now_v7());
        if let Some(res) = reservation {
            if let Err(err) = res.settle_for_request(
                Some(request_id),
                outcome.usage.estimated_cost_micros,
                outcome.usage.input_tokens,
                outcome.usage.output_tokens,
                "settled".to_owned(),
            ) {
                tracing::warn!(key = err.key.as_key(), "utility wallet settlement failed");
            }
        } else if let Err(err) = self.storage.record_wallet_entry_with_usage(
            thread_id.map(str::to_owned),
            provider.id.clone(),
            model.clone(),
            outcome.usage.estimated_cost_micros,
            outcome.usage.input_tokens,
            outcome.usage.output_tokens,
            "settled".to_owned(),
            slot.purpose(),
        ) {
            tracing::warn!(key = err.key.as_key(), "utility local ledger record failed");
        }

        Ok(UtilityOutcome {
            text: outcome.full_text.trim().to_owned(),
            provider,
            model_id: model,
            usage: outcome.usage,
            cost_known: cost.is_some(),
        })
    }

    /// Generates and persists a short title for `thread_id` using the Default models Title slot.
    pub(crate) async fn generate_thread_title_inner(
        &self,
        thread_id: &str,
    ) -> BistreResult<ThreadSummary> {
        let thread = self
            .storage
            .get_thread(thread_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        let nodes = self.storage.list_nodes(thread_id)?;
        let active_leaf = thread
            .active_head_node_id
            .as_deref()
            .or_else(|| nodes.last().map(|n| n.id.as_str()));
        let branch = match active_leaf {
            Some(leaf) => crate::engine_runs::collect_branch_ancestry(&nodes, leaf),
            None => nodes,
        };
        let first_user = branch
            .iter()
            .find(|n| n.role == NodeRole::User && !n.content.trim().is_empty())
            .ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::InvalidInput, "no_user_message")
            })?;
        let first_assistant = branch
            .iter()
            .find(|n| n.role == NodeRole::Assistant && !n.content.trim().is_empty());

        let mut exchange = format!(
            "User: {}",
            clip_chars(first_user.content.trim(), MAX_TITLE_SOURCE_CHARS)
        );
        if let Some(reply) = first_assistant {
            exchange.push_str("\n\nAssistant: ");
            exchange.push_str(&clip_chars(reply.content.trim(), MAX_TITLE_SOURCE_CHARS));
        }

        let defaults = load_default_models(&self.storage);
        let prompt = title_prompt(&defaults.title_prompt_template);
        let out = self
            .run_utility_completion(UtilitySlot::Title, Some(thread_id), prompt, &exchange, 64)
            .await?;
        let clean = sanitize_generated_title(&out.text);
        if clean.is_empty() {
            return Ok(thread);
        }
        self.storage.update_thread(
            thread_id.to_owned(),
            ThreadPatch {
                title: Some(clean),
                ..ThreadPatch::default()
            },
        )
    }

    /// Generates a model-written summary for the messages about to be compacted, returning `None`
    /// to fall back cleanly to the deterministic local summary when no model is available or the
    /// background request fails.
    pub(crate) async fn summarize_for_compaction_inner(
        &self,
        thread_id: &str,
        branch: &[NodeRecord],
        keep_recent_turns: usize,
        instructions: Option<&str>,
    ) -> Option<String> {
        let regular: Vec<&NodeRecord> = branch
            .iter()
            .filter(|n| n.role != NodeRole::CompactionSummary)
            .collect();
        let keep = keep_recent_turns.max(2);
        if regular.len() <= keep {
            return None;
        }
        let split_idx = regular.len().saturating_sub(keep);
        let to_compact = &regular[..split_idx];

        let mut transcript = String::new();
        for node in to_compact {
            let speaker = match node.role {
                NodeRole::User => "User",
                NodeRole::Assistant => "Assistant",
                NodeRole::Tool => "Tool",
                NodeRole::System => "System",
                NodeRole::CompactionSummary => "Summary",
            };
            if !transcript.is_empty() {
                transcript.push_str("\n\n");
            }
            transcript.push_str(speaker);
            transcript.push_str(": ");
            transcript.push_str(node.content.trim());
            if transcript.chars().count() >= MAX_SUMMARY_SOURCE_CHARS {
                transcript = clip_chars(&transcript, MAX_SUMMARY_SOURCE_CHARS);
                break;
            }
        }
        if transcript.trim().is_empty() {
            return None;
        }
        let wanted: String = instructions
            .unwrap_or_default()
            .chars()
            .filter(|c| !c.is_control() || *c == '\n')
            .take(MAX_COMPACT_INSTRUCTION_CHARS)
            .collect();
        if !wanted.trim().is_empty() {
            transcript.push_str("\n\nWhat the user wants this summary to keep: ");
            transcript.push_str(wanted.trim());
        }

        match self
            .run_utility_completion(
                UtilitySlot::Summary,
                Some(thread_id),
                SUMMARY_SYSTEM_PROMPT,
                &transcript,
                1024,
            )
            .await
        {
            Ok(out) if !out.text.trim().is_empty() => Some(out.text),
            Ok(_) => None,
            Err(err) => {
                if err.key != DiagnosticKey::ProviderNotConfigured {
                    tracing::warn!(
                        key = err.key.as_key(),
                        "model compaction summary unavailable; falling back to local summary"
                    );
                }
                None
            }
        }
    }

    /// Replaces a compaction summary's text with the user's own (trimmed, non-empty, at most
    /// [`MAX_EDITED_SUMMARY_CHARS`]); the messages it condenses stay saved.
    pub(crate) fn rewrite_compaction_summary_inner(
        &self,
        thread_id: &str,
        node_id: &str,
        content: &str,
    ) -> BistreResult<NodeRecord> {
        let text = content.trim();
        if text.is_empty() || text.chars().count() > MAX_EDITED_SUMMARY_CHARS {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "summary_length",
            ));
        }
        self.storage
            .rewrite_compaction_summary(thread_id, node_id, text)
    }

    /// Runs reversible compaction for `thread_id`, asking the Default models Summary slot
    /// for a summary (following the user's `instructions`) whenever no explicit
    /// `custom_summary` was supplied.
    pub(crate) async fn compact_thread_inner(
        &self,
        thread_id: &str,
        keep_recent_turns: u32,
        custom_summary: Option<String>,
        instructions: Option<String>,
    ) -> BistreResult<NodeRecord> {
        let nodes = self.storage.list_nodes(thread_id)?;
        let active_leaf = self
            .storage
            .get_thread(thread_id)?
            .and_then(|t| t.active_head_node_id)
            .or_else(|| nodes.last().map(|n| n.id.clone()));
        let branch = match active_leaf.as_deref() {
            Some(leaf) => crate::engine_runs::collect_branch_ancestry(&nodes, leaf),
            None => nodes,
        };
        let keep = usize::try_from(keep_recent_turns).unwrap_or(4);
        let resolved_summary = match custom_summary {
            Some(text) if !text.trim().is_empty() => Some(text),
            _ => {
                self.summarize_for_compaction_inner(
                    thread_id,
                    &branch,
                    keep,
                    instructions.as_deref(),
                )
                .await
            }
        };
        let node = compaction::create_reversible_compaction(
            &self.storage,
            thread_id,
            &branch,
            keep,
            resolved_summary.as_deref(),
        )?;
        let ev = EngineEvent::NodeCommitted { node: node.clone() };
        crate::events::emit_logged(
            &self.storage,
            &self.events_tx,
            Some(thread_id.to_owned()),
            ev,
        );
        Ok(node)
    }

    /// Translates `node_id` into `target_language` (or Settings > Default models > Target
    /// language) and commits the result as a new sibling version on the same parent.
    pub(crate) async fn translate_node_inner(
        &self,
        thread_id: &str,
        node_id: &str,
        target_language: Option<&str>,
    ) -> BistreResult<NodeRecord> {
        let nodes = self.storage.list_nodes(thread_id)?;
        let source = nodes
            .into_iter()
            .find(|n| n.id == node_id)
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        let text = source.content.trim();
        if text.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "empty_message",
            ));
        }
        let defaults = load_default_models(&self.storage);
        let lang = target_language
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(defaults.translation_target_language.as_str());
        let lang = if lang.is_empty() { "English" } else { lang };
        let sys = TRANSLATE_PROMPT.replace("{lang}", lang);
        let bounded = clip_chars(text, MAX_TRANSLATE_SOURCE_CHARS);
        let out = self
            .run_utility_completion(
                UtilitySlot::Translation,
                Some(thread_id),
                &sys,
                &bounded,
                4096,
            )
            .await?;
        if out.text.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::ProviderRequestFailed,
                "empty_translation",
            ));
        }
        let meta = serde_json::json!({
            "provider_id": out.provider.id,
            "provider_name": out.provider.name,
            "icon_slug": out.provider.icon_slug,
            "model_id": out.model_id,
            "input_tokens": out.usage.input_tokens,
            "output_tokens": out.usage.output_tokens,
            "cost_micros": out.usage.estimated_cost_micros.as_micros(),
            "cost_known": out.cost_known,
            "translated_from": source.id,
            "target_language": lang,
        })
        .to_string();
        let node = self.storage.append_node(
            thread_id.to_owned(),
            source.parent_id,
            source.role,
            out.text,
            Some(meta),
        )?;
        emit(
            &self.events_tx,
            EngineEvent::NodeCommitted { node: node.clone() },
        );
        Ok(node)
    }
}

/// The title prompt a run sends: the setting when it holds a prompt of its own, else the
/// built-in one.
fn title_prompt(setting: &str) -> &str {
    let custom = setting.trim();
    if custom.is_empty() || custom == STORED_OLD_TITLE_PROMPT {
        DEFAULT_TITLE_PROMPT
    } else {
        custom
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DEFAULT_TITLE_PROMPT, STORED_OLD_TITLE_PROMPT, SUMMARY_SYSTEM_PROMPT, TRANSLATE_PROMPT,
        sanitize_generated_title, title_prompt,
    };
    use crate::test_support::prompt_rule_breaks;

    #[test]
    fn built_in_prompts_follow_the_prompt_rules() {
        for prompt in [
            DEFAULT_TITLE_PROMPT,
            TRANSLATE_PROMPT,
            SUMMARY_SYSTEM_PROMPT,
        ] {
            assert_eq!(prompt_rule_breaks(prompt), Vec::<String>::new(), "{prompt}");
        }
    }

    #[test]
    fn a_stored_copy_of_the_old_title_prompt_sends_the_built_in_one() {
        assert_eq!(title_prompt(STORED_OLD_TITLE_PROMPT), DEFAULT_TITLE_PROMPT);
        assert_eq!(title_prompt("  "), DEFAULT_TITLE_PROMPT);
        assert_eq!(
            title_prompt(" Name it in two words. "),
            "Name it in two words."
        );
    }

    #[test]
    fn sanitize_generated_title_strips_quotes_headings_and_trailing_punctuation() {
        assert_eq!(
            sanitize_generated_title("## \"Rust async error handling.\"\nExtra line"),
            "Rust async error handling"
        );
        assert_eq!(
            sanitize_generated_title("  `Fixing SQLite WAL lock!`  "),
            "Fixing SQLite WAL lock"
        );
        assert_eq!(
            sanitize_generated_title(&"a".repeat(100)).chars().count(),
            60
        );
    }
}
