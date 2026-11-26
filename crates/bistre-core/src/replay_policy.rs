//! Canonical turn wire metadata, cryptographic reasoning block round-tripping, and safe
//! cross-provider / post-compaction replay policy (Spec 02 & late-2026 Big 3 wire standards).
//!
//! Invariants:
//! - Opaque reasoning signatures (`AnthropicThinking.signature`, `AnthropicRedactedThinking.data`,
//!   `OpenAiReasoning.encrypted_content`, `GeminiThought.signature`) are replayed ONLY when
//!   `(dialect, provider_id, model_id, system_hash, tools_hash)` match AND no intervening
//!   compaction or history mutation invalidated the prefix.
//! - Cross-provider switches NEVER forward opaque signatures, server response IDs, or
//!   provider-only encrypted compaction items.
//! - When replaying historical function calls to Gemini without a valid Gemini `thoughtSignature`,
//!   Google's documented sentinel [`GEMINI_THOUGHT_SIGNATURE_BYPASS`] prevents 400 validation errors.

use bistre_protocol::{NodeRecord, NodeRole, ProviderDialect, StoredAttachment};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Official Google Gemini sentinel value for synthetic or cross-provider-migrated function calls
/// that lack an original Gemini `thoughtSignature`.
pub const GEMINI_THOUGHT_SIGNATURE_BYPASS: &str = "skip_thought_signature_validator";

/// Versioned typed reasoning/thinking block stored inside `NodeRecord.provider_meta_json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ReasoningBlock {
    /// `OpenAI` Responses API encrypted reasoning item (`include: ["reasoning.encrypted_content"]`).
    OpenAiReasoning {
        id: String,
        #[serde(default)]
        summary: Vec<Value>,
        encrypted_content: String,
    },
    /// Anthropic Messages API `thinking` block with exact cryptographic `signature`.
    AnthropicThinking { thinking: String, signature: String },
    /// Anthropic Messages API immutable `redacted_thinking` block.
    AnthropicRedactedThinking { data: String },
    /// Google Gemini `thought` part with encrypted `thoughtSignature`.
    GeminiThought {
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        signature: Option<String>,
    },
    /// Plaintext reasoning trace (`DeepSeek` / vLLM / Ollama / cross-provider handoff).
    PlainReasoning { text: String },
    /// Gemini `thoughtSignature` on a (often empty, trailing) text part of the answer; it goes
    /// back on the text part, never moved onto a call (kelivo fixtures).
    GeminiTextSignature { signature: String },
}

/// Canonical persisted tool call attached to an `Assistant` turn.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredToolCall {
    pub call_id: String,
    pub name: String,
    pub arguments_json: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thought_signature: Option<String>,
}

/// Canonical persisted tool result metadata attached to a `NodeRole::Tool` node.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredToolResult {
    pub call_id: String,
    pub name: String,
    #[serde(default)]
    pub is_error: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub media_attachments: Vec<StoredAttachment>,
}

/// Provenance recorded on every committed `Assistant` node to decide prefix-binding safety.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnOriginMeta {
    pub dialect: ProviderDialect,
    pub provider_id: String,
    pub model_id: String,
    pub system_hash: String,
    pub tools_hash: String,
}

/// Optional server-side chaining handle (`store: true` opt-in only).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerStateMeta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interaction_id: Option<String>,
    #[serde(default)]
    pub store_enabled: bool,
}

/// Target request context used to validate whether stored opaque metadata may be replayed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplayContext {
    pub dialect: ProviderDialect,
    pub provider_id: String,
    pub model_id: String,
    pub system_hash: String,
    pub tools_hash: String,
    pub cache_key_seed: String,
}

impl ReplayContext {
    /// Builds a deterministic replay context from the outbound request parameters.
    #[must_use]
    pub fn new(
        dialect: ProviderDialect,
        provider_id: &str,
        model_id: &str,
        system_prompt: &str,
        tools_json_canonical: &str,
        thread_id: Option<&str>,
    ) -> Self {
        let seed = thread_id.unwrap_or(system_prompt);
        Self {
            dialect,
            provider_id: provider_id.to_owned(),
            model_id: model_id.to_owned(),
            system_hash: blake3_short_hash(system_prompt),
            tools_hash: blake3_short_hash(tools_json_canonical),
            cache_key_seed: blake3_short_hash(seed),
        }
    }

    /// Privacy-preserving deterministic `OpenAI` `prompt_cache_key` (contains zero PII).
    #[must_use]
    pub fn openai_prompt_cache_key(&self) -> String {
        format!("bistre_{}", self.cache_key_seed)
    }
}

/// Parsed subset of `NodeRecord.provider_meta_json` relevant to wire replay.
#[derive(Debug, Clone, Default)]
pub struct ParsedTurnWireMeta {
    pub origin: Option<TurnOriginMeta>,
    pub server_state: Option<ServerStateMeta>,
    pub reasoning_blocks: Vec<ReasoningBlock>,
    pub tool_calls: Vec<StoredToolCall>,
    pub tool_result: Option<StoredToolResult>,
    pub thinking_text: Option<String>,
}

/// Short 16-hex-char lowercase `blake3` fingerprint for prefix hashes and cache keys.
#[must_use]
pub fn blake3_short_hash(input: &str) -> String {
    let hex = blake3::hash(input.as_bytes()).to_hex();
    hex.as_str()[..16].to_owned()
}

/// Parses wire replay metadata from `NodeRecord.provider_meta_json` leniently (backward compatible
/// with pre-Wave-1 nodes that only stored `thinking_text` / `attachments`).
#[must_use]
pub fn parse_turn_wire_meta(meta_json: Option<&str>) -> ParsedTurnWireMeta {
    let Some(raw) = meta_json else {
        return ParsedTurnWireMeta::default();
    };
    let Ok(val) = serde_json::from_str::<Value>(raw) else {
        return ParsedTurnWireMeta::default();
    };
    let origin = val
        .get("origin")
        .and_then(|v| serde_json::from_value::<TurnOriginMeta>(v.clone()).ok());
    let server_state = val
        .get("server_state")
        .and_then(|v| serde_json::from_value::<ServerStateMeta>(v.clone()).ok());
    let reasoning_blocks = val
        .get("reasoning_blocks")
        .and_then(|v| serde_json::from_value::<Vec<ReasoningBlock>>(v.clone()).ok())
        .unwrap_or_default();
    let tool_calls = val
        .get("tool_calls")
        .and_then(|v| serde_json::from_value::<Vec<StoredToolCall>>(v.clone()).ok())
        .unwrap_or_default();
    let tool_result = val
        .get("tool_result")
        .and_then(|v| serde_json::from_value::<StoredToolResult>(v.clone()).ok());
    let thinking_text = val
        .get("thinking_text")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .map(ToOwned::to_owned);
    ParsedTurnWireMeta {
        origin,
        server_state,
        reasoning_blocks,
        tool_calls,
        tool_result,
        thinking_text,
    }
}

/// Returns `true` ONLY when stored opaque reasoning blocks/signatures are cryptographically safe
/// to replay verbatim to `target` without triggering prefix-binding or signature 400 errors.
#[must_use]
pub fn can_replay_opaque_reasoning(
    origin: Option<&TurnOriginMeta>,
    target: &ReplayContext,
    history_contains_compaction: bool,
) -> bool {
    if history_contains_compaction {
        return false;
    }
    let Some(orig) = origin else {
        return false;
    };
    orig.dialect == target.dialect
        && orig.provider_id == target.provider_id
        && orig.model_id == target.model_id
        && orig.system_hash == target.system_hash
        && orig.tools_hash == target.tools_hash
}

/// Returns `Some(server_id)` ONLY when stateful chaining (`previous_response_id` /
/// `previous_interaction_id`) is safe: `store: true`, same provider/model/prefix, and no edits.
#[must_use]
pub fn eligible_server_chain_id<'a>(
    origin: Option<&TurnOriginMeta>,
    state: Option<&'a ServerStateMeta>,
    target: &ReplayContext,
    store_requested: bool,
) -> Option<&'a str> {
    if !store_requested {
        return None;
    }
    let st = state?;
    if !st.store_enabled || !can_replay_opaque_reasoning(origin, target, false) {
        return None;
    }
    match target.dialect {
        ProviderDialect::OpenAi => st.response_id.as_deref().filter(|s| !s.is_empty()),
        ProviderDialect::GoogleGemini => st.interaction_id.as_deref().filter(|s| !s.is_empty()),
        ProviderDialect::Anthropic | ProviderDialect::CustomOpenAi => None,
    }
}

/// A safe stateful chain (R7): the stored reply to continue from, and where the items after
/// it (the only ones sent) begin in the history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChainPlan {
    pub previous_id: String,
    pub first_new_index: usize,
}

/// R7: chain from the latest assistant reply when storing is on for this request and the
/// history is uncompacted (a compaction rewrote the prefix the server holds). The request
/// then sends only what came after that reply; the server already has the rest.
#[must_use]
pub fn chain_plan(
    history: &[NodeRecord],
    target: &ReplayContext,
    store_enabled: bool,
) -> Option<ChainPlan> {
    if !store_enabled || history_has_client_compaction(history) {
        return None;
    }
    let idx = history
        .iter()
        .rposition(|n| n.role == NodeRole::Assistant)?;
    let meta = parse_turn_wire_meta(history[idx].provider_meta_json.as_deref());
    let id = eligible_server_chain_id(
        meta.origin.as_ref(),
        meta.server_state.as_ref(),
        target,
        store_enabled,
    )?;
    Some(ChainPlan {
        previous_id: id.to_owned(),
        first_new_index: idx.saturating_add(1),
    })
}

/// Keys of a node's metadata the app never reads (R39): opaque reasoning payloads and
/// signatures, server chain state, and parts delivered typed elsewhere (grounding through
/// `list_thread_grounding`, attachments on the node DTO). They stay in storage for replay.
const UI_HIDDEN_META_KEYS: [&str; 5] = [
    "reasoning_blocks",
    "server_state",
    "grounding",
    "attachments",
    "origin",
];

/// The node metadata sent to the app (R39): everything but [`UI_HIDDEN_META_KEYS`], so a
/// reply's large encrypted reasoning never crosses the FFI on every thread load.
#[must_use]
pub fn ui_node_meta(raw: Option<&str>) -> Option<String> {
    let text = raw?;
    let Ok(Value::Object(mut map)) = serde_json::from_str::<Value>(text) else {
        return Some(text.to_owned());
    };
    for key in UI_HIDDEN_META_KEYS {
        map.remove(key);
    }
    Some(Value::Object(map).to_string())
}

/// The result sent back for a tool call that never ran (written to the model, not the UI).
pub const TOOL_CALL_DID_NOT_RUN: &str = "This tool call did not run (the reply was stopped).";

/// Pairs every tool call with a result (pi #9986, cherry-studio #24997): a call left without
/// one by a stopped or crashed run gets a "did not run" error result right after its turn's
/// existing results, so the next request is valid and the model knows the call did not run.
#[must_use]
pub fn answer_dangling_tool_calls(history: Vec<NodeRecord>) -> Vec<NodeRecord> {
    let answered: std::collections::HashSet<String> = history
        .iter()
        .filter(|n| n.role == NodeRole::Tool)
        .filter_map(|n| parse_turn_wire_meta(n.provider_meta_json.as_deref()).tool_result)
        .map(|r| r.call_id)
        .collect();
    let mut out = Vec::with_capacity(history.len());
    let mut pending: Vec<(NodeRecord, StoredToolCall)> = Vec::new();
    let flush = |out: &mut Vec<NodeRecord>, pending: &mut Vec<(NodeRecord, StoredToolCall)>| {
        for (turn, call) in pending.drain(..) {
            let meta = serde_json::json!({ "tool_result": StoredToolResult {
                call_id: call.call_id.clone(),
                name: call.name,
                is_error: true,
                media_attachments: Vec::new(),
            }});
            out.push(NodeRecord {
                id: format!("{}:did-not-run:{}", turn.id, call.call_id),
                thread_id: turn.thread_id.clone(),
                parent_id: Some(turn.id.clone()),
                role: NodeRole::Tool,
                content: TOOL_CALL_DID_NOT_RUN.to_owned(),
                provider_meta_json: Some(meta.to_string()),
                created_at_ms: turn.created_at_ms,
            });
        }
    };
    for node in history {
        if node.role != NodeRole::Tool {
            flush(&mut out, &mut pending);
        }
        if node.role == NodeRole::Assistant {
            for call in parse_turn_wire_meta(node.provider_meta_json.as_deref()).tool_calls {
                if !call.call_id.is_empty() && !answered.contains(&call.call_id) {
                    pending.push((node.clone(), call));
                }
            }
        }
        out.push(node);
    }
    flush(&mut out, &mut pending);
    out
}

/// Drops `null` members from a stored provider item before it is sent back (codex #47733):
/// some providers reject `"field": null` they would accept as absent. Depth-bounded.
#[must_use]
pub fn without_null_fields(value: &Value) -> Value {
    fn strip(v: &Value, depth: u8) -> Value {
        if depth == 0 {
            return v.clone();
        }
        match v {
            Value::Object(map) => Value::Object(
                map.iter()
                    .filter(|(_, v)| !v.is_null())
                    .map(|(k, v)| (k.clone(), strip(v, depth - 1)))
                    .collect(),
            ),
            Value::Array(items) => {
                Value::Array(items.iter().map(|v| strip(v, depth - 1)).collect())
            }
            other => other.clone(),
        }
    }
    strip(value, 32)
}

/// When the history was last compacted: the newest summary marker's time, if any (R14).
#[must_use]
pub fn latest_compaction_ms(history: &[NodeRecord]) -> Option<i64> {
    history
        .iter()
        .filter(|n| {
            n.role == NodeRole::CompactionSummary
                || (n.role == NodeRole::User
                    && n.content.starts_with("[Earlier conversation summary]"))
        })
        .map(|n| n.created_at_ms)
        .max()
}

/// R14: a turn's opaque reasoning is bound to the prefix it was made with; only turns made
/// before the newest compaction lost that prefix (later turns were made after it).
#[must_use]
pub fn made_before_compaction(compaction_at: Option<i64>, node: &NodeRecord) -> bool {
    compaction_at.is_some_and(|at| node.created_at_ms <= at)
}

/// Detects whether `history` begins with a client-side compaction marker (which alters the
/// conversation prefix and therefore invalidates prefix-bound signatures on earlier turns).
#[must_use]
pub fn history_has_client_compaction(history: &[NodeRecord]) -> bool {
    history.iter().any(|n| {
        n.role == NodeRole::CompactionSummary
            || (n.role == NodeRole::User && n.content.starts_with("[Earlier conversation summary]"))
    })
}

/// Filters `reasoning_blocks` for `node` according to strict provenance and prefix-binding rules.
/// Returns only the blocks safe to emit on the wire for `target`.
#[must_use]
pub fn safe_reasoning_blocks_for_target(
    meta: &ParsedTurnWireMeta,
    target: &ReplayContext,
    history_compacted: bool,
) -> Vec<ReasoningBlock> {
    if !can_replay_opaque_reasoning(meta.origin.as_ref(), target, history_compacted) {
        return Vec::new();
    }
    meta.reasoning_blocks
        .iter()
        .filter(|blk| match (target.dialect, blk) {
            (
                ProviderDialect::OpenAi,
                ReasoningBlock::OpenAiReasoning {
                    encrypted_content, ..
                },
            ) => !encrypted_content.is_empty(),
            (ProviderDialect::Anthropic, ReasoningBlock::AnthropicThinking { signature, .. })
            | (ProviderDialect::GoogleGemini, ReasoningBlock::GeminiTextSignature { signature }) => {
                !signature.is_empty()
            }
            (ProviderDialect::Anthropic, ReasoningBlock::AnthropicRedactedThinking { data }) => {
                !data.is_empty()
            }
            (ProviderDialect::GoogleGemini, ReasoningBlock::GeminiThought { signature, .. }) => {
                signature.as_deref().is_some_and(|s| !s.is_empty())
            }
            _ => false,
        })
        .cloned()
        .collect()
}

/// Resolves the `thoughtSignature` to attach to a Gemini `functionCall` part:
/// uses the original signature when provenance matches, else Google's documented bypass sentinel.
#[must_use]
pub fn gemini_function_call_signature<'a>(
    call: &'a StoredToolCall,
    origin: Option<&TurnOriginMeta>,
    target: &ReplayContext,
    history_compacted: bool,
) -> &'a str {
    if can_replay_opaque_reasoning(origin, target, history_compacted)
        && let Some(sig) = call.thought_signature.as_deref()
        && !sig.is_empty()
    {
        return sig;
    }
    GEMINI_THOUGHT_SIGNATURE_BYPASS
}

/// Builds a compact, bounded (`<= 8,000` chars) plaintext reasoning handoff note when switching
/// providers/models mid-conversation, preserving key reasoning context without ever leaking
/// opaque cryptographic signatures.
#[must_use]
pub fn cross_provider_reasoning_handoff_for_node(
    meta: &ParsedTurnWireMeta,
    target: &ReplayContext,
    is_latest_assistant: bool,
) -> Option<String> {
    if !is_latest_assistant {
        return None;
    }
    let switched = meta
        .origin
        .as_ref()
        .is_some_and(|o| o.dialect != target.dialect || o.model_id != target.model_id);
    if !switched {
        return None;
    }
    let raw = meta.thinking_text.as_deref()?;
    let handoff = crate::compaction::format_cross_provider_reasoning_handoff(raw);
    if handoff.is_empty() {
        None
    } else {
        Some(handoff)
    }
}

#[cfg(test)]
mod tests {
    /// R39: the app gets the usage and thinking it shows, never the opaque reasoning payload.
    #[test]
    fn the_app_gets_slim_node_metadata() {
        let raw = serde_json::json!({
            "model_id": "m",
            "input_tokens": 12,
            "thinking_text": "because",
            "reasoning_blocks": [{ "kind": "anthropic_thinking", "thinking": "x", "signature": "s".repeat(4096) }],
            "server_state": { "response_id": "resp_1" },
            "attachments": [],
        })
        .to_string();
        let slim = ui_node_meta(Some(&raw)).unwrap_or_default();
        let val: Value = serde_json::from_str(&slim).unwrap_or(Value::Null);
        assert_eq!(val["model_id"], "m");
        assert_eq!(val["input_tokens"], 12);
        assert_eq!(val["thinking_text"], "because");
        assert!(val.get("reasoning_blocks").is_none());
        assert!(val.get("server_state").is_none());
        assert!(slim.len() < raw.len() / 4);
        assert_eq!(ui_node_meta(None), None);
    }

    /// A tool call left without a result (a stopped or crashed run) gets a "did not run" result
    /// right after its turn, so the next request is valid and the model knows (pi #9986).
    #[test]
    fn a_dangling_tool_call_gets_a_did_not_run_result() {
        let rec = |id: &str, role, meta: Option<Value>| NodeRecord {
            id: id.to_owned(),
            thread_id: "t".to_owned(),
            parent_id: None,
            role,
            content: "x".to_owned(),
            provider_meta_json: meta.map(|m| m.to_string()),
            created_at_ms: 1,
        };
        let calls = serde_json::json!({ "tool_calls": [
            { "call_id": "c1", "name": "read", "arguments_json": "{}" },
            { "call_id": "c2", "name": "grep", "arguments_json": "{}" }
        ]});
        let answered = serde_json::json!({ "tool_result": { "call_id": "c1", "name": "read" } });
        let history = vec![
            rec("u", NodeRole::User, None),
            rec("a", NodeRole::Assistant, Some(calls)),
            rec("r1", NodeRole::Tool, Some(answered)),
            rec("u2", NodeRole::User, None),
        ];
        let fixed = answer_dangling_tool_calls(history);
        let roles: Vec<NodeRole> = fixed.iter().map(|n| n.role).collect();
        assert_eq!(
            roles,
            [
                NodeRole::User,
                NodeRole::Assistant,
                NodeRole::Tool,
                NodeRole::Tool,
                NodeRole::User
            ]
        );
        let synthetic = parse_turn_wire_meta(fixed[3].provider_meta_json.as_deref());
        let res = synthetic.tool_result.unwrap_or_else(|| StoredToolResult {
            call_id: String::new(),
            name: String::new(),
            is_error: false,
            media_attachments: Vec::new(),
        });
        assert_eq!(
            (res.call_id.as_str(), res.name.as_str(), res.is_error),
            ("c2", "grep", true)
        );
        assert_eq!(fixed[3].content, TOOL_CALL_DID_NOT_RUN);
    }

    /// R14: a compaction only invalidates reasoning made before it; a turn made after the
    /// newest summary keeps its blocks.
    #[test]
    fn reasoning_made_after_the_compaction_is_still_replayable() {
        use bistre_protocol::{NodeRecord, NodeRole};
        let node = |role, at: i64| NodeRecord {
            id: format!("n{at}"),
            thread_id: "t".to_owned(),
            parent_id: None,
            role,
            content: "x".to_owned(),
            provider_meta_json: None,
            created_at_ms: at,
        };
        let history = vec![
            node(NodeRole::Assistant, 10),
            node(NodeRole::CompactionSummary, 20),
            node(NodeRole::Assistant, 30),
        ];
        let at = latest_compaction_ms(&history);
        assert!(made_before_compaction(at, &history[0]));
        assert!(!made_before_compaction(at, &history[2]));
        assert!(!made_before_compaction(None, &history[0]));
    }

    use super::*;

    fn ctx(dialect: ProviderDialect, model: &str, sys: &str, tools: &str) -> ReplayContext {
        ReplayContext::new(dialect, "prov-1", model, sys, tools, Some("thread-1"))
    }

    fn origin(dialect: ProviderDialect, model: &str, sys: &str, tools: &str) -> TurnOriginMeta {
        TurnOriginMeta {
            dialect,
            provider_id: "prov-1".to_owned(),
            model_id: model.to_owned(),
            system_hash: blake3_short_hash(sys),
            tools_hash: blake3_short_hash(tools),
        }
    }

    /// R7: chaining happens when storing is on and the history is uncompacted, and then only
    /// the items after the chained reply are sent.
    #[test]
    fn chaining_needs_storing_and_sends_only_the_new_items() {
        let target = ctx(ProviderDialect::OpenAi, "m", "sys", "tools");
        let meta = serde_json::json!({
            "origin": origin(ProviderDialect::OpenAi, "m", "sys", "tools"),
            "server_state": { "response_id": "resp_1", "store_enabled": true }
        });
        let rec = |id: &str, role, content: &str, meta: Option<String>| NodeRecord {
            id: id.to_owned(),
            thread_id: "thread-1".to_owned(),
            parent_id: None,
            role,
            content: content.to_owned(),
            provider_meta_json: meta,
            created_at_ms: 1,
        };
        let history = vec![
            rec("u1", NodeRole::User, "one", None),
            rec("a1", NodeRole::Assistant, "reply", Some(meta.to_string())),
            rec("u2", NodeRole::User, "two", None),
        ];
        let plan = chain_plan(&history, &target, true);
        assert_eq!(
            plan.as_ref()
                .map(|p| (p.previous_id.as_str(), p.first_new_index)),
            Some(("resp_1", 2))
        );
        assert_eq!(chain_plan(&history, &target, false), None, "storing is off");
        let mut compacted = history.clone();
        compacted.insert(0, rec("s", NodeRole::CompactionSummary, "sum", None));
        assert_eq!(chain_plan(&compacted, &target, true), None, "compacted");
    }

    #[test]
    fn opaque_reasoning_replays_only_on_exact_same_origin_and_unchanged_prefix() {
        let target = ctx(ProviderDialect::Anthropic, "m-a", "sys-1", "tools-1");
        let meta = ParsedTurnWireMeta {
            origin: Some(origin(
                ProviderDialect::Anthropic,
                "m-a",
                "sys-1",
                "tools-1",
            )),
            reasoning_blocks: vec![
                ReasoningBlock::AnthropicThinking {
                    thinking: "deep thought".to_owned(),
                    signature: "sig_abc".to_owned(),
                },
                ReasoningBlock::AnthropicRedactedThinking {
                    data: "redacted_xyz".to_owned(),
                },
            ],
            ..ParsedTurnWireMeta::default()
        };
        // Exact match, uncompacted -> both blocks preserved verbatim.
        assert_eq!(
            safe_reasoning_blocks_for_target(&meta, &target, false).len(),
            2
        );

        // Post-compaction -> stripped so prefix-bound signatures never 400.
        assert_eq!(
            safe_reasoning_blocks_for_target(&meta, &target, true).len(),
            0
        );

        // System prompt mutated -> stripped.
        let changed_sys = ctx(ProviderDialect::Anthropic, "m-a", "sys-2", "tools-1");
        assert_eq!(
            safe_reasoning_blocks_for_target(&meta, &changed_sys, false).len(),
            0
        );

        // Tools toggled -> stripped.
        let changed_tools = ctx(ProviderDialect::Anthropic, "m-a", "sys-1", "tools-2");
        assert_eq!(
            safe_reasoning_blocks_for_target(&meta, &changed_tools, false).len(),
            0
        );

        // Model switch -> stripped.
        let other_model = ctx(ProviderDialect::Anthropic, "m-b", "sys-1", "tools-1");
        assert_eq!(
            safe_reasoning_blocks_for_target(&meta, &other_model, false).len(),
            0
        );

        // Provider switch (Anthropic -> OpenAI) -> stripped.
        let other_dialect = ctx(ProviderDialect::OpenAi, "m-a", "sys-1", "tools-1");
        assert_eq!(
            safe_reasoning_blocks_for_target(&meta, &other_dialect, false).len(),
            0
        );
    }

    #[test]
    fn gemini_function_call_signature_falls_back_to_official_bypass_sentinel() {
        let target = ctx(ProviderDialect::GoogleGemini, "g-1", "sys", "tools");
        let call = StoredToolCall {
            call_id: "call_1".to_owned(),
            name: "read".to_owned(),
            arguments_json: r#"{"path":"a.rs"}"#.to_owned(),
            thought_signature: Some("real_gem_sig".to_owned()),
        };
        let same = origin(ProviderDialect::GoogleGemini, "g-1", "sys", "tools");
        assert_eq!(
            gemini_function_call_signature(&call, Some(&same), &target, false),
            "real_gem_sig"
        );
        // Cross-provider call -> bypass sentinel (never leaks invalid/empty signature).
        let from_oai = origin(ProviderDialect::OpenAi, "o-1", "sys", "tools");
        assert_eq!(
            gemini_function_call_signature(&call, Some(&from_oai), &target, false),
            GEMINI_THOUGHT_SIGNATURE_BYPASS
        );
    }

    #[test]
    fn cross_provider_handoff_activates_only_on_switch_and_bounds_length() {
        let meta = ParsedTurnWireMeta {
            origin: Some(origin(ProviderDialect::Anthropic, "m-a", "sys", "tools")),
            thinking_text: Some("A".repeat(10_000)),
            ..ParsedTurnWireMeta::default()
        };
        let same = ctx(ProviderDialect::Anthropic, "m-a", "sys", "tools");
        assert!(cross_provider_reasoning_handoff_for_node(&meta, &same, true).is_none());

        let switched = ctx(ProviderDialect::OpenAi, "m-b", "sys", "tools");
        let handoff = cross_provider_reasoning_handoff_for_node(&meta, &switched, true);
        assert!(handoff.is_some());
        assert!(handoff.unwrap_or_default().contains("chars omitted"));
    }
}
