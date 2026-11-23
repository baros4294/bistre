//! Pure-Rust HTTP & SSE provider wire adapters for Bistre (Spec 02 & Spec 03).
//!
//! Strictly implements the Big 3 + Custom `OpenAI`-Compatible dialects:
//! - `OpenAI` Responses API (`/v1/responses`, `store: false` stateless default)
//! - Google Gemini Interactions API (`/v1beta/interactions`, transparent `streamGenerateContent` downgrade)
//! - Anthropic Messages API (`/v1/messages`, stateless default)
//! - Custom `OpenAI`-Compatible (`/chat/completions` + `/models`)
//!
//! Every request goes through ONE dispatch path ([`dispatch`]): round-robin key rotation with
//! instant `401`/`403`/`429` failover, the ordered HTTP 400 heal ladder, the Gemini downgrade,
//! and typed failure classification with server retry hints (`error_policy`).

use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, GenerationParams, MoneyMicros, NodeRecord, NodeRole,
    ProviderDialect, ProviderModelInfo, ProviderProfile, UsageMetrics,
};
use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};

use crate::credentials::{KeyRing, is_key_failover_status};
use crate::error_policy::{
    FailureKind, MAX_ERROR_BODY_SCAN_BYTES, MAX_HTTP_400_HEALS, apply_next_heal,
    classify_http_failure, failure_error, parse_retry_hint,
};
use crate::registry::ModelRates;
use crate::sse::{INITIAL_LINE_TIMEOUT, STREAMING_LINE_TIMEOUT, SseFramer, StreamingTextBuffer};

/// Completed SSE stream payload paired with thinking trace, cancellation flag, and exact usage.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StreamOutcome {
    pub full_text: String,
    pub thinking_text: String,
    pub thinking_duration_ms: i64,
    pub cancelled: bool,
    /// The stream ended without the dialect's terminal event after partial output.
    pub interrupted: bool,
    pub usage: UsageMetrics,
    /// Non-fatal notices raised while dispatching (heals, key failover), as `(key, detail)`.
    pub notices: Vec<(DiagnosticKey, String)>,
}

/// Discovered local loopback inference server (`$0` priority, Spec 03).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct LocalServerDiscovery {
    pub kind: String,
    pub name: String,
    pub base_url: String,
    pub models: Vec<String>,
}

/// Exact integer micro-USD cost from live registry rates (zero floats, zero hardcoded rates).
/// Loopback inference is free; an unpriced model is `None` (unknown, never guessed).
pub fn estimate_cost_micros(
    provider: &ProviderProfile,
    rates: Option<ModelRates>,
    usage: &UsageMetrics,
) -> Option<MoneyMicros> {
    if crate::net::is_loopback_url(&provider.base_url)
        || (usage.input_tokens == 0 && usage.output_tokens == 0)
    {
        return Some(MoneyMicros::ZERO);
    }
    rates.map(|r| {
        r.cost(
            usage.input_tokens,
            usage.cached_input_tokens,
            usage.output_tokens,
        )
    })
}

static CRYPTO_PROVIDER_INIT: OnceLock<()> = OnceLock::new();

/// Ensures the `rustls` `ring` crypto provider is installed once before constructing `reqwest::Client`.
pub fn ensure_tls_provider() {
    CRYPTO_PROVIDER_INIT.get_or_init(|| {
        // `Err` only means another provider was installed first, which is equally valid.
        if rustls::crypto::ring::default_provider()
            .install_default()
            .is_err()
        {
            tracing::debug!("rustls crypto provider already installed");
        }
    });
}

/// Builds the shared provider `reqwest::Client` (see [`crate::http_clients::provider_client`]).
pub fn build_http_client() -> BistreResult<reqwest::Client> {
    crate::http_clients::provider_client()
}

/// One credential-free outbound request; auth is attached per attempt by [`dispatch`].
#[derive(Debug, Clone)]
pub struct WireRequest {
    pub dialect: ProviderDialect,
    pub method: reqwest::Method,
    pub url: String,
    pub headers: HeaderMap,
    pub body: Option<Value>,
    /// Downgrade request sent once when the primary answers `400`/`404` (Gemini Interactions).
    pub fallback: Option<Box<WireRequest>>,
}

fn attach_key(headers: &mut HeaderMap, dialect: ProviderDialect, key: &str) -> BistreResult<()> {
    let invalid = |_| BistreError::with_detail(DiagnosticKey::InvalidInput, "api_key_header");
    match dialect {
        ProviderDialect::OpenAi | ProviderDialect::CustomOpenAi => {
            headers.insert(
                AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {key}")).map_err(invalid)?,
            );
        }
        ProviderDialect::GoogleGemini => {
            headers.insert(
                "x-goog-api-key",
                HeaderValue::from_str(key).map_err(invalid)?,
            );
        }
        ProviderDialect::Anthropic => {
            headers.insert("x-api-key", HeaderValue::from_str(key).map_err(invalid)?);
        }
    }
    Ok(())
}

async fn read_error_body(mut resp: reqwest::Response) -> String {
    let mut buf = Vec::new();
    while buf.len() < MAX_ERROR_BODY_SCAN_BYTES {
        match resp.chunk().await {
            Ok(Some(chunk)) => buf.extend_from_slice(&chunk),
            Ok(None) | Err(_) => break,
        }
    }
    buf.truncate(MAX_ERROR_BODY_SCAN_BYTES);
    String::from_utf8_lossy(&buf).into_owned()
}

/// The single provider dispatch path: key rotation + failover, heal ladder, downgrade, and
/// typed failures carrying server retry hints. Notices are appended for the UI.
pub async fn dispatch(
    client: &reqwest::Client,
    mut wire: WireRequest,
    keys: &KeyRing,
    notices: &mut Vec<(DiagnosticKey, String)>,
) -> BistreResult<reqwest::Response> {
    let order = keys.rotation();
    let mut key_idx = 0_usize;
    let mut heal_cursor = 0_usize;
    let mut heals = 0_usize;
    loop {
        let mut headers = wire.headers.clone();
        if let Some(key) = order.get(key_idx) {
            attach_key(&mut headers, wire.dialect, key)?;
        }
        let mut req = client
            .request(wire.method.clone(), &wire.url)
            .headers(headers);
        if let Some(body) = &wire.body {
            req = req.json(body);
        }
        let resp = req.send().await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "connect")
        })?;
        let status = resp.status().as_u16();
        if resp.status().is_success() {
            check_captive_portal(&resp)?;
            return Ok(resp);
        }
        if is_key_failover_status(status) && key_idx + 1 < order.len() {
            key_idx += 1;
            notices.push((
                DiagnosticKey::ProviderAuthFailed,
                format!("key_failover_{}_of_{}", key_idx + 1, order.len()),
            ));
            continue;
        }
        if matches!(status, 400 | 404)
            && let Some(fallback) = wire.fallback.take()
        {
            wire = *fallback;
            heal_cursor = 0;
            continue;
        }
        let resp_headers = resp.headers().clone();
        let body_text = read_error_body(resp).await;
        let kind = classify_http_failure(status, &body_text);
        if status == 400
            && kind == FailureKind::BadRequest
            && heals < MAX_HTTP_400_HEALS
            && let Some(body) = wire.body.as_mut()
            && let Some(heal) = apply_next_heal(body, &mut heal_cursor)
        {
            heals += 1;
            notices.push((DiagnosticKey::ProviderRequestHealed, heal.code().to_owned()));
            continue;
        }
        return Err(failure_error(
            kind,
            status,
            parse_retry_hint(&resp_headers, &body_text, SystemTime::now()),
        ));
    }
}

/// Fetches live models directly from the configured provider endpoint (zero hardcoded model tables),
/// rotating keys with instant failover exactly like chat requests.
pub async fn fetch_models(
    client: &reqwest::Client,
    provider: &ProviderProfile,
    keys: &KeyRing,
) -> BistreResult<Vec<ProviderModelInfo>> {
    if provider.dialect.requires_api_key() && keys.is_empty() {
        return Err(BistreError::new(DiagnosticKey::ProviderNotConfigured));
    }
    let base = provider.base_url.trim_end_matches('/');
    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
    let url = match provider.dialect {
        ProviderDialect::OpenAi | ProviderDialect::CustomOpenAi => format!("{base}/models"),
        ProviderDialect::GoogleGemini => format!("{base}/v1beta/models"),
        ProviderDialect::Anthropic => {
            headers.insert("anthropic-version", HeaderValue::from_static("2023-06-01"));
            format!("{base}/models")
        }
    };
    let wire = WireRequest {
        dialect: provider.dialect,
        method: reqwest::Method::GET,
        url,
        headers,
        body: None,
        fallback: None,
    };
    let mut notices = Vec::new();
    let resp = dispatch(client, wire, keys, &mut notices).await?;
    let body: Value = resp.json().await.map_err(|_| {
        BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "json_decode")
    })?;
    Ok(parse_models_payload(provider.dialect, &body))
}

/// Streams a real completion from one of the Big 3 + Custom dialects, invoking `on_delta`
/// for each text chunk, applying `GenerationParams`, and capturing exact token usage.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable parameters avoid hidden global state in pure transport layer."
)]
pub async fn stream_completion<F>(
    client: &reqwest::Client,
    provider: &ProviderProfile,
    keys: &KeyRing,
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    stateless_default: bool,
    cancel_flag: &AtomicBool,
    on_delta: F,
) -> BistreResult<StreamOutcome>
where
    F: FnMut(&str) + Send,
{
    stream_completion_with_thinking(
        client,
        provider,
        keys,
        model,
        system_prompt,
        history,
        gen_params,
        stateless_default,
        cancel_flag,
        on_delta,
        |_| {},
    )
    .await
}

/// Mutable accumulator for one streamed reply.
#[derive(Debug, Default)]
struct StreamState {
    out: StreamOutcome,
    text_norm: StreamingTextBuffer,
    thinking_started: Option<std::time::Instant>,
    terminal_seen: bool,
}

impl StreamState {
    fn handle_payload<F, T>(
        &mut self,
        dialect: ProviderDialect,
        payload: &str,
        on_delta: &mut F,
        on_thinking: &mut T,
    ) where
        F: FnMut(&str) + Send,
        T: FnMut(&str) + Send,
    {
        if is_terminal_event(dialect, payload) {
            self.terminal_seen = true;
        }
        if payload == "[DONE]" {
            return;
        }
        merge_sse_usage(dialect, payload, &mut self.out.usage);
        if let Some(thought) = extract_sse_thinking_delta(dialect, payload)
            && !thought.is_empty()
        {
            let start = *self
                .thinking_started
                .get_or_insert_with(std::time::Instant::now);
            self.out.thinking_duration_ms = i64::try_from(start.elapsed().as_millis()).unwrap_or(0);
            self.out.thinking_text.push_str(&thought);
            on_thinking(&thought);
        }
        if let Some(delta) = extract_sse_delta(dialect, payload) {
            let clean = self.text_norm.push(&delta);
            if !clean.is_empty() {
                self.out.full_text.push_str(&clean);
                on_delta(&clean);
            }
        }
    }
}

/// Streams a real completion across all Big 3 + Custom dialects with separate `on_delta` and
/// `on_thinking` callbacks. A stream that ends without the dialect's terminal event is
/// `ProviderStreamInterrupted` (an error when nothing arrived, `interrupted` otherwise) — never
/// a silently "complete" truncation.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable parameters avoid hidden global state in pure transport layer."
)]
pub async fn stream_completion_with_thinking<F, T>(
    client: &reqwest::Client,
    provider: &ProviderProfile,
    keys: &KeyRing,
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    stateless_default: bool,
    cancel_flag: &AtomicBool,
    mut on_delta: F,
    mut on_thinking: T,
) -> BistreResult<StreamOutcome>
where
    F: FnMut(&str) + Send,
    T: FnMut(&str) + Send,
{
    let clean_model = model.trim();
    if clean_model.is_empty() {
        return Err(BistreError::new(DiagnosticKey::ProviderModelRequired));
    }
    if provider.dialect.requires_api_key() && keys.is_empty() {
        return Err(BistreError::new(DiagnosticKey::ProviderNotConfigured));
    }

    let store_server_state = !stateless_default && provider.use_server_state_cache;
    let base = provider.base_url.trim_end_matches('/');
    let wire = build_stream_request(
        provider.dialect,
        base,
        clean_model,
        system_prompt,
        history,
        gen_params,
        store_server_state,
    );
    let mut state = StreamState::default();
    let mut resp = dispatch(client, wire, keys, &mut state.out.notices).await?;

    let mut sse = SseFramer::new();
    let mut received_any = false;
    loop {
        if cancel_flag.load(Ordering::SeqCst) {
            state.out.cancelled = true;
            break;
        }
        let idle = if received_any {
            STREAMING_LINE_TIMEOUT
        } else {
            INITIAL_LINE_TIMEOUT
        };
        let next_chunk = match tokio::time::timeout(idle, resp.chunk()).await {
            Ok(Ok(chunk)) => chunk,
            failure => {
                let detail = if failure.is_err() {
                    "idle_timeout"
                } else {
                    "stream_io"
                };
                // Once any output reached the user the request is paid and visible: keep it and
                // mark the reply interrupted. Only a stream that produced nothing may be retried.
                if crate::error_policy::may_retry_stream(&state.out.full_text, 0)
                    && state.out.thinking_text.is_empty()
                {
                    return Err(BistreError::with_detail(
                        DiagnosticKey::ProviderStreamInterrupted,
                        detail,
                    ));
                }
                state.out.interrupted = true;
                break;
            }
        };
        let Some(bytes) = next_chunk else {
            break;
        };
        received_any = true;
        if cancel_flag.load(Ordering::SeqCst) {
            state.out.cancelled = true;
            break;
        }
        for payload in sse.push_bytes(&bytes)? {
            state.handle_payload(provider.dialect, &payload, &mut on_delta, &mut on_thinking);
        }
    }
    for payload in sse.finish() {
        state.handle_payload(provider.dialect, &payload, &mut on_delta, &mut on_thinking);
    }
    let tail = state.text_norm.finish();
    if !tail.is_empty() {
        state.out.full_text.push_str(&tail);
        on_delta(&tail);
    }

    if !state.out.cancelled && !state.terminal_seen {
        if state.out.full_text.is_empty() && state.out.thinking_text.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::ProviderStreamInterrupted,
                "eof_before_output",
            ));
        }
        state.out.interrupted = true;
    }
    Ok(state.out)
}

/// Probes common local inference servers (Ollama, LM Studio, `llama.cpp`, `KoboldCPP`) on loopback (`$0` priority).
pub async fn discover_local_servers() -> Vec<LocalServerDiscovery> {
    let Ok(fast_http) = crate::http_clients::loopback_client(
        Duration::from_millis(350),
        Duration::from_millis(800),
    ) else {
        return Vec::new();
    };

    let targets: [(&str, &str, &str, &str); 4] = [
        (
            "ollama",
            "Ollama (Local)",
            "http://127.0.0.1:11434/v1",
            "http://127.0.0.1:11434/api/tags",
        ),
        (
            "lmstudio",
            "LM Studio (Local)",
            "http://127.0.0.1:1234/v1",
            "http://127.0.0.1:1234/v1/models",
        ),
        (
            "llamacpp",
            "llama.cpp (Local)",
            "http://127.0.0.1:8080/v1",
            "http://127.0.0.1:8080/v1/models",
        ),
        (
            "koboldcpp",
            "KoboldCPP (Local)",
            "http://127.0.0.1:5001/v1",
            "http://127.0.0.1:5001/v1/models",
        ),
    ];

    let mut found = Vec::new();
    for (kind, name, base_url, probe_url) in targets {
        if let Ok(resp) = fast_http.get(probe_url).send().await
            && resp.status().is_success()
            && let Ok(body) = resp.json::<Value>().await
        {
            let models = parse_models_payload(ProviderDialect::CustomOpenAi, &body)
                .into_iter()
                .map(|m| m.id)
                .collect();
            found.push(LocalServerDiscovery {
                kind: kind.to_owned(),
                name: name.to_owned(),
                base_url: base_url.to_owned(),
                models,
            });
        }
    }
    found
}

fn milli_to_json_number(milli: u32) -> Value {
    let whole = milli / 1000;
    let frac = milli % 1000;
    let text = format!("{whole}.{frac:03}");
    serde_json::from_str::<Value>(&text).unwrap_or_else(|_| Value::from(whole))
}

fn stream_headers(dialect: ProviderDialect) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));
    if dialect == ProviderDialect::Anthropic {
        headers.insert("anthropic-version", HeaderValue::from_static("2023-06-01"));
    }
    headers
}

/// Wraps a JSON body as a credential-free streaming POST. Bodies serialize with sorted keys
/// (deterministic prompt-cache prefix); see Spec 02 for the `tools`-first rule once native tool
/// definitions are sent.
fn wire(
    dialect: ProviderDialect,
    url: String,
    body: Value,
    fallback: Option<Box<WireRequest>>,
) -> WireRequest {
    WireRequest {
        dialect,
        method: reqwest::Method::POST,
        url,
        headers: stream_headers(dialect),
        body: Some(body),
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
    match dialect {
        ProviderDialect::OpenAi => wire(
            dialect,
            format!("{base}/responses"),
            openai_responses_body(model, system_prompt, history, gen_params, store),
            None,
        ),
        ProviderDialect::GoogleGemini => {
            let clean_model = model.strip_prefix("models/").unwrap_or(model);
            let fallback = wire(
                dialect,
                format!("{base}/v1beta/models/{clean_model}:streamGenerateContent?alt=sse"),
                gemini_generate_content_body(system_prompt, history, gen_params),
                None,
            );
            wire(
                dialect,
                format!("{base}/v1beta/interactions"),
                gemini_interactions_body(model, system_prompt, history, gen_params, store),
                Some(Box::new(fallback)),
            )
        }
        ProviderDialect::Anthropic => wire(
            dialect,
            format!("{base}/messages"),
            anthropic_messages_body(model, system_prompt, history, gen_params),
            None,
        ),
        ProviderDialect::CustomOpenAi => wire(
            dialect,
            format!("{base}/chat/completions"),
            openai_compat_chat_body(model, system_prompt, history, gen_params),
            None,
        ),
    }
}

/// `(role, text)` turns replayed to the provider (UI-only roles never leave the device).
fn replay_turns(
    history: &[NodeRecord],
    assistant_role: &'static str,
) -> Vec<(&'static str, String)> {
    history
        .iter()
        .filter_map(|n| match n.role {
            NodeRole::Assistant => Some((assistant_role, n.content.clone())),
            NodeRole::CompactionSummary => Some((
                "user",
                format!("[Earlier conversation summary]\n{}", n.content),
            )),
            NodeRole::User => Some(("user", n.content.clone())),
            NodeRole::System | NodeRole::Tool => None,
        })
        .collect()
}

fn openai_responses_body(
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    store: bool,
) -> Value {
    let input: Vec<Value> = replay_turns(history, "assistant")
        .into_iter()
        .map(|(role, content)| json!({ "role": role, "content": content }))
        .collect();
    let mut payload = json!({
        "model": model,
        "input": input,
        "stream": true,
        "store": store,
    });
    if let Some(obj) = payload.as_object_mut() {
        if !system_prompt.trim().is_empty() {
            obj.insert(
                "instructions".to_owned(),
                Value::String(system_prompt.to_owned()),
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
    }
    payload
}

fn gemini_interactions_body(
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    store: bool,
) -> Value {
    let turns: Vec<Value> = replay_turns(history, "model")
        .into_iter()
        .map(|(role, text)| json!({ "role": role, "content": [{ "type": "text", "text": text }] }))
        .collect();
    let mut payload = json!({
        "model": model,
        "input": turns,
        "stream": true,
        "store": store,
    });
    if let Some(obj) = payload.as_object_mut() {
        if !system_prompt.trim().is_empty() {
            obj.insert(
                "system_instruction".to_owned(),
                Value::String(system_prompt.to_owned()),
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
        if !gen_cfg.is_empty() {
            obj.insert("generation_config".to_owned(), Value::Object(gen_cfg));
        }
    }
    payload
}

fn gemini_generate_content_body(
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
) -> Value {
    let contents: Vec<Value> = replay_turns(history, "model")
        .into_iter()
        .map(|(role, text)| json!({ "role": role, "parts": [{ "text": text }] }))
        .collect();
    let mut payload = json!({ "contents": contents });
    if let Some(obj) = payload.as_object_mut() {
        if !system_prompt.trim().is_empty() {
            obj.insert(
                "systemInstruction".to_owned(),
                json!({ "parts": [{ "text": system_prompt }] }),
            );
        }
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
        if !gen_cfg.is_empty() {
            obj.insert("generationConfig".to_owned(), Value::Object(gen_cfg));
        }
    }
    payload
}

fn anthropic_messages_body(
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
) -> Value {
    let messages: Vec<Value> = replay_turns(history, "assistant")
        .into_iter()
        .map(|(role, content)| json!({ "role": role, "content": content }))
        .collect();
    let max_tokens = gen_params.max_output_tokens.unwrap_or(4096);
    let mut payload = json!({
        "model": model,
        "max_tokens": max_tokens,
        "messages": messages,
        "stream": true,
    });
    if let Some(obj) = payload.as_object_mut() {
        if !system_prompt.trim().is_empty() {
            obj.insert("system".to_owned(), Value::String(system_prompt.to_owned()));
        }
        if let Some(t) = gen_params.temperature_milli {
            obj.insert("temperature".to_owned(), milli_to_json_number(t));
        }
        if let Some(p) = gen_params.top_p_milli {
            obj.insert("top_p".to_owned(), milli_to_json_number(p));
        }
    }
    payload
}

fn openai_compat_chat_body(
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
) -> Value {
    let mut messages = Vec::new();
    if !system_prompt.trim().is_empty() {
        messages.push(json!({ "role": "system", "content": system_prompt }));
    }
    messages.extend(
        replay_turns(history, "assistant")
            .into_iter()
            .map(|(role, content)| json!({ "role": role, "content": content })),
    );
    let mut payload = json!({
        "model": model,
        "messages": messages,
        "stream": true,
        "stream_options": { "include_usage": true },
    });
    if let Some(obj) = payload.as_object_mut() {
        if let Some(t) = gen_params.temperature_milli {
            obj.insert("temperature".to_owned(), milli_to_json_number(t));
        }
        if let Some(max_tok) = gen_params.max_output_tokens {
            obj.insert("max_tokens".to_owned(), Value::from(max_tok));
        }
        if let Some(p) = gen_params.top_p_milli {
            obj.insert("top_p".to_owned(), milli_to_json_number(p));
        }
    }
    payload
}

fn check_captive_portal(resp: &reqwest::Response) -> BistreResult<()> {
    if resp.status().is_success()
        && let Some(ct) = resp
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
        && ct.to_ascii_lowercase().contains("text/html")
    {
        return Err(BistreError::new(DiagnosticKey::NetworkCaptivePortal));
    }
    Ok(())
}

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

/// Extracts incremental text delta from an SSE JSON `data:` payload for any Big 3 + Custom dialect.
pub fn extract_sse_delta(dialect: ProviderDialect, json_str: &str) -> Option<String> {
    let val: Value = serde_json::from_str(json_str).ok()?;
    match dialect {
        ProviderDialect::OpenAi => {
            if val.get("type").and_then(Value::as_str) == Some("response.output_text.delta")
                && let Some(delta) = val.get("delta").and_then(Value::as_str)
            {
                return Some(delta.to_owned());
            }
            extract_openai_chat_delta(&val)
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
            // Transparent legacy generateContent SSE format.
            let parts = val
                .get("candidates")?
                .get(0)?
                .get("content")?
                .get("parts")?
                .as_array()?;
            let mut combined = String::new();
            for p in parts {
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
            None
        }
        ProviderDialect::CustomOpenAi => extract_openai_chat_delta(&val),
    }
}

fn extract_openai_chat_delta(val: &Value) -> Option<String> {
    val.get("choices")?
        .get(0)?
        .get("delta")?
        .get("content")?
        .as_str()
        .map(ToOwned::to_owned)
}

/// Extracts incremental reasoning/thinking deltas across `OpenAI` Responses, Anthropic, Gemini,
/// and `OpenAI`-compatible reasoning models (`DeepSeek` R1 / `QwQ` / vLLM / Ollama).
pub fn extract_sse_thinking_delta(dialect: ProviderDialect, json_str: &str) -> Option<String> {
    let val: Value = serde_json::from_str(json_str).ok()?;
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
            extract_openai_chat_reasoning_delta(&val)
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
        ProviderDialect::CustomOpenAi => extract_openai_chat_reasoning_delta(&val),
    }
}

fn extract_openai_chat_reasoning_delta(val: &Value) -> Option<String> {
    let delta = val.get("choices")?.get(0)?.get("delta")?;
    delta
        .get("reasoning_content")
        .or_else(|| delta.get("reasoning"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

/// Extracts exact integer token counts from SSE lifecycle frames across all 4 supported dialects.
pub fn merge_sse_usage(dialect: ProviderDialect, json_str: &str, usage: &mut UsageMetrics) {
    let Ok(val) = serde_json::from_str::<Value>(json_str) else {
        return;
    };
    match dialect {
        ProviderDialect::OpenAi => {
            // OpenAI Responses API (`response.completed`) or Chat Completions final `usage` block.
            let u = val
                .get("response")
                .and_then(|r| r.get("usage"))
                .or_else(|| val.get("usage"));
            if let Some(u) = u {
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
            }
        }
        ProviderDialect::Anthropic => {
            if let Some(u) = val.get("message").and_then(|m| m.get("usage")) {
                if let Some(v) = u.get("input_tokens").and_then(Value::as_u64) {
                    usage.input_tokens = v;
                }
                if let Some(v) = u.get("cache_read_input_tokens").and_then(Value::as_u64) {
                    usage.cached_input_tokens = v;
                }
            }
            if let Some(u) = val.get("usage") {
                if let Some(v) = u.get("input_tokens").and_then(Value::as_u64) {
                    usage.input_tokens = v;
                }
                if let Some(v) = u.get("output_tokens").and_then(Value::as_u64) {
                    usage.output_tokens = v;
                }
            }
        }
        ProviderDialect::GoogleGemini => {
            // Interactions: `interaction.usage` (created/completed), top-level `usage`
            // (status_update, step.stop); legacy generateContent: `usageMetadata`.
            let u = val
                .get("usageMetadata")
                .or_else(|| val.get("usage_metadata"))
                .or_else(|| val.get("interaction").and_then(|i| i.get("usage")))
                .or_else(|| val.get("usage"));
            if let Some(u) = u {
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
            }
        }
        ProviderDialect::CustomOpenAi => {
            if let Some(u) = val.get("usage") {
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
    let Ok(val) = serde_json::from_str::<Value>(payload) else {
        return false;
    };
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

#[cfg(test)]
#[path = "providers_tests.rs"]
mod tests;
