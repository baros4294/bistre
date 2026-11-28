//! Google Gemini history serialization (split out of `wire_history.rs`): Interactions API
//! turns and classic `generateContent` contents, with verified thought signatures (or the
//! documented bypass) on function calls.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use bistre_protocol::{NodeRecord, NodeRole, StoredAttachment};
use serde_json::{Value, json};

use crate::attachments::{
    attachment_not_sent_note, is_office_document, is_text_like, parse_node_attachments,
    read_attachment_as_text_block, read_attachment_base64,
};
use crate::replay_policy::{
    ReasoningBlock, ReplayContext, cross_provider_reasoning_handoff_for_node,
    gemini_function_call_signature, latest_compaction_ms, made_before_compaction,
    parse_turn_wire_meta, safe_reasoning_blocks_for_target,
};
use crate::tool_call_ids::ToolIdPlan;
use crate::wire_history::{
    MAX_REPLAYED_IMAGE_TURNS, latest_assistant_index, prepend_omitted_notes, replay_tool_input,
    retain_turn_attachments, user_text_with_summary_prefix,
};

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
    let ids = ToolIdPlan::new(history);
    let last_asst = latest_assistant_index(history);
    let retained_images =
        crate::compaction::plan_image_retention(history, MAX_REPLAYED_IMAGE_TURNS);
    let mut out = Vec::with_capacity(history.len());

    // As in the `OpenAI` builder, chained requests send only the new items.
    for (idx, node) in history.iter().enumerate().skip(chain_skip) {
        match node.role {
            NodeRole::System => {}
            NodeRole::User | NodeRole::CompactionSummary => {
                let raw_atts = parse_node_attachments(node.provider_meta_json.as_deref());
                let (atts, omitted) = retain_turn_attachments(&node.id, &retained_images, raw_atts);
                let text = prepend_omitted_notes(&omitted, user_text_with_summary_prefix(node));
                let mut parts = encode_gemini_interactions_atts(data_dir, gemini_uris, &atts);
                parts.push(json!({ "type": "text", "text": text }));
                out.push(json!({ "role": "user", "content": parts }));
            }
            NodeRole::Assistant => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                // Only reasoning made before the newest compaction lost its prefix.
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
                    if let Some(wire_id) = ids.call(idx, &call.call_id) {
                        let args_val = replay_tool_input(&call.arguments_json);
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
                            "id": wire_id,
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
                    && let Some(wire_id) = ids.result(idx)
                {
                    let mut parts = vec![json!({
                        "type": "function_result",
                        "call_id": wire_id,
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
            // Gemini rejects Office MIME types; text and Office files always go as text
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
        // Never a silent drop.
        if parts.len() == before {
            parts.push(json!({ "type": "text", "text": attachment_not_sent_note(att) }));
        }
    }
    parts
}

/// A reply's `functionCall` parts, in order. The first call of a turn always carries a
/// signature (its own, or the documented bypass); later parallel calls only their own.
fn push_gemini_calls(
    parts: &mut Vec<Value>,
    meta: &crate::replay_policy::ParsedTurnWireMeta,
    ids: &ToolIdPlan,
    idx: usize,
    replay_ctx: Option<&ReplayContext>,
    stale: bool,
) {
    let mut first_call = true;
    for call in &meta.tool_calls {
        if let Some(wire_id) = ids.call(idx, &call.call_id) {
            let args_val = replay_tool_input(&call.arguments_json);
            let sig = replay_ctx.map_or(
                crate::replay_policy::GEMINI_THOUGHT_SIGNATURE_BYPASS,
                |ctx| gemini_function_call_signature(call, meta.origin.as_ref(), ctx, stale),
            );
            let mut part = json!({
                "functionCall": {
                    "id": wire_id,
                    "name": call.name,
                    "args": args_val,
                },
            });
            if first_call || sig != crate::replay_policy::GEMINI_THOUGHT_SIGNATURE_BYPASS {
                part["thoughtSignature"] = Value::String(sig.to_owned());
            }
            first_call = false;
            parts.push(part);
        }
    }
}

/// Each reply whose pictures go back as its own parts: the pictures' paths and their parts,
/// each with its `thoughtSignature`. Only when the target may replay this reply's signatures,
/// every picture has one, and the reply is among the turns whose images are kept; any other
/// reply's pictures ride on the next user message (`carry_generated_media`).
fn own_pictures<S: std::hash::BuildHasher>(
    history: &[NodeRecord],
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
    replay_ctx: Option<&ReplayContext>,
    compaction_at: Option<i64>,
    retained_images: &HashSet<String>,
) -> HashMap<usize, (Vec<String>, Vec<Value>)> {
    let mut out = HashMap::new();
    let Some(ctx) = replay_ctx else {
        return out;
    };
    for (idx, node) in history.iter().enumerate() {
        if node.role != NodeRole::Assistant || !retained_images.contains(&node.id) {
            continue;
        }
        let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
        let stale = made_before_compaction(compaction_at, node);
        let Some(signatures) = safe_reasoning_blocks_for_target(&meta, ctx, stale)
            .into_iter()
            .find_map(|b| match b {
                ReasoningBlock::GeminiPictureSignatures { signatures } => Some(signatures),
                _ => None,
            })
        else {
            continue;
        };
        let made: Vec<StoredAttachment> =
            parse_node_attachments(node.provider_meta_json.as_deref())
                .into_iter()
                .filter(|a| a.mime_type.starts_with("image/"))
                .collect();
        if made.len() != signatures.len() {
            continue;
        }
        let mut parts = encode_gemini_generate_atts(data_dir, gemini_uris, &made);
        let all_pictures = parts.len() == made.len()
            && parts
                .iter()
                .all(|p| p.get("inline_data").is_some() || p.get("file_data").is_some());
        if !all_pictures {
            continue;
        }
        for (part, signature) in parts.iter_mut().zip(signatures) {
            part["thoughtSignature"] = Value::String(signature);
        }
        out.insert(
            idx,
            (made.into_iter().map(|a| a.blob_rel_path).collect(), parts),
        );
    }
    out
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
    let ids = ToolIdPlan::new(history);
    let last_asst = latest_assistant_index(history);
    let retained_images =
        crate::compaction::plan_image_retention(history, MAX_REPLAYED_IMAGE_TURNS);
    let mut pictures = own_pictures(
        history,
        data_dir,
        gemini_uris,
        replay_ctx,
        compaction_at,
        &retained_images,
    );
    let resent: HashSet<String> = pictures
        .values()
        .flat_map(|(paths, _)| paths.iter().cloned())
        .collect();
    let mut out = Vec::with_capacity(history.len());

    for (idx, node) in history.iter().enumerate() {
        match node.role {
            NodeRole::System => {}
            NodeRole::User | NodeRole::CompactionSummary => {
                let mut raw_atts = parse_node_attachments(node.provider_meta_json.as_deref());
                // A picture its reply sends back is not sent twice.
                raw_atts.retain(|a| !resent.contains(&a.blob_rel_path));
                let (atts, omitted) = retain_turn_attachments(&node.id, &retained_images, raw_atts);
                let text = prepend_omitted_notes(&omitted, user_text_with_summary_prefix(node));
                let mut parts = encode_gemini_generate_atts(data_dir, gemini_uris, &atts);
                parts.push(json!({ "text": text }));
                out.push(json!({ "role": "user", "parts": parts }));
            }
            NodeRole::Assistant => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                // Only reasoning made before the newest compaction lost its prefix.
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
                if let Some((_, own)) = pictures.remove(&idx) {
                    parts.extend(own);
                }
                push_gemini_calls(&mut parts, &meta, &ids, idx, replay_ctx, stale);
                // A detached signature part stays a separate part after the calls.
                if let Some(sig) = text_sig {
                    parts.push(json!({ "text": "", "thoughtSignature": sig }));
                }
                out.push(json!({ "role": "model", "parts": parts }));
            }
            NodeRole::Tool => {
                let meta = parse_turn_wire_meta(node.provider_meta_json.as_deref());
                if let Some(res) = meta.tool_result
                    && let Some(wire_id) = ids.result(idx)
                {
                    let mut parts = vec![json!({
                        "functionResponse": {
                            "id": wire_id,
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
            // Gemini rejects Office MIME types; always the pure-Rust ZIP+XML text.
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
        // Never a silent drop.
        if parts.len() == before {
            parts.push(json!({ "text": attachment_not_sent_note(att) }));
        }
    }
    parts
}
