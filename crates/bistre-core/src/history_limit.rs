//! The history limit (`kv_meta` [`KEY`]): a request sends only the latest messages of the
//! chat. The cut falls before a message the user wrote, so no reply or tool result is sent
//! without the turn it answers; a summary that opens the history stays.

use bistre_protocol::{NodeRecord, NodeRole};
use bistre_storage::StorageHandle;

/// The setting's key; its value is the message count, `0` or absent for every message.
pub const KEY: &str = "settings.history_message_limit";

/// The limit set, `None` for every message. An unreadable or malformed value sends every
/// message (logged): the setting only saves tokens.
pub(crate) fn load(storage: &StorageHandle) -> Option<usize> {
    match storage.get_kv_meta(KEY) {
        Ok(None) => None,
        Ok(Some(raw)) => match raw.trim().parse::<usize>() {
            Ok(0) => None,
            Ok(n) => Some(n),
            Err(err) => {
                tracing::warn!(%err, "history limit malformed; every message is sent");
                None
            }
        },
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "history limit unreadable; every message is sent"
            );
            None
        }
    }
}

/// `history` cut to at most `limit` user and assistant messages, starting at a user message
/// (the latest one is always kept, even past the limit).
pub(crate) fn apply(history: Vec<NodeRecord>, limit: Option<usize>) -> Vec<NodeRecord> {
    let Some(limit) = limit else {
        return history;
    };
    let lead = usize::from(
        history
            .first()
            .is_some_and(|n| n.role == NodeRole::CompactionSummary),
    );
    let mut counted = 0_usize;
    let mut cut: Option<usize> = None;
    for (i, node) in history.iter().enumerate().skip(lead).rev() {
        if matches!(node.role, NodeRole::User | NodeRole::Assistant) {
            counted += 1;
        }
        if node.role == NodeRole::User && (counted <= limit || cut.is_none()) {
            cut = Some(i);
        }
        if counted >= limit && cut.is_some() {
            break;
        }
    }
    let Some(cut) = cut.filter(|c| *c > lead) else {
        return history;
    };
    let mut kept = history;
    kept.drain(lead..cut);
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(id: &str, role: NodeRole) -> NodeRecord {
        NodeRecord {
            id: id.to_owned(),
            thread_id: "t".to_owned(),
            parent_id: None,
            role,
            content: id.to_owned(),
            provider_meta_json: None,
            created_at_ms: 0,
        }
    }

    fn ids(nodes: &[NodeRecord]) -> Vec<&str> {
        nodes.iter().map(|n| n.id.as_str()).collect()
    }

    /// The cut keeps the summary, starts at a user message, and never splits a tool call
    /// from its result.
    #[test]
    fn the_cut_starts_at_a_user_message_after_the_summary() {
        let history = vec![
            node("s", NodeRole::CompactionSummary),
            node("u1", NodeRole::User),
            node("a1", NodeRole::Assistant),
            node("u2", NodeRole::User),
            node("a2", NodeRole::Assistant),
            node("t2", NodeRole::Tool),
            node("a3", NodeRole::Assistant),
            node("u3", NodeRole::User),
        ];
        assert_eq!(ids(&apply(history.clone(), None)), ids(&history));
        assert_eq!(
            ids(&apply(history.clone(), Some(4))),
            ["s", "u2", "a2", "t2", "a3", "u3"]
        );
        assert_eq!(ids(&apply(history.clone(), Some(2))), ["s", "u3"]);
        assert_eq!(ids(&apply(history.clone(), Some(1))), ["s", "u3"]);
        assert_eq!(ids(&apply(history.clone(), Some(50))), ids(&history));
    }

    /// The latest user message stays even when the replies after it pass the limit.
    #[test]
    fn the_latest_user_message_always_stays() {
        let history = vec![
            node("u1", NodeRole::User),
            node("a1", NodeRole::Assistant),
            node("t1", NodeRole::Tool),
            node("a2", NodeRole::Assistant),
        ];
        assert_eq!(ids(&apply(history, Some(1))), ["u1", "a1", "t1", "a2"]);
    }
}
