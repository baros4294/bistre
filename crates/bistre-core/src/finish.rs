//! How a streamed reply ended, parsed from each dialect's terminal frames into one
//! typed [`FinishKind`]. Values against the official docs (Anthropic
//! `stop_reason` and the `error` event, `OpenAI` `incomplete_details.reason` and Chat
//! `finish_reason`, Gemini `FinishReason`); the `OpenAI` `response.failed` payload shape is
//! [UNVERIFIED] (read as the documented `ResponseError {code, message}`).

use bistre_protocol::ProviderDialect;
use serde_json::Value;

/// Longest provider-written error detail kept.
pub const MAX_REASON_CHARS: usize = 200;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FinishKind {
    /// A normal end of the reply.
    Stop,
    /// The reply asked for tools (another step follows).
    ToolUse,
    /// The output limit cut the reply short.
    Length,
    /// Anthropic paused a long server-side turn; sending it back continues it.
    PauseTurn,
    /// The provider declined or filtered the reply.
    Refusal,
    /// The provider ended the stream with an error. `retryable` for overload and server errors.
    Error { retryable: bool, code: String },
}

/// The provider's own words about an error, bounded and stripped of control characters and of
/// the `;` and `=` separators diagnostic details use.
pub fn sanitize_reason(raw: &str) -> String {
    raw.chars()
        .filter(|c| !c.is_control())
        .map(|c| if matches!(c, ';' | '=') { ',' } else { c })
        .collect::<String>()
        .trim()
        .chars()
        .take(MAX_REASON_CHARS)
        .collect()
}

/// The human message of a provider error body, if it has one.
pub fn provider_reason(body: &str) -> Option<String> {
    let val: Value = serde_json::from_str(body.trim()).ok()?;
    let msg = val
        .pointer("/error/message")
        .or_else(|| val.get("message"))
        .or_else(|| val.get("error").filter(|e| e.is_string()))
        .and_then(Value::as_str)?;
    let clean = sanitize_reason(msg);
    (!clean.is_empty()).then_some(clean)
}

fn error_kind(err: &Value) -> FinishKind {
    let code = err
        .get("type")
        .or_else(|| err.get("code"))
        .or_else(|| err.get("status"))
        .and_then(Value::as_str)
        .unwrap_or("error")
        .to_owned();
    let retryable = matches!(
        code.as_str(),
        "overloaded_error"
            | "api_error"
            | "timeout_error"
            | "server_error"
            | "rate_limit_exceeded"
            | "rate_limit_error"
            | "UNAVAILABLE"
            | "INTERNAL"
            | "RESOURCE_EXHAUSTED"
    );
    FinishKind::Error { retryable, code }
}

fn from_chat_reason(reason: &str) -> Option<FinishKind> {
    Some(match reason {
        "stop" => FinishKind::Stop,
        "length" => FinishKind::Length,
        "tool_calls" | "function_call" => FinishKind::ToolUse,
        "content_filter" => FinishKind::Refusal,
        _ => return None,
    })
}

fn from_gemini_reason(reason: &str) -> Option<FinishKind> {
    Some(match reason {
        "STOP" | "FINISH_REASON_UNSPECIFIED" => FinishKind::Stop,
        "MAX_TOKENS" => FinishKind::Length,
        "SAFETY"
        | "RECITATION"
        | "BLOCKLIST"
        | "PROHIBITED_CONTENT"
        | "SPII"
        | "IMAGE_SAFETY"
        | "IMAGE_PROHIBITED_CONTENT"
        | "IMAGE_RECITATION"
        | "LANGUAGE" => FinishKind::Refusal,
        "MALFORMED_FUNCTION_CALL" | "MALFORMED_RESPONSE" | "OTHER" => FinishKind::Error {
            retryable: true,
            code: reason.to_owned(),
        },
        _ => return None,
    })
}

/// The finish this frame reports, if it is a terminal (or error) frame.
pub fn finish_of_frame(dialect: ProviderDialect, val: &Value) -> Option<FinishKind> {
    // A plain JSON error body (often with HTTP 200) in any dialect.
    if let Some(err) = val.get("error").filter(|e| e.is_object())
        && val
            .get("type")
            .and_then(Value::as_str)
            .is_none_or(|t| t == "error")
    {
        return Some(error_kind(err));
    }
    let kind = val.get("type").and_then(Value::as_str).unwrap_or("");
    match dialect {
        ProviderDialect::Anthropic => match kind {
            "message_delta" => match val.pointer("/delta/stop_reason").and_then(Value::as_str)? {
                "end_turn" | "stop_sequence" => Some(FinishKind::Stop),
                "max_tokens" | "model_context_window_exceeded" => Some(FinishKind::Length),
                "tool_use" => Some(FinishKind::ToolUse),
                "pause_turn" => Some(FinishKind::PauseTurn),
                "refusal" => Some(FinishKind::Refusal),
                _ => None,
            },
            _ => None,
        },
        ProviderDialect::OpenAi => match kind {
            "response.completed" => Some(FinishKind::Stop),
            "response.incomplete" => Some(
                match val
                    .pointer("/response/incomplete_details/reason")
                    .and_then(Value::as_str)
                {
                    Some("content_filter") => FinishKind::Refusal,
                    _ => FinishKind::Length,
                },
            ),
            "response.failed" => Some(val.pointer("/response/error").map_or(
                FinishKind::Error {
                    retryable: true,
                    code: "failed".to_owned(),
                },
                error_kind,
            )),
            _ => chat_finish(val),
        },
        ProviderDialect::CustomOpenAi => chat_finish(val),
        ProviderDialect::GoogleGemini => val
            .pointer("/candidates/0/finishReason")
            .and_then(Value::as_str)
            .and_then(from_gemini_reason)
            .or_else(|| {
                (val.get("event_type").and_then(Value::as_str) == Some("interaction.completed"))
                    .then_some(FinishKind::Stop)
            }),
    }
}

fn chat_finish(val: &Value) -> Option<FinishKind> {
    val.pointer("/choices/0/finish_reason")
        .and_then(Value::as_str)
        .and_then(from_chat_reason)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn finish(dialect: ProviderDialect, raw: &str) -> Option<FinishKind> {
        serde_json::from_str::<Value>(raw)
            .ok()
            .and_then(|v| finish_of_frame(dialect, &v))
    }

    #[test]
    fn every_dialect_reports_how_the_reply_ended() {
        use ProviderDialect as D;
        assert_eq!(
            finish(
                D::Anthropic,
                r#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#
            ),
            Some(FinishKind::Length)
        );
        assert_eq!(
            finish(
                D::Anthropic,
                r#"{"type":"message_delta","delta":{"stop_reason":"pause_turn"}}"#
            ),
            Some(FinishKind::PauseTurn)
        );
        assert_eq!(
            finish(
                D::Anthropic,
                r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
            ),
            Some(FinishKind::Error {
                retryable: true,
                code: "overloaded_error".to_owned()
            })
        );
        assert_eq!(
            finish(
                D::OpenAi,
                r#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
            ),
            Some(FinishKind::Length)
        );
        assert_eq!(
            finish(
                D::CustomOpenAi,
                r#"{"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#
            ),
            Some(FinishKind::Refusal)
        );
        assert_eq!(
            finish(
                D::GoogleGemini,
                r#"{"candidates":[{"finishReason":"SAFETY"}]}"#
            ),
            Some(FinishKind::Refusal)
        );
        assert_eq!(
            finish(
                D::CustomOpenAi,
                r#"{"error":{"message":"model not found","code":"model_not_found"}}"#
            ),
            Some(FinishKind::Error {
                retryable: false,
                code: "model_not_found".to_owned()
            })
        );
    }

    #[test]
    fn provider_reasons_are_bounded_and_cannot_forge_detail_fields() {
        assert_eq!(
            provider_reason(r#"{"error":{"message":"model x;retry_after_ms=1 not found\n"}}"#)
                .as_deref(),
            Some("model x,retry_after_ms,1 not found")
        );
        let long = format!(r#"{{"error":{{"message":"{}"}}}}"#, "a".repeat(500));
        assert_eq!(
            provider_reason(&long).map(|r| r.chars().count()),
            Some(MAX_REASON_CHARS)
        );
        assert_eq!(provider_reason("not json"), None);
    }
}
