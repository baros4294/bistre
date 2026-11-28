//! Writing & Roleplay Studio FFI entrypoints: character cards, personas, and the story bible
//! as JSON; the writing tools (rewrite, scene brief, chapter summary) typed.

use flutter_rust_bridge::frb;

use super::current_engine;
use bistre_protocol::DiagnosticKey;

/// Lists saved Character Cards (CCv3/V2) as JSON.
#[frb]
pub async fn list_character_cards_json() -> Result<String, String> {
    let engine = current_engine()?;
    let cards = engine
        .list_character_cards()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&cards).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Upserts a Character Card from JSON (auto-recording a Time Machine snapshot) and returns JSON.
#[frb]
pub async fn upsert_character_card_json(card_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let parsed: bistre_protocol::CharacterCardRecord = serde_json::from_str(&card_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let saved = engine
        .upsert_character_card(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&saved).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Deletes a Character Card by ID.
#[frb]
pub async fn delete_character_card(card_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_character_card(card_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Imports a CCv3/V2 PNG, JSON, or `.charx` file from disk and returns the saved card JSON.
#[frb]
pub async fn import_character_card_file_json(file_path: String) -> Result<String, String> {
    let engine = current_engine()?;
    let card = engine
        .import_character_card_file(file_path)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&card).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Exports a Character Card (+ lorebook) as standard CCv3 JSON string.
#[frb]
pub async fn export_character_card_ccv3(card_id: String) -> Result<String, String> {
    let engine = current_engine()?;
    engine
        .export_character_card_ccv3(card_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Lists saved User Personas as JSON.
#[frb]
pub async fn list_user_personas_json() -> Result<String, String> {
    let engine = current_engine()?;
    let items = engine
        .list_user_personas()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&items).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Upserts a User Persona from JSON and returns saved JSON.
#[frb]
pub async fn upsert_user_persona_json(persona_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let parsed: bistre_protocol::UserPersonaRecord = serde_json::from_str(&persona_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let saved = engine
        .upsert_user_persona(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&saved).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Lists unified Story Bible / Lorebook V3 entries as JSON.
#[frb]
pub async fn list_story_entries_json(book_id: Option<String>) -> Result<String, String> {
    let engine = current_engine()?;
    let items = engine
        .list_story_entries(book_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&items).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Upserts a Story Bible / Lorebook V3 entry from JSON and returns saved JSON.
#[frb]
pub async fn upsert_story_entry_json(entry_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let parsed: bistre_protocol::StoryEntryRecord = serde_json::from_str(&entry_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let saved = engine
        .upsert_story_entry(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&saved).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Deletes a Story Bible / Lorebook entry by ID.
#[frb]
pub async fn delete_story_entry(entry_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_story_entry(entry_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Lists Chronological Progressions as JSON.
#[frb]
pub async fn list_story_progressions_json(entry_id: Option<String>) -> Result<String, String> {
    let engine = current_engine()?;
    let items = engine
        .list_story_progressions(entry_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&items).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Adds a chronological progression to a Story Bible entry from JSON.
#[frb]
pub async fn add_story_progression_json(prog_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let parsed: bistre_protocol::StoryProgressionRecord = serde_json::from_str(&prog_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let saved = engine
        .add_story_progression(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&saved).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Lists Manuscript Chapters for `thread_id` as JSON.
#[frb]
pub async fn list_story_chapters_json(thread_id: String) -> Result<String, String> {
    let engine = current_engine()?;
    let items = engine
        .list_story_chapters(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&items).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Upserts a Manuscript Chapter from JSON.
#[frb]
pub async fn upsert_story_chapter_json(chapter_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let parsed: bistre_protocol::StoryChapterRecord = serde_json::from_str(&chapter_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let saved = engine
        .upsert_story_chapter(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&saved).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Lists Manuscript Scenes for `chapter_id` as JSON.
#[frb]
pub async fn list_story_scenes_json(chapter_id: String) -> Result<String, String> {
    let engine = current_engine()?;
    let items = engine
        .list_story_scenes(chapter_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&items).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Upserts a Manuscript Scene from JSON.
#[frb]
pub async fn upsert_story_scene_json(scene_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let parsed: bistre_protocol::StorySceneRecord = serde_json::from_str(&scene_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let saved = engine
        .upsert_story_scene(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&saved).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Loads per-thread Story & Roleplay state as JSON.
#[frb]
pub async fn load_story_thread_state_json(thread_id: String) -> Result<String, String> {
    let engine = current_engine()?;
    let st = engine
        .load_story_thread_state(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&st).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Saves per-thread Story & Roleplay state from JSON.
#[frb]
pub async fn save_story_thread_state_json(state_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let parsed: bistre_protocol::StoryThreadStateRecord = serde_json::from_str(&state_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let saved = engine
        .save_story_thread_state(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&saved).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Lists safe linear-time regex rules as JSON.
#[frb]
pub async fn list_regex_rules_json() -> Result<String, String> {
    let engine = current_engine()?;
    let rules = engine
        .list_regex_rules()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&rules).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Upserts a safe linear-time regex rule from JSON.
#[frb]
pub async fn upsert_regex_rule_json(rule_json: String) -> Result<String, String> {
    let engine = current_engine()?;
    let parsed: bistre_protocol::RegexRuleRecord = serde_json::from_str(&rule_json)
        .map_err(|_| DiagnosticKey::InvalidInput.as_key().to_owned())?;
    let saved = engine
        .upsert_regex_rule(parsed)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&saved).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Lists Time Machine version snapshots for a Story Bible entity as JSON.
#[frb]
pub async fn list_story_snapshots_json(
    entity_type: String,
    entity_id: String,
    limit: u32,
) -> Result<String, String> {
    let engine = current_engine()?;
    let snaps = engine
        .list_story_snapshots(entity_type, entity_id, limit)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&snaps).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// Compiles and returns the exact `CompiledPromptReport` + Lorebook V3 Activation Trace as JSON.
#[frb]
pub async fn inspect_story_prompt_json(
    thread_id: String,
    active_scene_beats: Option<String>,
) -> Result<String, String> {
    let engine = current_engine()?;
    let report = engine
        .inspect_story_prompt(thread_id, active_scene_beats)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    serde_json::to_string(&report).map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())
}

/// The continuity librarian's answer for a chapter: the era summary to save and the
/// contradictions with earlier chapters (shown, never saved).
#[frb]
#[derive(Debug, Clone)]
pub struct FfiChapterSummary {
    pub era_summary: String,
    pub contradictions: Vec<String>,
}

/// The replacement for a manuscript excerpt under `mode` (`rewrite`, `expand`, `shorten`,
/// `polish`), with the scene text `context` around it; nothing is saved.
#[frb]
pub async fn rewrite_passage(
    thread_id: String,
    mode: String,
    excerpt: String,
    context: String,
) -> Result<String, String> {
    current_engine()?
        .rewrite_passage(thread_id, mode, excerpt, context)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// A writing brief for a scene from its title and beats as they stand in the editor.
#[frb]
pub async fn plan_scene(thread_id: String, title: String, beats: String) -> Result<String, String> {
    current_engine()?
        .plan_scene(thread_id, title, beats)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// The era summary of a chapter's saved scenes and its contradictions with earlier chapters.
#[frb]
pub async fn summarize_chapter(
    thread_id: String,
    chapter_id: String,
) -> Result<FfiChapterSummary, String> {
    let s = current_engine()?
        .summarize_chapter(thread_id, chapter_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(FfiChapterSummary {
        era_summary: s.era_summary,
        contradictions: s.contradictions,
    })
}
