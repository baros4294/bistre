//! Reversible branch-safe context compaction, Fixed Context Start Pin, and prompt-cache prefix guard.
//!
//! Inspired by Pi/Oh My Pi (`CompactionEntry`), Kelivo (undoable compaction + fixed context start pin),
//! and Hermes Agent (prompt-cache stability):
//! - Original DAG nodes are NEVER deleted or overwritten.
//! - Compaction inserts a readable `NodeRole::CompactionSummary` node carrying `first_kept_node_id`
//!   and `compacted_count` in `provider_meta_json`.
//! - Undoing compaction deletes ONLY the `CompactionSummary` marker node, instantly restoring 100%
//!   of prior verbatim history.

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, NodeRecord, NodeRole};
use bistre_storage::StorageHandle;
use serde_json::{Value, json};

/// Rough token estimate (~4 chars/token) suitable for proactive compaction threshold checks.
pub fn estimate_tokens_for_text(text: &str) -> u64 {
    let chars = text.chars().count();
    u64::try_from(chars.div_ceil(4)).unwrap_or(0)
}

/// Estimates total context tokens across system prompt and active branch history.
pub fn estimate_branch_tokens(system_prompt: &str, history: &[NodeRecord]) -> u64 {
    let mut total = estimate_tokens_for_text(system_prompt);
    for node in history {
        total = total.saturating_add(estimate_tokens_for_text(&node.content));
        total = total.saturating_add(6); // role/frame overhead
    }
    total
}

/// Returns `true` when estimated tokens cross the configurable compaction reserve threshold
/// (e.g., `reserve_percent = 20` triggers compaction once 80% of `context_window_tokens` is full).
pub fn should_auto_compact(
    estimated_tokens: u64,
    context_window_tokens: u64,
    reserve_percent: u8,
) -> bool {
    if context_window_tokens == 0 {
        return false;
    }
    let clamped_reserve = if reserve_percent > 50 {
        50
    } else {
        reserve_percent
    };
    let active_limit = context_window_tokens.saturating_mul(100 - u64::from(clamped_reserve)) / 100;
    estimated_tokens >= active_limit
}

/// Projects raw branch ancestry into the effective prompt window, honoring:
/// 1. Any user-pinned **Fixed Context Start** node (`pinned_start_node_id`), AND
/// 2. The latest active `NodeRole::CompactionSummary` node (sending `[CompactionSummary]` + kept suffix).
pub fn project_effective_history(
    branch: &[NodeRecord],
    pinned_start_node_id: Option<&str>,
) -> Vec<NodeRecord> {
    let start_slice = if let Some(pin_id) = pinned_start_node_id
        && let Some(pos) = branch.iter().position(|n| n.id == pin_id)
    {
        &branch[pos..]
    } else {
        branch
    };

    if let Some(compact_pos) = start_slice
        .iter()
        .rposition(|n| n.role == NodeRole::CompactionSummary)
    {
        let summary_node = &start_slice[compact_pos];
        let mut effective = vec![summary_node.clone()];
        let first_kept_id = summary_node
            .provider_meta_json
            .as_deref()
            .and_then(|s| serde_json::from_str::<Value>(s).ok())
            .and_then(|v| {
                v.get("first_kept_node_id")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            });

        if let Some(kept_id) = first_kept_id
            && let Some(kept_pos) = start_slice.iter().position(|n| n.id == kept_id)
        {
            for node in &start_slice[kept_pos..] {
                if node.id != summary_node.id && node.role != NodeRole::CompactionSummary {
                    effective.push(node.clone());
                }
            }
            return effective;
        }

        for node in &start_slice[(compact_pos + 1)..] {
            if node.role != NodeRole::CompactionSummary {
                effective.push(node.clone());
            }
        }
        return effective;
    }

    start_slice.to_vec()
}

/// Replay role used for alternation checks (`CompactionSummary` is replayed as a user turn).
const fn replay_role(role: NodeRole) -> Option<bool> {
    match role {
        NodeRole::User | NodeRole::CompactionSummary => Some(true),
        NodeRole::Assistant => Some(false),
        NodeRole::System | NodeRole::Tool => None,
    }
}

/// Post-compaction role-alternation validator: merges consecutive same-side turns (joined by a
/// blank line, never dropped) and removes trailing assistant turns so providers never receive an
/// assistant-tailed or non-alternating history (`Cannot continue from assistant` 400s).
pub fn enforce_role_alternation(history: Vec<NodeRecord>) -> Vec<NodeRecord> {
    let mut out: Vec<NodeRecord> = Vec::with_capacity(history.len());
    for node in history {
        let Some(side) = replay_role(node.role) else {
            out.push(node);
            continue;
        };
        if let Some(prev) = out.iter_mut().rev().find(|n| replay_role(n.role).is_some())
            && replay_role(prev.role) == Some(side)
            && prev.role == node.role
        {
            prev.content.push_str("\n\n");
            prev.content.push_str(&node.content);
            continue;
        }
        out.push(node);
    }
    while out
        .last()
        .is_some_and(|n| replay_role(n.role) == Some(false))
    {
        out.pop();
    }
    out
}

/// Creates a deterministic local reversible `CompactionSummary` DAG node without deleting prior nodes.
pub fn create_reversible_compaction(
    storage: &StorageHandle,
    thread_id: &str,
    branch: &[NodeRecord],
    keep_recent_turns: usize,
    custom_summary_text: Option<&str>,
) -> BistreResult<NodeRecord> {
    let regular: Vec<&NodeRecord> = branch
        .iter()
        .filter(|n| n.role != NodeRole::CompactionSummary)
        .collect();
    if regular.len() <= keep_recent_turns.max(2) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "not_enough_messages_to_compact",
        ));
    }

    let split_idx = regular.len().saturating_sub(keep_recent_turns.max(2));
    let to_compact = &regular[..split_idx];
    let first_kept = regular[split_idx];
    let parent_id = branch.last().map(|n| n.id.clone());

    let summary_body = custom_summary_text
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map_or_else(|| synthesize_local_summary(to_compact), str::to_owned);

    let meta = json!({
        "compaction": true,
        "compacted_count": to_compact.len(),
        "first_kept_node_id": first_kept.id,
        "reversible": true,
    })
    .to_string();

    storage.append_node(
        thread_id.to_owned(),
        parent_id,
        NodeRole::CompactionSummary,
        summary_body,
        Some(meta),
    )
}

/// Reverts a reversible `CompactionSummary` node, restoring 100% of original history cleanly.
pub fn undo_compaction(
    storage: &StorageHandle,
    thread_id: &str,
    compaction_node_id: &str,
) -> BistreResult<()> {
    let nodes = storage.list_nodes(thread_id)?;
    let is_summary = nodes
        .iter()
        .any(|n| n.id == compaction_node_id && n.role == NodeRole::CompactionSummary);
    if !is_summary {
        return Err(BistreError::with_detail(
            DiagnosticKey::StorageNotFound,
            "not_a_compaction_node",
        ));
    }
    storage.delete_node(thread_id.to_owned(), compaction_node_id.to_owned())
}

fn synthesize_local_summary(nodes: &[&NodeRecord]) -> String {
    let mut lines = vec![format!(
        "Context summary ({} earlier messages condensed; original history preserved locally):",
        nodes.len()
    )];
    for node in nodes.iter().take(12) {
        let speaker = match node.role {
            NodeRole::User => "User",
            NodeRole::Assistant => "Assistant",
            NodeRole::Tool => "Tool",
            NodeRole::System => "System",
            NodeRole::CompactionSummary => "Summary",
        };
        let snippet: String = node
            .content
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(140)
            .collect();
        lines.push(format!("- {speaker}: {snippet}"));
    }
    if nodes.len() > 12 {
        lines.push(format!(
            "- ...and {} additional earlier messages.",
            nodes.len() - 12
        ));
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use bistre_protocol::ThreadMode;
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn context_usage_follows_what_the_next_request_sends() -> TestResult {
        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("usage.sqlite"))?;
        let thread = storage.create_thread(None, "Usage", ThreadMode::Chat, None, None)?;
        let mut parent = None;
        let mut created = Vec::new();
        for idx in 0..6_u32 {
            let role = if idx % 2 == 0 {
                NodeRole::User
            } else {
                NodeRole::Assistant
            };
            let n = storage.append_node(
                thread.id.clone(),
                parent.clone(),
                role,
                format!("{idx}: {}", "words ".repeat(400)),
                None,
            )?;
            parent = Some(n.id.clone());
            created.push(n);
        }
        let leaf = created.last().map(|n| n.id.clone()).ok_or("no turns")?;
        let full = crate::engine_runs::branch_context_tokens(&storage, &thread.id, &leaf)?;
        // Five ~2,400-char turns: the trailing assistant turn is not resent.
        assert!(full >= 5 * 600, "five ~2,400-char turns: {full}");

        // A compaction keeping two turns lowers the gauge the way it lowers the real request.
        let summary = create_reversible_compaction(&storage, &thread.id, &created, 2, None)?;
        // The summary becomes the branch's newest node.
        let compacted =
            crate::engine_runs::branch_context_tokens(&storage, &thread.id, &summary.id)?;
        assert!(compacted < full / 2, "compacted {compacted} vs full {full}");

        undo_compaction(&storage, &thread.id, &summary.id)?;
        let restored = crate::engine_runs::branch_context_tokens(&storage, &thread.id, &leaf)?;
        assert_eq!(restored, full);
        Ok(())
    }

    #[test]
    fn reversible_compaction_and_fixed_context_start_pin_preserve_original_dag() -> TestResult {
        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("compact.sqlite"))?;
        let thread = storage.create_thread(None, "Compaction", ThreadMode::Chat, None, None)?;

        let mut parent = None;
        let mut created = Vec::new();
        for idx in 0..6_u32 {
            let role = if idx % 2 == 0 {
                NodeRole::User
            } else {
                NodeRole::Assistant
            };
            let n = storage.append_node(
                thread.id.clone(),
                parent.clone(),
                role,
                format!("Turn message #{idx}"),
                None,
            )?;
            parent = Some(n.id.clone());
            created.push(n);
        }

        // Fixed context start pin drops messages before pin #2.
        let pinned = project_effective_history(&created, Some(&created[2].id));
        assert_eq!(pinned.len(), 4);
        assert_eq!(pinned[0].id, created[2].id);

        // Compact keeping 2 recent turns.
        let summary = create_reversible_compaction(&storage, &thread.id, &created, 2, None)?;

        let all_after = storage.list_nodes(&thread.id)?;
        assert_eq!(all_after.len(), 7);
        let projected = project_effective_history(&all_after, None);
        assert_eq!(projected.len(), 3); // [CompactionSummary, Turn #4, Turn #5]
        assert_eq!(projected[0].role, NodeRole::CompactionSummary);

        // Undo compaction restores all 6 verbatim messages!
        assert!(undo_compaction(&storage, &thread.id, &summary.id).is_ok());
        let restored = storage.list_nodes(&thread.id)?;
        assert_eq!(restored.len(), 6);
        assert!(should_auto_compact(85_000, 100_000, 20));
        assert!(!should_auto_compact(50_000, 100_000, 20));
        Ok(())
    }

    #[test]
    fn role_alternation_merges_same_side_turns_and_drops_assistant_tail() {
        let node = |id: &str, role: NodeRole, content: &str| NodeRecord {
            id: id.to_owned(),
            thread_id: "t".to_owned(),
            parent_id: None,
            role,
            content: content.to_owned(),
            provider_meta_json: None,
            created_at_ms: 0,
        };
        let fixed = enforce_role_alternation(vec![
            node("s", NodeRole::CompactionSummary, "summary"),
            node("u1", NodeRole::User, "first"),
            node("u2", NodeRole::User, "second"),
            node("a1", NodeRole::Assistant, "reply"),
            node("u3", NodeRole::User, "third"),
            node("a2", NodeRole::Assistant, "dangling"),
        ]);
        let shape: Vec<(&str, &str)> = fixed
            .iter()
            .map(|n| (n.id.as_str(), n.content.as_str()))
            .collect();
        assert_eq!(
            shape,
            vec![
                ("s", "summary"),
                ("u1", "first\n\nsecond"),
                ("a1", "reply"),
                ("u3", "third")
            ]
        );
    }
}
