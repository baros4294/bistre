//! Request bodies and headers for each API format (split out of `providers.rs`).

use crate::media_wire::PickWire;
use crate::providers::{StreamRequestOptions, WireRequest};
use crate::registry::Modality;
pub use crate::wire_parse::{
    extract_sse_delta, extract_sse_thinking_delta, is_terminal_event, merge_sse_usage,
    parse_models_payload,
};
pub use crate::wire_stream::StreamOutcome;
use bistre_protocol::{GenerationParams, NodeRecord, ProviderDialect, ReasoningEffort};
use reqwest::header::{ACCEPT, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;

pub(crate) fn milli_to_json_number(milli: u32) -> Value {
    let whole = milli / 1000;
    let frac = milli % 1000;
    let text = format!("{whole}.{frac:03}");
    serde_json::from_str::<Value>(&text).unwrap_or_else(|_| Value::from(whole))
}

pub(crate) fn stream_headers(
    dialect: ProviderDialect,
    options: &StreamRequestOptions<'_>,
) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));
    if dialect == ProviderDialect::Anthropic {
        headers.insert(
            "anthropic-version",
            HeaderValue::from_static(bistre_protocol::dialect::ANTHROPIC_API_VERSION),
        );
        if !options.anthropic_beta_headers.is_empty()
            && let Ok(val) = HeaderValue::from_str(&options.anthropic_beta_headers.join(","))
        {
            headers.insert("anthropic-beta", val);
        }
    }
    // Already validated at the boundary (`custom_headers::parse_custom_headers`): never a
    // reserved, credential, or malformed header.
    for h in &options.extra_headers {
        headers.insert(h.name().clone(), h.value().clone());
    }
    headers
}

/// Wraps a JSON body as a credential-free streaming POST. Bodies serialize with `tools` first
/// (when active) for deterministic prompt-cache prefix stability (Spec 02).
pub(crate) fn wire(
    dialect: ProviderDialect,
    url: String,
    mut body: Value,
    options: &StreamRequestOptions<'_>,
    fallback: Option<Box<WireRequest>>,
) -> WireRequest {
    if let (Some(extra), Some(obj)) = (&options.extra_body_fields, body.as_object_mut()) {
        for (k, v) in extra {
            if !matches!(k.as_str(), "stream" | "messages" | "input" | "contents") {
                obj.insert(k.clone(), v.clone());
            }
        }
    }
    WireRequest {
        dialect,
        method: reqwest::Method::POST,
        url,
        headers: stream_headers(dialect, options),
        body: Some(body),
        auth: options.auth_mode,
        fallback,
    }
}

/// Dialect-specific streaming request (credential-free).
pub fn build_stream_request(
    dialect: ProviderDialect,
    base: &str,
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    store: bool,
) -> WireRequest {
    build_stream_request_with_attachments(
        dialect,
        base,
        model,
        system_prompt,
        history,
        gen_params,
        store,
        None,
        &HashMap::new(),
    )
}

/// Dialect-specific streaming request (credential-free) with multimodal attachment blocks.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable parameters keep wire serialization pure and testable."
)]
pub fn build_stream_request_with_attachments<S: std::hash::BuildHasher>(
    dialect: ProviderDialect,
    base: &str,
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    store: bool,
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
) -> WireRequest {
    let opts = StreamRequestOptions::default();
    build_stream_request_full(
        dialect,
        base,
        model,
        system_prompt,
        history,
        gen_params,
        store,
        data_dir,
        gemini_uris,
        &opts,
    )
}

/// Full dialect-specific streaming request builder with replay context, tools, caching, and options.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable parameters keep wire serialization pure and testable."
)]
pub fn build_stream_request_full<S: std::hash::BuildHasher>(
    dialect: ProviderDialect,
    base: &str,
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    store: bool,
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
    options: &StreamRequestOptions<'_>,
) -> WireRequest {
    let base = dialect.api_root(base);
    let endpoint = format!(
        "{base}{}",
        options
            .endpoint_path
            .unwrap_or_else(|| dialect.default_endpoint_path())
    );
    match dialect {
        ProviderDialect::OpenAi => wire(
            dialect,
            endpoint,
            openai_responses_body(
                model,
                system_prompt,
                history,
                gen_params,
                store,
                data_dir,
                gemini_uris,
                options,
            ),
            options,
            None,
        ),
        ProviderDialect::GoogleGemini => {
            let clean_model = model.strip_prefix("models/").unwrap_or(model);
            let fallback = (!options.disable_legacy_fallback).then(|| {
                Box::new(wire(
                    dialect,
                    format!("{base}/v1beta/models/{clean_model}:streamGenerateContent?alt=sse"),
                    gemini_generate_content_body(
                        system_prompt,
                        history,
                        gen_params,
                        data_dir,
                        gemini_uris,
                        options,
                    ),
                    options,
                    None,
                ))
            });
            wire(
                dialect,
                endpoint,
                gemini_interactions_body(
                    model,
                    system_prompt,
                    history,
                    gen_params,
                    store,
                    data_dir,
                    gemini_uris,
                    options,
                ),
                options,
                fallback,
            )
        }
        ProviderDialect::Anthropic => wire(
            dialect,
            endpoint,
            anthropic_messages_body(
                model,
                system_prompt,
                history,
                gen_params,
                data_dir,
                gemini_uris,
                options,
            ),
            options,
            None,
        ),
        ProviderDialect::CustomOpenAi => wire(
            dialect,
            endpoint,
            openai_compat_chat_body(
                model,
                system_prompt,
                history,
                gen_params,
                data_dir,
                options,
                bistre_protocol::dialect::is_openrouter_base(base),
            ),
            options,
            None,
        ),
    }
}

/// How many history nodes a chained request leaves out (the server holds them).
pub(crate) const fn chain_skip(store: bool, options: &StreamRequestOptions<'_>) -> usize {
    if store && options.previous_server_id.is_some() {
        options.chain_first_new_index
    } else {
        0
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable parameters keep wire serialization pure and testable."
)]
pub(crate) fn openai_responses_body<S: std::hash::BuildHasher>(
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    store: bool,
    data_dir: Option<&Path>,
    remote_refs: &HashMap<String, String, S>,
    options: &StreamRequestOptions<'_>,
) -> Value {
    let mut input = crate::wire_history::build_openai_responses_input_with_refs(
        history,
        data_dir,
        remote_refs,
        options.replay_ctx,
        chain_skip(store, options),
    );
    // Newer models append top-level
    // `instructions` after `input`; a `developer` message first in `input` keeps the system
    // prompt inside the cached prefix.
    // A chained request already has it in the stored conversation (prompt-caching guide).
    let chained = store && options.previous_server_id.is_some();
    if !system_prompt.trim().is_empty() && !chained {
        input.insert(
            0,
            serde_json::json!({ "role": "developer", "content": system_prompt }),
        );
    }
    let mut obj = serde_json::Map::new();
    // Serialize `tools` FIRST for prompt-cache prefix stability (Spec 02).
    if let Some(tools) = options.tools_wire
        && !tools.is_empty()
    {
        let tools = crate::paid_tools::with_paid_tools(
            ProviderDialect::OpenAi,
            options.paid_tools,
            tools.to_vec(),
        );
        obj.insert("tools".to_owned(), Value::Array(tools));
    }
    obj.insert("model".to_owned(), Value::String(model.to_owned()));
    obj.insert("input".to_owned(), Value::Array(input));
    obj.insert("stream".to_owned(), Value::Bool(true));
    obj.insert("store".to_owned(), Value::Bool(store));
    if store && let Some(prev_id) = options.previous_server_id {
        obj.insert(
            "previous_response_id".to_owned(),
            Value::String(prev_id.to_owned()),
        );
    }
    if let Some(ctx) = options.replay_ctx {
        obj.insert(
            "prompt_cache_key".to_owned(),
            Value::String(ctx.openai_prompt_cache_key()),
        );
    }
    if let Some(t) = gen_params.temperature_milli {
        obj.insert("temperature".to_owned(), milli_to_json_number(t));
    }
    if let Some(max_tok) = gen_params.max_output_tokens {
        obj.insert("max_output_tokens".to_owned(), Value::from(max_tok));
    }
    if let Some(p) = gen_params.top_p_milli {
        obj.insert("top_p".to_owned(), milli_to_json_number(p));
    }
    if let Some(effort) = openai_effort(ProviderDialect::OpenAi, gen_params.reasoning_effort) {
        obj.insert(
            "reasoning".to_owned(),
            json!({ "effort": effort, "summary": "auto" }),
        );
    }
    // Under stateless `store: false`, request encrypted reasoning blobs when reasoning is enabled
    // so subsequent turns can replay verified thought continuity without server-side retention.
    if !store
        && !matches!(
            gen_params.reasoning_effort,
            ReasoningEffort::ModelDefault | ReasoningEffort::Off
        )
    {
        obj.insert("include".to_owned(), json!(["reasoning.encrypted_content"]));
    }
    Value::Object(obj)
}

/// `OpenAI` `reasoning.effort` / `reasoning_effort` value (`none` turns thinking off).
pub(crate) fn openai_effort(
    dialect: ProviderDialect,
    effort: ReasoningEffort,
) -> Option<&'static str> {
    match effort {
        ReasoningEffort::ModelDefault => None,
        ReasoningEffort::Adaptive => Some("medium"),
        ReasoningEffort::Off => Some("none"),
        ReasoningEffort::Max if dialect == ProviderDialect::OpenAi => Some("xhigh"),
        other => Some(other.as_str()),
    }
}

/// Gemini thinking level (lowercase; Gemini has no `max`, and Off asks for minimal thoughts).
pub(crate) fn gemini_level(effort: ReasoningEffort) -> Option<&'static str> {
    match effort {
        ReasoningEffort::ModelDefault => None,
        ReasoningEffort::Off => Some("minimal"),
        ReasoningEffort::Low => Some("low"),
        ReasoningEffort::Adaptive | ReasoningEffort::Medium => Some("medium"),
        ReasoningEffort::High => Some("high"),
        ReasoningEffort::ExtraHigh | ReasoningEffort::Max => Some("xhigh"),
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable parameters keep wire serialization pure and testable."
)]
pub(crate) fn gemini_interactions_body<S: std::hash::BuildHasher>(
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    store: bool,
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
    options: &StreamRequestOptions<'_>,
) -> Value {
    let turns = crate::wire_history::build_gemini_interactions_input_with_ctx(
        history,
        data_dir,
        gemini_uris,
        options.replay_ctx,
        chain_skip(store, options),
    );
    let mut obj = serde_json::Map::new();
    if let Some(tools) = options.tools_wire
        && !tools.is_empty()
    {
        let mut all = tools.to_vec();
        if options.provider_tools {
            all.extend(provider_tools(ProviderDialect::GoogleGemini));
        }
        obj.insert("tools".to_owned(), Value::Array(all));
    }
    obj.insert("model".to_owned(), Value::String(model.to_owned()));
    if !system_prompt.trim().is_empty() {
        obj.insert(
            "system_instruction".to_owned(),
            Value::String(system_prompt.to_owned()),
        );
    }
    obj.insert("input".to_owned(), Value::Array(turns));
    obj.insert("stream".to_owned(), Value::Bool(true));
    obj.insert("store".to_owned(), Value::Bool(store));
    if store && let Some(prev_id) = options.previous_server_id {
        obj.insert(
            "previous_interaction_id".to_owned(),
            Value::String(prev_id.to_owned()),
        );
    }
    let mut gen_cfg = serde_json::Map::new();
    if let Some(t) = gen_params.temperature_milli {
        gen_cfg.insert("temperature".to_owned(), milli_to_json_number(t));
    }
    if let Some(max_tok) = gen_params.max_output_tokens {
        gen_cfg.insert("max_output_tokens".to_owned(), Value::from(max_tok));
    }
    if let Some(p) = gen_params.top_p_milli {
        gen_cfg.insert("top_p".to_owned(), milli_to_json_number(p));
    }
    if let Some(level) = gemini_level(gen_params.reasoning_effort) {
        gen_cfg.insert("thinking_level".to_owned(), Value::from(level));
        let summaries = if gen_params.reasoning_effort == ReasoningEffort::Off {
            "none"
        } else {
            "auto"
        };
        gen_cfg.insert("thinking_summaries".to_owned(), Value::from(summaries));
    }
    if !gen_cfg.is_empty() {
        obj.insert("generation_config".to_owned(), Value::Object(gen_cfg));
    }
    let mut body = Value::Object(obj);
    if options.media_out.contains(Modality::Image) {
        options.media_pick.apply(PickWire::GeminiImage, &mut body);
    }
    body
}

pub(crate) fn gemini_generate_content_body<S: std::hash::BuildHasher>(
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    data_dir: Option<&Path>,
    gemini_uris: &HashMap<String, String, S>,
    options: &StreamRequestOptions<'_>,
) -> Value {
    let contents = crate::wire_history::build_gemini_generate_contents_with_ctx(
        history,
        data_dir,
        gemini_uris,
        options.replay_ctx,
    );
    let mut obj = serde_json::Map::new();
    if let Some(tools) = options.tools_wire
        && !tools.is_empty()
    {
        let decls: Vec<Value> = tools
            .iter()
            .filter_map(|t| {
                let name = t.get("name")?.as_str()?;
                let description = t
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let parameters = t
                    .get("parameters")
                    .cloned()
                    .unwrap_or_else(|| json!({ "type": "object", "properties": {} }));
                Some(json!({
                    "name": name,
                    "description": description,
                    "parameters": parameters,
                }))
            })
            .collect();
        if !decls.is_empty() {
            obj.insert(
                "tools".to_owned(),
                json!([{ "functionDeclarations": decls }]),
            );
        }
    }
    if !system_prompt.trim().is_empty() {
        obj.insert(
            "systemInstruction".to_owned(),
            json!({ "parts": [{ "text": system_prompt }] }),
        );
    }
    obj.insert("contents".to_owned(), Value::Array(contents));
    let mut gen_cfg = serde_json::Map::new();
    if let Some(t) = gen_params.temperature_milli {
        gen_cfg.insert("temperature".to_owned(), milli_to_json_number(t));
    }
    if let Some(max_tok) = gen_params.max_output_tokens {
        gen_cfg.insert("maxOutputTokens".to_owned(), Value::from(max_tok));
    }
    if let Some(p) = gen_params.top_p_milli {
        gen_cfg.insert("topP".to_owned(), milli_to_json_number(p));
    }
    if let Some(level) = gemini_level(gen_params.reasoning_effort) {
        gen_cfg.insert(
            "thinkingConfig".to_owned(),
            json!({
                "includeThoughts": gen_params.reasoning_effort != ReasoningEffort::Off,
                "thinkingLevel": level.to_ascii_uppercase(),
            }),
        );
    }
    if !gen_cfg.is_empty() {
        obj.insert("generationConfig".to_owned(), Value::Object(gen_cfg));
    }
    let mut body = Value::Object(obj);
    if options.media_out.contains(Modality::Image) {
        options
            .media_pick
            .apply(PickWire::GeminiContentImage, &mut body);
    }
    body
}

/// Anthropic's link reader and code runner (wire-protocol versions). With this `web_fetch`
/// version in the request, code execution has no charge beyond tokens.
const ANTHROPIC_WEB_FETCH: &str = "web_fetch_20260318";
const ANTHROPIC_CODE_EXECUTION: &str = "code_execution_20260521";

/// Most links Anthropic's `web_fetch` reads in one request, and the most tokens each one
/// adds.
const MAX_PROVIDER_FETCHES: u32 = 5;
const MAX_PROVIDER_FETCH_TOKENS: u32 = 20_000;

/// The provider's own tools that cost nothing beyond tokens, for the dialects that have
/// them: Gemini Interactions reads links and runs Python; Anthropic Messages fetches links
/// and runs code. A provider or model that rejects them gets them stripped by the HTTP 400
/// heal (`Http400Heal::StripBuiltinTools`), and Bistre's own `web_fetch` and `web_search`
/// cover every other provider.
fn provider_tools(dialect: ProviderDialect) -> Vec<Value> {
    match dialect {
        ProviderDialect::GoogleGemini => vec![
            json!({ "type": "url_context" }),
            json!({ "type": "code_execution" }),
        ],
        ProviderDialect::Anthropic => vec![
            json!({
                "type": ANTHROPIC_WEB_FETCH,
                "name": "web_fetch",
                "max_uses": MAX_PROVIDER_FETCHES,
                "max_content_tokens": MAX_PROVIDER_FETCH_TOKENS,
            }),
            json!({ "type": ANTHROPIC_CODE_EXECUTION, "name": "code_execution" }),
        ],
        _ => Vec::new(),
    }
}

pub(crate) fn anthropic_cache_control(cache_1h: bool) -> Value {
    if cache_1h {
        json!({ "type": "ephemeral", "ttl": "1h" })
    } else {
        json!({ "type": "ephemeral" })
    }
}

pub(crate) fn anthropic_messages_body<S: std::hash::BuildHasher>(
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    data_dir: Option<&Path>,
    remote_refs: &HashMap<String, String, S>,
    options: &StreamRequestOptions<'_>,
) -> Value {
    let mut messages = crate::wire_history::build_anthropic_messages_with_refs(
        history,
        data_dir,
        remote_refs,
        options.replay_ctx,
    );
    if let Some(prefill) = options.reply_prefill.as_deref().map(str::trim)
        && !prefill.is_empty()
    {
        messages.push(json!({ "role": "assistant", "content": prefill }));
    }
    let thinking_active = !matches!(
        gen_params.reasoning_effort,
        ReasoningEffort::ModelDefault | ReasoningEffort::Off
    );
    let default_max_tokens = if thinking_active { 16_384 } else { 4_096 };
    let max_tokens = gen_params.max_output_tokens.unwrap_or(default_max_tokens);
    let cc = anthropic_cache_control(options.anthropic_cache_1h);

    let mut obj = serde_json::Map::new();
    if let Some(tools) = options.tools_wire
        && !tools.is_empty()
    {
        // The provider's `web_fetch` takes the name of Bistre's, which a request may hold
        // once; its tools go first so the cache mark stays on the last of Bistre's.
        let mut t_arr = if options.provider_tools {
            provider_tools(ProviderDialect::Anthropic)
        } else {
            Vec::new()
        };
        t_arr.extend(crate::paid_tools::with_paid_tools(
            ProviderDialect::Anthropic,
            options.paid_tools,
            tools
                .iter()
                .filter(|t| {
                    !options.provider_tools
                        || t.get("name").and_then(Value::as_str) != Some("web_fetch")
                })
                .cloned()
                .collect(),
        ));
        if let Some(last) = t_arr.last_mut().and_then(Value::as_object_mut) {
            last.insert("cache_control".to_owned(), cc.clone());
        }
        obj.insert("tools".to_owned(), Value::Array(t_arr));
    }
    obj.insert("model".to_owned(), Value::String(model.to_owned()));
    obj.insert("max_tokens".to_owned(), Value::from(max_tokens));
    // Default 5-minute ephemeral prompt caching (1.25x write / 0.1x read); automatically
    // stripped by `Http400Heal::StripPromptCacheControl` if a proxy rejects `cache_control`.
    obj.insert("cache_control".to_owned(), cc.clone());
    if !system_prompt.trim().is_empty() {
        obj.insert(
            "system".to_owned(),
            json!([{
                "type": "text",
                "text": system_prompt,
                "cache_control": cc,
            }]),
        );
    }
    obj.insert("messages".to_owned(), Value::Array(messages));
    obj.insert("stream".to_owned(), Value::Bool(true));
    if options.anthropic_server_compaction
        && history.len() >= 8
        && history
            .iter()
            .any(|n| n.role == bistre_protocol::NodeRole::Tool)
    {
        obj.insert(
            "context_management".to_owned(),
            json!({
                "edits": [
                    { "type": "clear_tool_uses_20250919" }
                ]
            }),
        );
    }
    if let Some(t) = gen_params.temperature_milli {
        obj.insert("temperature".to_owned(), milli_to_json_number(t));
    }
    if let Some(p) = gen_params.top_p_milli {
        obj.insert("top_p".to_owned(), milli_to_json_number(p));
    }
    match gen_params.reasoning_effort {
        ReasoningEffort::ModelDefault => {}
        ReasoningEffort::Off => {
            obj.insert("thinking".to_owned(), json!({ "type": "disabled" }));
        }
        ReasoningEffort::Adaptive => {
            obj.insert(
                "thinking".to_owned(),
                json!({ "type": "adaptive", "display": "summarized" }),
            );
        }
        effort => {
            obj.insert(
                "thinking".to_owned(),
                json!({ "type": "adaptive", "display": "summarized" }),
            );
            obj.insert(
                "output_config".to_owned(),
                json!({ "effort": effort.as_str() }),
            );
        }
    }
    Value::Object(obj)
}

/// `OpenRouter` routing preference sent on every `OpenRouter` request: only providers that do
/// not collect user data (local-first privacy default; `extra_body_fields` can override it).
fn openrouter_privacy_preference() -> Value {
    json!({ "data_collection": "deny" })
}

/// An `OpenAI`-compatible Chat Completions body; `openrouter` adds the `OpenRouter`-only fields
/// (`provider` and replayed `reasoning_details`), which no other target ever gets.
pub(crate) fn openai_compat_chat_body(
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    data_dir: Option<&Path>,
    options: &StreamRequestOptions<'_>,
    openrouter: bool,
) -> Value {
    let mut messages = Vec::new();
    if !system_prompt.trim().is_empty() {
        messages.push(json!({ "role": "system", "content": system_prompt }));
    }
    messages.extend(crate::wire_history::build_openai_compat_messages_with_ctx(
        history,
        data_dir,
        options.replay_ctx,
        openrouter,
        options.reads,
    ));
    if let Some(prefill) = options.reply_prefill.as_deref().map(str::trim)
        && !prefill.is_empty()
    {
        messages.push(json!({ "role": "assistant", "content": prefill }));
    }
    let mut obj = serde_json::Map::new();
    if let Some(tools) = options.tools_wire
        && !tools.is_empty()
    {
        obj.insert("tools".to_owned(), Value::Array(tools.to_vec()));
    }
    obj.insert("model".to_owned(), Value::String(model.to_owned()));
    obj.insert("messages".to_owned(), Value::Array(messages));
    obj.insert("stream".to_owned(), Value::Bool(true));
    obj.insert(
        "stream_options".to_owned(),
        json!({ "include_usage": true }),
    );
    if openrouter {
        obj.insert("provider".to_owned(), openrouter_privacy_preference());
    }
    for (key, value) in
        crate::media_wire::chat_output_fields(options.media_out, true, options.voice)
    {
        obj.insert(key.to_owned(), value);
    }
    if let Some(effort) = openai_effort(ProviderDialect::CustomOpenAi, gen_params.reasoning_effort)
    {
        obj.insert("reasoning_effort".to_owned(), Value::from(effort));
    }
    if let Some(t) = gen_params.temperature_milli {
        obj.insert("temperature".to_owned(), milli_to_json_number(t));
    }
    if let Some(max_tok) = gen_params.max_output_tokens {
        obj.insert("max_tokens".to_owned(), Value::from(max_tok));
    }
    if let Some(p) = gen_params.top_p_milli {
        obj.insert("top_p".to_owned(), milli_to_json_number(p));
    }
    let mut body = Value::Object(obj);
    if openrouter && options.media_out.contains(Modality::Image) {
        options.media_pick.apply(PickWire::ChatImage, &mut body);
    }
    body
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(dialect: ProviderDialect, base: &str) -> Value {
        let history = crate::test_support::user_turn("hi");
        build_stream_request(
            dialect,
            base,
            "m",
            "",
            &history,
            GenerationParams::default(),
            false,
        )
        .body
        .unwrap_or(Value::Null)
    }

    /// `OpenRouter` requests ask for providers that keep no data; no other provider ever gets
    /// the `OpenRouter`-only `provider` field.
    #[test]
    fn openrouter_only_fields_go_to_openrouter_only() {
        let or = body(
            ProviderDialect::CustomOpenAi,
            "https://openrouter.ai/api/v1",
        );
        assert_eq!(or["provider"], json!({ "data_collection": "deny" }));
        for other in ["https://api.example.com/v1", "http://127.0.0.1:11434/v1"] {
            let b = body(ProviderDialect::CustomOpenAi, other);
            assert!(b.get("provider").is_none(), "{other}: {b}");
        }
        let native = body(ProviderDialect::OpenAi, "https://openrouter.ai/api/v1");
        assert!(native.get("provider").is_none());
    }

    /// A chat model that draws gets the chat's picture settings in its dialect's fields;
    /// a text-only reply asks for none.
    #[test]
    fn picture_settings_reach_chat_requests_for_models_that_draw() {
        let history = crate::test_support::user_turn("a fox");
        let options = StreamRequestOptions {
            media_out: crate::registry::ModalitySet::of(&[Modality::Text, Modality::Image]),
            media_pick: crate::media_wire::MediaPick {
                aspect_ratio: Some("16:9".to_owned()),
                resolution: Some("2K".to_owned()),
                duration_s: None,
            },
            ..StreamRequestOptions::default()
        };
        let send = |dialect, base: &str, options: &StreamRequestOptions<'_>| {
            build_stream_request_full(
                dialect,
                base,
                "m",
                "",
                &history,
                GenerationParams::default(),
                false,
                None,
                &HashMap::<String, String>::new(),
                options,
            )
            .body
            .unwrap_or(Value::Null)
        };
        let or = send(
            ProviderDialect::CustomOpenAi,
            "https://openrouter.ai/api/v1",
            &options,
        );
        assert_eq!(
            or["image_config"],
            json!({"aspect_ratio": "16:9", "image_size": "2K"})
        );
        let gemini = send(
            ProviderDialect::GoogleGemini,
            "https://generativelanguage.googleapis.com",
            &options,
        );
        assert_eq!(
            gemini["response_format"],
            json!({"type": "image", "aspect_ratio": "16:9", "image_size": "2K"})
        );
        let other = send(
            ProviderDialect::CustomOpenAi,
            "https://api.example.com/v1",
            &options,
        );
        assert!(other.get("image_config").is_none(), "{other}");
        let text_only = StreamRequestOptions {
            media_out: crate::registry::ModalitySet::default(),
            ..options
        };
        let plain = send(
            ProviderDialect::GoogleGemini,
            "https://generativelanguage.googleapis.com",
            &text_only,
        );
        assert!(plain.get("response_format").is_none(), "{plain}");
    }

    fn tool_body(dialect: ProviderDialect, provider_tools: bool) -> Value {
        let history = crate::test_support::user_turn("read https://example.com");
        let local = vec![
            json!({"name": "web_fetch", "description": "d", "input_schema": {"type": "object"}}),
            json!({"name": "web_search", "description": "d", "input_schema": {"type": "object"}}),
        ];
        let options = StreamRequestOptions {
            tools_wire: Some(&local),
            provider_tools,
            ..StreamRequestOptions::default()
        };
        let base = match dialect {
            ProviderDialect::GoogleGemini => "https://generativelanguage.googleapis.com",
            _ => "https://api.anthropic.com",
        };
        build_stream_request_full(
            dialect,
            base,
            "m",
            "",
            &history,
            GenerationParams::default(),
            false,
            None,
            &HashMap::<String, String>::new(),
            &options,
        )
        .body
        .unwrap_or(Value::Null)
    }

    fn tool_ids(body: &Value) -> Vec<String> {
        body["tools"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|t| {
                t.get("name")
                    .and_then(Value::as_str)
                    .map_or_else(|| t["type"].to_string(), |n| format!("{}:{n}", t["type"]))
            })
            .collect()
    }

    /// Gemini gets its link reader and code runner beside Bistre's tools; Anthropic's
    /// `web_fetch` takes the place of Bistre's (a name is used once), and the cache mark
    /// stays on Bistre's last tool. Off, or for any other dialect, nothing is added.
    #[test]
    fn provider_tools_join_bistre_tools_only_where_free_and_turned_on() {
        let gemini = tool_body(ProviderDialect::GoogleGemini, true);
        let ids = tool_ids(&gemini);
        assert!(ids.contains(&"\"url_context\"".to_owned()), "{ids:?}");
        assert!(ids.contains(&"\"code_execution\"".to_owned()), "{ids:?}");
        assert_eq!(ids.len(), 4, "Bistre's two tools stay: {ids:?}");

        let anthropic = tool_body(ProviderDialect::Anthropic, true);
        assert_eq!(
            tool_ids(&anthropic),
            [
                format!("\"{ANTHROPIC_WEB_FETCH}\":web_fetch"),
                format!("\"{ANTHROPIC_CODE_EXECUTION}\":code_execution"),
                "null:web_search".to_owned(),
            ]
        );
        assert_eq!(
            anthropic["tools"][0]["max_uses"],
            json!(MAX_PROVIDER_FETCHES)
        );
        assert!(anthropic["tools"][2].get("cache_control").is_some());

        for dialect in [ProviderDialect::GoogleGemini, ProviderDialect::Anthropic] {
            assert_eq!(tool_ids(&tool_body(dialect, false)).len(), 2, "{dialect:?}");
        }
        assert_eq!(provider_tools(ProviderDialect::OpenAi), Vec::<Value>::new());
        assert_eq!(
            provider_tools(ProviderDialect::CustomOpenAi),
            Vec::<Value>::new()
        );
    }

    /// A provider or model that rejects them loses only the provider's tools.
    #[test]
    fn the_400_heal_strips_provider_tools_and_keeps_bistres() {
        for dialect in [ProviderDialect::GoogleGemini, ProviderDialect::Anthropic] {
            let mut body = tool_body(dialect, true);
            assert!(crate::error_policy::Http400Heal::StripBuiltinTools.apply(&mut body));
            let ids = tool_ids(&body);
            assert!(
                ids.iter()
                    .all(|id| id.contains("web_search") || id.contains("web_fetch")),
                "{dialect:?}: {ids:?}"
            );
            assert!(
                !ids.iter().any(|id| id.contains("code_execution")),
                "{ids:?}"
            );
        }
    }
}
