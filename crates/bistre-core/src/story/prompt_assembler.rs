//! Cache-Preserving Visual Story Prompt Assembler & Live Prompt Inspector Report.
//!
//! Strictly enforces a **Prompt-Cache Prefix Boundary**:
//! - Static Cached Prefix (`is_static_prefix = true`): System Prompt + Active Character Card(s) +
//!   User Persona + Pinned Story Memory + Continuity Librarian Era Summaries.
//! - Dynamic Volatile Suffix (`is_static_prefix = false`): Triggered Lorebook V3 entries +
//!   Floating Author's Note (`@Depth`) + Active Scene Beats + Recent Conversation Turns.

use bistre_protocol::{
    CharacterCardRecord, NodeRecord, StoryChapterRecord, StoryEntryRecord, StoryProgressionRecord,
    StoryThreadStateRecord, UserPersonaRecord,
};
use serde::{Deserialize, Serialize};

use crate::compaction::estimate_tokens_for_text;
use crate::story::lorebook::{LoreEvalContext, LoreEvalResult, LoreTurnState, evaluate_lorebook};

/// Single inspectable prompt block surfaced in Bistre's Live Prompt Inspector.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromptBlock {
    pub id: String,
    pub label: String,
    pub role: String,
    pub content: String,
    pub estimated_tokens: u64,
    /// `true` when this block lives before the Prompt-Cache Prefix Boundary (cache-stable).
    pub is_static_prefix: bool,
}

/// Complete compiled prompt report for both outbound LLM streaming and Live Prompt Inspector UI.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CompiledPromptReport {
    pub blocks: Vec<PromptBlock>,
    /// Index in `blocks` where the static cache-stable prefix ends and dynamic blocks begin.
    pub cache_boundary_index: usize,
    pub total_estimated_tokens: u64,
    pub static_prefix_tokens: u64,
    pub lore_result: LoreEvalResult,
}

/// Compiles a deterministic, cache-friendly Story & Roleplay prompt report with `{{char}}` / `{{user}}`
/// macro expansion and live Lorebook V3 activation trace.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit pure assembly inputs keep compiled prompt reports reproducible and testable."
)]
pub fn assemble_story_prompt(
    base_system_prompt: &str,
    state: &StoryThreadStateRecord,
    characters: &[CharacterCardRecord],
    persona: Option<&UserPersonaRecord>,
    entries: &[StoryEntryRecord],
    progressions: &[StoryProgressionRecord],
    chapters: &[StoryChapterRecord],
    recent_nodes: &[NodeRecord],
    active_scene_beats: Option<&str>,
    context_window_tokens: u64,
) -> CompiledPromptReport {
    let char_name = characters.first().map_or("Assistant", |c| c.name.as_str());
    let user_name = persona.map_or("User", |p| p.name.as_str());

    let static_blocks = build_static_prefix_blocks(
        base_system_prompt,
        state,
        characters,
        persona,
        chapters,
        char_name,
        user_name,
    );
    let mut dynamic_blocks = Vec::new();

    // --- DYNAMIC VOLATILE SUFFIX (after Cache Boundary) ---
    let recent_text = recent_nodes
        .iter()
        .rev()
        .take(8)
        .map(|n| n.content.as_str())
        .collect::<Vec<_>>()
        .join("\n");

    let eval_ctx = LoreEvalContext {
        recent_messages_text: &recent_text,
        turn_number: u32::try_from(recent_nodes.len()).unwrap_or(0),
        current_chapter_order: state.current_chapter_order,
        context_window_tokens,
        max_budget_percent: 25,
    };
    let lore_result =
        evaluate_lorebook(entries, progressions, &LoreTurnState::default(), &eval_ctx);

    for activated in &lore_result.activated {
        dynamic_blocks.push(make_block(
            &format!("lore_{}", activated.entry_id),
            &format!("Lorebook · {}", activated.name),
            &activated.role,
            expand_macros(&activated.rendered_content, char_name, user_name),
            false,
        ));
    }

    if !state.author_note.trim().is_empty() {
        dynamic_blocks.push(make_block(
            "author_note",
            &format!("Author's Note (@D{})", state.author_note_depth),
            "system",
            expand_macros(state.author_note.trim(), char_name, user_name),
            false,
        ));
    }

    if let Some(beats) = active_scene_beats.map(str::trim).filter(|s| !s.is_empty()) {
        dynamic_blocks.push(make_block(
            "scene_beats",
            "Active Scene Beats",
            "user",
            expand_macros(beats, char_name, user_name),
            false,
        ));
    }

    let cache_boundary_index = static_blocks.len();
    let static_prefix_tokens: u64 = static_blocks.iter().map(|b| b.estimated_tokens).sum();

    let mut all_blocks = static_blocks;
    all_blocks.extend(dynamic_blocks);
    let total_estimated_tokens: u64 = all_blocks.iter().map(|b| b.estimated_tokens).sum();

    CompiledPromptReport {
        blocks: all_blocks,
        cache_boundary_index,
        total_estimated_tokens,
        static_prefix_tokens,
        lore_result,
    }
}

fn build_static_prefix_blocks(
    base_system_prompt: &str,
    state: &StoryThreadStateRecord,
    characters: &[CharacterCardRecord],
    persona: Option<&UserPersonaRecord>,
    chapters: &[StoryChapterRecord],
    char_name: &str,
    user_name: &str,
) -> Vec<PromptBlock> {
    let mut static_blocks = Vec::new();
    if !base_system_prompt.trim().is_empty() {
        static_blocks.push(make_block(
            "system_base",
            "System prompt",
            "system",
            expand_macros(base_system_prompt, char_name, user_name),
            true,
        ));
    }
    for card in characters {
        let mut card_lines = vec![format!("Character: {}", card.name)];
        if !card.description.trim().is_empty() {
            card_lines.push(format!("Description: {}", card.description.trim()));
        }
        if !card.personality.trim().is_empty() {
            card_lines.push(format!("Personality: {}", card.personality.trim()));
        }
        if !card.scenario.trim().is_empty() {
            card_lines.push(format!("Scenario: {}", card.scenario.trim()));
        }
        if !card.system_prompt.trim().is_empty() {
            card_lines.push(card.system_prompt.trim().to_owned());
        }
        static_blocks.push(make_block(
            &format!("char_{}", card.id),
            &format!("Character · {}", card.name),
            "system",
            expand_macros(&card_lines.join("\n"), char_name, user_name),
            true,
        ));
    }
    if let Some(p) = persona
        && (!p.name.trim().is_empty() || !p.description.trim().is_empty())
    {
        static_blocks.push(make_block(
            "user_persona",
            &format!("User Persona · {}", p.name),
            "system",
            expand_macros(
                &format!("User Persona ({}): {}", p.name, p.description.trim()),
                char_name,
                user_name,
            ),
            true,
        ));
    }
    if !state.story_memory.trim().is_empty() {
        static_blocks.push(make_block(
            "story_memory",
            "Story Memory",
            "system",
            expand_macros(state.story_memory.trim(), char_name, user_name),
            true,
        ));
    }
    let era_lines: Vec<String> = chapters
        .iter()
        .filter(|ch| {
            ch.order_index < state.current_chapter_order && !ch.era_summary.trim().is_empty()
        })
        .map(|ch| {
            format!(
                "Ch {} ({}): {}",
                ch.order_index,
                ch.title,
                ch.era_summary.trim()
            )
        })
        .collect();
    if !era_lines.is_empty() {
        static_blocks.push(make_block(
            "era_summaries",
            "Continuity Era Summaries",
            "system",
            era_lines.join("\n"),
            true,
        ));
    }
    static_blocks
}

/// Expands standard `{{char}}` and `{{user}}` roleplay macros cleanly.
pub fn expand_macros(text: &str, char_name: &str, user_name: &str) -> String {
    text.replace("{{char}}", char_name)
        .replace("{{CHAR}}", char_name)
        .replace("{{user}}", user_name)
        .replace("{{USER}}", user_name)
}

fn make_block(
    id: &str,
    label: &str,
    role: &str,
    content: String,
    is_static_prefix: bool,
) -> PromptBlock {
    let estimated_tokens = estimate_tokens_for_text(&content);
    PromptBlock {
        id: id.to_owned(),
        label: label.to_owned(),
        role: role.to_owned(),
        content,
        estimated_tokens,
        is_static_prefix,
    }
}

/// A locked/frozen story canon fragment pinned by ordinal position and `blake3` digest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrozenFragment {
    pub block_id: String,
    pub position: usize,
    pub blake3_hex: String,
}

impl FrozenFragment {
    /// Seals a prompt block at `position` with its current `blake3` content hash.
    #[must_use]
    pub fn seal(block: &PromptBlock, position: usize) -> Self {
        Self {
            block_id: block.id.clone(),
            position,
            blake3_hex: blake3::hash(block.content.as_bytes()).to_hex().to_string(),
        }
    }
}

/// Verifies that every locked [`FrozenFragment`] still sits at its exact ordinal position with an
/// unchanged `blake3` digest; returns the first drifted `block_id` on mismatch (fail closed).
pub fn verify_frozen_fragments<'a>(
    blocks: &[PromptBlock],
    frozen: &'a [FrozenFragment],
) -> Result<(), &'a str> {
    for lock in frozen {
        let Some(block) = blocks.get(lock.position) else {
            return Err(&lock.block_id);
        };
        if block.id != lock.block_id {
            return Err(&lock.block_id);
        }
        let actual = blake3::hash(block.content.as_bytes()).to_hex();
        if actual.as_str() != lock.blake3_hex {
            return Err(&lock.block_id);
        }
    }
    Ok(())
}

/// Incremental hierarchical summary watermark preventing already-summarized chapters/nodes from
/// being re-summarized on later turns.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HierarchicalSummaryWatermark {
    pub summarized_up_to_node_id: Option<String>,
    pub chapter_summaries: Vec<(u32, String)>,
    pub era_summary: String,
}

impl HierarchicalSummaryWatermark {
    /// Returns the slice of `nodes` strictly after `summarized_up_to_node_id` (or all nodes if
    /// no watermark exists or the watermark is not on this branch).
    #[must_use]
    pub fn unsummarized_tail<'a>(&self, nodes: &'a [NodeRecord]) -> &'a [NodeRecord] {
        let Some(ref wm) = self.summarized_up_to_node_id else {
            return nodes;
        };
        match nodes.iter().position(|n| &n.id == wm) {
            Some(idx) => &nodes[idx + 1..],
            None => nodes,
        }
    }
}

/// Resolves a Story Studio role's model (`prewriter`, `librarian`, `writer`), falling back to the
/// thread/default model when no per-role override is configured.
#[must_use]
pub fn resolve_story_role_model<'a>(
    role_override: Option<&'a str>,
    fallback_model: &'a str,
) -> &'a str {
    role_override
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or(fallback_model)
}

#[cfg(test)]
mod tests {
    use super::*;
    use bistre_protocol::NodeRole;

    #[test]
    fn prompt_assembler_keeps_static_cache_prefix_strictly_before_dynamic_lore_and_author_note() {
        let state = StoryThreadStateRecord {
            thread_id: "t1".to_owned(),
            story_memory: "Static arc summary.".to_owned(),
            author_note: "Keep tension quiet and atmospheric.".to_owned(),
            author_note_depth: 3,
            current_chapter_order: 2,
            ..StoryThreadStateRecord::default()
        };
        let chars = vec![CharacterCardRecord {
            id: "c1".to_owned(),
            name: "Lyra".to_owned(),
            description: "{{char}} guides {{user}} through the archive.".to_owned(),
            ..CharacterCardRecord::default()
        }];
        let persona = UserPersonaRecord {
            id: "u1".to_owned(),
            name: "Rowan".to_owned(),
            description: "Cartographer".to_owned(),
            ..UserPersonaRecord::default()
        };
        let entries = vec![StoryEntryRecord {
            id: "l1".to_owned(),
            name: "Archive".to_owned(),
            keys: vec!["archive".to_owned()],
            content: "Lit by warm oil lamps.".to_owned(),
            ..StoryEntryRecord::default()
        }];
        let nodes = vec![NodeRecord {
            id: "n1".to_owned(),
            thread_id: "t1".to_owned(),
            parent_id: None,
            role: NodeRole::User,
            content: "Let's enter the archive.".to_owned(),
            provider_meta_json: None,
            created_at_ms: 1,
        }];

        let report = assemble_story_prompt(
            "Write vivid grounded prose.",
            &state,
            &chars,
            Some(&persona),
            &entries,
            &[],
            &[],
            &nodes,
            None,
            8192,
        );

        assert!(report.cache_boundary_index >= 4);
        assert!(
            report.blocks[..report.cache_boundary_index]
                .iter()
                .all(|b| b.is_static_prefix)
        );
        assert!(
            report.blocks[report.cache_boundary_index..]
                .iter()
                .all(|b| !b.is_static_prefix)
        );
        assert!(report.blocks[1].content.contains("Lyra guides Rowan"));
        assert_eq!(report.lore_result.activated.len(), 1);

        // Frozen fragment verification detects both content drift and position shifts.
        let frozen = vec![FrozenFragment::seal(&report.blocks[0], 0)];
        assert!(verify_frozen_fragments(&report.blocks, &frozen).is_ok());
        let mut drifted = report.blocks.clone();
        drifted[0].content.push_str(" tampered");
        assert_eq!(
            verify_frozen_fragments(&drifted, &frozen),
            Err(report.blocks[0].id.as_str())
        );

        // Hierarchical summary watermark returns only nodes strictly after the watermark.
        let mut wm = HierarchicalSummaryWatermark::default();
        assert_eq!(wm.unsummarized_tail(&nodes).len(), 1);
        wm.summarized_up_to_node_id = Some("n1".to_owned());
        assert_eq!(wm.unsummarized_tail(&nodes), []);

        // Per-role model fallback picks explicit override, else fallback.
        assert_eq!(
            resolve_story_role_model(Some("writer-pro"), "base"),
            "writer-pro"
        );
        assert_eq!(resolve_story_role_model(Some("  "), "base"), "base");
        assert_eq!(resolve_story_role_model(None, "base"), "base");
    }
}
