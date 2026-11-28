//! Provider `/models` catalog parsing and SSE/plain-JSON delta, thinking, usage, and terminal
//! frame extraction across all 4 wire dialects (`OpenAI`, Gemini, Anthropic, Custom `OpenAI`).

use bistre_protocol::{ProviderDialect, ProviderModelInfo, UsageMetrics};
use serde_json::Value;

/// Parses live `/models` JSON across Big 3 + `OpenAI`-compatible/Ollama endpoints.
pub fn parse_models_payload(dialect: ProviderDialect, body: &Value) -> Vec<ProviderModelInfo> {
    let mut out = Vec::new();

    match dialect {
        ProviderDialect::GoogleGemini => {
            if let Some(items) = body.get("models").and_then(Value::as_array) {
                for item in items {
                    let Some(raw_name) = item.get("name").and_then(Value::as_str) else {
                        continue;
                    };
                    let id = raw_name.strip_prefix("models/").unwrap_or(raw_name);
                    let display = item
                        .get("displayName")
                        .and_then(Value::as_str)
                        .unwrap_or(id);
                    out.push(ProviderModelInfo {
                        id: id.to_owned(),
                        display_name: display.to_owned(),
                    });
                }
            }
        }
        ProviderDialect::OpenAi | ProviderDialect::Anthropic | ProviderDialect::CustomOpenAi => {
            if let Some(items) = body.get("data").and_then(Value::as_array) {
                for item in items {
                    let Some(id) = item.get("id").and_then(Value::as_str) else {
                        continue;
                    };
                    let display = item
                        .get("display_name")
                        .and_then(Value::as_str)
                        .unwrap_or(id);
                    out.push(ProviderModelInfo {
                        id: id.to_owned(),
                        display_name: display.to_owned(),
                    });
                }
            } else if let Some(items) = body.get("models").and_then(Value::as_array) {
                for item in items {
                    let Some(id) = item
                        .get("name")
                        .or_else(|| item.get("id"))
                        .and_then(Value::as_str)
                    else {
                        continue;
                    };
                    out.push(ProviderModelInfo {
                        id: id.to_owned(),
                        display_name: id.to_owned(),
                    });
                }
            }
        }
    }

    out.sort_by(|a, b| a.id.cmp(&b.id));
    out.dedup_by(|a, b| a.id == b.id);
    out
}

/// Extracts incremental text delta (or non-streaming plain-JSON reply text) across all 4 dialects.
pub fn extract_sse_delta(dialect: ProviderDialect, json_str: &str) -> Option<String> {
    let val: Value = serde_json::from_str(json_str).ok()?;
    delta_of_frame(dialect, &val)
}

/// The same, on a frame already parsed once.
pub fn delta_of_frame(dialect: ProviderDialect, val: &Value) -> Option<String> {
    match dialect {
        ProviderDialect::OpenAi => {
            if val.get("type").and_then(Value::as_str) == Some("response.output_text.delta")
                && let Some(delta) = val.get("delta").and_then(Value::as_str)
            {
                return Some(delta.to_owned());
            }
            if let Some(chat) = extract_openai_chat_delta(val) {
                return Some(chat);
            }
            // Plain-JSON fallback (non-streaming Responses API body).
            if let Some(output) = val.get("output").and_then(Value::as_array) {
                let mut combined = String::new();
                for item in output {
                    if item.get("type").and_then(Value::as_str) != Some("message") {
                        continue;
                    }
                    if let Some(parts) = item.get("content").and_then(Value::as_array) {
                        for p in parts {
                            if p.get("type").and_then(Value::as_str) == Some("output_text")
                                && let Some(t) = p.get("text").and_then(Value::as_str)
                            {
                                combined.push_str(t);
                            }
                        }
                    }
                }
                if !combined.is_empty() {
                    return Some(combined);
                }
            }
            None
        }
        ProviderDialect::GoogleGemini => {
            if val.get("event_type").and_then(Value::as_str) == Some("step.delta")
                && val
                    .get("delta")
                    .and_then(|d| d.get("type"))
                    .and_then(Value::as_str)
                    == Some("text")
                && let Some(text) = val
                    .get("delta")
                    .and_then(|d| d.get("text"))
                    .and_then(Value::as_str)
            {
                return Some(text.to_owned());
            }
            // Transparent legacy generateContent SSE & plain-JSON format.
            // Strictly skip `"thought": true` parts so internal thoughts never leak into `full_text`.
            let parts = val
                .get("candidates")?
                .get(0)?
                .get("content")?
                .get("parts")?
                .as_array()?;
            let mut combined = String::new();
            for p in parts {
                if p.get("thought").and_then(Value::as_bool) == Some(true) {
                    continue;
                }
                if let Some(t) = p.get("text").and_then(Value::as_str) {
                    combined.push_str(t);
                }
            }
            if combined.is_empty() {
                None
            } else {
                Some(combined)
            }
        }
        ProviderDialect::Anthropic => {
            if val.get("type").and_then(Value::as_str) == Some("content_block_delta")
                && val
                    .get("delta")
                    .and_then(|d| d.get("type"))
                    .and_then(Value::as_str)
                    == Some("text_delta")
            {
                return val
                    .get("delta")
                    .and_then(|d| d.get("text"))
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
            }
            // Plain-JSON fallback (non-streaming Messages API body).
            if val.get("type").and_then(Value::as_str) == Some("message")
                && let Some(blocks) = val.get("content").and_then(Value::as_array)
            {
                let mut combined = String::new();
                for b in blocks {
                    if b.get("type").and_then(Value::as_str) == Some("text")
                        && let Some(t) = b.get("text").and_then(Value::as_str)
                    {
                        combined.push_str(t);
                    }
                }
                if !combined.is_empty() {
                    return Some(combined);
                }
            }
            None
        }
        ProviderDialect::CustomOpenAi => extract_openai_chat_delta(val),
    }
}

fn extract_openai_chat_delta(val: &Value) -> Option<String> {
    let choice = val.get("choices")?.get(0)?;
    choice
        .get("delta")
        .and_then(|d| d.get("content"))
        .or_else(|| choice.get("message").and_then(|m| m.get("content")))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

/// Extracts incremental reasoning/thinking deltas across `OpenAI` Responses, Anthropic, Gemini,
/// and `OpenAI`-compatible reasoning models.
pub fn extract_sse_thinking_delta(dialect: ProviderDialect, json_str: &str) -> Option<String> {
    let val: Value = serde_json::from_str(json_str).ok()?;
    thinking_delta_of_frame(dialect, &val)
}

/// The same, on a frame already parsed once.
pub fn thinking_delta_of_frame(dialect: ProviderDialect, val: &Value) -> Option<String> {
    match dialect {
        ProviderDialect::OpenAi => {
            let kind = val.get("type").and_then(Value::as_str);
            if matches!(
                kind,
                Some("response.reasoning_summary_text.delta" | "response.reasoning_text.delta")
            ) {
                return val
                    .get("delta")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
            }
            extract_openai_chat_reasoning_delta(val)
        }
        ProviderDialect::Anthropic => {
            if val.get("type").and_then(Value::as_str) == Some("content_block_delta")
                && val
                    .get("delta")
                    .and_then(|d| d.get("type"))
                    .and_then(Value::as_str)
                    == Some("thinking_delta")
            {
                return val
                    .get("delta")
                    .and_then(|d| d.get("thinking"))
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
            }
            None
        }
        ProviderDialect::GoogleGemini => {
            if val.get("event_type").and_then(Value::as_str) == Some("step.delta")
                && val
                    .get("delta")
                    .and_then(|d| d.get("type"))
                    .and_then(Value::as_str)
                    == Some("thought_summary")
            {
                return val
                    .get("delta")
                    .and_then(|d| d.get("text"))
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
            }
            let parts = val
                .get("candidates")?
                .get(0)?
                .get("content")?
                .get("parts")?
                .as_array()?;
            let mut combined = String::new();
            for p in parts {
                if p.get("thought").and_then(Value::as_bool) == Some(true)
                    && let Some(t) = p.get("text").and_then(Value::as_str)
                {
                    combined.push_str(t);
                }
            }
            if combined.is_empty() {
                None
            } else {
                Some(combined)
            }
        }
        ProviderDialect::CustomOpenAi => extract_openai_chat_reasoning_delta(val),
    }
}

/// A delta's reasoning text: the plain `reasoning_content` or `reasoning` string, else the
/// readable `OpenRouter` `reasoning_details` entries, so one thought is never shown twice.
/// The redaction placeholder `OpenRouter` streams for encrypted reasoning is never shown.
fn extract_openai_chat_reasoning_delta(val: &Value) -> Option<String> {
    let delta = val.get("choices")?.get(0)?.get("delta")?;
    let text = match delta
        .get("reasoning_content")
        .or_else(|| delta.get("reasoning"))
        .and_then(Value::as_str)
    {
        Some(plain) => plain.to_owned(),
        None => crate::reasoning_details::readable_text(
            delta
                .get("reasoning_details")
                .and_then(Value::as_array)
                .map_or(&[][..], Vec::as_slice),
        ),
    };
    (!text.is_empty() && !crate::reasoning_details::is_placeholder(&text)).then_some(text)
}

fn merge_anthropic_usage_block(u: &Value, usage: &mut UsageMetrics) {
    if let Some(v) = u.get("input_tokens").and_then(Value::as_u64) {
        usage.input_tokens = v;
    }
    if let Some(v) = u.get("output_tokens").and_then(Value::as_u64) {
        usage.output_tokens = v;
    }
    if let Some(v) = u.get("cache_read_input_tokens").and_then(Value::as_u64) {
        usage.cached_input_tokens = v;
    }
    if let Some(v) = u.get("cache_creation_input_tokens").and_then(Value::as_u64) {
        usage.cache_creation_input_tokens = v;
    }
    if let Some(v) = u
        .get("cache_creation")
        .and_then(|c| c.get("ephemeral_1h_input_tokens"))
        .and_then(Value::as_u64)
    {
        usage.cache_creation_1h_input_tokens = v;
    }
    if let Some(v) = u
        .pointer("/server_tool_use/web_search_requests")
        .and_then(Value::as_u64)
    {
        usage.web_searches = v;
    }
}

/// A reply's picture and sound tokens: `OpenAI` `completion_tokens_details` or
/// `output_tokens_details` (`image_tokens`, `audio_tokens`), Gemini `candidatesTokensDetails`
/// (`modality` `IMAGE` and `AUDIO`).
fn merge_media_output_tokens(u: &Value, usage: &mut UsageMetrics) {
    if let Some(d) = u
        .get("completion_tokens_details")
        .or_else(|| u.get("output_tokens_details"))
    {
        if let Some(v) = d.get("image_tokens").and_then(Value::as_u64) {
            usage.output_image_tokens = v;
        }
        if let Some(v) = d.get("audio_tokens").and_then(Value::as_u64) {
            usage.output_audio_tokens = v;
        }
    }
    if let Some(list) = u
        .get("candidatesTokensDetails")
        .or_else(|| u.get("candidates_tokens_details"))
        .and_then(Value::as_array)
    {
        let count = |m: &str| -> u64 {
            list.iter()
                .filter(|e| e["modality"] == m)
                .filter_map(|e| {
                    e["tokenCount"]
                        .as_u64()
                        .or_else(|| e["token_count"].as_u64())
                })
                .sum()
        };
        usage.output_image_tokens = count("IMAGE");
        usage.output_audio_tokens = count("AUDIO");
    }
}

/// The per-call provider tools of a finished `OpenAI` Responses reply: its `web_search_call`
/// items, and its code interpreter containers (each one session).
fn merge_openai_paid_calls(output: &[Value], usage: &mut UsageMetrics) {
    let of_type = |ty: &'static str| output.iter().filter(move |i| i["type"] == ty);
    usage.web_searches = u64::try_from(of_type("web_search_call").count()).unwrap_or(u64::MAX);
    let containers: std::collections::BTreeSet<&str> = of_type("code_interpreter_call")
        .map(|i| i["container_id"].as_str().unwrap_or_default())
        .collect();
    usage.code_sessions = u64::try_from(containers.len()).unwrap_or(u64::MAX);
}

/// Extracts exact integer token counts from SSE lifecycle frames across all 4 supported dialects.
pub fn merge_sse_usage(dialect: ProviderDialect, json_str: &str, usage: &mut UsageMetrics) {
    if let Ok(val) = serde_json::from_str::<Value>(json_str) {
        merge_usage_of_frame(dialect, &val, usage);
    }
}

/// The same, on a frame already parsed once.
pub fn merge_usage_of_frame(dialect: ProviderDialect, val: &Value, usage: &mut UsageMetrics) {
    match dialect {
        ProviderDialect::OpenAi => {
            if let Some(output) = val.pointer("/response/output").and_then(Value::as_array) {
                merge_openai_paid_calls(output, usage);
            }
            let u = val
                .get("response")
                .and_then(|r| r.get("usage"))
                .or_else(|| val.get("usage"));
            if let Some(u) = u {
                merge_media_output_tokens(u, usage);
                if let Some(v) = u
                    .get("input_tokens")
                    .or_else(|| u.get("prompt_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.input_tokens = v;
                }
                if let Some(v) = u
                    .get("output_tokens")
                    .or_else(|| u.get("completion_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.output_tokens = v;
                }
                if let Some(v) = u
                    .get("input_tokens_details")
                    .and_then(|d| d.get("cached_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.cached_input_tokens = v;
                }
                if let Some(v) = u
                    .get("output_tokens_details")
                    .or_else(|| u.get("completion_tokens_details"))
                    .and_then(|d| d.get("reasoning_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.reasoning_tokens = v;
                }
            }
        }
        ProviderDialect::Anthropic => {
            if let Some(u) = val.get("message").and_then(|m| m.get("usage")) {
                merge_anthropic_usage_block(u, usage);
            }
            if let Some(u) = val.get("usage") {
                merge_anthropic_usage_block(u, usage);
            }
        }
        ProviderDialect::GoogleGemini => {
            let u = val
                .get("usageMetadata")
                .or_else(|| val.get("usage_metadata"))
                .or_else(|| val.get("interaction").and_then(|i| i.get("usage")))
                .or_else(|| val.get("usage"));
            if let Some(u) = u {
                merge_media_output_tokens(u, usage);
                if let Some(v) = u
                    .get("promptTokenCount")
                    .or_else(|| u.get("total_input_tokens"))
                    .or_else(|| u.get("input_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.input_tokens = v;
                }
                if let Some(v) = u
                    .get("candidatesTokenCount")
                    .or_else(|| u.get("total_output_tokens"))
                    .or_else(|| u.get("output_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.output_tokens = v;
                }
                if let Some(v) = u
                    .get("cachedContentTokenCount")
                    .or_else(|| u.get("total_cached_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.cached_input_tokens = v;
                }
                if let Some(v) = u
                    .get("thoughtsTokenCount")
                    .or_else(|| u.get("total_thought_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.reasoning_tokens = v;
                }
            }
        }
        ProviderDialect::CustomOpenAi => {
            if let Some(u) = val.get("usage") {
                merge_media_output_tokens(u, usage);
                if let Some(v) = u
                    .get("prompt_tokens")
                    .or_else(|| u.get("input_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.input_tokens = v;
                }
                if let Some(v) = u
                    .get("completion_tokens")
                    .or_else(|| u.get("output_tokens"))
                    .and_then(Value::as_u64)
                {
                    usage.output_tokens = v;
                }
            }
        }
    }
}

/// Returns `true` when `payload` is the dialect's end-of-reply marker.
pub fn is_terminal_event(dialect: ProviderDialect, payload: &str) -> bool {
    if payload.trim() == "[DONE]" {
        return true;
    }
    serde_json::from_str::<Value>(payload).is_ok_and(|val| is_terminal_frame(dialect, &val))
}

/// The same, on a frame already parsed once.
pub fn is_terminal_frame(dialect: ProviderDialect, val: &Value) -> bool {
    let chat_finished = || {
        val.get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("finish_reason"))
            .is_some_and(|f| !f.is_null())
    };
    match dialect {
        ProviderDialect::OpenAi => {
            matches!(
                val.get("type").and_then(Value::as_str),
                Some("response.completed" | "response.incomplete" | "response.failed" | "error")
            ) || chat_finished()
        }
        ProviderDialect::Anthropic => matches!(
            val.get("type").and_then(Value::as_str),
            Some("message_stop" | "error")
        ),
        ProviderDialect::GoogleGemini => {
            matches!(
                val.get("event_type").and_then(Value::as_str),
                Some("interaction.completed" | "error")
            ) || val
                .get("candidates")
                .and_then(|c| c.get(0))
                .and_then(|c| c.get("finishReason"))
                .is_some_and(|f| !f.is_null())
        }
        ProviderDialect::CustomOpenAi => chat_finished(),
    }
}
