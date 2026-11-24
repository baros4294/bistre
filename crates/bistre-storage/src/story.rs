//! Schema v7 Expand-Contract tables and CRUD for Bistre's Writing & Roleplay Studio.
//!
//! Strictly additive migration (`v6_to_v7`) so N-1 binaries remain safely readable.

use bistre_protocol::{
    BistreResult, CharacterCardRecord, CreativeSamplerConfig, RegexRuleRecord, StoryChapterRecord,
    StoryEntryRecord, StoryProgressionRecord, StorySceneRecord, StorySnapshotRecord,
    StoryThreadStateRecord, UserPersonaRecord,
};
use rusqlite::{OptionalExtension, params};
use uuid::Uuid;

use crate::{StorageHandle, map_sqlite_err, now_unix_ms};

/// Expand-Contract Schema v7 SQL adding Story Bible, `CCv3` Cards, Personas, Progressions,
/// Manuscript Chapters/Scenes, Regex Rules, and Time Machine Snapshots.
pub const SCHEMA_V7_EXPAND_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS character_cards (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    nickname TEXT NOT NULL DEFAULT '',
    spec_version TEXT NOT NULL DEFAULT '3.0',
    description TEXT NOT NULL DEFAULT '',
    personality TEXT NOT NULL DEFAULT '',
    scenario TEXT NOT NULL DEFAULT '',
    first_message TEXT NOT NULL DEFAULT '',
    alternate_greetings_json TEXT NOT NULL DEFAULT '[]',
    system_prompt TEXT NOT NULL DEFAULT '',
    post_history_instructions TEXT NOT NULL DEFAULT '',
    creator_notes TEXT NOT NULL DEFAULT '',
    tags_json TEXT NOT NULL DEFAULT '[]',
    avatar_path TEXT NOT NULL DEFAULT '',
    extensions_json TEXT NOT NULL DEFAULT '{}',
    updated_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS user_personas (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    avatar_path TEXT NOT NULL DEFAULT '',
    is_default INTEGER NOT NULL DEFAULT 0,
    updated_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS story_books (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    created_at_ms INTEGER NOT NULL
);

INSERT OR IGNORE INTO story_books (id, name, description, created_at_ms)
VALUES ('default_book', 'Story Bible', 'Default unified codex and lorebook', 0);

CREATE TABLE IF NOT EXISTS story_entries (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL DEFAULT 'default_book',
    category TEXT NOT NULL DEFAULT 'lore',
    name TEXT NOT NULL,
    keys_json TEXT NOT NULL DEFAULT '[]',
    secondary_keys_json TEXT NOT NULL DEFAULT '[]',
    selective_logic TEXT NOT NULL DEFAULT 'and_any',
    content TEXT NOT NULL DEFAULT '',
    insertion_order INTEGER NOT NULL DEFAULT 100,
    priority INTEGER NOT NULL DEFAULT 10,
    position TEXT NOT NULL DEFAULT 'after_char',
    depth INTEGER NOT NULL DEFAULT 4,
    role TEXT NOT NULL DEFAULT 'system',
    constant INTEGER NOT NULL DEFAULT 0,
    use_regex INTEGER NOT NULL DEFAULT 0,
    case_sensitive INTEGER NOT NULL DEFAULT 0,
    sticky_turns INTEGER NOT NULL DEFAULT 0,
    cooldown_turns INTEGER NOT NULL DEFAULT 0,
    delay_turns INTEGER NOT NULL DEFAULT 0,
    decorators_json TEXT NOT NULL DEFAULT '[]',
    enabled INTEGER NOT NULL DEFAULT 1,
    updated_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_story_entries_book ON story_entries (book_id, insertion_order ASC);

CREATE TABLE IF NOT EXISTS story_progressions (
    id TEXT PRIMARY KEY NOT NULL,
    entry_id TEXT NOT NULL REFERENCES story_entries(id) ON DELETE CASCADE,
    chapter_order INTEGER NOT NULL DEFAULT 1,
    scene_order INTEGER NOT NULL DEFAULT 0,
    delta_text TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_story_progressions_entry
    ON story_progressions (entry_id, chapter_order ASC, scene_order ASC);

CREATE TABLE IF NOT EXISTS story_chapters (
    id TEXT PRIMARY KEY NOT NULL,
    thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    order_index INTEGER NOT NULL DEFAULT 1,
    title TEXT NOT NULL,
    summary TEXT NOT NULL DEFAULT '',
    era_summary TEXT NOT NULL DEFAULT '',
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_story_chapters_thread
    ON story_chapters (thread_id, order_index ASC);

CREATE TABLE IF NOT EXISTS story_scenes (
    id TEXT PRIMARY KEY NOT NULL,
    chapter_id TEXT NOT NULL REFERENCES story_chapters(id) ON DELETE CASCADE,
    order_index INTEGER NOT NULL DEFAULT 1,
    title TEXT NOT NULL,
    beats_text TEXT NOT NULL DEFAULT '',
    prose_text TEXT NOT NULL DEFAULT '',
    pov_character_id TEXT,
    word_count INTEGER NOT NULL DEFAULT 0,
    updated_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_story_scenes_chapter
    ON story_scenes (chapter_id, order_index ASC);

CREATE TABLE IF NOT EXISTS story_thread_state (
    thread_id TEXT PRIMARY KEY NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    active_character_ids_json TEXT NOT NULL DEFAULT '[]',
    user_persona_id TEXT,
    active_book_ids_json TEXT NOT NULL DEFAULT '["default_book"]',
    author_note TEXT NOT NULL DEFAULT '',
    author_note_depth INTEGER NOT NULL DEFAULT 4,
    story_memory TEXT NOT NULL DEFAULT '',
    group_turn_mode TEXT NOT NULL DEFAULT 'natural',
    dialogue_styling INTEGER NOT NULL DEFAULT 0,
    samplers_json TEXT NOT NULL DEFAULT '{}',
    prewriter_enabled INTEGER NOT NULL DEFAULT 0,
    librarian_enabled INTEGER NOT NULL DEFAULT 0,
    current_chapter_order INTEGER NOT NULL DEFAULT 1,
    updated_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS regex_rules (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    pattern TEXT NOT NULL,
    replacement TEXT NOT NULL DEFAULT '',
    scope TEXT NOT NULL DEFAULT 'display_only',
    enabled INTEGER NOT NULL DEFAULT 1,
    order_index INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS story_snapshots (
    id TEXT PRIMARY KEY NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    snapshot_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_story_snapshots_entity
    ON story_snapshots (entity_type, entity_id, created_at_ms DESC);
"#;

impl StorageHandle {
    /// Upserts a Character Card (`CCv3`/V2) and automatically records a Time Machine snapshot.
    pub fn upsert_character_card(
        &self,
        mut card: CharacterCardRecord,
    ) -> BistreResult<CharacterCardRecord> {
        if card.id.trim().is_empty() {
            card.id = Uuid::now_v7().to_string();
        }
        card.updated_at_ms = now_unix_ms();
        let alt_json =
            serde_json::to_string(&card.alternate_greetings).unwrap_or_else(|_| "[]".to_owned());
        let tags_json = serde_json::to_string(&card.tags).unwrap_or_else(|_| "[]".to_owned());
        let snap_json = serde_json::to_string(&card).unwrap_or_else(|_| "{}".to_owned());
        let snap_id = Uuid::now_v7().to_string();
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO character_cards (
                    id, name, nickname, spec_version, description, personality, scenario,
                    first_message, alternate_greetings_json, system_prompt, post_history_instructions,
                    creator_notes, tags_json, avatar_path, extensions_json, updated_at_ms
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
                 ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    nickname = excluded.nickname,
                    spec_version = excluded.spec_version,
                    description = excluded.description,
                    personality = excluded.personality,
                    scenario = excluded.scenario,
                    first_message = excluded.first_message,
                    alternate_greetings_json = excluded.alternate_greetings_json,
                    system_prompt = excluded.system_prompt,
                    post_history_instructions = excluded.post_history_instructions,
                    creator_notes = excluded.creator_notes,
                    tags_json = excluded.tags_json,
                    avatar_path = excluded.avatar_path,
                    extensions_json = excluded.extensions_json,
                    updated_at_ms = excluded.updated_at_ms",
                params![
                    card.id,
                    card.name,
                    card.nickname,
                    card.spec_version,
                    card.description,
                    card.personality,
                    card.scenario,
                    card.first_message,
                    alt_json,
                    card.system_prompt,
                    card.post_history_instructions,
                    card.creator_notes,
                    tags_json,
                    card.avatar_path,
                    card.extensions_json,
                    card.updated_at_ms
                ],
            )
            .map_err(map_sqlite_err)?;
            conn.execute(
                "INSERT INTO story_snapshots (id, entity_type, entity_id, snapshot_json, created_at_ms)
                 VALUES (?1, 'character_card', ?2, ?3, ?4)",
                params![snap_id, card.id, snap_json, card.updated_at_ms],
            )
            .map_err(map_sqlite_err)?;
            Ok(card)
        })
    }

    /// Lists all saved Character Cards ordered newest-updated first.
    pub fn list_character_cards(&self) -> BistreResult<Vec<CharacterCardRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, name, nickname, spec_version, description, personality, scenario,
                        first_message, alternate_greetings_json, system_prompt, post_history_instructions,
                        creator_notes, tags_json, avatar_path, extensions_json, updated_at_ms
                 FROM character_cards ORDER BY updated_at_ms DESC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([], map_character_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Deletes a Character Card by ID.
    pub fn delete_character_card(&self, card_id: String) -> BistreResult<()> {
        self.write(move |conn| {
            conn.execute("DELETE FROM character_cards WHERE id = ?1", [&card_id])
                .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Upserts a User Persona record.
    pub fn upsert_user_persona(
        &self,
        mut persona: UserPersonaRecord,
    ) -> BistreResult<UserPersonaRecord> {
        if persona.id.trim().is_empty() {
            persona.id = Uuid::now_v7().to_string();
        }
        persona.updated_at_ms = now_unix_ms();
        self.write(move |conn| {
            if persona.is_default {
                conn.execute("UPDATE user_personas SET is_default = 0", [])
                    .map_err(map_sqlite_err)?;
            }
            conn.execute(
                "INSERT INTO user_personas (id, name, description, avatar_path, is_default, updated_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    description = excluded.description,
                    avatar_path = excluded.avatar_path,
                    is_default = excluded.is_default,
                    updated_at_ms = excluded.updated_at_ms",
                params![
                    persona.id,
                    persona.name,
                    persona.description,
                    persona.avatar_path,
                    i64::from(persona.is_default),
                    persona.updated_at_ms
                ],
            )
            .map_err(map_sqlite_err)?;
            Ok(persona)
        })
    }

    /// Lists all User Personas ordered default first.
    pub fn list_user_personas(&self) -> BistreResult<Vec<UserPersonaRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, name, description, avatar_path, is_default, updated_at_ms
                 FROM user_personas ORDER BY is_default DESC, updated_at_ms DESC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([], |row| {
                let def_i64: i64 = row.get(4)?;
                Ok(UserPersonaRecord {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    description: row.get(2)?,
                    avatar_path: row.get(3)?,
                    is_default: def_i64 != 0,
                    updated_at_ms: row.get(5)?,
                })
            })
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Upserts a unified Story Bible / Lorebook V3 entry and records a Time Machine snapshot.
    pub fn upsert_story_entry(
        &self,
        mut entry: StoryEntryRecord,
    ) -> BistreResult<StoryEntryRecord> {
        if entry.id.trim().is_empty() {
            entry.id = Uuid::now_v7().to_string();
        }
        entry.updated_at_ms = now_unix_ms();
        let keys_json = serde_json::to_string(&entry.keys).unwrap_or_else(|_| "[]".to_owned());
        let sec_json =
            serde_json::to_string(&entry.secondary_keys).unwrap_or_else(|_| "[]".to_owned());
        let dec_json = serde_json::to_string(&entry.decorators).unwrap_or_else(|_| "[]".to_owned());
        let snap_json = serde_json::to_string(&entry).unwrap_or_else(|_| "{}".to_owned());
        let snap_id = Uuid::now_v7().to_string();
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO story_entries (
                    id, book_id, category, name, keys_json, secondary_keys_json, selective_logic,
                    content, insertion_order, priority, position, depth, role, constant,
                    use_regex, case_sensitive, sticky_turns, cooldown_turns, delay_turns,
                    decorators_json, enabled, updated_at_ms
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22)
                 ON CONFLICT(id) DO UPDATE SET
                    book_id = excluded.book_id,
                    category = excluded.category,
                    name = excluded.name,
                    keys_json = excluded.keys_json,
                    secondary_keys_json = excluded.secondary_keys_json,
                    selective_logic = excluded.selective_logic,
                    content = excluded.content,
                    insertion_order = excluded.insertion_order,
                    priority = excluded.priority,
                    position = excluded.position,
                    depth = excluded.depth,
                    role = excluded.role,
                    constant = excluded.constant,
                    use_regex = excluded.use_regex,
                    case_sensitive = excluded.case_sensitive,
                    sticky_turns = excluded.sticky_turns,
                    cooldown_turns = excluded.cooldown_turns,
                    delay_turns = excluded.delay_turns,
                    decorators_json = excluded.decorators_json,
                    enabled = excluded.enabled,
                    updated_at_ms = excluded.updated_at_ms",
                params![
                    entry.id,
                    entry.book_id,
                    entry.category,
                    entry.name,
                    keys_json,
                    sec_json,
                    entry.selective_logic,
                    entry.content,
                    entry.insertion_order,
                    entry.priority,
                    entry.position,
                    entry.depth,
                    entry.role,
                    i64::from(entry.constant),
                    i64::from(entry.use_regex),
                    i64::from(entry.case_sensitive),
                    entry.sticky_turns,
                    entry.cooldown_turns,
                    entry.delay_turns,
                    dec_json,
                    i64::from(entry.enabled),
                    entry.updated_at_ms
                ],
            )
            .map_err(map_sqlite_err)?;
            conn.execute(
                "INSERT INTO story_snapshots (id, entity_type, entity_id, snapshot_json, created_at_ms)
                 VALUES (?1, 'story_entry', ?2, ?3, ?4)",
                params![snap_id, entry.id, snap_json, entry.updated_at_ms],
            )
            .map_err(map_sqlite_err)?;
            Ok(entry)
        })
    }

    /// Lists Story Bible / Lorebook entries (optionally filtered by `book_id`).
    pub fn list_story_entries(&self, book_id: Option<&str>) -> BistreResult<Vec<StoryEntryRecord>> {
        let conn = self.open_reader()?;
        if let Some(bid) = book_id {
            let mut stmt = conn
                .prepare(
                    "SELECT id, book_id, category, name, keys_json, secondary_keys_json, selective_logic,
                            content, insertion_order, priority, position, depth, role, constant,
                            use_regex, case_sensitive, sticky_turns, cooldown_turns, delay_turns,
                            decorators_json, enabled, updated_at_ms
                     FROM story_entries WHERE book_id = ?1 ORDER BY insertion_order ASC, name ASC",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt
                .query_map([bid], map_story_entry_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        } else {
            let mut stmt = conn
                .prepare(
                    "SELECT id, book_id, category, name, keys_json, secondary_keys_json, selective_logic,
                            content, insertion_order, priority, position, depth, role, constant,
                            use_regex, case_sensitive, sticky_turns, cooldown_turns, delay_turns,
                            decorators_json, enabled, updated_at_ms
                     FROM story_entries ORDER BY insertion_order ASC, name ASC",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt
                .query_map([], map_story_entry_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        }
    }

    /// Deletes a Story Bible entry by ID.
    pub fn delete_story_entry(&self, entry_id: String) -> BistreResult<()> {
        self.write(move |conn| {
            conn.execute("DELETE FROM story_entries WHERE id = ?1", [&entry_id])
                .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Adds a chronological progression to a Story Bible entry.
    pub fn add_story_progression(
        &self,
        mut prog: StoryProgressionRecord,
    ) -> BistreResult<StoryProgressionRecord> {
        if prog.id.trim().is_empty() {
            prog.id = Uuid::now_v7().to_string();
        }
        prog.created_at_ms = now_unix_ms();
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO story_progressions (id, entry_id, chapter_order, scene_order, delta_text, created_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    prog.id,
                    prog.entry_id,
                    prog.chapter_order,
                    prog.scene_order,
                    prog.delta_text,
                    prog.created_at_ms
                ],
            )
            .map_err(map_sqlite_err)?;
            Ok(prog)
        })
    }

    /// Lists chronological progressions for an entry (or all entries if `None`).
    pub fn list_story_progressions(
        &self,
        entry_id: Option<&str>,
    ) -> BistreResult<Vec<StoryProgressionRecord>> {
        let conn = self.open_reader()?;
        if let Some(eid) = entry_id {
            let mut stmt = conn
                .prepare(
                    "SELECT id, entry_id, chapter_order, scene_order, delta_text, created_at_ms
                     FROM story_progressions WHERE entry_id = ?1
                     ORDER BY chapter_order ASC, scene_order ASC",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt
                .query_map([eid], map_progression_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        } else {
            let mut stmt = conn
                .prepare(
                    "SELECT id, entry_id, chapter_order, scene_order, delta_text, created_at_ms
                     FROM story_progressions
                     ORDER BY chapter_order ASC, scene_order ASC",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt
                .query_map([], map_progression_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        }
    }

    /// Upserts a Manuscript Chapter record.
    pub fn upsert_story_chapter(
        &self,
        mut chapter: StoryChapterRecord,
    ) -> BistreResult<StoryChapterRecord> {
        if chapter.id.trim().is_empty() {
            chapter.id = Uuid::now_v7().to_string();
        }
        if chapter.created_at_ms == 0 {
            chapter.created_at_ms = now_unix_ms();
        }
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO story_chapters (id, thread_id, order_index, title, summary, era_summary, created_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(id) DO UPDATE SET
                    order_index = excluded.order_index,
                    title = excluded.title,
                    summary = excluded.summary,
                    era_summary = excluded.era_summary",
                params![
                    chapter.id,
                    chapter.thread_id,
                    chapter.order_index,
                    chapter.title,
                    chapter.summary,
                    chapter.era_summary,
                    chapter.created_at_ms
                ],
            )
            .map_err(map_sqlite_err)?;
            Ok(chapter)
        })
    }

    /// Lists Manuscript Chapters for a thread ordered by `order_index`.
    pub fn list_story_chapters(&self, thread_id: &str) -> BistreResult<Vec<StoryChapterRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, thread_id, order_index, title, summary, era_summary, created_at_ms
                 FROM story_chapters WHERE thread_id = ?1 ORDER BY order_index ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([thread_id], |row| {
                Ok(StoryChapterRecord {
                    id: row.get(0)?,
                    thread_id: row.get(1)?,
                    order_index: row.get(2)?,
                    title: row.get(3)?,
                    summary: row.get(4)?,
                    era_summary: row.get(5)?,
                    created_at_ms: row.get(6)?,
                })
            })
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Upserts a Manuscript Scene record and updates word count automatically.
    pub fn upsert_story_scene(
        &self,
        mut scene: StorySceneRecord,
    ) -> BistreResult<StorySceneRecord> {
        if scene.id.trim().is_empty() {
            scene.id = Uuid::now_v7().to_string();
        }
        scene.word_count =
            u32::try_from(scene.prose_text.split_whitespace().count()).unwrap_or(u32::MAX);
        scene.updated_at_ms = now_unix_ms();
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO story_scenes (id, chapter_id, order_index, title, beats_text, prose_text, pov_character_id, word_count, updated_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(id) DO UPDATE SET
                    order_index = excluded.order_index,
                    title = excluded.title,
                    beats_text = excluded.beats_text,
                    prose_text = excluded.prose_text,
                    pov_character_id = excluded.pov_character_id,
                    word_count = excluded.word_count,
                    updated_at_ms = excluded.updated_at_ms",
                params![
                    scene.id,
                    scene.chapter_id,
                    scene.order_index,
                    scene.title,
                    scene.beats_text,
                    scene.prose_text,
                    scene.pov_character_id,
                    scene.word_count,
                    scene.updated_at_ms
                ],
            )
            .map_err(map_sqlite_err)?;
            Ok(scene)
        })
    }

    /// Lists Manuscript Scenes belonging to `chapter_id`.
    pub fn list_story_scenes(&self, chapter_id: &str) -> BistreResult<Vec<StorySceneRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, chapter_id, order_index, title, beats_text, prose_text, pov_character_id, word_count, updated_at_ms
                 FROM story_scenes WHERE chapter_id = ?1 ORDER BY order_index ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([chapter_id], |row| {
                Ok(StorySceneRecord {
                    id: row.get(0)?,
                    chapter_id: row.get(1)?,
                    order_index: row.get(2)?,
                    title: row.get(3)?,
                    beats_text: row.get(4)?,
                    prose_text: row.get(5)?,
                    pov_character_id: row.get(6)?,
                    word_count: row.get(7)?,
                    updated_at_ms: row.get(8)?,
                })
            })
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Loads per-thread Story & Roleplay state (returning sensible defaults if unset).
    pub fn load_story_thread_state(&self, thread_id: &str) -> BistreResult<StoryThreadStateRecord> {
        let conn = self.open_reader()?;
        let found: Option<StoryThreadStateRecord> = conn
            .query_row(
                "SELECT thread_id, active_character_ids_json, user_persona_id, active_book_ids_json,
                        author_note, author_note_depth, story_memory, group_turn_mode, dialogue_styling,
                        samplers_json, prewriter_enabled, librarian_enabled, current_chapter_order, updated_at_ms
                 FROM story_thread_state WHERE thread_id = ?1",
                [thread_id],
                |row| {
                    let chars_raw: String = row.get(1)?;
                    let books_raw: String = row.get(3)?;
                    let samplers_raw: String = row.get(9)?;
                    let dialogue_i64: i64 = row.get(8)?;
                    let pre_i64: i64 = row.get(10)?;
                    let lib_i64: i64 = row.get(11)?;
                    Ok(StoryThreadStateRecord {
                        thread_id: row.get(0)?,
                        active_character_ids: json_column(&chars_raw)?,
                        user_persona_id: row.get(2)?,
                        active_book_ids: json_column(&books_raw)?,
                        author_note: row.get(4)?,
                        author_note_depth: row.get(5)?,
                        story_memory: row.get(6)?,
                        group_turn_mode: row.get(7)?,
                        dialogue_styling: dialogue_i64 != 0,
                        samplers: json_column::<CreativeSamplerConfig>(&samplers_raw)?,
                        prewriter_enabled: pre_i64 != 0,
                        librarian_enabled: lib_i64 != 0,
                        current_chapter_order: row.get(12)?,
                        updated_at_ms: row.get(13)?,
                    })
                },
            )
            .optional()
            .map_err(map_sqlite_err)?;

        Ok(found.unwrap_or_else(|| StoryThreadStateRecord {
            thread_id: thread_id.to_owned(),
            ..StoryThreadStateRecord::default()
        }))
    }

    /// Saves per-thread Story & Roleplay state atomically.
    pub fn save_story_thread_state(
        &self,
        mut state: StoryThreadStateRecord,
    ) -> BistreResult<StoryThreadStateRecord> {
        state.updated_at_ms = now_unix_ms();
        let chars_json =
            serde_json::to_string(&state.active_character_ids).unwrap_or_else(|_| "[]".to_owned());
        let books_json =
            serde_json::to_string(&state.active_book_ids).unwrap_or_else(|_| "[]".to_owned());
        let samplers_json =
            serde_json::to_string(&state.samplers).unwrap_or_else(|_| "{}".to_owned());
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO story_thread_state (
                    thread_id, active_character_ids_json, user_persona_id, active_book_ids_json,
                    author_note, author_note_depth, story_memory, group_turn_mode, dialogue_styling,
                    samplers_json, prewriter_enabled, librarian_enabled, current_chapter_order, updated_at_ms
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
                 ON CONFLICT(thread_id) DO UPDATE SET
                    active_character_ids_json = excluded.active_character_ids_json,
                    user_persona_id = excluded.user_persona_id,
                    active_book_ids_json = excluded.active_book_ids_json,
                    author_note = excluded.author_note,
                    author_note_depth = excluded.author_note_depth,
                    story_memory = excluded.story_memory,
                    group_turn_mode = excluded.group_turn_mode,
                    dialogue_styling = excluded.dialogue_styling,
                    samplers_json = excluded.samplers_json,
                    prewriter_enabled = excluded.prewriter_enabled,
                    librarian_enabled = excluded.librarian_enabled,
                    current_chapter_order = excluded.current_chapter_order,
                    updated_at_ms = excluded.updated_at_ms",
                params![
                    state.thread_id,
                    chars_json,
                    state.user_persona_id,
                    books_json,
                    state.author_note,
                    state.author_note_depth,
                    state.story_memory,
                    state.group_turn_mode,
                    i64::from(state.dialogue_styling),
                    samplers_json,
                    i64::from(state.prewriter_enabled),
                    i64::from(state.librarian_enabled),
                    state.current_chapter_order,
                    state.updated_at_ms
                ],
            )
            .map_err(map_sqlite_err)?;
            Ok(state)
        })
    }

    /// Upserts a safe linear-time regex transformation rule.
    pub fn upsert_regex_rule(&self, mut rule: RegexRuleRecord) -> BistreResult<RegexRuleRecord> {
        if rule.id.trim().is_empty() {
            rule.id = Uuid::now_v7().to_string();
        }
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO regex_rules (id, name, pattern, replacement, scope, enabled, order_index)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    pattern = excluded.pattern,
                    replacement = excluded.replacement,
                    scope = excluded.scope,
                    enabled = excluded.enabled,
                    order_index = excluded.order_index",
                params![
                    rule.id,
                    rule.name,
                    rule.pattern,
                    rule.replacement,
                    rule.scope,
                    i64::from(rule.enabled),
                    rule.order_index
                ],
            )
            .map_err(map_sqlite_err)?;
            Ok(rule)
        })
    }

    /// Lists all configured regex rules ordered by `order_index`.
    pub fn list_regex_rules(&self) -> BistreResult<Vec<RegexRuleRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, name, pattern, replacement, scope, enabled, order_index
                 FROM regex_rules ORDER BY order_index ASC, name ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([], |row| {
                let en_i64: i64 = row.get(5)?;
                Ok(RegexRuleRecord {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    pattern: row.get(2)?,
                    replacement: row.get(3)?,
                    scope: row.get(4)?,
                    enabled: en_i64 != 0,
                    order_index: row.get(6)?,
                })
            })
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Lists Time Machine version snapshots for a Character Card or Story Entry.
    pub fn list_story_snapshots(
        &self,
        entity_type: &str,
        entity_id: &str,
        limit: u32,
    ) -> BistreResult<Vec<StorySnapshotRecord>> {
        let conn = self.open_reader()?;
        let cap = i64::from(limit.clamp(1, 50));
        let mut stmt = conn
            .prepare(
                "SELECT id, entity_type, entity_id, snapshot_json, created_at_ms
                 FROM story_snapshots
                 WHERE entity_type = ?1 AND entity_id = ?2
                 ORDER BY created_at_ms DESC LIMIT ?3",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map(params![entity_type, entity_id, cap], |row| {
                Ok(StorySnapshotRecord {
                    id: row.get(0)?,
                    entity_type: row.get(1)?,
                    entity_id: row.get(2)?,
                    snapshot_json: row.get(3)?,
                    created_at_ms: row.get(4)?,
                })
            })
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }
}

fn map_character_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CharacterCardRecord> {
    let alt_raw: String = row.get(8)?;
    let tags_raw: String = row.get(12)?;
    Ok(CharacterCardRecord {
        id: row.get(0)?,
        name: row.get(1)?,
        nickname: row.get(2)?,
        spec_version: row.get(3)?,
        description: row.get(4)?,
        personality: row.get(5)?,
        scenario: row.get(6)?,
        first_message: row.get(7)?,
        alternate_greetings: json_column(&alt_raw)?,
        system_prompt: row.get(9)?,
        post_history_instructions: row.get(10)?,
        creator_notes: row.get(11)?,
        tags: json_column(&tags_raw)?,
        avatar_path: row.get(13)?,
        extensions_json: row.get(14)?,
        updated_at_ms: row.get(15)?,
    })
}

fn map_story_entry_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoryEntryRecord> {
    let keys_raw: String = row.get(4)?;
    let sec_raw: String = row.get(5)?;
    let dec_raw: String = row.get(19)?;
    let const_i: i64 = row.get(13)?;
    let regex_i: i64 = row.get(14)?;
    let case_i: i64 = row.get(15)?;
    let en_i: i64 = row.get(20)?;
    Ok(StoryEntryRecord {
        id: row.get(0)?,
        book_id: row.get(1)?,
        category: row.get(2)?,
        name: row.get(3)?,
        keys: json_column(&keys_raw)?,
        secondary_keys: json_column(&sec_raw)?,
        selective_logic: row.get(6)?,
        content: row.get(7)?,
        insertion_order: row.get(8)?,
        priority: row.get(9)?,
        position: row.get(10)?,
        depth: row.get(11)?,
        role: row.get(12)?,
        constant: const_i != 0,
        use_regex: regex_i != 0,
        case_sensitive: case_i != 0,
        sticky_turns: row.get(16)?,
        cooldown_turns: row.get(17)?,
        delay_turns: row.get(18)?,
        decorators: json_column(&dec_raw)?,
        enabled: en_i != 0,
        updated_at_ms: row.get(21)?,
    })
}

fn map_progression_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoryProgressionRecord> {
    Ok(StoryProgressionRecord {
        id: row.get(0)?,
        entry_id: row.get(1)?,
        chapter_order: row.get(2)?,
        scene_order: row.get(3)?,
        delta_text: row.get(4)?,
        created_at_ms: row.get(5)?,
    })
}

/// Decodes a JSON column written by this crate. Corrupt data is a storage error, never a silent
/// empty default.
fn json_column<T: serde::de::DeserializeOwned>(raw: &str) -> rusqlite::Result<T> {
    serde_json::from_str(raw).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
    })
}
