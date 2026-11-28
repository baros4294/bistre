//! Story (Write mode) use cases of `InProcessEngine`, kept apart from `engine_impl.rs`.

use std::collections::HashMap;

use bistre_protocol::{
    BistreError, BistreResult, ChapterSummary, CharacterCardRecord, DiagnosticKey, NodeRecord,
    NodeRole,
};
use serde::{Deserialize, Serialize};

use crate::story::writer_agents::{self, LaserEditMode, WriterPrompt};
use crate::utility::{UtilitySlot, clip_chars};
use crate::{BoxFuture, InProcessEngine, import_policy, story};

/// Longest excerpt a rewrite tool takes, in characters.
pub(crate) const MAX_EXCERPT_CHARS: usize = 16_000;
/// Most scene text sent beside an excerpt, or beats and story memory sent to the prewriter,
/// in characters.
const MAX_WRITER_CONTEXT_CHARS: usize = 24_000;
/// Most chapter text the librarian reads, in characters (the chapter's start first).
const MAX_CHAPTER_CHARS: usize = 60_000;
/// Reply budgets of the writing tools, in tokens.
const REWRITE_MAX_TOKENS: u32 = 4096;
const BRIEF_MAX_TOKENS: u32 = 1024;

/// The persona the user writes as in a story chat: the chat's own, else the default one.
fn active_persona(
    storage: &bistre_storage::StorageHandle,
    state: &bistre_protocol::StoryThreadStateRecord,
) -> BistreResult<Option<bistre_protocol::UserPersonaRecord>> {
    let personas = storage.list_user_personas()?;
    let chosen = state
        .user_persona_id
        .as_deref()
        .and_then(|pid| personas.iter().find(|p| p.id == pid))
        .or_else(|| personas.iter().find(|p| p.is_default));
    Ok(chosen.cloned())
}

fn writer_failed(detail: &'static str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, detail)
}

impl InProcessEngine {
    /// The persona a Write-mode chat's user writes as; `None` in other modes.
    pub(crate) fn chat_persona(
        &self,
        thread_id: &str,
    ) -> BistreResult<Option<bistre_protocol::UserPersonaRecord>> {
        let thread = self
            .storage
            .get_thread(thread_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        if thread.mode != bistre_protocol::ThreadMode::Write {
            return Ok(None);
        }
        let state = self.storage.load_story_thread_state(thread_id)?;
        active_persona(&self.storage, &state)
    }

    /// One writing tool request with the chat's own model; nothing is saved to the chat and
    /// the spend is booked on it. An empty answer is an error.
    async fn run_writer(
        &self,
        thread_id: &str,
        prompt: WriterPrompt,
        max_tokens: u32,
    ) -> BistreResult<String> {
        let out = self
            .run_utility_completion(
                UtilitySlot::SideQuestion,
                Some(thread_id),
                prompt.system,
                &prompt.user,
                max_tokens,
            )
            .await?;
        if out.text.trim().is_empty() {
            return Err(writer_failed("empty_writer_reply"));
        }
        Ok(out.text.trim().to_owned())
    }

    /// The replacement for `excerpt` of a manuscript scene under `mode` (`rewrite`, `expand`,
    /// `shorten`, `polish`), with the scene's text `context` around it.
    pub fn rewrite_passage(
        &self,
        thread_id: String,
        mode: String,
        excerpt: String,
        context: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let excerpt = excerpt.trim();
            if excerpt.is_empty() || excerpt.chars().count() > MAX_EXCERPT_CHARS {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "excerpt_length",
                ));
            }
            let prompt = writer_agents::laser_edit_prompt(
                LaserEditMode::parse(&mode),
                excerpt,
                &clip_chars(&context, MAX_WRITER_CONTEXT_CHARS),
            );
            self.run_writer(&thread_id, prompt, REWRITE_MAX_TOKENS)
                .await
        })
    }

    /// A writing brief for a scene from its `title` and `beats` (as they stand in the editor)
    /// and the chat's story memory.
    pub fn plan_scene(
        &self,
        thread_id: String,
        title: String,
        beats: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            if beats.trim().is_empty() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "scene_has_no_beats",
                ));
            }
            let state = self.storage.load_story_thread_state(&thread_id)?;
            let prompt = writer_agents::prewriter_prompt(
                &title,
                &clip_chars(&beats, MAX_WRITER_CONTEXT_CHARS),
                &clip_chars(&state.story_memory, MAX_WRITER_CONTEXT_CHARS),
            );
            self.run_writer(&thread_id, prompt, BRIEF_MAX_TOKENS).await
        })
    }

    /// The era summary of `chapter_id` from its saved scenes, checked against the era
    /// summaries of the chapters before it.
    pub fn summarize_chapter(
        &self,
        thread_id: String,
        chapter_id: String,
    ) -> BoxFuture<'_, BistreResult<ChapterSummary>> {
        Box::pin(async move {
            let chapters = self.storage.list_story_chapters(&thread_id)?;
            let chapter = chapters
                .iter()
                .find(|c| c.id == chapter_id)
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
            let mut scenes = self.storage.list_story_scenes(&chapter_id)?;
            scenes.sort_by_key(|s| s.order_index);
            let text = scenes
                .iter()
                .map(|s| s.prose_text.trim())
                .filter(|t| !t.is_empty())
                .collect::<Vec<_>>()
                .join("\n\n");
            if text.is_empty() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "chapter_has_no_prose",
                ));
            }
            let prior = chapters
                .iter()
                .filter(|c| c.order_index < chapter.order_index && !c.era_summary.trim().is_empty())
                .map(|c| format!("{}: {}", c.title.trim(), c.era_summary.trim()))
                .collect::<Vec<_>>()
                .join("\n");
            let prompt = writer_agents::continuity_librarian_prompt(
                &chapter.title,
                &clip_chars(&text, MAX_CHAPTER_CHARS),
                &clip_chars(&prior, MAX_WRITER_CONTEXT_CHARS),
            );
            let reply = self
                .run_writer(&thread_id, prompt, BRIEF_MAX_TOKENS)
                .await?;
            let (era_summary, contradictions) = writer_agents::split_librarian_reply(&reply);
            Ok(ChapterSummary {
                era_summary,
                contradictions,
            })
        })
    }
}

/// Credential-free snapshot of the exact wire request core would send next for a chat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InspectedRequest {
    pub method: String,
    pub url: String,
    pub dialect: String,
    pub model: String,
    pub headers: Vec<(String, String)>,
    pub body_json: String,
}

/// The context window the story budget assumes when the price registry does not know the
/// model (the assembler gives the story parts a share of it).
pub(crate) const STORY_FALLBACK_CONTEXT_TOKENS: u64 = 16_384;

/// The ONE story prompt builder (Write mode): what a turn sends and what the inspector shows
/// come from here, sized from the model's context window (`None`: not in the registry).
pub(crate) fn story_prompt_report(
    storage: &bistre_storage::StorageHandle,
    thread_id: &str,
    base_system_prompt: &str,
    history: &[NodeRecord],
    active_scene_beats: Option<&str>,
    context_window: Option<u64>,
) -> BistreResult<story::prompt_assembler::CompiledPromptReport> {
    let state = storage.load_story_thread_state(thread_id)?;
    let all_cards = storage.list_character_cards()?;
    let active_cards: Vec<CharacterCardRecord> = if state.active_character_ids.is_empty() {
        all_cards.into_iter().take(1).collect()
    } else {
        all_cards
            .into_iter()
            .filter(|c| state.active_character_ids.contains(&c.id))
            .collect()
    };
    let active_persona = active_persona(storage, &state)?;
    let entries = storage.list_story_entries(None)?;
    let progressions = storage.list_story_progressions(None)?;
    let chapters = storage.list_story_chapters(thread_id)?;
    Ok(story::prompt_assembler::assemble_story_prompt(
        base_system_prompt,
        &state,
        &active_cards,
        active_persona.as_ref(),
        &entries,
        &progressions,
        &chapters,
        history,
        active_scene_beats,
        context_window.unwrap_or(STORY_FALLBACK_CONTEXT_TOKENS),
    ))
}

impl InProcessEngine {
    /// Reads a character card file (PNG, CHARX/ZIP, or JSON) and saves it with its lore; the
    /// card's permissions are stripped first (imported cards are data, never authority).
    pub(crate) fn import_character_card_file_inner(
        &self,
        path: &std::path::Path,
    ) -> BistreResult<CharacterCardRecord> {
        let raw = std::fs::read(path)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::StorageNotFound, "card_read"))?;
        let bundle = if path
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("png"))
        {
            story::card_io::import_card_png(&raw)?
        } else if path
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("charx") || ext.eq_ignore_ascii_case("zip"))
        {
            story::card_io::import_card_charx(&raw)?
        } else {
            let text = String::from_utf8(raw)
                .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "card_utf8"))?;
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
    }

    /// The story prompt a Write-mode turn would send, with what each part contributed.
    pub(crate) fn inspect_story_prompt_inner(
        &self,
        thread_id: &str,
        active_scene_beats: Option<&str>,
    ) -> BistreResult<story::prompt_assembler::CompiledPromptReport> {
        let thread = self.storage.get_thread(thread_id)?;
        let base_system = thread
            .as_ref()
            .and_then(|t| t.system_prompt_override.clone())
            .unwrap_or_default();
        let nodes = self.storage.list_nodes(thread_id)?;
        let (provider_id, model) = match thread.as_ref() {
            Some(t) => crate::context_breakdown::thread_provider_and_model(&self.storage, t)?,
            None => (None, None),
        };
        let window = model
            .and_then(|m| {
                let scope = match provider_id.as_deref() {
                    Some(pid) => self.catalog_scope(pid).unwrap_or_else(|err| {
                        tracing::debug!(key = err.key.as_key(), "provider gone; plain catalog ids");
                        crate::registry::CatalogScope::ANY
                    }),
                    None => crate::registry::CatalogScope::ANY,
                };
                let base = self.pricing.snapshot().lookup(&scope, &m);
                match provider_id.as_deref() {
                    Some(pid) => crate::provider_prefs::load_provider_advanced(&self.storage, pid)
                        .context_tokens(&m, base),
                    None => base.and_then(|r| r.context_tokens),
                }
            })
            .map(u64::from);
        story_prompt_report(
            &self.storage,
            thread_id,
            &base_system,
            &nodes,
            active_scene_beats,
            window,
        )
    }

    /// The history a run of this chat would send next, with the unsent draft as the newest
    /// message.
    fn inspect_history(
        &self,
        thread: &bistre_protocol::ThreadSummary,
        base_prompt: String,
        ctx_window: Option<u64>,
        reads: Option<crate::registry::ModalitySet>,
        draft: &str,
    ) -> BistreResult<(Vec<NodeRecord>, bistre_protocol::ThreadMode, String)> {
        let thread_id = thread.id.as_str();
        let nodes = self.storage.list_nodes(thread_id)?;
        let leaf = thread
            .active_head_node_id
            .as_deref()
            .or_else(|| nodes.last().map(|n| n.id.as_str()));
        let (mut history, thread_mode, effective_system_prompt) = match leaf {
            Some(leaf_id) => crate::engine_runs::load_turn_context(
                &self.storage,
                thread_id,
                leaf_id,
                &base_prompt,
                ctx_window,
            )?,
            None => (Vec::new(), thread.mode, base_prompt),
        };
        crate::media_wire::carry_generated_media(&mut history, reads);
        if !draft.trim().is_empty() {
            history.push(draft_preview_node(thread_id, leaf, draft));
        }
        Ok((history, thread_mode, effective_system_prompt))
    }

    /// Builds the exact credential-free wire request core would send for `thread_id` (plus
    /// optional unsent `draft`). Fails closed on invalid custom headers/body or missing provider.
    pub(crate) fn inspect_next_request_inner(
        &self,
        thread_id: &str,
        draft: &str,
    ) -> BistreResult<InspectedRequest> {
        let settings = self.storage.load_settings()?;
        let thread = self
            .storage
            .get_thread(thread_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        let assistant = self
            .storage
            .list_assistants()?
            .into_iter()
            .find(|a| a.id == thread.assistant_id);
        let (provider, _keys, model, gen_params) =
            self.resolve_execution_target(&settings, &thread, assistant.as_ref())?;
        let prov_adv = crate::provider_prefs::load_provider_advanced(&self.storage, &provider.id);
        // The same catalog facts as a run: wire, limit, and media fields.
        let spoken = prov_adv.speaking(&provider);
        let prices = self.pricing.snapshot();
        let rates = prices.lookup(&crate::registry::CatalogScope::of(&spoken), &model);
        let wired = crate::media_gen::chat_wire_for(spoken, rates.as_ref());
        let overrides =
            crate::provider_prefs::load_provider_overrides(&self.storage, &provider.id)?;
        let ctx_window = prov_adv.context_tokens(&model, rates).map(u64::from);

        let base_prompt = base_system_prompt(
            &thread,
            assistant.map(|a| a.system_prompt),
            &settings.user_display_name,
        );

        let reads = rates.and_then(|r| r.input_modalities);
        let (history, thread_mode, effective_system_prompt) =
            self.inspect_history(&thread, base_prompt, ctx_window, reads, draft)?;
        let mut tool_catalog = crate::agent_tools::resolve_active_tool_catalog(
            &self.storage,
            Some(&thread.id),
            thread_mode,
        )?;
        crate::agent_tools::offer_turn_tools(
            &mut tool_catalog,
            &self.storage,
            &thread.id,
            thread_mode,
            &history,
        );
        let tools_wire = tool_catalog.wire_tools_for_dialect(wired.dialect);
        let tools_canonical = tool_catalog.canonical_json();
        let replay_ctx = crate::replay_policy::ReplayContext::new(
            wired.dialect,
            &wired.id,
            &model,
            &effective_system_prompt,
            &tools_canonical,
            Some(thread_id),
        );
        let store_enabled = crate::provider_prefs::stores_on_server(
            settings.provider_stateless_default,
            wired.use_server_state_cache,
        );
        let chain = if prov_adv.use_stateful_chaining {
            crate::replay_policy::chain_plan(&history, &replay_ctx, store_enabled)
        } else {
            None
        };
        let reply_prefill =
            crate::provider_prefs::load_thread_reply_prefill(&self.storage, thread_id);
        let opts = crate::providers::StreamRequestOptions {
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
            extra_headers: overrides.headers,
            extra_body_fields: overrides.body_fields,
            media_out: rates.and_then(|r| r.output_modalities).unwrap_or_default(),
            reads,
            voice: prices.voice(&model),
            media_pick: crate::media_gen::load_media_pick(&self.storage)
                .for_model(prices.extras(&model)),
            provider_tools: crate::turn_context::provider_tools_on(
                &self.storage,
                thread_id,
                &prov_adv,
                !tools_wire.is_empty(),
            ),
            paid_tools: crate::paid_tools::paid_tools(
                &prov_adv,
                wired.dialect,
                rates.as_ref(),
                !tools_wire.is_empty(),
            ),
            raw_request_id: None,
        };
        let empty_uploads: HashMap<String, String> = HashMap::new();
        let wire = crate::providers::build_stream_request_full(
            wired.dialect,
            wired.base_url.trim_end_matches('/'),
            &model,
            &effective_system_prompt,
            &history,
            gen_params,
            store_enabled,
            Some(&self.data_dir),
            &empty_uploads,
            &opts,
        );
        let body_json = wire.body.map_or_else(
            || "{}".to_owned(),
            |v| serde_json::to_string_pretty(&v).unwrap_or_else(|_| v.to_string()),
        );
        Ok(InspectedRequest {
            method: wire.method.as_str().to_owned(),
            url: wire.url,
            dialect: wired.dialect.as_str().to_owned(),
            model,
            headers: redacted_headers(&wire.headers),
            body_json,
        })
    }
}

/// The composer's unsent text as the next user turn of a previewed request.
fn draft_preview_node(thread_id: &str, leaf: Option<&str>, draft: &str) -> NodeRecord {
    NodeRecord {
        id: "draft-preview".to_owned(),
        thread_id: thread_id.to_owned(),
        parent_id: leaf.map(str::to_owned),
        role: NodeRole::User,
        content: draft.trim().to_owned(),
        provider_meta_json: None,
        created_at_ms: crate::engine_runs::utc_now_unix_ms(),
    }
}

fn redacted_headers(headers: &reqwest::header::HeaderMap) -> Vec<(String, String)> {
    headers
        .iter()
        .filter(|(name, _)| {
            !matches!(
                name.as_str(),
                "authorization" | "x-api-key" | "x-goog-api-key" | "api-key"
            )
        })
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|v| (name.as_str().to_owned(), v.to_owned()))
        })
        .collect()
}

/// The chat's own system prompt, else its assistant's, with the user's name added as a run
/// adds it.
fn base_system_prompt(
    thread: &bistre_protocol::ThreadSummary,
    assistant_prompt: Option<String>,
    user_name: &str,
) -> String {
    let prompt = thread
        .system_prompt_override
        .clone()
        .or(assistant_prompt)
        .unwrap_or_default();
    crate::engine_runs::with_user_name(prompt, user_name, thread.mode)
}

#[cfg(test)]
mod tests {
    use bistre_protocol::ThreadMode;

    /// The story budget follows the model's context window (one builder for the run and the
    /// inspector; the old code used 32,000 for one and 16,384 for the other, for every model).
    #[test]
    fn the_story_budget_follows_the_models_context_window() -> Result<(), Box<dyn std::error::Error>>
    {
        let dir = tempfile::tempdir()?;
        let storage = bistre_storage::StorageHandle::open(dir.path().join("s.sqlite"))?;
        let thread = storage.create_thread(None, "t", ThreadMode::Write, None, None)?;
        let cap = |window| {
            super::story_prompt_report(&storage, &thread.id, "", &[], None, window)
                .map(|r| r.lore_result.token_budget_cap)
        };
        let unknown = cap(None)?;
        let large = cap(Some(200_000))?;
        assert!(large > unknown, "{large} vs {unknown}");
        assert_eq!(unknown, cap(Some(super::STORY_FALLBACK_CONTEXT_TOKENS))?);
        Ok(())
    }
}

#[cfg(test)]
#[path = "writer_tools_tests.rs"]
mod writer_tools_tests;
