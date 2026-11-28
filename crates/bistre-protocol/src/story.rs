//! Canonical Writing & Roleplay Studio domain types (CCv3/V2 Cards,
//! Personas, Unified Codex & Lorebook V3, Chronological Progressions, Chapters/Scenes,
//! Safe Linear-Time Regex Rules, Creative Samplers, and Time Machine Snapshots).

use serde::{Deserialize, Serialize};

/// Character Card V3 / V2 record persisted in local SQLite (`character_cards`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CharacterCardRecord {
    #[serde(default)]
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub nickname: String,
    #[serde(default = "default_cc_spec_version")]
    pub spec_version: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub personality: String,
    #[serde(default)]
    pub scenario: String,
    #[serde(default)]
    pub first_message: String,
    #[serde(default)]
    pub alternate_greetings: Vec<String>,
    #[serde(default)]
    pub system_prompt: String,
    #[serde(default)]
    pub post_history_instructions: String,
    #[serde(default)]
    pub creator_notes: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub avatar_path: String,
    #[serde(default = "default_empty_json_obj")]
    pub extensions_json: String,
    #[serde(default)]
    pub updated_at_ms: i64,
}

fn default_cc_spec_version() -> String {
    "3.0".to_owned()
}

fn default_empty_json_obj() -> String {
    "{}".to_owned()
}

/// User Persona record (`user_personas`) injected as `{{user}}` context during roleplay or writing.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserPersonaRecord {
    #[serde(default)]
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub avatar_path: String,
    #[serde(default)]
    pub is_default: bool,
    #[serde(default)]
    pub updated_at_ms: i64,
}

/// Unified Story Bible (Codex) & Lorebook V3 entry (`story_entries`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "Canonical CCv3/Lorebook V3 specification flags map cleanly to explicit booleans."
)]
pub struct StoryEntryRecord {
    #[serde(default)]
    pub id: String,
    #[serde(default = "default_book_id")]
    pub book_id: String,
    /// One of: `character`, `location`, `object`, `lore`, `subplot`, `rule`.
    #[serde(default = "default_entry_category")]
    pub category: String,
    pub name: String,
    #[serde(default)]
    pub keys: Vec<String>,
    #[serde(default)]
    pub secondary_keys: Vec<String>,
    /// One of: `and_any`, `and_all`, `not_any`, `not_all`.
    #[serde(default = "default_selective_logic")]
    pub selective_logic: String,
    #[serde(default)]
    pub content: String,
    #[serde(default = "default_insertion_order")]
    pub insertion_order: i32,
    #[serde(default = "default_priority")]
    pub priority: i32,
    /// One of: `before_char`, `after_char`, `at_depth`.
    #[serde(default = "default_position")]
    pub position: String,
    #[serde(default = "default_depth")]
    pub depth: u32,
    #[serde(default = "default_role")]
    pub role: String,
    #[serde(default)]
    pub constant: bool,
    #[serde(default)]
    pub use_regex: bool,
    #[serde(default)]
    pub case_sensitive: bool,
    #[serde(default)]
    pub sticky_turns: u32,
    #[serde(default)]
    pub cooldown_turns: u32,
    #[serde(default)]
    pub delay_turns: u32,
    #[serde(default)]
    pub decorators: Vec<String>,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub updated_at_ms: i64,
}

fn default_book_id() -> String {
    "default_book".to_owned()
}
fn default_entry_category() -> String {
    "lore".to_owned()
}
fn default_selective_logic() -> String {
    "and_any".to_owned()
}
const fn default_insertion_order() -> i32 {
    100
}
const fn default_priority() -> i32 {
    10
}
fn default_position() -> String {
    "after_char".to_owned()
}
const fn default_depth() -> u32 {
    4
}
fn default_role() -> String {
    "system".to_owned()
}
const fn default_true() -> bool {
    true
}

impl Default for StoryEntryRecord {
    fn default() -> Self {
        Self {
            id: String::new(),
            book_id: default_book_id(),
            category: default_entry_category(),
            name: String::new(),
            keys: Vec::new(),
            secondary_keys: Vec::new(),
            selective_logic: default_selective_logic(),
            content: String::new(),
            insertion_order: default_insertion_order(),
            priority: default_priority(),
            position: default_position(),
            depth: default_depth(),
            role: default_role(),
            constant: false,
            use_regex: false,
            case_sensitive: false,
            sticky_turns: 0,
            cooldown_turns: 0,
            delay_turns: 0,
            decorators: Vec::new(),
            enabled: true,
            updated_at_ms: 0,
        }
    }
}

/// Chronological character/world update gated by `chapter_order` (zero spoilers).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoryProgressionRecord {
    #[serde(default)]
    pub id: String,
    pub entry_id: String,
    pub chapter_order: u32,
    #[serde(default)]
    pub scene_order: u32,
    pub delta_text: String,
    #[serde(default)]
    pub created_at_ms: i64,
}

/// Long-form fiction Manuscript Chapter (`story_chapters`) carrying optional Continuity Librarian Era Summary.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoryChapterRecord {
    #[serde(default)]
    pub id: String,
    pub thread_id: String,
    pub order_index: u32,
    pub title: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub era_summary: String,
    #[serde(default)]
    pub created_at_ms: i64,
}

/// Long-form fiction Manuscript Scene (`story_scenes`) pairing Beats -> Prose.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StorySceneRecord {
    #[serde(default)]
    pub id: String,
    pub chapter_id: String,
    pub order_index: u32,
    pub title: String,
    #[serde(default)]
    pub beats_text: String,
    #[serde(default)]
    pub prose_text: String,
    #[serde(default)]
    pub pov_character_id: Option<String>,
    #[serde(default)]
    pub word_count: u32,
    #[serde(default)]
    pub updated_at_ms: i64,
}

/// Creative samplers & anti-cliché phrase bias settings stored cleanly with integer milli-units (zero float drift).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreativeSamplerConfig {
    #[serde(default)]
    pub min_p_milli: Option<u32>,
    #[serde(default)]
    pub top_k: Option<u32>,
    #[serde(default)]
    pub repetition_penalty_milli: Option<u32>,
    #[serde(default)]
    pub dry_multiplier_milli: Option<u32>,
    #[serde(default)]
    pub xtc_probability_milli: Option<u32>,
    #[serde(default)]
    pub banned_phrases: Vec<String>,
}

/// The continuity librarian's answer for one chapter: the era summary to save and the
/// statements that conflict with earlier chapters (shown to the author, never saved).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChapterSummary {
    pub era_summary: String,
    pub contradictions: Vec<String>,
}

/// Per-thread Story & Roleplay binding (`story_thread_state`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoryThreadStateRecord {
    pub thread_id: String,
    #[serde(default)]
    pub active_character_ids: Vec<String>,
    #[serde(default)]
    pub user_persona_id: Option<String>,
    #[serde(default)]
    pub active_book_ids: Vec<String>,
    #[serde(default)]
    pub author_note: String,
    #[serde(default = "default_depth")]
    pub author_note_depth: u32,
    #[serde(default)]
    pub story_memory: String,
    /// One of: `natural`, `round_robin`, `manual`.
    #[serde(default = "default_group_mode")]
    pub group_turn_mode: String,
    #[serde(default)]
    pub dialogue_styling: bool,
    #[serde(default)]
    pub samplers: CreativeSamplerConfig,
    #[serde(default)]
    pub prewriter_enabled: bool,
    #[serde(default)]
    pub librarian_enabled: bool,
    #[serde(default = "default_chapter_one")]
    pub current_chapter_order: u32,
    #[serde(default)]
    pub updated_at_ms: i64,
}

fn default_group_mode() -> String {
    "natural".to_owned()
}
const fn default_chapter_one() -> u32 {
    1
}

impl Default for StoryThreadStateRecord {
    fn default() -> Self {
        Self {
            thread_id: String::new(),
            active_character_ids: Vec::new(),
            user_persona_id: None,
            active_book_ids: vec![default_book_id()],
            author_note: String::new(),
            author_note_depth: default_depth(),
            story_memory: String::new(),
            group_turn_mode: default_group_mode(),
            dialogue_styling: false,
            samplers: CreativeSamplerConfig::default(),
            prewriter_enabled: false,
            librarian_enabled: false,
            current_chapter_order: 1,
            updated_at_ms: 0,
        }
    }
}

/// Safe linear-time Rust `regex` rule (`regex_rules`) for display or prompt transforms.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegexRuleRecord {
    #[serde(default)]
    pub id: String,
    pub name: String,
    pub pattern: String,
    #[serde(default)]
    pub replacement: String,
    /// One of: `display_only`, `prompt_outgoing`, `incoming_commit`.
    #[serde(default = "default_regex_scope")]
    pub scope: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub order_index: i32,
}

fn default_regex_scope() -> String {
    "display_only".to_owned()
}

/// Time Machine automatic version snapshot for Character Cards, Story Entries, or Scenes.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StorySnapshotRecord {
    pub id: String,
    pub entity_type: String,
    pub entity_id: String,
    pub snapshot_json: String,
    pub created_at_ms: i64,
}
