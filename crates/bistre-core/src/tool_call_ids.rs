//! Tool-call id sanitizing and healing of malformed or duplicate calls (split out of `tools.rs`).

use crate::replay_policy::{blake3_short_hash, parse_turn_wire_meta};
use crate::tools::ParsedToolCall;
use bistre_protocol::{NodeRecord, NodeRole};
use regex::Regex;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

/// Maximum replayed tool-call ID length.
pub const MAX_TOOL_CALL_ID_LEN: usize = 64;

/// The ids a history's tool calls and results are sent with. A result pairs with the latest
/// earlier call of its id that is still open; a call or result left unpaired (a deleted or
/// edited branch) is not sent. A paired id that is unique in the history and already
/// `[A-Za-z0-9_-]{1,64}` is sent as stored, so a replay to the model that made it keeps every
/// link to it; any other pair (a reused `call_0` from a provider that sends no ids, or an id
/// stored before sanitizing) gets one new deterministic id for both call and result.
#[derive(Debug, Default)]
pub struct ToolIdPlan {
    /// `(assistant node index, stored call id)` -> wire id.
    calls: HashMap<(usize, String), String>,
    /// Tool node index -> wire id.
    results: HashMap<usize, String>,
}

impl ToolIdPlan {
    #[must_use]
    pub fn new(history: &[NodeRecord]) -> Self {
        let mut open: HashMap<String, usize> = HashMap::new();
        let mut pairs: Vec<(usize, String, usize)> = Vec::new();
        for (idx, node) in history.iter().enumerate() {
            let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
            match node.role {
                NodeRole::Assistant => {
                    for call in meta.tool_calls {
                        if !call.call_id.is_empty() {
                            open.insert(call.call_id, idx);
                        }
                    }
                }
                NodeRole::Tool => {
                    if let Some(res) = meta.tool_result
                        && let Some(asst) = open.remove(&res.call_id)
                    {
                        pairs.push((asst, res.call_id, idx));
                    }
                }
                NodeRole::System | NodeRole::User | NodeRole::CompactionSummary => {}
            }
        }
        let mut uses: HashMap<&str, usize> = HashMap::new();
        for (_, id, _) in &pairs {
            *uses.entry(id.as_str()).or_default() += 1;
        }
        let mut plan = Self::default();
        for (asst, id, tool) in &pairs {
            let wire = if uses.get(id.as_str()) == Some(&1) && is_wire_safe(id) {
                id.clone()
            } else {
                format!(
                    "call_{}",
                    blake3_short_hash(&format!("{}:{id}", history[*asst].id))
                )
            };
            plan.results.insert(*tool, wire.clone());
            plan.calls.insert((*asst, id.clone()), wire);
        }
        plan
    }

    /// The wire id of the call `call_id` stored on assistant node `node_idx`; `None` when it
    /// has no result and is not sent.
    #[must_use]
    pub fn call(&self, node_idx: usize, call_id: &str) -> Option<&str> {
        self.calls
            .get(&(node_idx, call_id.to_owned()))
            .map(String::as_str)
    }

    /// The wire id of the result on tool node `node_idx`; `None` when it answers no call.
    #[must_use]
    pub fn result(&self, node_idx: usize) -> Option<&str> {
        self.results.get(&node_idx).map(String::as_str)
    }
}

fn is_wire_safe(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_TOOL_CALL_ID_LEN
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// `ReplayToolCallIds`: restricts IDs to `[A-Za-z0-9_-]{1,64}` and makes them unique, so a
/// provider never rejects replayed history over a foreign or duplicated call ID.
pub fn sanitize_tool_call_id<S: std::hash::BuildHasher>(
    raw: &str,
    seen: &mut HashSet<String, S>,
    ordinal: usize,
) -> String {
    let mut id: String = raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .take(MAX_TOOL_CALL_ID_LEN)
        .collect();
    if id.is_empty() {
        id = format!("call_{ordinal}");
    }
    let base = id.clone();
    let mut n = 1_usize;
    while !seen.insert(id.clone()) {
        n += 1;
        let suffix = format!("_{n}");
        let keep = MAX_TOOL_CALL_ID_LEN
            .saturating_sub(suffix.len())
            .min(base.len());
        id = format!("{}{suffix}", &base[..keep]);
    }
    id
}

/// Unsloth-inspired self-healing tool-call parser: recovers XML-leaked `<tool_call>{...}</tool_call>`
/// calls emitted as plain text by local/open models and deduplicates identical invocations.
pub fn heal_and_dedup_tool_calls(
    native_calls: Vec<ParsedToolCall>,
    assistant_text: &str,
) -> (Vec<ParsedToolCall>, String) {
    let mut out = Vec::new();
    let mut seen: HashSet<(String, String)> = HashSet::new();
    let mut seen_ids: HashSet<String> = HashSet::new();

    for mut call in native_calls {
        let sig = (call.name.clone(), call.arguments.to_string());
        if seen.insert(sig) {
            call.id = sanitize_tool_call_id(&call.id, &mut seen_ids, out.len() + 1);
            out.push(call);
        }
    }

    let Ok(re) = Regex::new(r"(?s)<tool_call>\s*(\{.*?\})\s*</tool_call>") else {
        return (out, assistant_text.to_owned());
    };
    let mut healed_idx: u32 = 0;
    for cap in re.captures_iter(assistant_text) {
        let Some(json_slice) = cap.get(1).map(|m| m.as_str()) else {
            continue;
        };
        if let Ok(val) = serde_json::from_str::<Value>(json_slice)
            && let Some(name) = val.get("name").and_then(Value::as_str)
        {
            let args = val.get("arguments").cloned().unwrap_or_else(|| json!({}));
            let sig = (name.to_owned(), args.to_string());
            if seen.insert(sig) {
                healed_idx = healed_idx.saturating_add(1);
                out.push(ParsedToolCall {
                    id: sanitize_tool_call_id(
                        &format!("healed_call_{healed_idx}"),
                        &mut seen_ids,
                        out.len() + 1,
                    ),
                    name: name.to_owned(),
                    arguments: args,
                    healed_from_text: true,
                });
            }
        }
    }

    let cleaned_text = re.replace_all(assistant_text, "").trim().to_owned();
    (out, cleaned_text)
}
