//! Actions on one chat beside its runs: leaving messages out of the context, a reply edited as
//! a new version, a side question answered by the chat's own model (never saved to the chat),
//! a summary that opens a new chat, the chat's goal, and the raw request of a reply.

use bistre_protocol::{
    AppSettings, BistreError, BistreResult, DiagnosticKey, EngineEvent, NodeRecord, NodeRole,
    ProviderProfile, ThreadSummary,
};
use serde_json::Value;

use crate::credentials::KeyRing;
use crate::events::emit;
use crate::off_worker::off_worker;
use crate::provider_prefs::{ProviderAdvancedPrefs, load_provider_advanced};
use crate::utility::{UtilitySlot, clip_chars};
use crate::{BoxFuture, InProcessEngine, context_exclusion, goal, raw_exchange};

/// Longest reply text an edit may save, in characters.
pub(crate) const MAX_EDITED_REPLY_CHARS: usize = 64_000;
/// Longest side question, in characters.
pub(crate) const MAX_SIDE_QUESTION_CHARS: usize = 4_000;
/// Most chat text a side question or a resume summary reads, in characters (the latest
/// messages first).
const MAX_CHAT_SOURCE_CHARS: usize = 24_000;

const SIDE_QUESTION_PROMPT: &str = "Answer the side question about the conversation below. The conversation is context only: do not continue it or answer its earlier messages. Reply in the language of the question.";
const RESUME_SUMMARY_PROMPT: &str = "Summarize the conversation below so a new chat can continue it without the messages. Keep decisions, open tasks, constraints, file paths, code identifiers, and the user's stated preferences. Write in the conversation's language. Return only the summary.";

/// The metadata fields an edited reply keeps from the one it replaces (who wrote it).
const KEPT_REPLY_FIELDS: [&str; 4] = ["provider_id", "provider_name", "icon_slug", "model_id"];

/// The chat as `Speaker: text` blocks, the latest messages kept when it is longer than
/// [`MAX_CHAT_SOURCE_CHARS`]. Tool results and empty messages are left out.
pub(crate) fn latest_transcript(history: &[NodeRecord]) -> String {
    let mut blocks: Vec<String> = Vec::new();
    let mut used = 0_usize;
    for node in history.iter().rev() {
        let speaker = match node.role {
            NodeRole::User => "User",
            NodeRole::Assistant => "Assistant",
            NodeRole::CompactionSummary => "Summary",
            NodeRole::Tool | NodeRole::System => continue,
        };
        let text = node.content.trim();
        if text.is_empty() {
            continue;
        }
        let left = MAX_CHAT_SOURCE_CHARS.saturating_sub(used);
        if left == 0 {
            break;
        }
        let block = clip_chars(&format!("{speaker}: {text}"), left);
        used = used.saturating_add(block.chars().count());
        blocks.push(block);
    }
    blocks.reverse();
    blocks.join("\n\n")
}

fn invalid(detail: &'static str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::InvalidInput, detail)
}

impl InProcessEngine {
    /// The chat's own provider, keys, and model (what its next reply would use).
    pub(crate) fn resolve_chat_target(
        &self,
        settings: &AppSettings,
        thread_id: Option<&str>,
    ) -> BistreResult<(ProviderProfile, KeyRing, String, ProviderAdvancedPrefs)> {
        let thread = thread_id
            .map(|tid| self.storage.get_thread(tid))
            .transpose()?
            .flatten()
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        let assistant = self
            .storage
            .list_assistants()?
            .into_iter()
            .find(|a| a.id == thread.assistant_id);
        let (provider, keys, model, _) =
            self.resolve_execution_target(settings, &thread, assistant.as_ref())?;
        let adv = load_provider_advanced(&self.storage, &provider.id);
        Ok((adv.speaking(&provider), keys, model, adv))
    }

    /// The history the chat's next reply reads, from its active head.
    pub(crate) fn active_history(&self, thread_id: &str) -> BistreResult<Vec<NodeRecord>> {
        let head = self
            .storage
            .get_thread(thread_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?
            .active_head_node_id
            .ok_or_else(|| invalid("empty_chat"))?;
        crate::turn_context::project_turn_history(&self.storage, thread_id, &head, false)
    }

    /// Leaves `node_id` out of the chat's context, or brings it back; returns the new list.
    pub fn set_node_excluded(
        &self,
        thread_id: String,
        node_id: String,
        excluded: bool,
    ) -> BoxFuture<'_, BistreResult<Vec<String>>> {
        Box::pin(off_worker(&self.storage, move |s| {
            context_exclusion::set(s, &thread_id, &node_id, excluded)
        }))
    }

    /// The ids of the chat's left-out messages.
    pub fn list_excluded_nodes(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<String>>> {
        Box::pin(off_worker(&self.storage, move |s| {
            context_exclusion::load(s, &thread_id)
        }))
    }

    /// Saves `content` as a new version of the reply `node_id` (a sibling on its parent, the
    /// chat's new head), stopping the chat's reply first. The new version keeps who wrote
    /// the reply and drops its tool calls, thinking, and provider state.
    pub fn edit_reply(
        &self,
        thread_id: String,
        node_id: String,
        content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>> {
        Box::pin(async move {
            let text = content.trim();
            if text.is_empty() || text.chars().count() > MAX_EDITED_REPLY_CHARS {
                return Err(invalid("edited_reply_length"));
            }
            self.cancel_active_run(thread_id.clone()).await?;
            let source = self
                .storage
                .list_branch(&thread_id, &node_id)?
                .pop()
                .filter(|n| n.id == node_id && n.role == NodeRole::Assistant)
                .ok_or_else(|| invalid("not_a_reply"))?;
            let old = match source
                .provider_meta_json
                .as_deref()
                .map(serde_json::from_str)
            {
                Some(Ok(v)) => v,
                Some(Err(err)) => {
                    tracing::warn!(%err, "reply metadata unreadable; the edit names no author");
                    Value::Null
                }
                None => Value::Null,
            };
            let mut meta = serde_json::Map::new();
            for field in KEPT_REPLY_FIELDS {
                if let Some(v) = old.get(field) {
                    meta.insert(field.to_owned(), v.clone());
                }
            }
            meta.insert("edited_from".to_owned(), Value::String(source.id.clone()));
            let node = self.storage.append_node(
                thread_id,
                source.parent_id,
                NodeRole::Assistant,
                text.to_owned(),
                Some(Value::Object(meta).to_string()),
            )?;
            emit(
                &self.events_tx,
                EngineEvent::NodeCommitted { node: node.clone() },
            );
            Ok(node)
        })
    }

    /// Answers `question` about the chat with its own model, from the history its next reply
    /// reads. Nothing is saved to the chat; the spend is booked on it.
    pub fn ask_side_question(
        &self,
        thread_id: String,
        question: String,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let q = question.trim();
            if q.is_empty() || q.chars().count() > MAX_SIDE_QUESTION_CHARS {
                return Err(invalid("side_question_length"));
            }
            let transcript = latest_transcript(&self.active_history(&thread_id)?);
            let prompt = format!("{transcript}\n\n[Side question]\n{q}");
            let out = self
                .run_utility_completion(
                    UtilitySlot::SideQuestion,
                    Some(&thread_id),
                    SIDE_QUESTION_PROMPT,
                    &prompt,
                    2048,
                )
                .await?;
            if out.text.is_empty() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ProviderRequestFailed,
                    "empty_answer",
                ));
            }
            Ok(out.text)
        })
    }

    /// Summarizes the chat (Default models > Summary) into a new chat that opens with the
    /// summary, keeping the chat's title, settings, and open goal. A failed summary is an
    /// error: no chat opens with a partial one.
    pub fn summarize_into_new_chat(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>> {
        Box::pin(async move {
            let transcript = latest_transcript(&self.active_history(&thread_id)?);
            if transcript.is_empty() {
                return Err(invalid("empty_chat"));
            }
            let out = self
                .run_utility_completion(
                    UtilitySlot::Summary,
                    Some(&thread_id),
                    RESUME_SUMMARY_PROMPT,
                    &transcript,
                    2048,
                )
                .await?;
            if out.text.is_empty() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ProviderRequestFailed,
                    "empty_summary",
                ));
            }
            let meta = serde_json::json!({
                "compaction": true,
                "summarized_from": thread_id,
                "provider_id": out.provider.id,
                "provider_name": out.provider.name,
                "model_id": out.model_id,
                "cost_micros": out.usage.estimated_cost_micros.as_micros(),
                "cost_known": out.cost_known,
            })
            .to_string();
            let thread = self
                .storage
                .resume_from_summary(&thread_id, &out.text, &meta)?;
            if let Some(open) = goal::load(&self.storage, &thread_id)?.filter(|g| !g.completed) {
                goal::set_objective(&self.storage, &thread.id, &open.objective)?;
            }
            Ok(thread)
        })
    }

    /// The chat's goal, if one is set.
    pub fn get_thread_goal(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<goal::ThreadGoal>>> {
        Box::pin(off_worker(&self.storage, move |s| {
            goal::load(s, &thread_id)
        }))
    }

    /// Sets a new open goal for the chat; blank text clears it.
    pub fn set_thread_goal(
        &self,
        thread_id: String,
        objective: String,
    ) -> BoxFuture<'_, BistreResult<Option<goal::ThreadGoal>>> {
        Box::pin(off_worker(&self.storage, move |s| {
            goal::set_objective(s, &thread_id, &objective)
        }))
    }

    /// The raw request and response of the reply whose `request_id` is given, while it is
    /// among the latest kept in memory.
    pub fn raw_exchange(
        &self,
        request_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<raw_exchange::RawExchange>>> {
        Box::pin(async move { Ok(raw_exchange::get(&request_id)) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(role: NodeRole, content: &str) -> NodeRecord {
        NodeRecord {
            id: content.to_owned(),
            thread_id: "t".to_owned(),
            parent_id: None,
            role,
            content: content.to_owned(),
            provider_meta_json: None,
            created_at_ms: 0,
        }
    }

    /// The transcript keeps the latest messages within its bound and leaves tool results out.
    #[test]
    fn the_transcript_keeps_the_latest_messages() {
        let long = "x".repeat(MAX_CHAT_SOURCE_CHARS);
        let history = [
            node(NodeRole::User, &long),
            node(NodeRole::Assistant, "reply"),
            node(NodeRole::Tool, "tool output"),
            node(NodeRole::User, "last"),
        ];
        let text = latest_transcript(&history);
        assert!(text.ends_with("Assistant: reply\n\nUser: last"), "{text}");
        assert!(!text.contains("tool output"));
        assert!(text.chars().count() <= MAX_CHAT_SOURCE_CHARS + 4);
    }

    #[test]
    fn the_chat_action_prompts_follow_the_prompt_rules() {
        for prompt in [SIDE_QUESTION_PROMPT, RESUME_SUMMARY_PROMPT] {
            assert_eq!(
                crate::test_support::prompt_rule_breaks(prompt),
                Vec::<String>::new(),
                "{prompt}"
            );
        }
    }
}
