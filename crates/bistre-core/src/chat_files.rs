//! Every file in a chat, newest first: the files you sent and the files replies and tools
//! made, read from the messages that carry them (all branches, loaded or not).

use std::collections::HashSet;

use bistre_protocol::{BistreResult, NodeRole};
use bistre_storage::StorageHandle;
use serde::{Deserialize, Serialize};

/// Most messages with files one list reads (the newest).
const MAX_FILE_MESSAGES: usize = 500;
/// Most files one list holds.
pub const MAX_CHAT_FILES: usize = 500;

/// One file of a chat and the message it came with.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatFile {
    pub node_id: String,
    /// You sent it; otherwise a reply or a tool made it.
    pub from_user: bool,
    pub name: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub blob_rel_path: String,
    pub created_at_ms: i64,
}

/// The chat's files, newest first; a file sent again (an edited message keeps its files)
/// shows once, at its newest message.
pub fn list(storage: &StorageHandle, thread_id: &str) -> BistreResult<Vec<ChatFile>> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for node in storage.list_nodes_with_files(thread_id, MAX_FILE_MESSAGES)? {
        for att in crate::attachments::parse_node_attachments(node.provider_meta_json.as_deref()) {
            if out.len() >= MAX_CHAT_FILES {
                return Ok(out);
            }
            if !seen.insert(att.blob_rel_path.clone()) {
                continue;
            }
            out.push(ChatFile {
                node_id: node.id.clone(),
                from_user: node.role == NodeRole::User,
                name: att.name,
                mime_type: att.mime_type,
                size_bytes: att.size_bytes,
                blob_rel_path: att.blob_rel_path,
                created_at_ms: node.created_at_ms,
            });
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    fn meta(files: &[(&str, &str)]) -> String {
        let list: Vec<_> = files
            .iter()
            .map(|(name, blob)| {
                serde_json::json!({
                    "id": format!("att_{name}"), "name": name, "mime_type": "image/png",
                    "blob_rel_path": blob, "size_bytes": 3, "blake3_hex": "",
                })
            })
            .collect();
        serde_json::json!({ "attachments": list }).to_string()
    }

    /// Files from every branch are listed newest first, a re-sent file once, and messages
    /// without files are skipped.
    #[test]
    fn the_chat_lists_sent_and_made_files_once_newest_first() -> TestResult {
        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("f.sqlite"))?;
        let t =
            storage.create_thread(None, "Files", bistre_protocol::ThreadMode::Chat, None, None)?;
        let ask = storage.append_node(
            t.id.clone(),
            None,
            NodeRole::User,
            "see".to_owned(),
            Some(meta(&[("a.png", "attachments/a.png")])),
        )?;
        storage.append_node(
            t.id.clone(),
            Some(ask.id.clone()),
            NodeRole::Assistant,
            "plain".to_owned(),
            None,
        )?;
        let reply = storage.append_node(
            t.id.clone(),
            Some(ask.id.clone()),
            NodeRole::Assistant,
            "made".to_owned(),
            Some(meta(&[("b.png", "attachments/b.png")])),
        )?;
        storage.append_node(
            t.id.clone(),
            Some(reply.id.clone()),
            NodeRole::User,
            "again".to_owned(),
            Some(meta(&[("a.png", "attachments/a.png")])),
        )?;
        let files = list(&storage, &t.id)?;
        let names: Vec<(&str, bool)> = files
            .iter()
            .map(|f| (f.name.as_str(), f.from_user))
            .collect();
        assert_eq!(names, [("a.png", true), ("b.png", false)]);
        assert_eq!(files[1].node_id, reply.id);
        Ok(())
    }
}
