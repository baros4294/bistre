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

use std::collections::HashMap;
use std::path::Path;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, GenerationParams, MoneyMicros, NodeRecord,
    ProviderDialect, ProviderModelInfo, ProviderProfile, ReasoningEffort, UsageMetrics,
};
use reqwest::header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, HeaderMap, HeaderValue};
use serde_json::{Value, json};

use crate::credentials::{KeyRing, is_key_failover_status};
use crate::error_policy::{
    FailureKind, MAX_ERROR_BODY_SCAN_BYTES, MAX_HTTP_400_HEALS, classify_http_failure,
    failure_error, parse_retry_hint,
};
use crate::registry::ModelRates;
use crate::replay_policy::ReplayContext;
use crate::sse::{INITIAL_LINE_TIMEOUT, STREAMING_LINE_TIMEOUT, SseFramer};
pub use crate::wire_stream::StreamOutcome;
use crate::wire_stream::StreamState;

/// Optional per-request extensions: replay policy context, active wire tools, stateful chaining
/// ID, Anthropic cache TTL, server compaction, reply prefill, and custom overrides.
#[derive(Debug, Default, Clone)]
pub struct StreamRequestOptions<'a> {
    pub replay_ctx: Option<&'a ReplayContext>,
    pub tools_wire: Option<&'a [Value]>,
    pub previous_server_id: Option<&'a str>,
    /// R7: where the items after the chained reply begin in `history` (only they are sent
    /// when chaining); ignored without `previous_server_id`.
    pub chain_first_new_index: usize,
    /// The run's decision whether the provider stores this request (R7: one decision shared
    /// with chaining); `None` takes it from the provider profile.
    pub store: Option<bool>,
    pub anthropic_cache_1h: bool,
    pub anthropic_server_compaction: bool,
    pub disable_legacy_fallback: bool,
    pub reply_prefill: Option<String>,
    pub anthropic_beta_headers: Vec<String>,
    pub extra_headers: Vec<crate::custom_headers::CustomHeader>,
    pub extra_body_fields: Option<serde_json::Map<String, Value>>,
}

/// Exact integer micro-USD cost from live registry rates (zero floats, zero hardcoded rates).
/// Loopback inference is free; an unpriced model is `None` (unknown, never guessed).
pub fn estimate_cost_micros(
    provider: &ProviderProfile,
    rates: Option<ModelRates>,
    usage: &UsageMetrics,
) -> Option<MoneyMicros> {
    if crate::net::is_loopback_url(&provider.base_url)
        || (usage.input_tokens == 0
            && usage.output_tokens == 0
            && usage.cached_input_tokens == 0
            && usage.cache_creation_input_tokens == 0)
    {
        return Some(MoneyMicros::ZERO);
    }
    rates.and_then(|r| r.cost_for_dialect(provider.dialect, usage))
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
        let resp_headers = resp.headers().clone();
        let body_text = read_error_body(resp).await;
        let kind = classify_http_failure(status, &body_text);
        if status == 400
            && kind == FailureKind::BadRequest
            && heals < MAX_HTTP_400_HEALS
            && let Some(body) = wire.body.as_mut()
            && let Some(heal) = crate::error_policy::apply_next_heal_for_dialect(
                wire.dialect,
                body,
                &mut heal_cursor,
                &body_text,
            )
        {
            if heal == crate::error_policy::Http400Heal::StripContextManagement {
                wire.headers.remove("anthropic-beta");
            }
            heals += 1;
            // R14: dropping reasoning for one request only marks the model "no reasoning"
            // when the provider said reasoning is unsupported.
            let code = if heal == crate::error_policy::Http400Heal::DropReasoning
                && !crate::error_policy::says_reasoning_unsupported(&body_text)
            {
                "heal_drop_reasoning_once".to_owned()
            } else {
                heal.code().to_owned()
            };
            notices.push((DiagnosticKey::ProviderRequestHealed, code));
            continue;
        }
        // Only downgrade Gemini Interactions -> streamGenerateContent on 404 or once 400 heals are exhausted.
        if matches!(status, 400 | 404)
            && let Some(fallback) = wire.fallback.take()
        {
            wire = *fallback;
            heal_cursor = 0;
            continue;
        }
        return Err(failure_error(
            kind,
            status,
            parse_retry_hint(&resp_headers, &body_text, SystemTime::now()),
            crate::finish::provider_reason(&body_text).as_deref(),
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
    let base = provider.dialect.api_root(&provider.base_url);
    let mut headers = HeaderMap::new();
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
    if provider.dialect == ProviderDialect::Anthropic {
        headers.insert(
            "anthropic-version",
            HeaderValue::from_static(bistre_protocol::dialect::ANTHROPIC_API_VERSION),
        );
    }
    let url = format!("{base}{}", provider.dialect.models_path());
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
    on_delta: F,
    on_thinking: T,
) -> BistreResult<StreamOutcome>
where
    F: FnMut(&str) + Send,
    T: FnMut(&str) + Send,
{
    stream_completion_with_attachments(
        client,
        provider,
        keys,
        model,
        system_prompt,
        history,
        gen_params,
        stateless_default,
        None,
        cancel_flag,
        on_delta,
        on_thinking,
    )
    .await
}

/// Streams a completion across all Big 3 + Custom dialects with full native multimodal,
/// PDF, Office document, audio, video, and plain-text attachment wire encoding.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable parameters avoid hidden global state in pure transport layer."
)]
pub async fn stream_completion_with_attachments<F, T>(
    client: &reqwest::Client,
    provider: &ProviderProfile,
    keys: &KeyRing,
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    stateless_default: bool,
    data_dir: Option<&Path>,
    cancel_flag: &AtomicBool,
    on_delta: F,
    on_thinking: T,
) -> BistreResult<StreamOutcome>
where
    F: FnMut(&str) + Send,
    T: FnMut(&str) + Send,
{
    let opts = StreamRequestOptions::default();
    stream_completion_with_options(
        client,
        provider,
        keys,
        model,
        system_prompt,
        history,
        gen_params,
        stateless_default,
        data_dir,
        &opts,
        cancel_flag,
        on_delta,
        on_thinking,
    )
    .await
}

/// Streams a completion with full replay context, native tools, prompt caching, and attachments.
#[expect(
    clippy::too_many_arguments,
    reason = "Explicit immutable parameters avoid hidden global state in pure transport layer."
)]
#[expect(
    clippy::too_many_lines,
    reason = "Single linear SSE transport, preupload, cancellation, and cleanup lifecycle."
)]
pub async fn stream_completion_with_options<F, T>(
    client: &reqwest::Client,
    provider: &ProviderProfile,
    keys: &KeyRing,
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    stateless_default: bool,
    data_dir: Option<&Path>,
    options: &StreamRequestOptions<'_>,
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

    let store_server_state = match options.store {
        Some(store) => store,
        None => !stateless_default && provider.use_server_state_cache,
    };
    let base = provider.base_url.trim_end_matches('/');
    let primary_key = keys.primary().unwrap_or("");
    let uploaded = tokio::select! {
        biased;
        () = until_cancelled(cancel_flag) => None,
        u = crate::attachments::preupload_attachments_for_dialect(
            client,
            provider.dialect,
            base,
            primary_key,
            data_dir,
            history,
            store_server_state,
        ) => Some(u),
    };
    let Some(uploaded) = uploaded else {
        return Ok(StreamOutcome {
            cancelled: true,
            ..StreamOutcome::default()
        });
    };
    // R11: uploaded files belong to the key that uploaded them (the primary).
    let pinned_keys;
    let request_keys = if uploaded.refs.is_empty() {
        keys
    } else {
        pinned_keys = keys.primary_only();
        &pinned_keys
    };
    // R24: say which attachments the model will not get (each is replaced by a note).
    let unsent = data_dir.map_or_else(Vec::new, |dir| {
        crate::attachments::unsent_attachment_names_with_refs(dir, history, &uploaded.refs)
    });
    let result: BistreResult<StreamOutcome> = async {
        let mut effective_opts = options.clone();
        if provider.dialect == ProviderDialect::Anthropic {
            if !uploaded.refs.is_empty()
                && !effective_opts
                    .anthropic_beta_headers
                    .iter()
                    .any(|b| b == bistre_protocol::dialect::ANTHROPIC_BETA_FILES)
            {
                effective_opts
                    .anthropic_beta_headers
                    .push(bistre_protocol::dialect::ANTHROPIC_BETA_FILES.to_owned());
            }
            if effective_opts.anthropic_server_compaction
                && history.len() >= 8
                && history
                    .iter()
                    .any(|n| n.role == bistre_protocol::NodeRole::Tool)
                && !effective_opts
                    .anthropic_beta_headers
                    .iter()
                    .any(|b| b == bistre_protocol::dialect::ANTHROPIC_BETA_CONTEXT_MANAGEMENT)
            {
                effective_opts
                    .anthropic_beta_headers
                    .push(bistre_protocol::dialect::ANTHROPIC_BETA_CONTEXT_MANAGEMENT.to_owned());
            }
        }
        let wire = build_stream_request_full(
            provider.dialect,
            base,
            clean_model,
            system_prompt,
            history,
            gen_params,
            store_server_state,
            data_dir,
            &uploaded.refs,
            &effective_opts,
        );
        let mut state = StreamState::default();
        state.started_at = Some(std::time::Instant::now());
        // Stop must take effect while connecting and while waiting for the first token, not only
        // between chunks (the first-token budget is 300 s).
        let dispatched = tokio::select! {
            biased;
            () = until_cancelled(cancel_flag) => None,
            r = dispatch(client, wire, request_keys, &mut state.out.notices) => Some(r),
        };
        let Some(dispatched) = dispatched else {
            state.out.cancelled = true;
            return Ok(state.out);
        };
        let mut resp = match dispatched {
            Ok(r) => r,
            Err(err) => {
                if !uploaded.refs.is_empty()
                    && matches!(
                        err.key,
                        DiagnosticKey::ProviderRequestFailed | DiagnosticKey::ProviderAuthFailed
                    )
                {
                    crate::attachments::evict_remote_file_cache(
                        data_dir,
                        provider.dialect,
                        base,
                        primary_key,
                    );
                }
                return Err(err);
            }
        };

        let mut sse = SseFramer::new();
        let mut received_any = false;
        let epoch = RESUME_EPOCH.load(Ordering::SeqCst);
        let mut last_byte = std::time::Instant::now();
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
            let waited = tokio::select! {
                biased;
                () = until_cancelled(cancel_flag) => None,
                () = stalled_across_resume(epoch, last_byte) => Some(Ok(Err(None))),
                r = tokio::time::timeout(idle, resp.chunk()) => Some(r.map(|c| c.map_err(Some))),
            };
            let Some(waited) = waited else {
                state.out.cancelled = true;
                break;
            };
            let next_chunk = match waited {
                Ok(Ok(chunk)) => chunk,
                failure => {
                    let detail = match failure {
                        Err(_) => "idle_timeout",
                        Ok(Err(None)) => "resume_stall",
                        _ => "stream_io",
                    };
                    // Once any output reached the user the request is paid and visible: keep it and
                    // mark the reply interrupted. Only a stream that produced nothing may be retried.
                    if crate::error_policy::may_retry_stream(
                        &state.out.full_text,
                        state.out.tool_calls.len(),
                    ) && state.out.thinking_text.is_empty()
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
            last_byte = std::time::Instant::now();
            received_any = true;
            if cancel_flag.load(Ordering::SeqCst) {
                state.out.cancelled = true;
                break;
            }
            let payloads = match sse.push_bytes(&bytes) {
                Ok(payloads) => payloads,
                Err(err) => {
                    // R8: the buffer cap follows the dropped-stream rule. Retry only when nothing
                    // was shown; otherwise keep the paid, visible output and mark it interrupted.
                    if crate::error_policy::may_retry_stream(
                        &state.out.full_text,
                        state.out.tool_calls.len(),
                    ) && state.out.thinking_text.is_empty()
                    {
                        return Err(err);
                    }
                    tracing::warn!(
                        key = err.key.as_key(),
                        detail = err.detail_code.as_deref().unwrap_or_default(),
                        "stream stopped after output; reply kept as interrupted"
                    );
                    state.out.interrupted = true;
                    break;
                }
            };
            for payload in payloads {
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
        state.finalize(provider.dialect);

        // R10/R42: an error frame (or a plain JSON error body) is the real ending. Without
        // output, a retryable one (overload, server error) takes the retry path and anything
        // else fails at once with the provider's reason; after output, the reply is kept and
        // marked interrupted.
        if let Some(crate::finish::FinishKind::Error { retryable, code }) = state.out.finish.clone()
            && !state.out.cancelled
        {
            let no_output = state.out.full_text.is_empty()
                && state.out.thinking_text.is_empty()
                && state.out.tool_calls.is_empty();
            if no_output {
                let mut detail = format!("stream_error:{}", crate::finish::sanitize_reason(&code));
                if let Some(reason) = state.out.error_reason.as_deref() {
                    detail.push_str(";reason=");
                    detail.push_str(reason);
                }
                let key = if retryable {
                    DiagnosticKey::ProviderStreamInterrupted
                } else {
                    DiagnosticKey::ProviderRequestFailed
                };
                return Err(BistreError::with_detail(key, detail));
            }
            state.out.interrupted = true;
        }

        if !state.out.cancelled && !state.terminal_seen {
            if state.out.full_text.is_empty()
                && state.out.thinking_text.is_empty()
                && state.out.tool_calls.is_empty()
            {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ProviderStreamInterrupted,
                    "eof_before_output",
                ));
            }
            state.out.interrupted = true;
        }
        Ok(state.out)
    }
    .await;
    // R12: files uploaded for this request alone (`store: false`) are deleted on every path
    // (success, error, and Stop), never only after a clean finish.
    for (d, fid) in &uploaded.ephemeral_ids {
        crate::attachments::delete_remote_file(client, *d, base, primary_key, fid).await;
    }
    result.map(|mut out| {
        out.notices.extend(
            unsent
                .into_iter()
                .map(|name| (DiagnosticKey::AttachmentNotSent, name)),
        );
        out
    })
}

/// How often an in-flight request re-checks its Stop flag (cancel latency bound).
pub const CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(50);

/// Resolves once `flag` is set. Only awaited while a request is in flight, never while idle.
/// Bumped each time the app comes back to the foreground or the system wakes (P19).
static RESUME_EPOCH: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// How long a stream may have been silent before a resume ends it (P19). A live stream sends
/// something well within this; one that died while the app was away never will.
#[cfg(not(test))]
const RESUME_STALL_AFTER: Duration = Duration::from_secs(15);
#[cfg(test)]
const RESUME_STALL_AFTER: Duration = Duration::from_millis(500);

/// P19: the app came back (or the system woke); streams silent for longer than
/// [`RESUME_STALL_AFTER`] end now instead of waiting out their idle timeout.
pub fn note_app_resumed() {
    RESUME_EPOCH.fetch_add(1, Ordering::SeqCst);
}

/// Resolves once a resume happened after `seen_epoch` while the stream had been silent for
/// [`RESUME_STALL_AFTER`] since `last_byte`.
async fn stalled_across_resume(seen_epoch: u64, last_byte: std::time::Instant) {
    loop {
        tokio::time::sleep(CANCEL_POLL_INTERVAL).await;
        if RESUME_EPOCH.load(Ordering::SeqCst) != seen_epoch
            && last_byte.elapsed() >= RESUME_STALL_AFTER
        {
            return;
        }
    }
}

pub async fn until_cancelled(flag: &AtomicBool) {
    while !flag.load(Ordering::SeqCst) {
        tokio::time::sleep(CANCEL_POLL_INTERVAL).await;
    }
}

fn milli_to_json_number(milli: u32) -> Value {
    let whole = milli / 1000;
    let frac = milli % 1000;
    let text = format!("{whole}.{frac:03}");
    serde_json::from_str::<Value>(&text).unwrap_or_else(|_| Value::from(whole))
}

fn stream_headers(dialect: ProviderDialect, options: &StreamRequestOptions<'_>) -> HeaderMap {
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
fn wire(
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
    let endpoint = format!("{base}{}", dialect.default_endpoint_path());
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
            openai_compat_chat_body(model, system_prompt, history, gen_params, data_dir, options),
            options,
            None,
        ),
    }
}

/// R7: how many history nodes a chained request leaves out (the server holds them).
const fn chain_skip(store: bool, options: &StreamRequestOptions<'_>) -> usize {
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
fn openai_responses_body<S: std::hash::BuildHasher>(
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
    // G1 (`OpenAI` prompt-caching guide, read 2026-11-26): newer models append top-level
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
        obj.insert("tools".to_owned(), Value::Array(tools.to_vec()));
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
fn openai_effort(dialect: ProviderDialect, effort: ReasoningEffort) -> Option<&'static str> {
    match effort {
        ReasoningEffort::ModelDefault => None,
        ReasoningEffort::Adaptive => Some("medium"),
        ReasoningEffort::Off => Some("none"),
        ReasoningEffort::Max if dialect == ProviderDialect::OpenAi => Some("xhigh"),
        other => Some(other.as_str()),
    }
}

/// Gemini thinking level (lowercase; Gemini has no `max`, and Off asks for minimal thoughts).
fn gemini_level(effort: ReasoningEffort) -> Option<&'static str> {
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
fn gemini_interactions_body<S: std::hash::BuildHasher>(
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
        obj.insert("tools".to_owned(), Value::Array(tools.to_vec()));
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
    Value::Object(obj)
}

fn gemini_generate_content_body<S: std::hash::BuildHasher>(
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
    Value::Object(obj)
}

fn anthropic_cache_control(cache_1h: bool) -> Value {
    if cache_1h {
        json!({ "type": "ephemeral", "ttl": "1h" })
    } else {
        json!({ "type": "ephemeral" })
    }
}

fn anthropic_messages_body<S: std::hash::BuildHasher>(
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
        let mut t_arr = tools.to_vec();
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

fn openai_compat_chat_body(
    model: &str,
    system_prompt: &str,
    history: &[NodeRecord],
    gen_params: GenerationParams,
    data_dir: Option<&Path>,
    options: &StreamRequestOptions<'_>,
) -> Value {
    let mut messages = Vec::new();
    if !system_prompt.trim().is_empty() {
        messages.push(json!({ "role": "system", "content": system_prompt }));
    }
    messages.extend(crate::wire_history::build_openai_compat_messages_with_ctx(
        history,
        data_dir,
        options.replay_ctx,
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
    Value::Object(obj)
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

pub use crate::wire_parse::{
    extract_sse_delta, extract_sse_thinking_delta, is_terminal_event, merge_sse_usage,
    parse_models_payload,
};

#[cfg(test)]
#[path = "providers_tests.rs"]
mod tests;
