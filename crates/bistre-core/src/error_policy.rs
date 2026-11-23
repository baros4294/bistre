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

/// Builds the typed error, encoding the status and any retry hint in the detail code
/// (`http_429;retry_after_ms=30000`) so the run loop can schedule its backoff.
pub fn failure_error(kind: FailureKind, status: u16, retry_after_ms: Option<u64>) -> BistreError {
    let detail = retry_after_ms.map_or_else(
        || format!("http_{status}"),
        |ms| format!("http_{status};retry_after_ms={ms}"),
    );
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
    StripAnthropicThinkingDisplay,
    GeminiThinkingLevelToBudget,
    StepDownReasoningEffort,
    StripStreamOptions,
    ToggleMaxTokensField,
    StripBuiltinTools,
    StripSamplingParams,
    DropReasoning,
}

pub const HEAL_LADDER: [Http400Heal; 8] = [
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
    pub fn apply(self, body: &mut Value) -> bool {
        let Some(obj) = body.as_object_mut() else {
            return false;
        };
        match self {
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
                for k in ["reasoning", "reasoning_effort", "thinking"] {
                    changed |= obj.remove(k).is_some();
                }
                for cfg_key in ["generationConfig", "generation_config"] {
                    if let Some(cfg) = obj.get_mut(cfg_key).and_then(Value::as_object_mut) {
                        changed |= cfg.remove("thinkingConfig").is_some();
                    }
                }
                changed
            }
        }
    }
}

/// Applies the next applicable heal at or after `*cursor`; advances the cursor past it.
pub fn apply_next_heal(body: &mut Value, cursor: &mut usize) -> Option<Http400Heal> {
    while *cursor < HEAL_LADDER.len() {
        let heal = HEAL_LADDER[*cursor];
        *cursor += 1;
        if heal.apply(body) {
            return Some(heal);
        }
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
}
