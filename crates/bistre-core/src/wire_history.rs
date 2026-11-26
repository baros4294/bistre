//! Dialect-specific conversation history serialization with:
//! - Native multimodal/PDF/Office attachment encoding
//! - Cryptographic reasoning block round-tripping (verified by [`crate::replay_policy`])
//! - Bounded cross-provider reasoning handoffs (`<= 8,000` chars, zero leaked signatures)
//! - Full `NodeRole::Tool` & `StoredToolCall` replay (including rich media tool outputs)
//! - Automatic orphan `tool_use` / `tool_result` pair protection so delete/branch never 400s

use std::collections::{HashMap, HashSet};
use std::path::Path;

use bistre_protocol::{NodeRecord, NodeRole, StoredAttachment};
use serde_json::{Value, json};

use crate::attachments::{
    attachment_not_sent_note, is_office_document, is_text_like, parse_node_attachments,
    read_attachment_as_text_block, read_attachment_base64,
};
use crate::replay_policy::{
    ReasoningBlock, ReplayContext, StoredToolCall, StoredToolResult,
    cross_provider_reasoning_handoff_for_node, gemini_function_call_signature,
    latest_compaction_ms, made_before_compaction, parse_turn_wire_meta,
    safe_reasoning_blocks_for_target,
};

/// Returns the set of `call_id`s that have BOTH an emitting `Assistant` tool call and a matching
/// `NodeRole::Tool` result in `history`, so an edited/deleted branch never sends an orphaned call.
fn paired_tool_call_ids(history: &[NodeRecord]) -> HashSet<String> {
    let mut emitted = HashSet::new();
    let mut answered = HashSet::new();
    for node in history {
        let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
        if node.role == NodeRole::Assistant {
            for call in meta.tool_calls {
                if !call.call_id.is_empty() {
                    emitted.insert(call.call_id);
                }
            }
        } else if node.role == NodeRole::Tool
            && let Some(res) = meta.tool_result
            && !res.call_id.is_empty()
        {
            answered.insert(res.call_id);
        }
    }
    emitted.intersection(&answered).cloned().collect()
}

fn latest_assistant_index(history: &[NodeRecord]) -> Option<usize> {
    history.iter().rposition(|n| n.role == NodeRole::Assistant)
}

fn user_text_with_summary_prefix(node: &NodeRecord) -> String {
    if node.role == NodeRole::CompactionSummary {
        format!("[Earlier conversation summary]\n{}", node.content)
    } else {
        node.content.clone()
    }
}

/// Builds `OpenAI` Responses API (`v1/responses`) `input` items with native `input_image`,
/// `input_file` (inline base64 or Files API `file_id`), verified `reasoning` (`encrypted_content`)
/// items, `function_call`, and rich-media `function_call_output`.
pub fn build_openai_responses_input_with_ctx(
    history: &[NodeRecord],
    data_dir: Option<&Path>,
    replay_ctx: Option<&ReplayContext>,
) -> Vec<Value> {
    let empty: HashMap<String, String> = HashMap::new();
    build_openai_responses_input_with_refs(history, data_dir, &empty, replay_ctx, 0)
}

/// Builds `OpenAI` Responses API (`v1/responses`) `input` items with optional remote `file_id` refs.
pub fn build_openai_responses_input_with_refs<S: std::hash::BuildHasher>(
    history: &[NodeRecord],
    data_dir: Option<&Path>,
    remote_refs: &HashMap<String, String, S>,
    replay_ctx: Option<&ReplayContext>,
    chain_skip: usize,
) -> Vec<Value> {
    let compaction_at = latest_compaction_ms(history);
    let paired = paired_tool_call_ids(history);
    let last_asst = latest_assistant_index(history);
    let mut out: Vec<Value> = Vec::with_capacity(history.len());

    // R7: a chained request sends only the items after `chain_skip` (the server holds the
    // rest), while pairing still sees the whole history.
    for (idx, node) in history.iter().enumerate().skip(chain_skip) {
        match node.role {
            NodeRole::System => {}
            NodeRole::User | NodeRole::CompactionSummary => {
                let text = user_text_with_summary_prefix(node);
                let atts = parse_node_attachments(node.provider_meta_json.as_deref());
                if atts.is_empty() || data_dir.is_none() {
                    out.push(json!({ "role": "user", "content": text }));
                } else if let Some(dir) = data_dir {
                    let mut parts = encode_openai_user_attachments(dir, remote_refs, &atts);
                    if !text.is_empty() {
                        parts.push(json!({ "type": "input_text", "text": text }));
                    }
                    out.push(json!({ "role": "user", "content": parts }));
                }
            }
            NodeRole::Assistant => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                // R14: only reasoning made before the newest compaction lost its prefix.
                let stale = made_before_compaction(compaction_at, node);
                if let Some(ctx) = replay_ctx {
                    for blk in safe_reasoning_blocks_for_target(&meta, ctx, stale) {
                        if let ReasoningBlock::OpenAiReasoning {
                            id,
                            summary,
                            encrypted_content,
                        } = blk
                        {
                            let summary: Vec<Value> = summary
                                .iter()
                                .map(crate::replay_policy::without_null_fields)
                                .collect();
                            let mut item = json!({
                                "type": "reasoning",
                                "summary": summary,
                                "encrypted_content": encrypted_content,
                            });
                            if !id.is_empty()
                                && let Some(obj) = item.as_object_mut()
                            {
                                obj.insert("id".to_owned(), Value::String(id));
                            }
                            out.push(item);
                        }
                    }
                }
                let mut content = node.content.clone();
                if let Some(ctx) = replay_ctx
                    && let Some(handoff) = cross_provider_reasoning_handoff_for_node(
                        &meta,
                        ctx,
                        last_asst == Some(idx),
                    )
                {
                    content = format!("[Prior reasoning summary]\n{handoff}\n\n{content}");
                }
                if !content.is_empty() || meta.tool_calls.is_empty() {
                    out.push(json!({ "role": "assistant", "content": content }));
                }
                for call in &meta.tool_calls {
                    if paired.contains(&call.call_id) {
                        out.push(json!({
                            "type": "function_call",
                            "call_id": call.call_id,
                            "name": call.name,
                            "arguments": call.arguments_json,
                            // G2: the documented status the API returned it with.
                            "status": "completed",
                        }));
                    }
                }
            }
            NodeRole::Tool => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                if let Some(res) = meta.tool_result
                    && paired.contains(&res.call_id)
                {
                    let output_val = encode_openai_tool_output(data_dir, &node.content, &res);
                    out.push(json!({
                        "type": "function_call_output",
                        "call_id": res.call_id,
                        "output": output_val,
                    }));
                }
            }
        }
    }
    out
}

fn encode_openai_user_attachments<S: std::hash::BuildHasher>(
    dir: &Path,
    remote_refs: &HashMap<String, String, S>,
    atts: &[StoredAttachment],
) -> Vec<Value> {
    let mut parts = Vec::new();
    for att in atts {
        let before = parts.len();
        if att.mime_type.starts_with("image/") {
            if let Some(file_id) = remote_refs.get(&att.blake3_hex) {
                parts.push(json!({
                    "type": "input_image",
                    "file_id": file_id,
                }));
            } else if let Some(b64) = read_attachment_base64(dir, att) {
                parts.push(json!({
                    "type": "input_image",
                    "image_url": format!("data:{};base64,{b64}", att.mime_type),
                }));
            }
        } else if att.mime_type == "application/pdf"
            || is_office_document(&att.mime_type, &att.name)
            || is_text_like(&att.mime_type, &att.name)
        {
            if let Some(file_id) = remote_refs.get(&att.blake3_hex) {
                parts.push(json!({
                    "type": "input_file",
                    "file_id": file_id,
                }));
            } else if let Some(b64) = read_attachment_base64(dir, att) {
                parts.push(json!({
                    "type": "input_file",
                    "filename": att.name,
                    "file_data": format!("data:{};base64,{b64}", att.mime_type),
                }));
            } else if let Some(block) = read_attachment_as_text_block(dir, att) {
                parts.push(json!({ "type": "input_text", "text": block }));
            }
        } else if let Some(file_id) = remote_refs.get(&att.blake3_hex) {
            parts.push(json!({
                "type": "input_file",
                "file_id": file_id,
            }));
        } else {
            parts.push(json!({
                "type": "input_text",
                "text": format!("[Attachment: {} ({})]", att.name, att.mime_type),
            }));
        }
        // R24: never a silent drop.
        if parts.len() == before {
            parts.push(json!({ "type": "input_text", "text": attachment_not_sent_note(att) }));
        }
    }
    parts
}

fn encode_openai_tool_output(data_dir: Option<&Path>, text: &str, res: &StoredToolResult) -> Value {
    if res.media_attachments.is_empty() || data_dir.is_none() {
        return Value::String(text.to_owned());
    }
    let Some(dir) = data_dir else {
        return Value::String(text.to_owned());
    };
    let empty: HashMap<String, String> = HashMap::new();
    let mut parts = vec![json!({ "type": "input_text", "text": text })];
    parts.extend(encode_openai_user_attachments(
        dir,
        &empty,
        &res.media_attachments,
    ));
    Value::Array(parts)
}

/// Builds Google Gemini Interactions API (`/v1beta/interactions`) input turns with Files API URIs,
/// verified `thought` signatures, and `function_call` / `function_result` turns.
pub fn build_gemini_interactions_input_with_ctx<S: std::hash::BuildHasher>(
    history: &[NodeRecord],
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
    replay_ctx: Option<&ReplayContext>,
    chain_skip: usize,
) -> Vec<Value> {
    let compaction_at = latest_compaction_ms(history);
    let paired = paired_tool_call_ids(history);
    let last_asst = latest_assistant_index(history);
    let mut out = Vec::with_capacity(history.len());

    // R7: as in the `OpenAI` builder, chained requests send only the new items.
    for (idx, node) in history.iter().enumerate().skip(chain_skip) {
        match node.role {
            NodeRole::System => {}
            NodeRole::User | NodeRole::CompactionSummary => {
                let text = user_text_with_summary_prefix(node);
                let atts = parse_node_attachments(node.provider_meta_json.as_deref());
                let mut parts = encode_gemini_interactions_atts(data_dir, gemini_uris, &atts);
                parts.push(json!({ "type": "text", "text": text }));
                out.push(json!({ "role": "user", "content": parts }));
            }
            NodeRole::Assistant => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                // R14: only reasoning made before the newest compaction lost its prefix.
                let stale = made_before_compaction(compaction_at, node);
                let mut parts: Vec<Value> = Vec::new();
                if let Some(ctx) = replay_ctx {
                    for blk in safe_reasoning_blocks_for_target(&meta, ctx, stale) {
                        if let ReasoningBlock::GeminiThought {
                            text,
                            signature: Some(sig),
                        } = blk
                        {
                            parts.push(json!({
                                "type": "thought",
                                "summary": text,
                                "signature": sig,
                            }));
                        }
                    }
                }
                let mut text = node.content.clone();
                if let Some(ctx) = replay_ctx
                    && let Some(handoff) = cross_provider_reasoning_handoff_for_node(
                        &meta,
                        ctx,
                        last_asst == Some(idx),
                    )
                {
                    text = format!("[Prior reasoning summary]\n{handoff}\n\n{text}");
                }
                if !text.is_empty() || meta.tool_calls.is_empty() {
                    parts.push(json!({ "type": "text", "text": text }));
                }
                for call in &meta.tool_calls {
                    if paired.contains(&call.call_id) {
                        let args_val = serde_json::from_str::<Value>(&call.arguments_json)
                            .unwrap_or_else(|_| json!({}));
                        let sig = replay_ctx.map_or(
                            crate::replay_policy::GEMINI_THOUGHT_SIGNATURE_BYPASS,
                            |ctx| {
                                gemini_function_call_signature(
                                    call,
                                    meta.origin.as_ref(),
                                    ctx,
                                    stale,
                                )
                            },
                        );
                        parts.push(json!({
                            "type": "function_call",
                            "id": call.call_id,
                            "name": call.name,
                            "arguments": args_val,
                            "thought_signature": sig,
                        }));
                    }
                }
                out.push(json!({ "role": "model", "content": parts }));
            }
            NodeRole::Tool => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                if let Some(res) = meta.tool_result
                    && paired.contains(&res.call_id)
                {
                    let mut parts = vec![json!({
                        "type": "function_result",
                        "call_id": res.call_id,
                        "name": res.name,
                        "is_error": res.is_error,
                        "result": node.content,
                    })];
                    parts.extend(encode_gemini_interactions_atts(
                        data_dir,
                        gemini_uris,
                        &res.media_attachments,
                    ));
                    out.push(json!({ "role": "user", "content": parts }));
                }
            }
        }
    }
    out
}

fn encode_gemini_interactions_atts<S: std::hash::BuildHasher>(
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
    atts: &[StoredAttachment],
) -> Vec<Value> {
    let mut parts = Vec::new();
    let Some(dir) = data_dir else {
        return parts;
    };
    for att in atts {
        let before = parts.len();
        let block_type = if att.mime_type.starts_with("image/") {
            "image"
        } else if att.mime_type.starts_with("audio/") {
            "audio"
        } else if att.mime_type.starts_with("video/") {
            "video"
        } else {
            "document"
        };
        if is_office_document(&att.mime_type, &att.name) || is_text_like(&att.mime_type, &att.name)
        {
            // R25: Gemini rejects Office MIME types; text and Office files always go as text
            // (Office through the pure-Rust ZIP+XML extraction).
            if let Some(block) = read_attachment_as_text_block(dir, att) {
                parts.push(json!({ "type": "text", "text": block }));
            }
        } else if let Some(uri) = gemini_uris.get(&att.blake3_hex) {
            parts.push(json!({
                "type": block_type,
                "uri": uri,
                "mime_type": att.mime_type,
            }));
        } else if let Some(b64) = read_attachment_base64(dir, att) {
            parts.push(json!({
                "type": block_type,
                "data": b64,
                "mime_type": att.mime_type,
            }));
        } else if let Some(block) = read_attachment_as_text_block(dir, att) {
            parts.push(json!({ "type": "text", "text": block }));
        }
        // R24: never a silent drop.
        if parts.len() == before {
            parts.push(json!({ "type": "text", "text": attachment_not_sent_note(att) }));
        }
    }
    parts
}

/// Builds Google Gemini `generateContent` (`contents`) turns with `file_data`, `inline_data`,
/// verified `thoughtSignature`, and `functionCall` / `functionResponse`.
pub fn build_gemini_generate_contents_with_ctx<S: std::hash::BuildHasher>(
    history: &[NodeRecord],
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
    replay_ctx: Option<&ReplayContext>,
) -> Vec<Value> {
    let compaction_at = latest_compaction_ms(history);
    let paired = paired_tool_call_ids(history);
    let last_asst = latest_assistant_index(history);
    let mut out = Vec::with_capacity(history.len());

    for (idx, node) in history.iter().enumerate() {
        match node.role {
            NodeRole::System => {}
            NodeRole::User | NodeRole::CompactionSummary => {
                let text = user_text_with_summary_prefix(node);
                let atts = parse_node_attachments(node.provider_meta_json.as_deref());
                let mut parts = encode_gemini_generate_atts(data_dir, gemini_uris, &atts);
                parts.push(json!({ "text": text }));
                out.push(json!({ "role": "user", "parts": parts }));
            }
            NodeRole::Assistant => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                // R14: only reasoning made before the newest compaction lost its prefix.
                let stale = made_before_compaction(compaction_at, node);
                let mut parts: Vec<Value> = Vec::new();
                let mut text_sig: Option<String> = None;
                if let Some(ctx) = replay_ctx {
                    for blk in safe_reasoning_blocks_for_target(&meta, ctx, stale) {
                        match blk {
                            ReasoningBlock::GeminiThought {
                                text,
                                signature: Some(sig),
                            } => parts.push(json!({
                                "thought": true,
                                "text": text,
                                "thoughtSignature": sig,
                            })),
                            ReasoningBlock::GeminiTextSignature { signature } => {
                                text_sig = Some(signature);
                            }
                            _ => {}
                        }
                    }
                }
                let mut text = node.content.clone();
                if let Some(ctx) = replay_ctx
                    && let Some(handoff) = cross_provider_reasoning_handoff_for_node(
                        &meta,
                        ctx,
                        last_asst == Some(idx),
                    )
                {
                    text = format!("[Prior reasoning summary]\n{handoff}\n\n{text}");
                }
                if !text.is_empty() || meta.tool_calls.is_empty() {
                    let mut part = json!({ "text": text });
                    if let Some(sig) = text_sig.take() {
                        part["thoughtSignature"] = Value::String(sig);
                    }
                    parts.push(part);
                }
                let mut first_call = true;
                for call in &meta.tool_calls {
                    if paired.contains(&call.call_id) {
                        let args_val = serde_json::from_str::<Value>(&call.arguments_json)
                            .unwrap_or_else(|_| json!({}));
                        let sig = replay_ctx.map_or(
                            crate::replay_policy::GEMINI_THOUGHT_SIGNATURE_BYPASS,
                            |ctx| {
                                gemini_function_call_signature(
                                    call,
                                    meta.origin.as_ref(),
                                    ctx,
                                    stale,
                                )
                            },
                        );
                        let mut part = json!({
                            "functionCall": {
                                "id": call.call_id,
                                "name": call.name,
                                "args": args_val,
                            },
                        });
                        // The first call of a turn always carries a signature (its own, or
                        // the documented bypass); later parallel calls only their own.
                        if first_call
                            || sig != crate::replay_policy::GEMINI_THOUGHT_SIGNATURE_BYPASS
                        {
                            part["thoughtSignature"] = Value::String(sig.to_owned());
                        }
                        first_call = false;
                        parts.push(part);
                    }
                }
                // A detached signature part stays a separate part after the calls.
                if let Some(sig) = text_sig {
                    parts.push(json!({ "text": "", "thoughtSignature": sig }));
                }
                out.push(json!({ "role": "model", "parts": parts }));
            }
            NodeRole::Tool => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                if let Some(res) = meta.tool_result
                    && paired.contains(&res.call_id)
                {
                    let mut parts = vec![json!({
                        "functionResponse": {
                            "id": res.call_id,
                            "name": res.name,
                            "response": {
                                "output": node.content,
                                "is_error": res.is_error,
                            }
                        }
                    })];
                    parts.extend(encode_gemini_generate_atts(
                        data_dir,
                        gemini_uris,
                        &res.media_attachments,
                    ));
                    out.push(json!({ "role": "user", "parts": parts }));
                }
            }
        }
    }
    out
}

fn encode_gemini_generate_atts<S: std::hash::BuildHasher>(
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
    atts: &[StoredAttachment],
) -> Vec<Value> {
    let mut parts = Vec::new();
    let Some(dir) = data_dir else {
        return parts;
    };
    for att in atts {
        let before = parts.len();
        if is_office_document(&att.mime_type, &att.name) {
            // R25: Gemini rejects Office MIME types; always the pure-Rust ZIP+XML text.
            if let Some(block) = read_attachment_as_text_block(dir, att) {
                parts.push(json!({ "text": block }));
            }
        } else if let Some(uri) = gemini_uris.get(&att.blake3_hex) {
            parts.push(json!({
                "file_data": {
                    "mime_type": att.mime_type,
                    "file_uri": uri,
                }
            }));
        } else if is_text_like(&att.mime_type, &att.name)
            || is_office_document(&att.mime_type, &att.name)
        {
            if let Some(block) = read_attachment_as_text_block(dir, att) {
                parts.push(json!({ "text": block }));
            }
        } else if let Some(b64) = read_attachment_base64(dir, att) {
            parts.push(json!({
                "inline_data": {
                    "mime_type": att.mime_type,
                    "data": b64,
                }
            }));
        } else if let Some(block) = read_attachment_as_text_block(dir, att) {
            parts.push(json!({ "text": block }));
        }
        // R24: never a silent drop.
        if parts.len() == before {
            parts.push(json!({ "text": attachment_not_sent_note(att) }));
        }
    }
    parts
}

/// Builds Anthropic Messages API (`messages`) with native `image`, native PDF `document`,
/// verified byte-exact `thinking`/`redacted_thinking` blocks, `tool_use`, and rich-media `tool_result`.
pub fn build_anthropic_messages_with_ctx(
    history: &[NodeRecord],
    data_dir: Option<&Path>,
    replay_ctx: Option<&ReplayContext>,
) -> Vec<Value> {
    let empty: HashMap<String, String> = HashMap::new();
    build_anthropic_messages_with_refs(history, data_dir, &empty, replay_ctx)
}

/// Builds Anthropic Messages API (`messages`) with optional Files API `file_id` references.
pub fn build_anthropic_messages_with_refs<S: std::hash::BuildHasher>(
    history: &[NodeRecord],
    data_dir: Option<&Path>,
    remote_refs: &HashMap<String, String, S>,
    replay_ctx: Option<&ReplayContext>,
) -> Vec<Value> {
    let compaction_at = latest_compaction_ms(history);
    let paired = paired_tool_call_ids(history);
    let last_asst = latest_assistant_index(history);
    let mut out: Vec<Value> = Vec::with_capacity(history.len());

    let mut i = 0_usize;
    while i < history.len() {
        let node = &history[i];
        match node.role {
            NodeRole::System => {
                i += 1;
            }
            NodeRole::User | NodeRole::CompactionSummary => {
                let text = user_text_with_summary_prefix(node);
                let atts = parse_node_attachments(node.provider_meta_json.as_deref());
                if atts.is_empty() || data_dir.is_none() {
                    out.push(json!({ "role": "user", "content": text }));
                } else if let Some(dir) = data_dir {
                    let mut blocks =
                        encode_anthropic_attachments_with_refs(dir, remote_refs, &atts);
                    if !text.is_empty() {
                        blocks.push(json!({ "type": "text", "text": text }));
                    }
                    out.push(json!({ "role": "user", "content": blocks }));
                }
                i += 1;
            }
            NodeRole::Assistant => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                // R14: only reasoning made before the newest compaction lost its prefix.
                let stale = made_before_compaction(compaction_at, node);
                let mut blocks: Vec<Value> = Vec::new();
                if let Some(ctx) = replay_ctx {
                    for blk in safe_reasoning_blocks_for_target(&meta, ctx, stale) {
                        match blk {
                            ReasoningBlock::AnthropicThinking {
                                thinking,
                                signature,
                            } => {
                                blocks.push(json!({
                                    "type": "thinking",
                                    "thinking": thinking,
                                    "signature": signature,
                                }));
                            }
                            ReasoningBlock::AnthropicRedactedThinking { data } => {
                                blocks.push(json!({
                                    "type": "redacted_thinking",
                                    "data": data,
                                }));
                            }
                            _ => {}
                        }
                    }
                }
                let mut text = node.content.clone();
                if let Some(ctx) = replay_ctx
                    && let Some(handoff) =
                        cross_provider_reasoning_handoff_for_node(&meta, ctx, last_asst == Some(i))
                {
                    text = format!("[Prior reasoning summary]\n{handoff}\n\n{text}");
                }
                let active_calls: Vec<&StoredToolCall> = meta
                    .tool_calls
                    .iter()
                    .filter(|c| paired.contains(&c.call_id))
                    .collect();
                if blocks.is_empty() && active_calls.is_empty() {
                    out.push(json!({ "role": "assistant", "content": text }));
                } else {
                    if !text.is_empty() || active_calls.is_empty() {
                        blocks.push(json!({ "type": "text", "text": text }));
                    }
                    for call in active_calls {
                        let input = serde_json::from_str::<Value>(&call.arguments_json)
                            .unwrap_or_else(|_| json!({}));
                        blocks.push(json!({
                            "type": "tool_use",
                            "id": call.call_id,
                            "name": call.name,
                            "input": input,
                        }));
                    }
                    out.push(json!({ "role": "assistant", "content": blocks }));
                }
                i += 1;
            }
            NodeRole::Tool => {
                // Anthropic requires all consecutive tool_results for parallel tool calls inside
                // ONE `"role": "user"` message!
                let mut result_blocks: Vec<Value> = Vec::new();
                while i < history.len() && history[i].role == NodeRole::Tool {
                    let tnode = &history[i];
                    let meta = parse_turn_wire_meta(tnode.provider_meta_json.as_deref());
                    if let Some(res) = meta.tool_result
                        && paired.contains(&res.call_id)
                    {
                        let content_val = encode_anthropic_tool_content(
                            data_dir,
                            &tnode.content,
                            &res.media_attachments,
                        );
                        let mut block = json!({
                            "type": "tool_result",
                            "tool_use_id": res.call_id,
                            "content": content_val,
                        });
                        if res.is_error
                            && let Some(obj) = block.as_object_mut()
                        {
                            obj.insert("is_error".to_owned(), Value::Bool(true));
                        }
                        result_blocks.push(block);
                    }
                    i += 1;
                }
                if !result_blocks.is_empty() {
                    out.push(json!({ "role": "user", "content": result_blocks }));
                }
            }
        }
    }
    out
}

fn encode_anthropic_attachments(dir: &Path, atts: &[StoredAttachment]) -> Vec<Value> {
    let empty: HashMap<String, String> = HashMap::new();
    encode_anthropic_attachments_with_refs(dir, &empty, atts)
}

fn encode_anthropic_attachments_with_refs<S: std::hash::BuildHasher>(
    dir: &Path,
    remote_refs: &HashMap<String, String, S>,
    atts: &[StoredAttachment],
) -> Vec<Value> {
    let mut blocks = Vec::new();
    for att in atts {
        let before = blocks.len();
        if att.mime_type.starts_with("image/") {
            if let Some(file_id) = remote_refs.get(&att.blake3_hex) {
                blocks.push(json!({
                    "type": "image",
                    "source": {
                        "type": "file",
                        "file_id": file_id,
                    }
                }));
            } else if let Some(b64) = read_attachment_base64(dir, att) {
                blocks.push(json!({
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": att.mime_type,
                        "data": b64,
                    }
                }));
            }
        } else if att.mime_type == "application/pdf" {
            if let Some(file_id) = remote_refs.get(&att.blake3_hex) {
                blocks.push(json!({
                    "type": "document",
                    "source": {
                        "type": "file",
                        "file_id": file_id,
                    }
                }));
            } else if let Some(b64) = read_attachment_base64(dir, att) {
                blocks.push(json!({
                    "type": "document",
                    "source": {
                        "type": "base64",
                        "media_type": "application/pdf",
                        "data": b64,
                    }
                }));
            }
        } else if let Some(file_id) = remote_refs.get(&att.blake3_hex) {
            blocks.push(json!({
                "type": "document",
                "source": {
                    "type": "file",
                    "file_id": file_id,
                }
            }));
        } else if let Some(block) = read_attachment_as_text_block(dir, att) {
            blocks.push(json!({ "type": "text", "text": block }));
        } else {
            blocks.push(json!({
                "type": "text",
                "text": format!("[Attachment: {} ({})]", att.name, att.mime_type),
            }));
        }
        // R24: never a silent drop.
        if blocks.len() == before {
            blocks.push(json!({ "type": "text", "text": attachment_not_sent_note(att) }));
        }
    }
    blocks
}

fn encode_anthropic_tool_content(
    data_dir: Option<&Path>,
    text: &str,
    media: &[StoredAttachment],
) -> Value {
    if media.is_empty() || data_dir.is_none() {
        return Value::String(text.to_owned());
    }
    let Some(dir) = data_dir else {
        return Value::String(text.to_owned());
    };
    let mut blocks = vec![json!({ "type": "text", "text": text })];
    blocks.extend(encode_anthropic_attachments(dir, media));
    Value::Array(blocks)
}

/// Builds Custom `OpenAI`-Compatible `/chat/completions` messages with `image_url`, extracted
/// text/Office documents, `tool_calls`, and `role: "tool"` responses.
pub fn build_openai_compat_messages_with_ctx(
    history: &[NodeRecord],
    data_dir: Option<&Path>,
    replay_ctx: Option<&ReplayContext>,
) -> Vec<Value> {
    let paired = paired_tool_call_ids(history);
    let last_asst = latest_assistant_index(history);
    let mut out = Vec::with_capacity(history.len());

    for (idx, node) in history.iter().enumerate() {
        match node.role {
            NodeRole::System => {}
            NodeRole::User | NodeRole::CompactionSummary => {
                let text = user_text_with_summary_prefix(node);
                let atts = parse_node_attachments(node.provider_meta_json.as_deref());
                if atts.is_empty() || data_dir.is_none() {
                    out.push(json!({ "role": "user", "content": text }));
                } else if let Some(dir) = data_dir {
                    let mut parts = Vec::new();
                    for att in &atts {
                        if att.mime_type.starts_with("image/") {
                            if let Some(b64) = read_attachment_base64(dir, att) {
                                parts.push(json!({
                                    "type": "image_url",
                                    "image_url": {
                                        "url": format!("data:{};base64,{b64}", att.mime_type),
                                    }
                                }));
                            }
                        } else if let Some(block) = read_attachment_as_text_block(dir, att) {
                            parts.push(json!({ "type": "text", "text": block }));
                        } else {
                            parts.push(json!({
                                "type": "text",
                                "text": format!("[Attachment: {} ({})]", att.name, att.mime_type),
                            }));
                        }
                    }
                    if !text.is_empty() {
                        parts.push(json!({ "type": "text", "text": text }));
                    }
                    out.push(json!({ "role": "user", "content": parts }));
                }
            }
            NodeRole::Assistant => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                let mut text = node.content.clone();
                if let Some(ctx) = replay_ctx
                    && let Some(handoff) = cross_provider_reasoning_handoff_for_node(
                        &meta,
                        ctx,
                        last_asst == Some(idx),
                    )
                {
                    text = format!("[Prior reasoning summary]\n{handoff}\n\n{text}");
                }
                let active_calls: Vec<Value> = meta
                    .tool_calls
                    .iter()
                    .filter(|c| paired.contains(&c.call_id))
                    .map(|c| {
                        json!({
                            "id": c.call_id,
                            "type": "function",
                            "function": {
                                "name": c.name,
                                "arguments": c.arguments_json,
                            }
                        })
                    })
                    .collect();
                if active_calls.is_empty() {
                    out.push(json!({ "role": "assistant", "content": text }));
                } else {
                    out.push(json!({
                        "role": "assistant",
                        "content": if text.is_empty() { Value::Null } else { Value::String(text) },
                        "tool_calls": active_calls,
                    }));
                }
            }
            NodeRole::Tool => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                if let Some(res) = meta.tool_result
                    && paired.contains(&res.call_id)
                {
                    out.push(json!({
                        "role": "tool",
                        "tool_call_id": res.call_id,
                        "name": res.name,
                        "content": node.content,
                    }));
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::replay_policy::{TurnOriginMeta, blake3_short_hash};
    use bistre_protocol::ProviderDialect;

    fn rec(id: &str, role: NodeRole, content: &str, meta: Option<Value>, at: i64) -> NodeRecord {
        NodeRecord {
            id: id.to_owned(),
            thread_id: "t1".to_owned(),
            parent_id: None,
            role,
            content: content.to_owned(),
            provider_meta_json: meta.map(|m| m.to_string()),
            created_at_ms: at,
        }
    }

    /// Null fields in a stored reasoning item are never sent back (codex #47733).
    #[test]
    fn replayed_reasoning_items_carry_no_null_fields() {
        let origin = TurnOriginMeta {
            dialect: ProviderDialect::OpenAi,
            provider_id: "p1".to_owned(),
            model_id: "m".to_owned(),
            system_hash: blake3_short_hash(""),
            tools_hash: blake3_short_hash(""),
        };
        let meta = json!({
            "origin": origin,
            "reasoning_blocks": [{
                "kind": "open_ai_reasoning",
                "id": "rs_1",
                "summary": [{ "type": "summary_text", "text": "x", "status": null }],
                "encrypted_content": "enc"
            }]
        });
        let history = vec![
            rec("u1", NodeRole::User, "Hi", None, 1),
            rec("a1", NodeRole::Assistant, "Hello", Some(meta), 2),
            rec("u2", NodeRole::User, "Next", None, 3),
        ];
        let ctx = ReplayContext::new(ProviderDialect::OpenAi, "p1", "m", "", "", Some("t1"));
        let items = build_openai_responses_input_with_ctx(&history, None, Some(&ctx));
        let text = Value::Array(items).to_string();
        assert!(text.contains("\"encrypted_content\":\"enc\""), "{text}");
        assert!(!text.contains("null"), "{text}");
    }

    #[test]
    fn replays_anthropic_thinking_signature_only_when_prefix_matches_and_drops_on_switch() {
        let origin = TurnOriginMeta {
            dialect: ProviderDialect::Anthropic,
            provider_id: "p1".to_owned(),
            model_id: "claude-x".to_owned(),
            system_hash: blake3_short_hash("sys"),
            tools_hash: blake3_short_hash(""),
        };
        let meta = json!({
            "origin": origin,
            "reasoning_blocks": [
                { "kind": "anthropic_thinking", "thinking": "chain", "signature": "sig_123" },
                { "kind": "anthropic_redacted_thinking", "data": "redacted_9" }
            ],
            "thinking_text": "chain"
        })
        .to_string();
        let history = vec![
            NodeRecord {
                id: "u1".to_owned(),
                thread_id: "t1".to_owned(),
                parent_id: None,
                role: NodeRole::User,
                content: "Hi".to_owned(),
                provider_meta_json: None,
                created_at_ms: 1,
            },
            NodeRecord {
                id: "a1".to_owned(),
                thread_id: "t1".to_owned(),
                parent_id: Some("u1".to_owned()),
                role: NodeRole::Assistant,
                content: "Hello".to_owned(),
                provider_meta_json: Some(meta),
                created_at_ms: 2,
            },
            NodeRecord {
                id: "u2".to_owned(),
                thread_id: "t1".to_owned(),
                parent_id: Some("a1".to_owned()),
                role: NodeRole::User,
                content: "Next".to_owned(),
                provider_meta_json: None,
                created_at_ms: 3,
            },
        ];

        // Exact same Anthropic context -> verbatim thinking + redacted_thinking replayed!
        let same = ReplayContext::new(
            ProviderDialect::Anthropic,
            "p1",
            "claude-x",
            "sys",
            "",
            Some("t1"),
        );
        let msgs = build_anthropic_messages_with_ctx(&history, None, Some(&same));
        assert_eq!(msgs[1]["content"][0]["type"], "thinking");
        assert_eq!(msgs[1]["content"][0]["signature"], "sig_123");
        assert_eq!(msgs[1]["content"][1]["type"], "redacted_thinking");
        assert_eq!(msgs[1]["content"][1]["data"], "redacted_9");

        // System prompt mutated mid-chat -> thinking blocks stripped cleanly (zero prefix 400)!
        let changed_sys = ReplayContext::new(
            ProviderDialect::Anthropic,
            "p1",
            "claude-x",
            "new-sys",
            "",
            Some("t1"),
        );
        let msgs_mut = build_anthropic_messages_with_ctx(&history, None, Some(&changed_sys));
        assert_eq!(msgs_mut[1]["content"], "Hello");

        // Switched to OpenAI mid-chat -> zero Anthropic signatures leaked; 8k handoff included!
        let oai_ctx = ReplayContext::new(
            ProviderDialect::OpenAi,
            "p2",
            "oai-x",
            "sys",
            "",
            Some("t1"),
        );
        let oai_in = build_openai_responses_input_with_ctx(&history, None, Some(&oai_ctx));
        let serialized = Value::Array(oai_in).to_string();
        assert!(!serialized.contains("sig_123"));
        assert!(!serialized.contains("redacted_9"));
        assert!(serialized.contains("Prior reasoning summary"));
    }

    #[test]
    fn orphan_tool_call_without_result_is_pruned_before_wire_serialization() {
        let meta = json!({
            "tool_calls": [{ "call_id": "call_orphan", "name": "read", "arguments_json": "{}" }]
        })
        .to_string();
        let history = vec![
            NodeRecord {
                id: "u1".to_owned(),
                thread_id: "t1".to_owned(),
                parent_id: None,
                role: NodeRole::User,
                content: "Check file".to_owned(),
                provider_meta_json: None,
                created_at_ms: 1,
            },
            NodeRecord {
                id: "a1".to_owned(),
                thread_id: "t1".to_owned(),
                parent_id: Some("u1".to_owned()),
                role: NodeRole::Assistant,
                content: "Checking".to_owned(),
                provider_meta_json: Some(meta),
                created_at_ms: 2,
            },
            NodeRecord {
                id: "u2".to_owned(),
                thread_id: "t1".to_owned(),
                parent_id: Some("a1".to_owned()),
                role: NodeRole::User,
                content: "Never mind".to_owned(),
                provider_meta_json: None,
                created_at_ms: 3,
            },
        ];
        let anth = build_anthropic_messages_with_ctx(&history, None, None);
        assert!(!Value::Array(anth).to_string().contains("call_orphan"));
        let oai = build_openai_responses_input_with_ctx(&history, None, None);
        assert!(!Value::Array(oai).to_string().contains("call_orphan"));
    }
}
