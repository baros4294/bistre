//! Provider failure classification, retry hints, and the ordered HTTP 400 heal ladder (Spec 02).
//!
//! - Retry hints, in priority order: `retry-after-ms`, `retry-after` (seconds or RFC 7231
//!   IMF-fixdate), then Gemini `google.rpc.RetryInfo.retryDelay` scanned from the first 64 KiB
//!   of the body. Hints are clamped to `1..=300 s`.
//! - Billing stops, per-day quota failures, and spend caps are never retried.
//! - Transient-worded HTTP 400s (overloaded, try again) are retryable.
//! - An unsupported request field is healed by one ordered, data-driven step at a time
//!   (`MAX_HTTP_400_HEALS` resends), each surfaced as `DiagnosticKey::ProviderRequestHealed`.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use bistre_protocol::{BistreError, DiagnosticKey};
use reqwest::header::HeaderMap;
use serde_json::Value;

/// Maximum resends after HTTP 400 heals for one request.
pub const MAX_HTTP_400_HEALS: usize = 6;
/// Bytes of an error body scanned for hints and markers.
pub const MAX_ERROR_BODY_SCAN_BYTES: usize = 64 * 1024;
const MIN_HINT_MS: u64 = 1_000;
const MAX_HINT_MS: u64 = 300_000;

/// Typed failure kinds driving retry decisions and jump-to-fix UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureKind {
    Auth,
    RateLimited,
    QuotaExhausted,
    ContextOverflow,
    BadRequest,
    NotFound,
    Transient,
}

impl FailureKind {
    /// Whether an automatic backoff retry is allowed for this kind.
    pub const fn is_retryable(self) -> bool {
        matches!(self, Self::RateLimited | Self::Transient)
    }

    pub const fn diagnostic(self) -> DiagnosticKey {
        match self {
            Self::Auth => DiagnosticKey::ProviderAuthFailed,
            Self::RateLimited => DiagnosticKey::ProviderRateLimited,
            Self::QuotaExhausted => DiagnosticKey::ProviderQuotaExhausted,
            Self::ContextOverflow => DiagnosticKey::ProviderContextOverflow,
            Self::BadRequest | Self::NotFound | Self::Transient => {
                DiagnosticKey::ProviderRequestFailed
            }
        }
    }
}

const QUOTA_MARKERS: [&str; 7] = [
    "insufficient_quota",
    "billing_hard_limit_reached",
    "billing_not_active",
    "exceeded your current quota",
    "perday",
    "credit balance is too low",
    "enforced_spend_limit_reached",
];
const OVERFLOW_MARKERS: [&str; 7] = [
    "context_length_exceeded",
    "maximum context length",
    "context window",
    "prompt is too long",
    "input is too long",
    "too many tokens",
    "request_too_large",
];
const TRANSIENT_MARKERS: [&str; 5] = [
    "overloaded",
    "temporarily",
    "try again",
    "server is busy",
    "capacity",
];

fn scan(body: &str) -> String {
    let mut end = body.len().min(MAX_ERROR_BODY_SCAN_BYTES);
    while end > 0 && !body.is_char_boundary(end) {
        end -= 1;
    }
    body[..end].to_ascii_lowercase()
}

/// Classifies an HTTP failure from status + (bounded) body text.
pub fn classify_http_failure(status: u16, body: &str) -> FailureKind {
    let lower = scan(body);
    let has = |markers: &[&str]| markers.iter().any(|m| lower.contains(m));
    if has(&QUOTA_MARKERS) || status == 402 {
        return FailureKind::QuotaExhausted;
    }
    if status == 413 || has(&OVERFLOW_MARKERS) {
        return FailureKind::ContextOverflow;
    }
    match status {
        401 | 403 => FailureKind::Auth,
        429 => FailureKind::RateLimited,
        404 => FailureKind::NotFound,
        408 | 409 | 425 => FailureKind::Transient,
        400 if has(&TRANSIENT_MARKERS) => FailureKind::Transient,
        400 | 405..=412 | 414..=428 => FailureKind::BadRequest,
        _ => FailureKind::Transient,
    }
}

/// Builds the typed error, encoding the status, transient marker, and any retry hint in the detail
/// code (`http_429;retry_after_ms=30000` or `http_400;transient`) so the run loop schedules backoff.
pub fn failure_error(kind: FailureKind, status: u16, retry_after_ms: Option<u64>) -> BistreError {
    let mut detail = format!("http_{status}");
    if kind == FailureKind::Transient && status == 400 {
        detail.push_str(";transient");
    }
    if let Some(ms) = retry_after_ms {
        detail.push_str(";retry_after_ms=");
        detail.push_str(&ms.to_string());
    }
    BistreError::with_detail(kind.diagnostic(), detail)
}

/// Extracts `retry_after_ms=N` from a failure detail code.
pub fn retry_after_from_detail(detail: Option<&str>) -> Option<u64> {
    detail?
        .split(';')
        .find_map(|part| part.strip_prefix("retry_after_ms="))
        .and_then(|v| v.parse().ok())
}

/// Parses the server retry hint (milliseconds, clamped `1 s ..= 300 s`).
pub fn parse_retry_hint(headers: &HeaderMap, body: &str, now: SystemTime) -> Option<u64> {
    let header = |name: &str| {
        headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .map(str::trim)
    };
    let raw_ms = header("retry-after-ms")
        .and_then(|v| v.parse::<u64>().ok())
        .or_else(|| header("retry-after").and_then(|v| parse_retry_after_value(v, now)))
        .or_else(|| parse_gemini_retry_delay(body))?;
    Some(raw_ms.clamp(MIN_HINT_MS, MAX_HINT_MS))
}

/// `Retry-After`: delta-seconds or an RFC 7231 IMF-fixdate.
pub fn parse_retry_after_value(value: &str, now: SystemTime) -> Option<u64> {
    if let Ok(secs) = value.parse::<u64>() {
        return Some(secs.saturating_mul(1000));
    }
    let target = parse_imf_fixdate(value)?;
    let now_secs = now.duration_since(UNIX_EPOCH).ok()?.as_secs();
    Some(target.saturating_sub(now_secs).saturating_mul(1000))
}

/// Parses `Sun, 06 Nov 1994 08:49:37 GMT` into Unix seconds.
pub fn parse_imf_fixdate(value: &str) -> Option<u64> {
    let parts: Vec<&str> = value.split_whitespace().collect();
    if parts.len() != 6 || parts[5] != "GMT" || !parts[0].ends_with(',') {
        return None;
    }
    let day: u64 = parts[1].parse().ok()?;
    let month = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
    .iter()
    .position(|m| *m == parts[2])?;
    let year: i64 = parts[3].parse().ok()?;
    let hms: Vec<u64> = parts[4].split(':').filter_map(|p| p.parse().ok()).collect();
    if hms.len() != 3 || !(1..=31).contains(&day) || hms[0] > 23 || hms[1] > 59 || hms[2] > 60 {
        return None;
    }
    let days = days_from_civil(
        year,
        u32::try_from(month + 1).ok()?,
        u32::try_from(day).ok()?,
    );
    let secs =
        days.checked_mul(86_400)? + i64::try_from(hms[0] * 3600 + hms[1] * 60 + hms[2]).ok()?;
    u64::try_from(secs).ok()
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let m = i64::from(month);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Finds `"retryDelay": "12.5s"` (Gemini `google.rpc.RetryInfo`) in the bounded body.
pub fn parse_gemini_retry_delay(body: &str) -> Option<u64> {
    let lower = scan(body);
    let idx = lower.find("\"retrydelay\"")?;
    let rest = &lower[idx + "\"retrydelay\"".len()..];
    let open = rest.find('"')?;
    let value = &rest[open + 1..];
    let close = value.find('"')?;
    let text = value[..close].trim().strip_suffix('s')?;
    let (whole, frac) = text.split_once('.').unwrap_or((text, ""));
    let secs: u64 = whole.parse().ok()?;
    let frac_ms: u64 = format!("{frac:0<3}").get(..3)?.parse().ok()?;
    Some(secs.saturating_mul(1000).saturating_add(frac_ms))
}

/// Mid-stream retry is only safe when nothing was shown to the user (no double output).
pub fn may_retry_stream(full_text: &str, tool_calls_emitted: usize) -> bool {
    full_text.is_empty() && tool_calls_emitted == 0
}

/// Ordered HTTP 400 heal steps (first applicable step wins).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Http400Heal {
    StripOpaqueThoughtSignatures,
    StripContextManagement,
    StripReplyPrefill,
    StripPromptCacheControl,
    StripInclude,
    FallbackInputFileToExtractedText,
    StripAnthropicThinkingDisplay,
    GeminiThinkingLevelToBudget,
    StepDownReasoningEffort,
    StripStreamOptions,
    ToggleMaxTokensField,
    StripBuiltinTools,
    StripSamplingParams,
    DropReasoning,
}

pub const HEAL_LADDER: [Http400Heal; 14] = [
    Http400Heal::StripOpaqueThoughtSignatures,
    Http400Heal::StripContextManagement,
    Http400Heal::StripReplyPrefill,
    Http400Heal::StripPromptCacheControl,
    Http400Heal::StripInclude,
    Http400Heal::FallbackInputFileToExtractedText,
    Http400Heal::StripAnthropicThinkingDisplay,
    Http400Heal::GeminiThinkingLevelToBudget,
    Http400Heal::StepDownReasoningEffort,
    Http400Heal::StripStreamOptions,
    Http400Heal::ToggleMaxTokensField,
    Http400Heal::StripBuiltinTools,
    Http400Heal::StripSamplingParams,
    Http400Heal::DropReasoning,
];

impl Http400Heal {
    /// Stable detail code reported with `DiagnosticKey::ProviderRequestHealed`.
    pub const fn code(self) -> &'static str {
        match self {
            Self::StripOpaqueThoughtSignatures => "heal_strip_thought_signatures",
            Self::StripContextManagement => "heal_strip_context_management",
            Self::StripReplyPrefill => "heal_strip_reply_prefill",
            Self::StripPromptCacheControl => "heal_strip_prompt_cache_control",
            Self::StripInclude => "heal_strip_include",
            Self::FallbackInputFileToExtractedText => "heal_fallback_input_file",
            Self::StripAnthropicThinkingDisplay => "heal_strip_thinking_display",
            Self::GeminiThinkingLevelToBudget => "heal_thinking_level_to_budget",
            Self::StepDownReasoningEffort => "heal_reasoning_effort_step_down",
            Self::StripStreamOptions => "heal_strip_stream_options",
            Self::ToggleMaxTokensField => "heal_toggle_max_tokens_field",
            Self::StripBuiltinTools => "heal_strip_builtin_tools",
            Self::StripSamplingParams => "heal_strip_sampling_params",
            Self::DropReasoning => "heal_drop_reasoning",
        }
    }

    /// Applies this heal to the JSON body; returns `true` only when the body changed.
    #[expect(
        clippy::too_many_lines,
        reason = "Ordered 14-step wire-dialect heal dispatch kept linear for auditability."
    )]
    pub fn apply(self, body: &mut Value) -> bool {
        let Some(obj) = body.as_object_mut() else {
            return false;
        };
        match self {
            Self::StripOpaqueThoughtSignatures => strip_opaque_thought_signatures(obj),
            Self::StripContextManagement => {
                let mut changed = obj.remove("context_management").is_some();
                changed |= obj.remove("previous_response_id").is_some();
                changed |= obj.remove("previous_interaction_id").is_some();
                changed
            }
            Self::StripReplyPrefill => {
                if let Some(msgs) = obj.get_mut("messages").and_then(Value::as_array_mut)
                    && msgs
                        .last()
                        .and_then(|m| m.get("role"))
                        .and_then(Value::as_str)
                        == Some("assistant")
                {
                    msgs.pop();
                    true
                } else {
                    false
                }
            }
            Self::StripPromptCacheControl => strip_prompt_cache_controls(obj),
            Self::StripInclude => obj.remove("include").is_some(),
            Self::FallbackInputFileToExtractedText => fallback_input_files_to_text(obj),
            Self::StripAnthropicThinkingDisplay => obj
                .get_mut("thinking")
                .and_then(Value::as_object_mut)
                .is_some_and(|t| t.remove("display").is_some()),
            Self::GeminiThinkingLevelToBudget => ["generationConfig", "generation_config"]
                .iter()
                .any(|cfg_key| {
                    let Some(thinking) = obj
                        .get_mut(*cfg_key)
                        .and_then(|c| c.get_mut("thinkingConfig"))
                        .and_then(Value::as_object_mut)
                    else {
                        return false;
                    };
                    let Some(level) = thinking.remove("thinkingLevel") else {
                        return false;
                    };
                    let budget = match level
                        .as_str()
                        .unwrap_or_default()
                        .to_ascii_lowercase()
                        .as_str()
                    {
                        "minimal" | "low" => 1_024,
                        "medium" => 8_192,
                        _ => 24_576,
                    };
                    thinking.insert("thinkingBudget".to_owned(), Value::from(budget));
                    true
                }),
            Self::StepDownReasoningEffort => {
                let slot = if obj.get("reasoning").and_then(|r| r.get("effort")).is_some() {
                    obj.get_mut("reasoning").and_then(|r| r.get_mut("effort"))
                } else if obj
                    .get("output_config")
                    .and_then(|r| r.get("effort"))
                    .is_some()
                {
                    obj.get_mut("output_config")
                        .and_then(|r| r.get_mut("effort"))
                } else if obj
                    .get("generation_config")
                    .and_then(|r| r.get("thinking_level"))
                    .is_some()
                {
                    obj.get_mut("generation_config")
                        .and_then(|r| r.get_mut("thinking_level"))
                } else {
                    obj.get_mut("reasoning_effort")
                };
                let Some(effort) = slot else {
                    return false;
                };
                let next = match effort.as_str().unwrap_or_default() {
                    "max" => "xhigh",
                    "xhigh" => "high",
                    "minimal" => "low",
                    _ => return false,
                };
                *effort = Value::from(next);
                true
            }
            Self::StripStreamOptions => obj.remove("stream_options").is_some(),
            Self::ToggleMaxTokensField => {
                if let Some(v) = obj.remove("max_completion_tokens") {
                    obj.insert("max_tokens".to_owned(), v);
                    true
                } else if let Some(v) = obj.remove("max_tokens") {
                    obj.insert("max_completion_tokens".to_owned(), v);
                    true
                } else {
                    false
                }
            }
            Self::StripBuiltinTools => {
                let Some(tools) = obj.get_mut("tools").and_then(Value::as_array_mut) else {
                    return false;
                };
                let before = tools.len();
                tools.retain(|t| {
                    t.get("type")
                        .and_then(Value::as_str)
                        .is_none_or(|ty| ty == "function")
                });
                tools.len() != before
            }
            Self::StripSamplingParams => {
                let mut changed =
                    obj.remove("temperature").is_some() | obj.remove("top_p").is_some();
                for cfg_key in ["generationConfig", "generation_config"] {
                    if let Some(cfg) = obj.get_mut(cfg_key).and_then(Value::as_object_mut) {
                        for k in ["temperature", "topP", "top_p"] {
                            changed |= cfg.remove(k).is_some();
                        }
                    }
                }
                changed
            }
            Self::DropReasoning => {
                let mut changed = false;
                for k in ["reasoning", "reasoning_effort", "thinking", "output_config"] {
                    changed |= obj.remove(k).is_some();
                }
                for cfg_key in ["generationConfig", "generation_config"] {
                    if let Some(cfg) = obj.get_mut(cfg_key).and_then(Value::as_object_mut) {
                        for k in ["thinkingConfig", "thinking_level", "thinking_summaries"] {
                            changed |= cfg.remove(k).is_some();
                        }
                    }
                }
                changed
            }
        }
    }
}

/// Strips provider-specific opaque reasoning/thought blocks and signatures from a request body
/// when a provider rejects a stale or prefix-mismatched signature with HTTP 400.
fn strip_opaque_thought_signatures(obj: &mut serde_json::Map<String, Value>) -> bool {
    let mut changed = false;
    // OpenAI Responses: remove `type == "reasoning"` items from `input`.
    if let Some(input) = obj.get_mut("input").and_then(Value::as_array_mut) {
        let before = input.len();
        input.retain(|item| item.get("type").and_then(Value::as_str) != Some("reasoning"));
        if input.len() != before {
            changed = true;
        }
        // Gemini Interactions: strip `thought` parts and `signature` fields from `input[*].content[*]`.
        for turn in input.iter_mut() {
            if let Some(parts) = turn.get_mut("content").and_then(Value::as_array_mut) {
                let p_before = parts.len();
                parts.retain(|p| p.get("type").and_then(Value::as_str) != Some("thought"));
                if parts.len() != p_before {
                    changed = true;
                }
                for p in parts.iter_mut() {
                    if let Some(p_obj) = p.as_object_mut() {
                        changed |= p_obj.remove("signature").is_some();
                        changed |= p_obj.remove("thought_signature").is_some();
                        changed |= p_obj.remove("thoughtSignature").is_some();
                    }
                }
            }
        }
    }
    // Anthropic Messages: strip `thinking` and `redacted_thinking` content blocks from `messages`.
    if let Some(messages) = obj.get_mut("messages").and_then(Value::as_array_mut) {
        for msg in messages.iter_mut() {
            if let Some(blocks) = msg.get_mut("content").and_then(Value::as_array_mut) {
                let b_before = blocks.len();
                blocks.retain(|b| {
                    !matches!(
                        b.get("type").and_then(Value::as_str),
                        Some("thinking" | "redacted_thinking")
                    )
                });
                if blocks.len() != b_before {
                    changed = true;
                }
            }
        }
    }
    // Gemini generateContent: strip `thought: true` parts and replace any `thoughtSignature`
    // on functionCall parts with the official bypass sentinel or remove it on non-call parts.
    if let Some(contents) = obj.get_mut("contents").and_then(Value::as_array_mut) {
        for turn in contents.iter_mut() {
            if let Some(parts) = turn.get_mut("parts").and_then(Value::as_array_mut) {
                let p_before = parts.len();
                parts.retain(|p| p.get("thought").and_then(Value::as_bool) != Some(true));
                if parts.len() != p_before {
                    changed = true;
                }
                for p in parts.iter_mut() {
                    if let Some(p_obj) = p.as_object_mut() {
                        let is_fc = p_obj.contains_key("functionCall");
                        if is_fc {
                            if p_obj.get("thoughtSignature").and_then(Value::as_str)
                                != Some(crate::replay_policy::GEMINI_THOUGHT_SIGNATURE_BYPASS)
                                && p_obj.contains_key("thoughtSignature")
                            {
                                p_obj.insert(
                                    "thoughtSignature".to_owned(),
                                    Value::String(
                                        crate::replay_policy::GEMINI_THOUGHT_SIGNATURE_BYPASS
                                            .to_owned(),
                                    ),
                                );
                                changed = true;
                            }
                        } else {
                            changed |= p_obj.remove("thoughtSignature").is_some();
                            changed |= p_obj.remove("thought_signature").is_some();
                        }
                    }
                }
            }
        }
    }
    changed
}

/// Strips prompt caching directives (`cache_control`, `prompt_cache_key`) when a gateway or
/// older model endpoint rejects caching fields with HTTP 400.
fn strip_prompt_cache_controls(obj: &mut serde_json::Map<String, Value>) -> bool {
    let mut changed = obj.remove("cache_control").is_some();
    changed |= obj.remove("prompt_cache_key").is_some();
    if let Some(system_blocks) = obj.get_mut("system").and_then(Value::as_array_mut) {
        for block in system_blocks.iter_mut() {
            if let Some(b_obj) = block.as_object_mut() {
                changed |= b_obj.remove("cache_control").is_some();
            }
        }
    }
    if let Some(tools) = obj.get_mut("tools").and_then(Value::as_array_mut) {
        for tool in tools.iter_mut() {
            if let Some(t_obj) = tool.as_object_mut() {
                changed |= t_obj.remove("cache_control").is_some();
            }
        }
    }
    if let Some(messages) = obj.get_mut("messages").and_then(Value::as_array_mut) {
        for msg in messages.iter_mut() {
            if let Some(blocks) = msg.get_mut("content").and_then(Value::as_array_mut) {
                for block in blocks.iter_mut() {
                    if let Some(b_obj) = block.as_object_mut() {
                        changed |= b_obj.remove("cache_control").is_some();
                    }
                }
            }
        }
    }
    changed
}

/// Replaces unsupported `input_file` parts in `OpenAI` Responses `input` with a readable
/// `input_text` notice when a proxy or model rejects native `input_file` blocks with HTTP 400.
fn fallback_input_files_to_text(obj: &mut serde_json::Map<String, Value>) -> bool {
    let mut changed = false;
    if let Some(input) = obj.get_mut("input").and_then(Value::as_array_mut) {
        for item in input.iter_mut() {
            if let Some(parts) = item.get_mut("content").and_then(Value::as_array_mut) {
                for part in parts.iter_mut() {
                    if part.get("type").and_then(Value::as_str) == Some("input_file") {
                        let name = part
                            .get("filename")
                            .or_else(|| part.get("file_id"))
                            .and_then(Value::as_str)
                            .unwrap_or("attachment")
                            .to_owned();
                        *part = serde_json::json!({
                            "type": "input_text",
                            "text": format!("[Attached file `{name}` could not be passed natively by this endpoint]"),
                        });
                        changed = true;
                    }
                }
            }
        }
    }
    changed
}

/// Applies the next applicable heal at or after `*cursor`; advances the cursor past it.
pub fn apply_next_heal(body: &mut Value, cursor: &mut usize) -> Option<Http400Heal> {
    apply_next_heal_for_dialect(
        bistre_protocol::ProviderDialect::CustomOpenAi,
        body,
        cursor,
        "",
    )
}

/// Dialect-aware, error-body-guided HTTP 400 heal stepper:
/// - Immediately strips opaque signatures if the error cites `signature` / `encrypted_content` /
///   `thought_signature` / invalid `thinking` block.
/// - Immediately strips `cache_control` / `prompt_cache_key` when rejected.
/// - Immediately strips `temperature`/`top_p` when the error body cites sampling conflict with thinking.
/// - Never renames `max_tokens` -> `max_completion_tokens` on Anthropic or Gemini.
/// - Allows `StepDownReasoningEffort` to step repeatedly (`max -> xhigh -> high`) before moving on.
pub fn apply_next_heal_for_dialect(
    dialect: bistre_protocol::ProviderDialect,
    body: &mut Value,
    cursor: &mut usize,
    error_body: &str,
) -> Option<Http400Heal> {
    let lower = scan(error_body);
    if (lower.contains("signature")
        || lower.contains("encrypted_content")
        || lower.contains("thought_signature")
        || (lower.contains("thinking") && lower.contains("cannot be modified")))
        && Http400Heal::StripOpaqueThoughtSignatures.apply(body)
    {
        return Some(Http400Heal::StripOpaqueThoughtSignatures);
    }
    if (lower.contains("context_management")
        || lower.contains("previous_response_id")
        || lower.contains("previous_interaction_id")
        || lower.contains("anthropic-beta"))
        && Http400Heal::StripContextManagement.apply(body)
    {
        return Some(Http400Heal::StripContextManagement);
    }
    if lower.contains("prefill") && Http400Heal::StripReplyPrefill.apply(body) {
        return Some(Http400Heal::StripReplyPrefill);
    }
    if (lower.contains("cache_control") || lower.contains("prompt_cache"))
        && Http400Heal::StripPromptCacheControl.apply(body)
    {
        return Some(Http400Heal::StripPromptCacheControl);
    }
    if (lower.contains("input_file") || lower.contains("file_data"))
        && Http400Heal::FallbackInputFileToExtractedText.apply(body)
    {
        return Some(Http400Heal::FallbackInputFileToExtractedText);
    }
    if (lower.contains("temperature") || lower.contains("top_p") || lower.contains("topp"))
        && Http400Heal::StripSamplingParams.apply(body)
    {
        return Some(Http400Heal::StripSamplingParams);
    }
    while *cursor < HEAL_LADDER.len() {
        let heal = HEAL_LADDER[*cursor];
        if heal == Http400Heal::ToggleMaxTokensField
            && matches!(
                dialect,
                bistre_protocol::ProviderDialect::Anthropic
                    | bistre_protocol::ProviderDialect::GoogleGemini
            )
        {
            *cursor += 1;
            continue;
        }
        if heal.apply(body) {
            if heal != Http400Heal::StepDownReasoningEffort {
                *cursor += 1;
            }
            return Some(heal);
        }
        *cursor += 1;
    }
    None
}

/// Converts a hint into a sleep duration.
pub const fn hint_duration(ms: u64) -> Duration {
    Duration::from_millis(ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqwest::header::HeaderValue;
    use serde_json::json;

    #[test]
    fn classifies_quota_overflow_transient_and_auth() {
        assert_eq!(
            classify_http_failure(429, r#"{"error":{"code":"insufficient_quota"}}"#),
            FailureKind::QuotaExhausted
        );
        assert_eq!(
            classify_http_failure(
                429,
                r#"{"details":[{"quotaId":"GenerateRequestsPerDayPerProject"}]}"#
            ),
            FailureKind::QuotaExhausted
        );
        assert_eq!(
            classify_http_failure(429, "slow down"),
            FailureKind::RateLimited
        );
        assert_eq!(
            classify_http_failure(400, "This model's maximum context length is 128000"),
            FailureKind::ContextOverflow
        );
        assert_eq!(classify_http_failure(413, ""), FailureKind::ContextOverflow);
        assert_eq!(
            classify_http_failure(400, "Model is overloaded, please try again"),
            FailureKind::Transient
        );
        assert_eq!(
            classify_http_failure(400, "unknown field"),
            FailureKind::BadRequest
        );
        assert_eq!(classify_http_failure(401, ""), FailureKind::Auth);
        assert_eq!(classify_http_failure(503, ""), FailureKind::Transient);
        assert!(!FailureKind::QuotaExhausted.is_retryable());
        assert!(FailureKind::RateLimited.is_retryable());
    }

    #[test]
    fn retry_hint_priority_and_formats() {
        let now = UNIX_EPOCH + Duration::from_secs(784_111_777); // Sun, 06 Nov 1994 08:49:37 GMT
        let mut h = HeaderMap::new();
        h.insert(
            "retry-after",
            HeaderValue::from_static("Sun, 06 Nov 1994 08:50:07 GMT"),
        );
        assert_eq!(parse_retry_hint(&h, "", now), Some(30_000));
        h.insert("retry-after-ms", HeaderValue::from_static("2500"));
        assert_eq!(parse_retry_hint(&h, "", now), Some(2_500));
        let empty = HeaderMap::new();
        let body = r#"{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"12.5s"}]}}"#;
        assert_eq!(parse_retry_hint(&empty, body, now), Some(12_500));
        let mut huge = HeaderMap::new();
        huge.insert("retry-after", HeaderValue::from_static("86400"));
        assert_eq!(parse_retry_hint(&huge, "", now), Some(300_000));
        assert_eq!(
            parse_imf_fixdate("Sun, 06 Nov 1994 08:49:37 GMT"),
            Some(784_111_777)
        );
        let err = failure_error(FailureKind::RateLimited, 429, Some(4_000));
        assert_eq!(
            retry_after_from_detail(err.detail_code.as_deref()),
            Some(4_000)
        );
    }

    #[test]
    fn heal_ladder_applies_in_order_and_only_when_it_changes_the_body() {
        let mut body = json!({
            "thinking": {"type": "adaptive", "display": "summarized"},
            "reasoning_effort": "max",
            "stream_options": {"include_usage": true},
            "max_tokens": 100,
            "tools": [{"type": "web_search"}, {"type": "function", "name": "read"}],
            "temperature": 0.7,
        });
        let mut cursor = 0;
        let mut applied = Vec::new();
        while let Some(h) = apply_next_heal(&mut body, &mut cursor) {
            applied.push(h);
        }
        assert_eq!(
            applied,
            vec![
                Http400Heal::StripAnthropicThinkingDisplay,
                Http400Heal::StepDownReasoningEffort,
                Http400Heal::StepDownReasoningEffort,
                Http400Heal::StripStreamOptions,
                Http400Heal::ToggleMaxTokensField,
                Http400Heal::StripBuiltinTools,
                Http400Heal::StripSamplingParams,
                Http400Heal::DropReasoning,
            ]
        );
        assert_eq!(body.get("max_completion_tokens"), Some(&json!(100)));
        assert_eq!(
            body.get("tools").and_then(Value::as_array).map(Vec::len),
            Some(1)
        );
        assert!(body.get("thinking").is_none() && body.get("reasoning_effort").is_none());

        let mut gemini = json!({"generationConfig": {"thinkingConfig": {"thinkingLevel": "high"}}});
        assert!(Http400Heal::GeminiThinkingLevelToBudget.apply(&mut gemini));
        assert_eq!(
            gemini.pointer("/generationConfig/thinkingConfig/thinkingBudget"),
            Some(&json!(24_576))
        );
        assert!(may_retry_stream("", 0));
        assert!(!may_retry_stream("partial", 0));
    }

    #[test]
    fn effort_heals_cover_anthropic_and_gemini_interactions_fields() {
        let mut anthropic = json!({
            "thinking": {"type": "adaptive"},
            "output_config": {"effort": "max"}
        });
        assert!(Http400Heal::StepDownReasoningEffort.apply(&mut anthropic));
        assert_eq!(anthropic["output_config"]["effort"], "xhigh");
        assert!(Http400Heal::DropReasoning.apply(&mut anthropic));
        assert!(anthropic.get("output_config").is_none() && anthropic.get("thinking").is_none());

        let mut gemini = json!({
            "generation_config": {"thinking_level": "xhigh", "thinking_summaries": "auto", "temperature": 1}
        });
        assert!(Http400Heal::StepDownReasoningEffort.apply(&mut gemini));
        assert_eq!(gemini["generation_config"]["thinking_level"], "high");
        assert!(Http400Heal::DropReasoning.apply(&mut gemini));
        assert!(gemini["generation_config"].get("thinking_level").is_none());
        assert!(
            gemini["generation_config"]
                .get("thinking_summaries")
                .is_none()
        );
        assert_eq!(gemini["generation_config"]["temperature"], 1);
    }

    #[test]
    fn anthropic_400_never_renames_max_tokens_and_transient_400_is_tagged() {
        let mut body = json!({
            "model": "claude-test",
            "max_tokens": 4096,
            "temperature": 0.7,
            "thinking": { "type": "adaptive" },
            "output_config": { "effort": "max" }
        });
        let mut cursor = 0;
        let h1 = apply_next_heal_for_dialect(
            bistre_protocol::ProviderDialect::Anthropic,
            &mut body,
            &mut cursor,
            "temperature may only be set to 1 when thinking is enabled",
        );
        assert_eq!(h1, Some(Http400Heal::StripSamplingParams));
        assert!(body.get("temperature").is_none());
        assert_eq!(body["max_tokens"], 4096);

        while apply_next_heal_for_dialect(
            bistre_protocol::ProviderDialect::Anthropic,
            &mut body,
            &mut cursor,
            "generic bad request",
        )
        .is_some()
        {}
        assert_eq!(body["max_tokens"], 4096);
        assert!(body.get("max_completion_tokens").is_none());

        let err = failure_error(FailureKind::Transient, 400, None);
        assert!(
            err.detail_code
                .as_deref()
                .is_some_and(|d| d.contains("transient"))
        );
    }

    #[test]
    fn strips_opaque_thought_signatures_and_prompt_cache_controls_on_400() {
        let mut anth = json!({
            "model": "claude-test",
            "max_tokens": 16384,
            "cache_control": { "type": "ephemeral" },
            "system": [{ "type": "text", "text": "sys", "cache_control": { "type": "ephemeral" } }],
            "messages": [
                { "role": "user", "content": "hi" },
                { "role": "assistant", "content": [
                    { "type": "thinking", "thinking": "t", "signature": "stale_sig" },
                    { "type": "text", "text": "ok" }
                ]}
            ]
        });
        let mut cursor = 0;
        let h1 = apply_next_heal_for_dialect(
            bistre_protocol::ProviderDialect::Anthropic,
            &mut anth,
            &mut cursor,
            "Invalid signature in thinking block",
        );
        assert_eq!(h1, Some(Http400Heal::StripOpaqueThoughtSignatures));
        assert_eq!(
            anth["messages"][1]["content"].as_array().map(Vec::len),
            Some(1)
        );

        let h2 = apply_next_heal_for_dialect(
            bistre_protocol::ProviderDialect::Anthropic,
            &mut anth,
            &mut cursor,
            "cache_control is not supported by this proxy",
        );
        assert_eq!(h2, Some(Http400Heal::StripPromptCacheControl));
        assert!(anth.get("cache_control").is_none());
        assert!(anth["system"][0].get("cache_control").is_none());
    }
}
