//! Stateful SSE stream accumulator across all Big 3 + Custom dialects.
//!
//! Captures:
//! - Incremental visible text deltas (normalized to `\n`) and thinking deltas
//! - Exact cryptographic reasoning/thinking blocks (`OpenAI` `reasoning.encrypted_content`,
//!   Anthropic `thinking.signature` + `redacted_thinking.data`, Gemini `thoughtSignature`)
//! - Provider server response / interaction IDs (for opt-in stateful chaining & usage dedup)
//! - Streaming tool/function calls across all 4 dialects (`OpenAI` `function_call`, Anthropic
//!   `tool_use`, Gemini `functionCall`, `CustomOpenAi` `delta.tool_calls`)

use std::collections::BTreeMap;

use bistre_protocol::{DiagnosticKey, ProviderDialect, UsageMetrics};
use serde_json::Value;

use crate::replay_policy::{ReasoningBlock, StoredToolCall};
use crate::sse::StreamingTextBuffer;
use crate::tools::{heal_and_dedup_tool_calls, sanitize_tool_call_id};

/// Completed SSE stream payload paired with thinking trace, cryptographic reasoning blocks,
/// parsed tool calls, cancellation flag, and exact usage.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StreamOutcome {
    pub full_text: String,
    pub thinking_text: String,
    pub thinking_duration_ms: i64,
    pub reasoning_blocks: Vec<ReasoningBlock>,
    pub tool_calls: Vec<StoredToolCall>,
    pub provider_response_id: Option<String>,
    pub cancelled: bool,
    /// The stream ended without the dialect's terminal event after partial output.
    pub interrupted: bool,
    pub usage: UsageMetrics,
    /// Non-fatal notices raised while dispatching (heals, key failover), as `(key, detail)`.
    pub notices: Vec<(DiagnosticKey, String)>,
    /// Web pages the reply used (search results and citations), parsed and bounded.
    pub grounding: Vec<crate::grounding::GroundingSource>,
    /// How the reply ended; `None` when no terminal frame said.
    pub finish: Option<crate::finish::FinishKind>,
    /// The provider's own words when it ended the stream with an error, bounded.
    pub error_reason: Option<String>,
    /// Images and audio the reply carried (`media_wire`), bounded.
    pub(crate) media: Vec<crate::media_wire::GeneratedMedia>,
}

#[derive(Debug, Default)]
struct AnthropicBlockAcc {
    kind: String,
    text: String,
    signature: String,
    redacted_data: String,
    tool_id: String,
    tool_name: String,
    tool_json: String,
}

#[derive(Debug, Default)]
struct OpenAiToolAcc {
    call_id: String,
    name: String,
    arguments: String,
}

/// Mutable accumulator for one streamed reply across all 4 dialects.
#[derive(Debug, Default)]
pub(crate) struct StreamState {
    pub(crate) out: StreamOutcome,
    pub(crate) text_norm: StreamingTextBuffer,
    pub(crate) started_at: Option<std::time::Instant>,
    pub(crate) thinking_started: Option<std::time::Instant>,
    pub(crate) terminal_seen: bool,
    anthropic_blocks: BTreeMap<usize, AnthropicBlockAcc>,
    openai_calls_by_item: BTreeMap<String, OpenAiToolAcc>,
    chat_calls_by_index: BTreeMap<usize, OpenAiToolAcc>,
    gemini_thought_buf: String,
    gemini_thought_sig: Option<String>,
    /// The latest signature seen on a plain text part (classic `generateContent`).
    gemini_text_sig: Option<String>,
    /// One per picture part of a Gemini reply, empty when it carried no signature.
    gemini_picture_sigs: Vec<String>,
    /// `OpenRouter` `reasoning_details` fragments of this reply.
    reasoning_details: crate::reasoning_details::DetailsAssembler,
    media: crate::media_wire::MediaCollector,
    /// Raw provider call ids already captured: a call repeated by the provider (`OpenAI`
    /// Responses `response.completed` after `output_item.done`) is dropped before its id is
    /// sanitized, so it can never come back renamed and run twice.
    raw_tool_call_ids: std::collections::HashSet<String>,
    grounding: crate::grounding::GroundingCollector,
}

impl StreamState {
    fn mark_first_token(&mut self) {
        if self.out.usage.first_token_ms == 0
            && let Some(t0) = self.started_at
        {
            self.out.usage.first_token_ms =
                u64::try_from(t0.elapsed().as_millis()).unwrap_or(u64::MAX);
        }
    }

    pub(crate) fn handle_payload<F, T>(
        &mut self,
        dialect: ProviderDialect,
        payload: &str,
        on_delta: &mut F,
        on_thinking: &mut T,
    ) where
        F: FnMut(&str) + Send,
        T: FnMut(&str) + Send,
    {
        if payload.trim() == "[DONE]" {
            self.terminal_seen = true;
            return;
        }
        // Each frame is parsed once; every reader below works on this value.
        let Ok(val) = serde_json::from_str::<Value>(payload) else {
            return;
        };
        if crate::wire_parse::is_terminal_frame(dialect, &val) {
            self.terminal_seen = true;
        }
        crate::wire_parse::merge_usage_of_frame(dialect, &val, &mut self.out.usage);
        {
            self.capture_structured_frame(dialect, &val);
            self.grounding.absorb_frame(&val);
            if let Some(finish) = crate::finish::finish_of_frame(dialect, &val) {
                if matches!(finish, crate::finish::FinishKind::Error { .. }) {
                    self.out.error_reason = crate::finish::provider_reason(payload);
                    self.terminal_seen = true;
                }
                // An error is never overwritten by a later "stop" (it is the real ending).
                if !matches!(
                    self.out.finish,
                    Some(crate::finish::FinishKind::Error { .. })
                ) {
                    self.out.finish = Some(finish);
                }
            }
        }
        if let Some(thought) = crate::wire_parse::thinking_delta_of_frame(dialect, &val)
            && !thought.is_empty()
        {
            self.mark_first_token();
            let start = *self
                .thinking_started
                .get_or_insert_with(std::time::Instant::now);
            self.out.thinking_duration_ms = i64::try_from(start.elapsed().as_millis()).unwrap_or(0);
            self.out.thinking_text.push_str(&thought);
            on_thinking(&thought);
        }
        // A spoken reply's transcript is its text.
        let spoken = self.media.absorb(dialect, &val);
        for delta in [crate::wire_parse::delta_of_frame(dialect, &val), spoken]
            .into_iter()
            .flatten()
        {
            let clean = self.text_norm.push(&delta);
            if !clean.is_empty() {
                self.mark_first_token();
                self.out.full_text.push_str(&clean);
                on_delta(&clean);
            }
        }
    }

    /// Finalizes any buffered blocks/tool calls at stream end and runs self-healing dedup.
    pub(crate) fn finalize(&mut self, dialect: ProviderDialect) {
        self.out.grounding = core::mem::take(&mut self.grounding).into_sources();
        // Flush any unclosed Anthropic blocks (e.g. if stream ended before content_block_stop).
        let pending_anth = core::mem::take(&mut self.anthropic_blocks);
        for (_, blk) in pending_anth {
            self.commit_anthropic_block(blk);
        }
        // Flush accumulated Gemini thought signature block if present.
        if (!self.gemini_thought_buf.is_empty() || self.gemini_thought_sig.is_some())
            && !self
                .out
                .reasoning_blocks
                .iter()
                .any(|b| matches!(b, ReasoningBlock::GeminiThought { .. }))
        {
            self.out
                .reasoning_blocks
                .push(ReasoningBlock::GeminiThought {
                    text: core::mem::take(&mut self.gemini_thought_buf),
                    signature: self.gemini_thought_sig.take(),
                });
        }
        if let Some(signature) = self.gemini_text_sig.take() {
            self.out
                .reasoning_blocks
                .push(ReasoningBlock::GeminiTextSignature { signature });
        }
        let signatures = core::mem::take(&mut self.gemini_picture_sigs);
        if !signatures.is_empty() {
            self.out
                .reasoning_blocks
                .push(ReasoningBlock::GeminiPictureSignatures { signatures });
        }
        // Flush OpenAI Responses / Chat Completions tool call accumulators.
        let oai_items = core::mem::take(&mut self.openai_calls_by_item);
        for (_, acc) in oai_items {
            self.push_tool_call(acc.call_id, acc.name, acc.arguments, None);
        }
        let chat_items = core::mem::take(&mut self.chat_calls_by_index);
        for (_, acc) in chat_items {
            self.push_tool_call(acc.call_id, acc.name, acc.arguments, None);
        }
        let media = core::mem::take(&mut self.media);
        if media.dropped {
            tracing::warn!(
                max_items = crate::media_wire::MAX_MEDIA_ITEMS,
                max_bytes = crate::media_wire::MAX_MEDIA_BYTES,
                "reply media over the bound left out"
            );
        }
        self.out.media = media.finish();
        let details = core::mem::take(&mut self.reasoning_details).finish();
        if !details.is_empty() {
            self.out
                .reasoning_blocks
                .push(ReasoningBlock::OpenRouterDetails { details });
        }
        // If CustomOpenAi/plain reasoning produced text without structured blocks, store PlainReasoning.
        if self.out.reasoning_blocks.is_empty() && !self.out.thinking_text.trim().is_empty() {
            self.out
                .reasoning_blocks
                .push(ReasoningBlock::PlainReasoning {
                    text: self.out.thinking_text.clone(),
                });
        }
        // Run XML/JSON leaked tool-call healing ONLY when no native tool calls arrived on non-native models.
        if self.out.tool_calls.is_empty()
            && dialect == ProviderDialect::CustomOpenAi
            && (self.out.full_text.contains("<tool_call>")
                || self.out.full_text.contains("<function_call>"))
        {
            let (healed, cleaned_text) = heal_and_dedup_tool_calls(Vec::new(), &self.out.full_text);
            if !healed.is_empty() {
                self.out.full_text = cleaned_text;
                for call in healed {
                    self.out.tool_calls.push(StoredToolCall {
                        call_id: call.id,
                        name: call.name,
                        arguments_json: call.arguments.to_string(),
                        thought_signature: None,
                    });
                }
            }
        }
        // Sanitize every tool call ID to `[A-Za-z0-9_-]{<=64}` and deduplicate.
        let mut seen_ids = std::collections::HashSet::new();
        for (idx, call) in self.out.tool_calls.iter_mut().enumerate() {
            let clean = sanitize_tool_call_id(&call.call_id, &mut seen_ids, idx);
            call.call_id = clean;
        }
        let mut seen_pairs = std::collections::HashSet::new();
        self.out
            .tool_calls
            .retain(|c| seen_pairs.insert((c.call_id.clone(), c.name.clone())));
    }

    fn capture_structured_frame(&mut self, dialect: ProviderDialect, val: &Value) {
        match dialect {
            ProviderDialect::OpenAi => self.capture_openai(val),
            ProviderDialect::Anthropic => self.capture_anthropic(val),
            ProviderDialect::GoogleGemini => self.capture_gemini(val),
            ProviderDialect::CustomOpenAi => self.capture_chat_tool_deltas(val),
        }
    }

    fn capture_openai(&mut self, val: &Value) {
        let kind = val.get("type").and_then(Value::as_str).unwrap_or("");
        if let Some(id) = val
            .pointer("/response/id")
            .or_else(|| val.get("id"))
            .and_then(Value::as_str)
            .filter(|s| s.starts_with("resp_"))
        {
            self.out.provider_response_id = Some(id.to_owned());
        }
        match kind {
            "response.output_item.added" => {
                if let Some(item) = val.get("item")
                    && item.get("type").and_then(Value::as_str) == Some("function_call")
                {
                    let key = openai_call_key(val, Some(item));
                    let entry = self.openai_calls_by_item.entry(key).or_default();
                    if let Some(cid) = item.get("call_id").and_then(Value::as_str) {
                        cid.clone_into(&mut entry.call_id);
                    }
                    if let Some(name) = item.get("name").and_then(Value::as_str) {
                        name.clone_into(&mut entry.name);
                    }
                    if let Some(args) = item.get("arguments").and_then(Value::as_str)
                        && !args.is_empty()
                    {
                        args.clone_into(&mut entry.arguments);
                    }
                }
            }
            "response.function_call_arguments.delta" => {
                let key = openai_call_key(val, None);
                if let Some(delta) = val.get("delta").and_then(Value::as_str) {
                    self.openai_calls_by_item
                        .entry(key)
                        .or_default()
                        .arguments
                        .push_str(delta);
                }
            }
            "response.function_call_arguments.done" => {
                let key = openai_call_key(val, None);
                if let Some(args) = val.get("arguments").and_then(Value::as_str)
                    && !args.is_empty()
                {
                    args.clone_into(
                        &mut self.openai_calls_by_item.entry(key).or_default().arguments,
                    );
                }
            }
            "response.output_item.done" => {
                if let Some(item) = val.get("item") {
                    if item.get("type").and_then(Value::as_str) == Some("function_call") {
                        self.openai_calls_by_item
                            .remove(&openai_call_key(val, Some(item)));
                    }
                    self.capture_openai_output_item(item);
                }
            }
            "response.completed" => {
                if let Some(outputs) = val.pointer("/response/output").and_then(Value::as_array) {
                    for item in outputs {
                        self.capture_openai_output_item(item);
                    }
                }
            }
            _ => {
                // Plain-JSON non-streaming OpenAI Responses or Chat fallback.
                if let Some(outputs) = val.get("output").and_then(Value::as_array) {
                    for item in outputs {
                        self.capture_openai_output_item(item);
                    }
                }
                self.capture_chat_tool_deltas(val);
            }
        }
    }

    fn capture_openai_output_item(&mut self, item: &Value) {
        match item.get("type").and_then(Value::as_str) {
            Some("reasoning") => {
                let enc = item
                    .get("encrypted_content")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                if enc.is_empty() {
                    return;
                }
                let id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                if self.out.reasoning_blocks.iter().any(|b| {
                    matches!(b, ReasoningBlock::OpenAiReasoning { id: existing, encrypted_content, .. }
                        if (!id.is_empty() && existing == &id) || encrypted_content == &enc)
                }) {
                    return;
                }
                let summary = item
                    .get("summary")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                self.out
                    .reasoning_blocks
                    .push(ReasoningBlock::OpenAiReasoning {
                        id,
                        summary,
                        encrypted_content: enc,
                    });
            }
            Some("function_call") => {
                let call_id = item
                    .get("call_id")
                    .or_else(|| item.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                let name = item
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                let arguments = item
                    .get("arguments")
                    .and_then(Value::as_str)
                    .unwrap_or("{}")
                    .to_owned();
                // The finished item replaces any partial copy of the same call.
                if !call_id.is_empty() {
                    self.openai_calls_by_item
                        .retain(|_, acc| acc.call_id != call_id);
                }
                self.push_tool_call(call_id, name, arguments, None);
            }
            _ => {}
        }
    }

    #[expect(
        clippy::too_many_lines,
        reason = "Handles all Anthropic SSE content_block_start/delta/stop and plain-JSON frames linearly."
    )]
    fn capture_anthropic(&mut self, val: &Value) {
        let kind = val.get("type").and_then(Value::as_str).unwrap_or("");
        match kind {
            "message_start" => {
                if let Some(id) = val.pointer("/message/id").and_then(Value::as_str) {
                    self.out.provider_response_id = Some(id.to_owned());
                }
            }
            "content_block_start" => {
                let idx = val
                    .get("index")
                    .and_then(Value::as_u64)
                    .and_then(|v| usize::try_from(v).ok())
                    .unwrap_or(0);
                let Some(cb) = val.get("content_block") else {
                    return;
                };
                let cb_type = cb.get("type").and_then(Value::as_str).unwrap_or("");
                let mut acc = AnthropicBlockAcc {
                    kind: cb_type.to_owned(),
                    ..AnthropicBlockAcc::default()
                };
                match cb_type {
                    "thinking" => {
                        if let Some(t) = cb.get("thinking").and_then(Value::as_str) {
                            acc.text.push_str(t);
                        }
                        if let Some(s) = cb.get("signature").and_then(Value::as_str) {
                            acc.signature.push_str(s);
                        }
                    }
                    "redacted_thinking" => {
                        if let Some(d) = cb.get("data").and_then(Value::as_str) {
                            d.clone_into(&mut acc.redacted_data);
                        }
                    }
                    "tool_use" => {
                        cb.get("id")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .clone_into(&mut acc.tool_id);
                        cb.get("name")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .clone_into(&mut acc.tool_name);
                    }
                    _ => {}
                }
                self.anthropic_blocks.insert(idx, acc);
            }
            "content_block_delta" => {
                let idx = val
                    .get("index")
                    .and_then(Value::as_u64)
                    .and_then(|v| usize::try_from(v).ok())
                    .unwrap_or(0);
                let Some(delta) = val.get("delta") else {
                    return;
                };
                let d_type = delta.get("type").and_then(Value::as_str).unwrap_or("");
                let entry = self.anthropic_blocks.entry(idx).or_default();
                match d_type {
                    "thinking_delta" => {
                        if let Some(t) = delta.get("thinking").and_then(Value::as_str) {
                            entry.text.push_str(t);
                        }
                    }
                    "signature_delta" => {
                        if let Some(s) = delta.get("signature").and_then(Value::as_str) {
                            entry.signature.push_str(s);
                        }
                    }
                    "input_json_delta" => {
                        if let Some(j) = delta.get("partial_json").and_then(Value::as_str) {
                            entry.tool_json.push_str(j);
                        }
                    }
                    _ => {}
                }
            }
            "content_block_stop" => {
                let idx = val
                    .get("index")
                    .and_then(Value::as_u64)
                    .and_then(|v| usize::try_from(v).ok())
                    .unwrap_or(0);
                if let Some(blk) = self.anthropic_blocks.remove(&idx) {
                    self.commit_anthropic_block(blk);
                }
            }
            "message" => {
                // Plain-JSON non-streaming Anthropic Messages response.
                if let Some(id) = val.get("id").and_then(Value::as_str) {
                    self.out.provider_response_id = Some(id.to_owned());
                }
                if let Some(blocks) = val.get("content").and_then(Value::as_array) {
                    for b in blocks {
                        match b.get("type").and_then(Value::as_str) {
                            Some("thinking") => {
                                let thinking = b
                                    .get("thinking")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_owned();
                                let signature = b
                                    .get("signature")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_owned();
                                if !signature.is_empty() {
                                    self.out.reasoning_blocks.push(
                                        ReasoningBlock::AnthropicThinking {
                                            thinking,
                                            signature,
                                        },
                                    );
                                }
                            }
                            Some("redacted_thinking") => {
                                if let Some(data) = b.get("data").and_then(Value::as_str)
                                    && !data.is_empty()
                                {
                                    self.out.reasoning_blocks.push(
                                        ReasoningBlock::AnthropicRedactedThinking {
                                            data: data.to_owned(),
                                        },
                                    );
                                }
                            }
                            Some("tool_use") => {
                                let cid =
                                    b.get("id").and_then(Value::as_str).unwrap_or("").to_owned();
                                let name = b
                                    .get("name")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_owned();
                                let args = b
                                    .get("input")
                                    .map_or_else(|| "{}".to_owned(), Value::to_string);
                                self.push_tool_call(cid, name, args, None);
                            }
                            _ => {}
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn commit_anthropic_block(&mut self, blk: AnthropicBlockAcc) {
        match blk.kind.as_str() {
            "thinking" if !blk.signature.is_empty() => {
                self.out
                    .reasoning_blocks
                    .push(ReasoningBlock::AnthropicThinking {
                        thinking: blk.text,
                        signature: blk.signature,
                    });
            }
            "redacted_thinking" if !blk.redacted_data.is_empty() => {
                self.out
                    .reasoning_blocks
                    .push(ReasoningBlock::AnthropicRedactedThinking {
                        data: blk.redacted_data,
                    });
            }
            "tool_use" if !blk.tool_name.is_empty() => {
                let args = if blk.tool_json.trim().is_empty() {
                    "{}".to_owned()
                } else {
                    blk.tool_json
                };
                self.push_tool_call(blk.tool_id, blk.tool_name, args, None);
            }
            _ => {}
        }
    }

    #[expect(
        clippy::too_many_lines,
        reason = "Handles Gemini Interactions and legacy generateContent SSE frames linearly."
    )]
    fn capture_gemini(&mut self, val: &Value) {
        // Interactions API: interaction ID, thought signatures, and function calls.
        if let Some(id) = val
            .pointer("/interaction/id")
            .or_else(|| val.get("interaction_id"))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            self.out.provider_response_id = Some(id.to_owned());
        }
        if val.get("event_type").and_then(Value::as_str) == Some("step.delta")
            && let Some(delta) = val.get("delta")
        {
            if let Some(sig) = delta
                .get("thought_signature")
                .or_else(|| delta.get("thoughtSignature"))
                .or_else(|| delta.get("signature"))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                self.gemini_thought_sig = Some(sig.to_owned());
            }
            if delta.get("type").and_then(Value::as_str) == Some("thought_summary")
                && let Some(t) = delta.get("text").and_then(Value::as_str)
            {
                self.gemini_thought_buf.push_str(t);
            }
            if delta.get("type").and_then(Value::as_str) == Some("function_call") {
                let cid = delta
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                let name = delta
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                let args = delta
                    .get("arguments")
                    .map_or_else(|| "{}".to_owned(), Value::to_string);
                let sig = delta
                    .get("thought_signature")
                    .or_else(|| delta.get("thoughtSignature"))
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
                    .or_else(|| self.gemini_thought_sig.clone());
                self.push_tool_call(cid, name, args, sig);
            }
        }
        if let Some(outputs) = val
            .pointer("/interaction/outputs")
            .and_then(Value::as_array)
        {
            for out_item in outputs {
                if out_item.get("type").and_then(Value::as_str) == Some("thought")
                    && let Some(sig) = out_item
                        .get("signature")
                        .or_else(|| out_item.get("thought_signature"))
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())
                {
                    let text = out_item
                        .get("summary")
                        .and_then(Value::as_str)
                        .or_else(|| out_item.get("text").and_then(Value::as_str))
                        .unwrap_or("")
                        .to_owned();
                    self.gemini_thought_sig = Some(sig.to_owned());
                    if !self.out.reasoning_blocks.iter().any(|b| {
                        matches!(b, ReasoningBlock::GeminiThought { signature: Some(s), .. } if s == sig)
                    }) {
                        self.out
                            .reasoning_blocks
                            .push(ReasoningBlock::GeminiThought {
                                text,
                                signature: Some(sig.to_owned()),
                            });
                    }
                }
                if out_item.get("type").and_then(Value::as_str) == Some("function_call") {
                    let cid = out_item
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned();
                    let name = out_item
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned();
                    let args = out_item
                        .get("arguments")
                        .map_or_else(|| "{}".to_owned(), Value::to_string);
                    let sig = out_item
                        .get("thought_signature")
                        .or_else(|| out_item.get("thoughtSignature"))
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                        .or_else(|| self.gemini_thought_sig.clone());
                    self.push_tool_call(cid, name, args, sig);
                }
            }
        }
        // Classic generateContent SSE parts: thoughtSignature + functionCall.
        if let Some(parts) = val
            .pointer("/candidates/0/content/parts")
            .and_then(Value::as_array)
        {
            for part in parts {
                let part_sig = part
                    .get("thoughtSignature")
                    .or_else(|| part.get("thought_signature"))
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .map(ToOwned::to_owned);
                let is_thought = part.get("thought").and_then(Value::as_bool) == Some(true);
                let is_call = part.get("functionCall").is_some();
                if !is_thought
                    && part.get("inlineData").is_some()
                    && self.gemini_picture_sigs.len() < crate::media_wire::MAX_MEDIA_ITEMS
                {
                    self.gemini_picture_sigs
                        .push(part_sig.clone().unwrap_or_default());
                }
                if let Some(ref sig) = part_sig {
                    if !is_thought && !is_call && part.get("text").is_some() {
                        // A text part's signature stays with the text (kelivo fixtures).
                        self.gemini_text_sig = Some(sig.clone());
                    } else if is_thought {
                        self.gemini_thought_sig = Some(sig.clone());
                    }
                }
                if is_thought {
                    if let Some(t) = part.get("text").and_then(Value::as_str) {
                        self.gemini_thought_buf.push_str(t);
                    }
                    if let Some(sig) = part_sig.clone() {
                        self.out
                            .reasoning_blocks
                            .push(ReasoningBlock::GeminiThought {
                                text: core::mem::take(&mut self.gemini_thought_buf),
                                signature: Some(sig),
                            });
                    }
                }
                if let Some(fc) = part.get("functionCall") {
                    let name = fc
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned();
                    let cid = fc
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned();
                    let args = fc
                        .get("args")
                        .map_or_else(|| "{}".to_owned(), Value::to_string);
                    // Only the call's own signature: in parallel calls only the first is
                    // signed, and an unsigned call never borrows one (kelivo fixtures).
                    self.push_tool_call(cid, name, args, part_sig);
                }
            }
        }
    }

    fn capture_chat_tool_deltas(&mut self, val: &Value) {
        let Some(choice) = val.pointer("/choices/0") else {
            return;
        };
        if let Some(details) = choice
            .pointer("/delta/reasoning_details")
            .or_else(|| choice.pointer("/message/reasoning_details"))
            .and_then(Value::as_array)
        {
            for fragment in details {
                self.reasoning_details.push(fragment);
            }
        }
        if let Some(calls) = choice
            .pointer("/delta/tool_calls")
            .or_else(|| choice.pointer("/message/tool_calls"))
            .and_then(Value::as_array)
        {
            for (fallback_idx, call) in calls.iter().enumerate() {
                let idx = call
                    .get("index")
                    .and_then(Value::as_u64)
                    .and_then(|v| usize::try_from(v).ok())
                    .unwrap_or(fallback_idx);
                let entry = self.chat_calls_by_index.entry(idx).or_default();
                if let Some(id) = call.get("id").and_then(Value::as_str)
                    && !id.is_empty()
                {
                    id.clone_into(&mut entry.call_id);
                }
                if let Some(name) = call.pointer("/function/name").and_then(Value::as_str)
                    && !name.is_empty()
                {
                    // A gateway that resends the whole (or the growing) name replaces it;
                    // a name split over chunks joins.
                    if name.starts_with(entry.name.as_str()) {
                        name.clone_into(&mut entry.name);
                    } else {
                        entry.name.push_str(name);
                    }
                }
                if let Some(args) = call.pointer("/function/arguments").and_then(Value::as_str) {
                    entry.arguments.push_str(args);
                }
            }
        }
    }

    #[expect(
        clippy::needless_pass_by_value,
        reason = "All 8 callers already own call_id Strings extracted from SSE JSON frames."
    )]
    fn push_tool_call(
        &mut self,
        call_id: String,
        name: String,
        arguments_json: String,
        thought_signature: Option<String>,
    ) {
        if name.trim().is_empty() {
            return;
        }
        if !call_id.is_empty() && !self.raw_tool_call_ids.insert(call_id.clone()) {
            return;
        }
        let idx = self.out.tool_calls.len();
        let mut seen: std::collections::HashSet<String> = self
            .out
            .tool_calls
            .iter()
            .map(|c| c.call_id.clone())
            .collect();
        let clean_id = sanitize_tool_call_id(&call_id, &mut seen, idx);
        let args = if arguments_json.trim().is_empty() {
            "{}".to_owned()
        } else {
            arguments_json
        };
        self.out.tool_calls.push(StoredToolCall {
            call_id: clean_id,
            name,
            arguments_json: args,
            thought_signature,
        });
    }
}

/// The accumulator key of a streamed Responses function call: its `output_index`, which
/// every streaming event of the call carries, else the item id, so calls from a gateway that
/// omits ids never merge.
fn openai_call_key(frame: &Value, item: Option<&Value>) -> String {
    if let Some(index) = frame.get("output_index").and_then(Value::as_u64) {
        return format!("#{index}");
    }
    item.and_then(|it| it.get("id").or_else(|| it.get("call_id")))
        .or_else(|| frame.get("item_id"))
        .and_then(Value::as_str)
        .unwrap_or("#?")
        .to_owned()
}

#[cfg(test)]
#[path = "wire_stream_tests.rs"]
mod tests;
