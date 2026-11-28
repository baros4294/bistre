//! Messages the user left out of a chat's context: still saved and shown, never sent. Leaving
//! out a reply also leaves out the results of the tools it called, so no request carries a
//! tool result without its call.

use std::collections::HashSet;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, NodeRecord, NodeRole};
use bistre_storage::StorageHandle;

/// Most messages one chat can leave out.
pub const MAX_EXCLUDED_MESSAGES: usize = 512;

/// The `kv_meta` key prefix; the chat id follows.
pub(crate) const KEY_PREFIX: &str = "thread_excluded:";

/// The ids of the chat's left-out messages, in the order they were left out. A stored value
/// that does not parse is an error: a run never sends a message the user left out.
pub fn load(storage: &StorageHandle, thread_id: &str) -> BistreResult<Vec<String>> {
    let Some(raw) = storage.get_kv_meta(&format!("{KEY_PREFIX}{thread_id}"))? else {
        return Ok(Vec::new());
    };
    serde_json::from_str(&raw)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "excluded_decode"))
}

/// Leaves `node_id` out of the context (`excluded`) or brings it back, and returns the new
/// list. Only a user message or a reply on the chat can be left out.
pub fn set(
    storage: &StorageHandle,
    thread_id: &str,
    node_id: &str,
    excluded: bool,
) -> BistreResult<Vec<String>> {
    let mut ids = load(storage, thread_id)?;
    ids.retain(|id| id != node_id);
    if excluded {
        let node = storage
            .list_branch(thread_id, node_id)?
            .pop()
            .filter(|n| n.id == node_id)
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        if !matches!(node.role, NodeRole::User | NodeRole::Assistant) {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "exclude_role",
            ));
        }
        if ids.len() >= MAX_EXCLUDED_MESSAGES {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "excluded_limit",
            ));
        }
        ids.push(node_id.to_owned());
    }
    let encoded = serde_json::to_string(&ids)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "excluded_encode"))?;
    storage.set_kv_meta(format!("{KEY_PREFIX}{thread_id}"), encoded)?;
    Ok(ids)
}

/// `history` without the left-out messages and the tool results right after a left-out reply.
pub(crate) fn apply(history: Vec<NodeRecord>, excluded: &[String]) -> Vec<NodeRecord> {
    if excluded.is_empty() {
        return history;
    }
    let left_out: HashSet<&str> = excluded.iter().map(String::as_str).collect();
    let mut after_left_out_reply = false;
    history
        .into_iter()
        .filter(|node| {
            if left_out.contains(node.id.as_str()) {
                after_left_out_reply = node.role == NodeRole::Assistant;
                return false;
            }
            if node.role == NodeRole::Tool && after_left_out_reply {
                return false;
            }
            after_left_out_reply = false;
            true
        })
        .collect()
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

    /// A left-out reply takes its tool results with it; the next reply's results stay.
    #[test]
    fn a_left_out_reply_takes_its_tool_results_along() {
        let history = vec![
            node("u1", NodeRole::User),
            node("a1", NodeRole::Assistant),
            node("t1", NodeRole::Tool),
            node("t2", NodeRole::Tool),
            node("a2", NodeRole::Assistant),
            node("t3", NodeRole::Tool),
            node("u2", NodeRole::User),
        ];
        let ids: Vec<String> = apply(history, &["a1".to_owned(), "u2".to_owned()])
            .into_iter()
            .map(|n| n.id)
            .collect();
        assert_eq!(ids, ["u1", "a2", "t3"]);
    }

    /// Leaving out and bringing back round-trips; a tool result or an unknown id is refused.
    #[test]
    fn only_messages_on_the_chat_can_be_left_out() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("ex.sqlite"))?;
        let thread =
            storage.create_thread(None, "Ex", bistre_protocol::ThreadMode::Chat, None, None)?;
        let tid = thread.id;
        let user = storage.append_node(tid.clone(), None, NodeRole::User, "Hi".to_owned(), None)?;
        let tool = storage.append_node(
            tid.clone(),
            Some(user.id.clone()),
            NodeRole::Tool,
            "out".to_owned(),
            None,
        )?;
        assert_eq!(
            set(&storage, &tid, &user.id, true)?,
            std::slice::from_ref(&user.id)
        );
        assert!(set(&storage, &tid, &tool.id, true).is_err());
        assert!(set(&storage, &tid, "missing", true).is_err());
        assert_eq!(set(&storage, &tid, &user.id, false)?, Vec::<String>::new());
        storage.set_kv_meta(format!("{KEY_PREFIX}{tid}"), "not json".to_owned())?;
        assert!(load(&storage, &tid).is_err(), "a broken list fails closed");
        Ok(())
    }
}
