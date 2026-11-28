//! `OpenRouter` `reasoning_details` on Chat Completions: the reasoning entries a model streams,
//! kept as raw JSON (every field, no fixed list of `type` or `format` values) and sent back
//! unmodified and in order on assistant tool-call turns, as the `OpenRouter` reasoning tokens
//! guide requires. A different target model gets only the entries that carry no encrypted or
//! signed payload, which it could not verify.

use std::collections::HashMap;

use serde_json::{Map, Value};

use crate::replay_policy::{
    ParsedTurnWireMeta, ReasoningBlock, ReplayContext, can_replay_opaque_reasoning,
};

/// The `type` of an encrypted entry: never merged with another fragment, never readable.
const ENCRYPTED_TYPE: &str = "reasoning.encrypted";
/// What `OpenRouter` may stream in place of encrypted reasoning; never shown as thinking.
const REDACTED_PLACEHOLDER: &str = "[REDACTED]";
/// String fields a streamed entry spreads over fragments of the same `index`.
const APPENDED_FIELDS: [&str; 3] = ["text", "summary", "signature"];
/// Most entries kept for one reply; later ones are dropped and logged.
const MAX_ENTRIES_PER_REPLY: usize = 256;

/// Builds a reply's entries from streamed fragments. Fragments of one `index` and `type` join
/// into one entry (their text, summary, and signature concatenate); an encrypted entry, a
/// changed `type` or `id`, or a fragment without `index` starts a new entry.
#[derive(Debug, Default)]
pub(crate) struct DetailsAssembler {
    entries: Vec<Value>,
    /// `index` -> position in `entries` of the entry that index is still building.
    open: HashMap<u64, usize>,
    dropped: usize,
}

impl DetailsAssembler {
    pub(crate) fn push(&mut self, fragment: &Value) {
        let Some(frag) = fragment.as_object() else {
            return;
        };
        let index = frag.get("index").and_then(Value::as_u64);
        if let Some(pos) = index.and_then(|i| self.open.get(&i).copied())
            && let Some(Value::Object(entry)) = self.entries.get_mut(pos)
            && joins(entry, frag)
        {
            merge(entry, frag);
            return;
        }
        if self.entries.len() >= MAX_ENTRIES_PER_REPLY {
            self.dropped = self.dropped.saturating_add(1);
            return;
        }
        self.entries.push(Value::Object(frag.clone()));
        if let Some(i) = index {
            self.open.insert(i, self.entries.len() - 1);
        }
    }

    /// The finished entries, in the order they started.
    pub(crate) fn finish(self) -> Vec<Value> {
        if self.dropped > 0 {
            tracing::warn!(
                dropped = self.dropped,
                kept = MAX_ENTRIES_PER_REPLY,
                "reasoning_details entries over the per-reply cap were dropped"
            );
        }
        self.entries
    }
}

fn joins(entry: &Map<String, Value>, frag: &Map<String, Value>) -> bool {
    let kind = entry.get("type").and_then(Value::as_str);
    let same_kind = frag
        .get("type")
        .and_then(Value::as_str)
        .is_none_or(|t| Some(t) == kind);
    let same_id = match (entry.get("id"), frag.get("id")) {
        (Some(a), Some(b)) if !a.is_null() && !b.is_null() => a == b,
        _ => true,
    };
    same_kind && same_id && kind != Some(ENCRYPTED_TYPE)
}

fn merge(entry: &mut Map<String, Value>, frag: &Map<String, Value>) {
    for (key, value) in frag {
        match (entry.get_mut(key), value) {
            (Some(Value::String(cur)), Value::String(more))
                if APPENDED_FIELDS.contains(&key.as_str()) =>
            {
                cur.push_str(more);
            }
            (None | Some(Value::Null), _) => {
                entry.insert(key.clone(), value.clone());
            }
            // The first value of `id`, `format`, and other fields stands.
            _ => {}
        }
    }
}

/// The readable reasoning in one delta's entries (`text` and `summary` strings), never
/// encrypted data or the redaction placeholder. Used only when the delta has no plain
/// `reasoning` string, so the same thought is never shown twice.
pub(crate) fn readable_text(entries: &[Value]) -> String {
    let mut out = String::new();
    for entry in entries {
        if entry.get("type").and_then(Value::as_str) == Some(ENCRYPTED_TYPE) {
            continue;
        }
        for key in ["text", "summary"] {
            if let Some(t) = entry.get(key).and_then(Value::as_str)
                && !is_placeholder(t)
            {
                out.push_str(t);
            }
        }
    }
    out
}

/// Whether a reasoning string is only `OpenRouter`'s stand-in for hidden reasoning.
pub(crate) fn is_placeholder(text: &str) -> bool {
    text.trim() == REDACTED_PLACEHOLDER
}

/// An entry another model can take: neither encrypted nor signed.
fn portable(entry: &Value) -> bool {
    let encrypted = entry.get("type").and_then(Value::as_str) == Some(ENCRYPTED_TYPE);
    let signed = entry
        .get("signature")
        .is_some_and(|s| !s.is_null() && s.as_str() != Some(""));
    !encrypted && !signed
}

/// The entries to send back with a stored assistant tool-call turn: all of them, unmodified and
/// in order, to the model (and unchanged prefix) that made them; to any other target only the
/// portable ones. `made_before_compaction` marks a turn whose prefix a compaction rewrote.
pub(crate) fn replay_for_target(
    meta: &ParsedTurnWireMeta,
    target: &ReplayContext,
    made_before_compaction: bool,
) -> Vec<Value> {
    let same_origin =
        can_replay_opaque_reasoning(meta.origin.as_ref(), target, made_before_compaction);
    meta.reasoning_blocks
        .iter()
        .filter_map(|b| match b {
            ReasoningBlock::OpenRouterDetails { details } => Some(details),
            _ => None,
        })
        .flatten()
        .filter(|d| same_origin || portable(d))
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::replay_policy::{TurnOriginMeta, blake3_short_hash};
    use bistre_protocol::ProviderDialect;
    use serde_json::json;

    fn assemble(fragments: &[Value]) -> Vec<Value> {
        let mut asm = DetailsAssembler::default();
        for f in fragments {
            asm.push(f);
        }
        asm.finish()
    }

    #[test]
    fn fragments_join_by_index_and_keep_every_raw_field() {
        let out = assemble(&[
            json!({"type": "reasoning.text", "index": 0, "format": "anthropic-claude-v1", "text": "Let me "}),
            json!({"type": "reasoning.text", "index": 0, "text": "check."}),
            json!({"type": "reasoning.text", "index": 0, "signature": "sig-a", "extra": {"k": 1}}),
        ]);
        assert_eq!(
            out,
            [
                json!({"type": "reasoning.text", "index": 0, "format": "anthropic-claude-v1", "text": "Let me check.", "signature": "sig-a", "extra": {"k": 1}})
            ]
        );
    }

    #[test]
    fn distinct_encrypted_blocks_are_never_merged() {
        let out = assemble(&[
            json!({"type": "reasoning.encrypted", "index": 0, "id": "tool_1", "data": "AAA"}),
            json!({"type": "reasoning.encrypted", "index": 0, "id": "tool_2", "data": "BBB"}),
            json!({"type": "reasoning.encrypted", "index": 0, "data": "CCC"}),
            json!({"type": "reasoning.summary", "index": 0, "summary": "x"}),
            json!({"type": "reasoning.text", "text": "no index"}),
            json!({"type": "reasoning.text", "text": "no index either"}),
        ]);
        let data: Vec<&Value> = out.iter().map(|e| &e["data"]).collect();
        assert_eq!(data[..3], [&json!("AAA"), &json!("BBB"), &json!("CCC")]);
        assert_eq!(out.len(), 6, "{out:?}");
    }

    #[test]
    fn readable_text_skips_encrypted_and_placeholder_entries() {
        let entries = [
            json!({"type": "reasoning.text", "text": "Plan."}),
            json!({"type": "reasoning.encrypted", "data": "opaque"}),
            json!({"type": "reasoning.text", "text": "[REDACTED]"}),
            json!({"type": "reasoning.summary", "summary": " Done."}),
        ];
        assert_eq!(readable_text(&entries), "Plan. Done.");
        assert!(is_placeholder(" [REDACTED] "));
    }

    #[test]
    fn replay_is_whole_for_the_origin_and_portable_only_after_a_switch() {
        let details = vec![
            json!({"type": "reasoning.text", "text": "a", "signature": "s"}),
            json!({"type": "reasoning.summary", "summary": "b"}),
            json!({"type": "reasoning.encrypted", "data": "c"}),
            json!({"type": "reasoning.text", "text": "d", "signature": null}),
        ];
        let meta = ParsedTurnWireMeta {
            origin: Some(TurnOriginMeta {
                dialect: ProviderDialect::CustomOpenAi,
                provider_id: "openrouter".to_owned(),
                model_id: "vendor/m1".to_owned(),
                system_hash: blake3_short_hash("sys"),
                tools_hash: blake3_short_hash("tools"),
            }),
            reasoning_blocks: vec![ReasoningBlock::OpenRouterDetails {
                details: details.clone(),
            }],
            ..ParsedTurnWireMeta::default()
        };
        let ctx = |model: &str| {
            ReplayContext::new(
                ProviderDialect::CustomOpenAi,
                "openrouter",
                model,
                "sys",
                "tools",
                Some("t"),
            )
        };
        assert_eq!(replay_for_target(&meta, &ctx("vendor/m1"), false), details);
        let switched = replay_for_target(&meta, &ctx("vendor/m2"), false);
        assert_eq!(switched, [details[1].clone(), details[3].clone()]);
        let compacted = replay_for_target(&meta, &ctx("vendor/m1"), true);
        assert_eq!(
            compacted, switched,
            "a rewritten prefix strips signed entries"
        );
    }
}
