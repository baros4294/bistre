//! Dialect-specific conversation history serialization with:
//! - Native multimodal/PDF/Office attachment encoding
//! - Cryptographic reasoning block round-tripping (verified by [`crate::replay_policy`])
//! - Bounded cross-provider reasoning handoffs (`<= 8,000` chars, zero leaked signatures)
//! - Full `NodeRole::Tool` & `StoredToolCall` replay (including rich media tool outputs)
//! - Automatic orphan `tool_use` / `tool_result` pair protection so delete/branch never 400s,
//!   and unique call ids per history ([`ToolIdPlan`])
//! - `OpenRouter` `reasoning_details` replay on tool-call turns ([`crate::reasoning_details`])

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
    cross_provider_reasoning_handoff_for_node, latest_compaction_ms, made_before_compaction,
    parse_turn_wire_meta, safe_reasoning_blocks_for_target,
};
use crate::tool_call_ids::ToolIdPlan;
pub use crate::wire_history_gemini::{
    build_gemini_generate_contents_with_ctx, build_gemini_interactions_input_with_ctx,
};

/// A stored call's arguments as the JSON object Anthropic `input` and Gemini `args` require.
/// Arguments that are not a JSON object go back as `{"INVALID_JSON": raw}` (Anthropic's
/// documented recovery), so the model sees what it sent next to the error result instead of a
/// call it never made with no arguments.
pub(crate) fn replay_tool_input(arguments_json: &str) -> Value {
    match serde_json::from_str::<Value>(arguments_json) {
        Ok(v @ Value::Object(_)) => v,
        Ok(_) | Err(_) => json!({ "INVALID_JSON": arguments_json }),
    }
}

pub(crate) fn latest_assistant_index(history: &[NodeRecord]) -> Option<usize> {
    history.iter().rposition(|n| n.role == NodeRole::Assistant)
}

/// Maximum number of most-recent image-bearing turns whose binary image payloads are replayed
/// in full; older image turns are evicted to compact text placeholders so long multimodal chats
/// stay within context budgets.
pub const MAX_REPLAYED_IMAGE_TURNS: usize = 8;

/// Splits `atts` into attachments to serialize normally and compact placeholder notes for
/// image attachments on older turns evicted by [`crate::compaction::plan_image_retention`].
pub(crate) fn retain_turn_attachments(
    node_id: &str,
    retained_images: &HashSet<String>,
    atts: Vec<StoredAttachment>,
) -> (Vec<StoredAttachment>, Vec<String>) {
    if retained_images.contains(node_id) {
        return (atts, Vec::new());
    }
    let mut kept = Vec::with_capacity(atts.len());
    let mut notes = Vec::new();
    for att in atts {
        if att.mime_type.starts_with("image/") {
            notes.push(format!("[Earlier image omitted: {}]", att.name));
        } else {
            kept.push(att);
        }
    }
    (kept, notes)
}

pub(crate) fn prepend_omitted_notes(notes: &[String], text: String) -> String {
    if notes.is_empty() {
        return text;
    }
    let mut joined = notes.join("\n");
    if !text.is_empty() {
        joined.push('\n');
        joined.push_str(&text);
    }
    joined
}

pub(crate) fn user_text_with_summary_prefix(node: &NodeRecord) -> String {
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
    let ids = ToolIdPlan::new(history);
    let last_asst = latest_assistant_index(history);
    let retained_images =
        crate::compaction::plan_image_retention(history, MAX_REPLAYED_IMAGE_TURNS);
    let mut out: Vec<Value> = Vec::with_capacity(history.len());

    // A chained request sends only the items after `chain_skip` (the server holds the
    // rest), while pairing still sees the whole history.
    for (idx, node) in history.iter().enumerate().skip(chain_skip) {
        match node.role {
            NodeRole::System => {}
            NodeRole::User | NodeRole::CompactionSummary => {
                let raw_atts = parse_node_attachments(node.provider_meta_json.as_deref());
                let (atts, omitted) = retain_turn_attachments(&node.id, &retained_images, raw_atts);
                let text = prepend_omitted_notes(&omitted, user_text_with_summary_prefix(node));
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
                // Only reasoning made before the newest compaction lost its prefix.
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
                    if let Some(wire_id) = ids.call(idx, &call.call_id) {
                        out.push(json!({
                            "type": "function_call",
                            "call_id": wire_id,
                            "name": call.name,
                            "arguments": call.arguments_json,
                            // The documented status the API returned it with.
                            "status": "completed",
                        }));
                    }
                }
            }
            NodeRole::Tool => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                if let Some(res) = meta.tool_result
                    && let Some(wire_id) = ids.result(idx)
                {
                    let output_val = encode_openai_tool_output(data_dir, &node.content, &res);
                    out.push(json!({
                        "type": "function_call_output",
                        "call_id": wire_id,
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
        // Never a silent drop.
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

fn anthropic_user_message<S: std::hash::BuildHasher>(
    node: &NodeRecord,
    retained_images: &HashSet<String>,
    data_dir: Option<&Path>,
    remote_refs: &HashMap<String, String, S>,
) -> Value {
    let raw_atts = parse_node_attachments(node.provider_meta_json.as_deref());
    let (atts, omitted) = retain_turn_attachments(&node.id, retained_images, raw_atts);
    let text = prepend_omitted_notes(&omitted, user_text_with_summary_prefix(node));
    if atts.is_empty() || data_dir.is_none() {
        return json!({ "role": "user", "content": text });
    }
    if let Some(dir) = data_dir {
        let mut blocks = encode_anthropic_attachments_with_refs(dir, remote_refs, &atts);
        if !text.is_empty() {
            blocks.push(json!({ "type": "text", "text": text }));
        }
        return json!({ "role": "user", "content": blocks });
    }
    json!({ "role": "user", "content": text })
}

/// Builds Anthropic Messages API (`messages`) with optional Files API `file_id` references.
pub fn build_anthropic_messages_with_refs<S: std::hash::BuildHasher>(
    history: &[NodeRecord],
    data_dir: Option<&Path>,
    remote_refs: &HashMap<String, String, S>,
    replay_ctx: Option<&ReplayContext>,
) -> Vec<Value> {
    let compaction_at = latest_compaction_ms(history);
    let ids = ToolIdPlan::new(history);
    let last_asst = latest_assistant_index(history);
    let retained_images =
        crate::compaction::plan_image_retention(history, MAX_REPLAYED_IMAGE_TURNS);
    let mut out: Vec<Value> = Vec::with_capacity(history.len());

    let mut i = 0_usize;
    while i < history.len() {
        let node = &history[i];
        match node.role {
            NodeRole::System => {
                i += 1;
            }
            NodeRole::User | NodeRole::CompactionSummary => {
                out.push(anthropic_user_message(
                    node,
                    &retained_images,
                    data_dir,
                    remote_refs,
                ));
                i += 1;
            }
            NodeRole::Assistant => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                // Only reasoning made before the newest compaction lost its prefix.
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
                let active_calls: Vec<(&StoredToolCall, &str)> = meta
                    .tool_calls
                    .iter()
                    .filter_map(|c| ids.call(i, &c.call_id).map(|w| (c, w)))
                    .collect();
                if blocks.is_empty() && active_calls.is_empty() {
                    out.push(json!({ "role": "assistant", "content": text }));
                } else {
                    if !text.is_empty() || active_calls.is_empty() {
                        blocks.push(json!({ "type": "text", "text": text }));
                    }
                    for (call, wire_id) in active_calls {
                        blocks.push(json!({
                            "type": "tool_use",
                            "id": wire_id,
                            "name": call.name,
                            "input": replay_tool_input(&call.arguments_json),
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
                        && let Some(wire_id) = ids.result(i)
                    {
                        let content_val = encode_anthropic_tool_content(
                            data_dir,
                            &tnode.content,
                            &res.media_attachments,
                        );
                        let mut block = json!({
                            "type": "tool_result",
                            "tool_use_id": wire_id,
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
        // Never a silent drop.
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
    openrouter: bool,
    reads: Option<crate::registry::ModalitySet>,
) -> Vec<Value> {
    let compaction_at = latest_compaction_ms(history);
    let ids = ToolIdPlan::new(history);
    let last_asst = latest_assistant_index(history);
    let retained_images =
        crate::compaction::plan_image_retention(history, MAX_REPLAYED_IMAGE_TURNS);
    let mut out = Vec::with_capacity(history.len());

    for (idx, node) in history.iter().enumerate() {
        match node.role {
            NodeRole::System => {}
            NodeRole::User | NodeRole::CompactionSummary => {
                let raw_atts = parse_node_attachments(node.provider_meta_json.as_deref());
                let (atts, omitted) = retain_turn_attachments(&node.id, &retained_images, raw_atts);
                let text = prepend_omitted_notes(&omitted, user_text_with_summary_prefix(node));
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
                        } else if let Some(part) = compat_media_part(dir, att, reads, openrouter) {
                            parts.push(part);
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
                    .filter_map(|c| ids.call(idx, &c.call_id).map(|w| (c, w)))
                    .map(|(c, wire_id)| {
                        json!({
                            "id": wire_id,
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
                    let mut msg = json!({
                        "role": "assistant",
                        "content": if text.is_empty() { Value::Null } else { Value::String(text) },
                        "tool_calls": active_calls,
                    });
                    // An `OpenRouter`-only field, sent to `OpenRouter` only.
                    if openrouter && let Some(ctx) = replay_ctx {
                        let stale = made_before_compaction(compaction_at, node);
                        let details =
                            crate::reasoning_details::replay_for_target(&meta, ctx, stale);
                        if !details.is_empty() {
                            msg["reasoning_details"] = Value::Array(details);
                        }
                    }
                    out.push(msg);
                }
            }
            NodeRole::Tool => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                if let Some(res) = meta.tool_result
                    && let Some(wire_id) = ids.result(idx)
                {
                    out.push(json!({
                        "role": "tool",
                        "tool_call_id": wire_id,
                        "name": res.name,
                        "content": node.content,
                    }));
                }
            }
        }
    }
    out
}

/// Audio or video as a Chat Completions part, for a model the catalog says reads it:
/// `input_audio` (`wav` and `mp3` everywhere; `OpenRouter` also takes `ogg`, `flac`, `aac`,
/// `m4a`, and `aiff`) and `OpenRouter`'s `video_url`. Anything else stays a named note.
fn compat_media_part(
    dir: &Path,
    att: &StoredAttachment,
    reads: Option<crate::registry::ModalitySet>,
    openrouter: bool,
) -> Option<Value> {
    use crate::registry::Modality;
    let reads = reads?;
    let (kind, subtype) = att.mime_type.split_once('/')?;
    match kind {
        "audio" if reads.contains(Modality::Audio) => {
            let format = match subtype {
                "wav" | "x-wav" | "wave" => "wav",
                "mpeg" | "mp3" => "mp3",
                "ogg" if openrouter => "ogg",
                "flac" | "x-flac" if openrouter => "flac",
                "aac" if openrouter => "aac",
                "mp4" | "x-m4a" if openrouter => "m4a",
                "aiff" | "x-aiff" if openrouter => "aiff",
                _ => return None,
            };
            let data = read_attachment_base64(dir, att)?;
            Some(
                json!({ "type": "input_audio", "input_audio": { "data": data, "format": format } }),
            )
        }
        "video" if openrouter && reads.contains(Modality::Video) => {
            let data = read_attachment_base64(dir, att)?;
            Some(json!({
                "type": "video_url",
                "video_url": { "url": format!("data:{};base64,{data}", att.mime_type) },
            }))
        }
        _ => None,
    }
}

#[cfg(test)]
#[path = "wire_history_tests.rs"]
mod tests;
