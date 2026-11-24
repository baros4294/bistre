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
            (ProviderDialect::Anthropic, ReasoningBlock::AnthropicThinking { signature, .. }) => {
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
