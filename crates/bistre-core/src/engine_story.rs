//! Story (Write mode) use cases of `InProcessEngine`, kept apart from `engine_impl.rs` so every
//! module stays under 1,500 lines (Spec 00 section 5).

use bistre_protocol::{BistreResult, CharacterCardRecord};

use crate::{InProcessEngine, story};

/// The context window the story budget assumes when the price registry does not know the
/// model (the assembler gives the story parts a share of it).
pub(crate) const STORY_FALLBACK_CONTEXT_TOKENS: u64 = 16_384;

/// The ONE story prompt builder (Write mode): what a turn sends and what the inspector shows
/// come from here, sized from the model's context window (`None`: not in the registry).
pub(crate) fn story_prompt_report(
    storage: &bistre_storage::StorageHandle,
    thread_id: &str,
    base_system_prompt: &str,
    history: &[bistre_protocol::NodeRecord],
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
    let personas = storage.list_user_personas()?;
    let active_persona = state
        .user_persona_id
        .as_deref()
        .and_then(|pid| personas.iter().find(|p| p.id == pid))
        .or_else(|| personas.iter().find(|p| p.is_default));
    let entries = storage.list_story_entries(None)?;
    let progressions = storage.list_story_progressions(None)?;
    let chapters = storage.list_story_chapters(thread_id)?;
    Ok(story::prompt_assembler::assemble_story_prompt(
        base_system_prompt,
        &state,
        &active_cards,
        active_persona,
        &entries,
        &progressions,
        &chapters,
        history,
        active_scene_beats,
        context_window.unwrap_or(STORY_FALLBACK_CONTEXT_TOKENS),
    ))
}

impl InProcessEngine {
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
        let model = match thread.as_ref() {
            Some(t) => crate::context_breakdown::thread_model_id(&self.storage, t)?,
            None => None,
        };
        let window = model
            .and_then(|m| {
                self.pricing
                    .snapshot()
                    .lookup(&m)
                    .and_then(|r| r.context_tokens)
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
