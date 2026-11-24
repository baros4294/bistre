//! Unified Story Bible (Codex) + Lorebook V3 Activation Engine.
//!
//! Features:
//! - Primary keywords, secondary keys (`and_any` / `and_all` / `not_any` / `not_all`), linear-time `regex`
//! - Cycle-safe recursive scanning (`max_depth = 3`, visited set prevents infinite loops)
//! - Hard token budget cap (`<= 25%` of context window) with `@@ignore_on_max_context`
//! - `CCv3` `@@` / `@@@` fallback decorators (`@@depth`, `@@position`, `@@activate_only_after`, `@@every`)
//! - Sticky / Cooldown / Delay turn state tracking
//! - Chronological progressions strictly gated by `chapter_order <= current_chapter`
//! - Full transparent `LorebookActivationTrace` (fired vs skipped reasons) for Live Prompt Inspector.

use std::collections::{HashMap, HashSet};

use bistre_protocol::{StoryEntryRecord, StoryProgressionRecord};
use regex::Regex;
use serde::{Deserialize, Serialize};

use crate::compaction::estimate_tokens_for_text;

/// Maximum recursive lorebook scan depth to prevent cascade blow-up.
pub const MAX_LORE_RECURSION_DEPTH: u8 = 3;

/// Per-entry runtime turn state supporting Sticky, Cooldown, and Delay timers.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoreTurnState {
    /// Map of `entry_id` -> remaining sticky turns (>0 forces activation).
    pub sticky_remaining: HashMap<String, u32>,
    /// Map of `entry_id` -> remaining cooldown turns (>0 suppresses activation).
    pub cooldown_remaining: HashMap<String, u32>,
}

/// Evaluation input context for the unified Story Bible / Lorebook V3 engine.
#[derive(Debug, Clone)]
pub struct LoreEvalContext<'a> {
    pub recent_messages_text: &'a str,
    pub turn_number: u32,
    pub current_chapter_order: u32,
    pub context_window_tokens: u64,
    pub max_budget_percent: u8,
}

/// Single activated lorebook entry rendered with any unlocked chronological progressions.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivatedLoreEntry {
    pub entry_id: String,
    pub name: String,
    pub position: String,
    pub depth: u32,
    pub role: String,
    pub rendered_content: String,
    pub estimated_tokens: u64,
    pub matched_by: String,
    pub unlocked_progressions: u32,
}

/// Transparent activation trace record for Prompt Inspector (fired OR skipped with reason).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoreTraceItem {
    pub entry_id: String,
    pub name: String,
    pub fired: bool,
    pub reason: String,
    pub estimated_tokens: u64,
}

/// Complete Lorebook V3 evaluation output.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoreEvalResult {
    pub activated: Vec<ActivatedLoreEntry>,
    pub trace: Vec<LoreTraceItem>,
    pub total_tokens_used: u64,
    pub token_budget_cap: u64,
}

/// Evaluates all Story Bible / Lorebook entries against recent context, applying:
/// 1. Delay / Cooldown / Sticky + `@@activate_only_after` / `@@every` decorators
/// 2. Primary + Secondary keys (`and_any` / `and_all` / `not_any` / `not_all`) or `constant`
/// 3. Cycle-safe recursive scan (`max_depth <= 3`)
/// 4. Chronological Progressions (`chapter_order <= current_chapter_order`, zero spoilers!)
/// 5. Hard token budget enforcement (`<= 25%` of context window, sorted by `priority` then `insertion_order`).
#[expect(
    clippy::too_many_lines,
    reason = "Unified linear Lorebook V3 evaluation pipeline keeps trace generation deterministic."
)]
pub fn evaluate_lorebook(
    entries: &[StoryEntryRecord],
    progressions: &[StoryProgressionRecord],
    turn_state: &LoreTurnState,
    ctx: &LoreEvalContext<'_>,
) -> LoreEvalResult {
    let clamped_pct = u64::from(ctx.max_budget_percent.clamp(5, 25));
    let budget_cap = ctx.context_window_tokens.saturating_mul(clamped_pct) / 100;

    let mut matched_map: HashMap<String, String> = HashMap::new();
    let mut skipped_reasons: HashMap<String, String> = HashMap::new();

    // Pass 0: Check gating rules & initial match against recent messages.
    let mut frontier_texts = vec![ctx.recent_messages_text.to_owned()];

    for depth_pass in 0..=MAX_LORE_RECURSION_DEPTH {
        if frontier_texts.is_empty() {
            break;
        }
        let haystack = frontier_texts.join("\n");
        let mut next_frontier = Vec::new();

        for entry in entries {
            if !entry.enabled {
                skipped_reasons
                    .entry(entry.id.clone())
                    .or_insert_with(|| "disabled".to_owned());
                continue;
            }
            if matched_map.contains_key(&entry.id) {
                continue;
            }

            let dec = parse_decorators(&entry.decorators);
            if ctx.turn_number < entry.delay_turns.max(dec.activate_only_after) {
                skipped_reasons
                    .entry(entry.id.clone())
                    .or_insert_with(|| "delay_not_reached".to_owned());
                continue;
            }
            if let Some(every_n) = dec.every_n_turns
                && every_n > 0
                && !ctx.turn_number.is_multiple_of(every_n)
            {
                skipped_reasons
                    .entry(entry.id.clone())
                    .or_insert_with(|| "every_interval_skipped".to_owned());
                continue;
            }
            if turn_state
                .cooldown_remaining
                .get(&entry.id)
                .copied()
                .unwrap_or(0)
                > 0
            {
                skipped_reasons
                    .entry(entry.id.clone())
                    .or_insert_with(|| "cooldown_active".to_owned());
                continue;
            }

            let sticky = turn_state
                .sticky_remaining
                .get(&entry.id)
                .copied()
                .unwrap_or(0)
                > 0;
            let trigger_reason = if depth_pass == 0 && entry.constant {
                Some("constant".to_owned())
            } else if depth_pass == 0 && sticky {
                Some("sticky".to_owned())
            } else if entry_matches_text(entry, &haystack) {
                Some(if depth_pass == 0 {
                    "keyword_match".to_owned()
                } else {
                    format!("recursive_depth_{depth_pass}")
                })
            } else {
                None
            };

            if let Some(reason) = trigger_reason {
                matched_map.insert(entry.id.clone(), reason);
                skipped_reasons.remove(&entry.id);
                next_frontier.push(entry.content.clone());
            } else if depth_pass == 0 {
                skipped_reasons
                    .entry(entry.id.clone())
                    .or_insert_with(|| "no_keyword_match".to_owned());
            }
        }

        frontier_texts = next_frontier;
    }

    // Sort candidates by priority DESC, then insertion_order ASC for deterministic cache ordering.
    let mut candidates: Vec<&StoryEntryRecord> = entries
        .iter()
        .filter(|e| matched_map.contains_key(&e.id))
        .collect();
    candidates.sort_by(|a, b| {
        b.priority
            .cmp(&a.priority)
            .then_with(|| a.insertion_order.cmp(&b.insertion_order))
            .then_with(|| a.name.cmp(&b.name))
    });

    let mut activated = Vec::new();
    let mut trace = Vec::new();
    let mut fired_ids = HashSet::new();
    let mut tokens_used: u64 = 0;

    for entry in candidates {
        let dec = parse_decorators(&entry.decorators);
        let (rendered, unlocked_count) =
            render_with_progressions(entry, progressions, ctx.current_chapter_order);
        let tok = estimate_tokens_for_text(&rendered);

        if budget_cap > 0 && tokens_used.saturating_add(tok) > budget_cap && !dec.ignore_on_max {
            trace.push(LoreTraceItem {
                entry_id: entry.id.clone(),
                name: entry.name.clone(),
                fired: false,
                reason: "budget_exceeded".to_owned(),
                estimated_tokens: tok,
            });
            continue;
        }

        tokens_used = tokens_used.saturating_add(tok);
        fired_ids.insert(entry.id.clone());
        let matched_by = matched_map
            .get(&entry.id)
            .cloned()
            .unwrap_or_else(|| "keyword_match".to_owned());
        trace.push(LoreTraceItem {
            entry_id: entry.id.clone(),
            name: entry.name.clone(),
            fired: true,
            reason: matched_by.clone(),
            estimated_tokens: tok,
        });
        activated.push(ActivatedLoreEntry {
            entry_id: entry.id.clone(),
            name: entry.name.clone(),
            position: dec.position.unwrap_or_else(|| entry.position.clone()),
            depth: dec.depth.unwrap_or(entry.depth),
            role: entry.role.clone(),
            rendered_content: rendered,
            estimated_tokens: tok,
            matched_by,
            unlocked_progressions: unlocked_count,
        });
    }

    // Record skipped entries into trace for complete Prompt Inspector transparency.
    for entry in entries {
        if fired_ids.contains(&entry.id) {
            continue;
        }
        if trace.iter().any(|t| t.entry_id == entry.id) {
            continue;
        }
        let reason = skipped_reasons
            .get(&entry.id)
            .cloned()
            .unwrap_or_else(|| "no_keyword_match".to_owned());
        trace.push(LoreTraceItem {
            entry_id: entry.id.clone(),
            name: entry.name.clone(),
            fired: false,
            reason,
            estimated_tokens: estimate_tokens_for_text(&entry.content),
        });
    }

    // Final insertion order sort for stable prompt assembly.
    activated.sort_by(|a, b| {
        a.position
            .cmp(&b.position)
            .then_with(|| a.name.cmp(&b.name))
    });

    LoreEvalResult {
        activated,
        trace,
        total_tokens_used: tokens_used,
        token_budget_cap: budget_cap,
    }
}

/// Renders a Story Bible entry plus ONLY chronological progressions whose `chapter_order <= current_chapter_order`.
/// Future chapters are strictly excluded (zero spoilers!).
pub fn render_with_progressions(
    entry: &StoryEntryRecord,
    progressions: &[StoryProgressionRecord],
    current_chapter_order: u32,
) -> (String, u32) {
    let mut unlocked: Vec<&StoryProgressionRecord> = progressions
        .iter()
        .filter(|p| p.entry_id == entry.id && p.chapter_order <= current_chapter_order)
        .collect();
    unlocked.sort_by_key(|p| (p.chapter_order, p.scene_order));

    if unlocked.is_empty() {
        return (entry.content.clone(), 0);
    }

    let mut out = entry.content.clone();
    out.push_str("\n[Chronological updates:]");
    for p in &unlocked {
        out.push_str("\n- (Ch ");
        out.push_str(&p.chapter_order.to_string());
        out.push_str(") ");
        out.push_str(p.delta_text.trim());
    }
    let count = u32::try_from(unlocked.len()).unwrap_or(u32::MAX);
    (out, count)
}

#[derive(Debug, Default)]
struct ParsedDecorators {
    depth: Option<u32>,
    position: Option<String>,
    ignore_on_max: bool,
    activate_only_after: u32,
    every_n_turns: Option<u32>,
}

/// Parses `CCv3` `@@` / `@@@` fallback decorators cleanly.
fn parse_decorators(decorators: &[String]) -> ParsedDecorators {
    let mut parsed = ParsedDecorators::default();
    for raw in decorators {
        let cleaned = raw
            .trim()
            .trim_start_matches("@@@")
            .trim_start_matches("@@")
            .trim();
        if let Some(rest) = cleaned.strip_prefix("depth ") {
            if let Ok(d) = rest.trim().parse::<u32>() {
                parsed.depth = Some(d);
            }
        } else if let Some(rest) = cleaned.strip_prefix("position ") {
            let p = rest.trim();
            if !p.is_empty() {
                parsed.position = Some(p.to_owned());
            }
        } else if cleaned == "ignore_on_max_context" {
            parsed.ignore_on_max = true;
        } else if let Some(rest) = cleaned.strip_prefix("activate_only_after ") {
            if let Ok(n) = rest.trim().parse::<u32>() {
                parsed.activate_only_after = n;
            }
        } else if let Some(rest) = cleaned.strip_prefix("every ")
            && let Ok(n) = rest.trim().parse::<u32>()
        {
            parsed.every_n_turns = Some(n);
        }
    }
    parsed
}

fn entry_matches_text(entry: &StoryEntryRecord, haystack: &str) -> bool {
    if entry.keys.is_empty() {
        return false;
    }
    let primary_hit = entry
        .keys
        .iter()
        .any(|k| key_matches(k, haystack, entry.use_regex, entry.case_sensitive));
    if !primary_hit {
        return false;
    }
    if entry.secondary_keys.is_empty() {
        return true;
    }

    let sec_hits = entry
        .secondary_keys
        .iter()
        .filter(|k| key_matches(k, haystack, entry.use_regex, entry.case_sensitive))
        .count();
    match entry.selective_logic.as_str() {
        "and_all" => sec_hits == entry.secondary_keys.len(),
        "not_any" => sec_hits == 0,
        "not_all" => sec_hits < entry.secondary_keys.len(),
        _ => sec_hits > 0, // `and_any`
    }
}

fn key_matches(key: &str, haystack: &str, use_regex: bool, case_sensitive: bool) -> bool {
    let trimmed = key.trim();
    if trimmed.is_empty() {
        return false;
    }
    if use_regex {
        let pattern = if case_sensitive {
            trimmed.to_owned()
        } else {
            format!("(?i){trimmed}")
        };
        return Regex::new(&pattern).is_ok_and(|re| re.is_match(haystack));
    }
    if case_sensitive {
        haystack.contains(trimmed)
    } else {
        haystack
            .to_ascii_lowercase()
            .contains(&trimmed.to_ascii_lowercase())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lorebook_v3_handles_recursion_cycles_decorators_budget_and_no_spoiler_progressions() {
        let entries = vec![
            StoryEntryRecord {
                id: "e1".to_owned(),
                name: "Glass City".to_owned(),
                keys: vec!["glass city".to_owned()],
                content: "Home of the Salt Lantern guild.".to_owned(),
                priority: 20,
                decorators: vec!["@@depth 2".to_owned()],
                ..StoryEntryRecord::default()
            },
            StoryEntryRecord {
                id: "e2".to_owned(),
                name: "Salt Lantern".to_owned(),
                keys: vec!["salt lantern".to_owned()],
                content: "Forged inside the Glass City vaults.".to_owned(), // Cyclic back-reference!
                priority: 15,
                ..StoryEntryRecord::default()
            },
            StoryEntryRecord {
                id: "e3".to_owned(),
                name: "Delayed Secret".to_owned(),
                keys: vec!["glass city".to_owned()],
                content: "Revealed only after turn 10.".to_owned(),
                decorators: vec!["@@activate_only_after 10".to_owned()],
                ..StoryEntryRecord::default()
            },
        ];

        let progressions = vec![
            StoryProgressionRecord {
                id: "p1".to_owned(),
                entry_id: "e1".to_owned(),
                chapter_order: 1,
                scene_order: 1,
                delta_text: "Harbor gates were sealed.".to_owned(),
                created_at_ms: 1,
            },
            StoryProgressionRecord {
                id: "p2".to_owned(),
                entry_id: "e1".to_owned(),
                chapter_order: 5,
                scene_order: 1,
                delta_text: "SPOILER: The citadel fell in Chapter 5.".to_owned(),
                created_at_ms: 2,
            },
        ];

        let ctx = LoreEvalContext {
            recent_messages_text: "We sailed into the Glass City at dusk.",
            turn_number: 3,
            current_chapter_order: 2,
            context_window_tokens: 4000,
            max_budget_percent: 25,
        };

        let result = evaluate_lorebook(&entries, &progressions, &LoreTurnState::default(), &ctx);
        // e1 matched directly, e2 matched recursively via "Salt Lantern" without infinite cycle, e3 gated by delay!
        assert_eq!(result.activated.len(), 2);
        let glass = result.activated.iter().find(|a| a.entry_id == "e1");
        assert!(glass.is_some());
        if let Some(g) = glass {
            assert_eq!(g.depth, 2); // @@depth 2 applied!
            assert_eq!(g.unlocked_progressions, 1);
            assert!(g.rendered_content.contains("Harbor gates were sealed"));
            assert!(!g.rendered_content.contains("SPOILER")); // Zero future chapter spoilers!
        }

        let skipped_e3 = result.trace.iter().find(|t| t.entry_id == "e3");
        assert_eq!(skipped_e3.map(|t| t.fired), Some(false));
        assert_eq!(
            skipped_e3.map(|t| t.reason.as_str()),
            Some("delay_not_reached")
        );
    }
}
