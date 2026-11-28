//! User-supplied custom provider headers and body fields.
//!
//! Parsed once at the boundary into types that cannot hold an invalid header: a
//! [`CustomHeader`] can only be built by [`parse_custom_headers`], which rejects reserved and
//! credential headers, non-token names, control characters (line breaks are injection), and
//! values that are not printable ASCII after zero-width characters are removed. An invalid entry is an error, never silently dropped.

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use reqwest::header::{HeaderName, HeaderValue};
use serde_json::{Map, Value};

use crate::credentials::sanitize_header_value;

/// Most custom headers one provider may send.
pub const MAX_CUSTOM_HEADERS: usize = 32;
/// Longest custom header value, in bytes.
pub const MAX_CUSTOM_HEADER_VALUE: usize = 4096;
/// Longest custom body (`body_json`), in bytes.
pub const MAX_CUSTOM_BODY: usize = 64 * 1024;

/// Headers Bistre sets itself, that carry credentials, or that control the connection.
const RESERVED: [&str; 17] = [
    "accept",
    "anthropic-beta",
    "anthropic-version",
    "api-key",
    "authorization",
    "connection",
    "content-length",
    "content-type",
    "cookie",
    "host",
    "keep-alive",
    "proxy-authorization",
    "te",
    "transfer-encoding",
    "upgrade",
    "x-api-key",
    "x-goog-api-key",
];

/// One validated custom header.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CustomHeader {
    name: HeaderName,
    value: HeaderValue,
}

impl CustomHeader {
    pub const fn name(&self) -> &HeaderName {
        &self.name
    }

    pub const fn value(&self) -> &HeaderValue {
        &self.value
    }
}

fn invalid(detail: &str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::ProviderHeadersInvalid, detail)
}

/// RFC 9110 `token` characters.
fn is_token_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b)
}

/// Parses the `headers_json` text: an empty string is no headers; anything else must be a
/// JSON object of string names to string values that all pass validation.
pub fn parse_custom_headers(raw: &str) -> BistreResult<Vec<CustomHeader>> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    let Ok(Value::Object(map)) = serde_json::from_str::<Value>(trimmed) else {
        return Err(invalid("headers_not_object"));
    };
    if map.len() > MAX_CUSTOM_HEADERS {
        return Err(invalid("too_many_headers"));
    }
    map.into_iter()
        .map(|(name, value)| {
            let name = name.trim().to_ascii_lowercase();
            if name.is_empty() || !name.bytes().all(is_token_char) {
                return Err(invalid("header_name_invalid"));
            }
            if RESERVED.contains(&name.as_str()) {
                return Err(invalid(&format!("header_reserved:{name}")));
            }
            let Value::String(value) = value else {
                return Err(invalid(&format!("header_value_not_text:{name}")));
            };
            // A line break or other control character is header injection, not paste noise:
            // refuse it rather than strip it. Zero-width characters and a BOM are removed.
            if value.chars().any(char::is_control) {
                return Err(invalid(&format!("header_value_invalid:{name}")));
            }
            let clean = sanitize_header_value(&value);
            if clean.len() > MAX_CUSTOM_HEADER_VALUE
                || !clean.bytes().all(|b| (0x20..=0x7e).contains(&b))
            {
                return Err(invalid(&format!("header_value_invalid:{name}")));
            }
            let header_name = HeaderName::from_bytes(name.as_bytes())
                .map_err(|_| invalid("header_name_invalid"))?;
            let header_value = HeaderValue::from_str(&clean)
                .map_err(|_| invalid(&format!("header_value_invalid:{name}")))?;
            Ok(CustomHeader {
                name: header_name,
                value: header_value,
            })
        })
        .collect()
}

/// Parses the `body_json` text: empty means no extra fields; otherwise a JSON object.
pub fn parse_custom_body(raw: &str) -> BistreResult<Option<Map<String, Value>>> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if trimmed.len() > MAX_CUSTOM_BODY {
        return Err(BistreError::with_detail(
            DiagnosticKey::ProviderBodyInvalid,
            "body_too_large",
        ));
    }
    match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Object(m)) if m.is_empty() => Ok(None),
        Ok(Value::Object(m)) => Ok(Some(m)),
        _ => Err(BistreError::with_detail(
            DiagnosticKey::ProviderBodyInvalid,
            "body_not_object",
        )),
    }
}

/// `scheme://host[:port]` of a base URL; `None` when it does not parse.
pub fn origin_of(base_url: &str) -> Option<String> {
    let url = reqwest::Url::parse(base_url.trim()).ok()?;
    let host = url.host_str()?;
    Some(match url.port_or_known_default() {
        Some(port) => format!("{}://{host}:{port}", url.scheme()),
        None => format!("{}://{host}", url.scheme()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detail(raw: &str) -> Option<String> {
        parse_custom_headers(raw).err().and_then(|e| e.detail_code)
    }

    #[test]
    fn valid_headers_parse_and_invisible_characters_are_removed() -> BistreResult<()> {
        let parsed =
            parse_custom_headers("{\"X-Team\":\" a\u{200b}b \",\"HTTP-Referer\":\"https://x\"}")?;
        let pairs: Vec<_> = parsed
            .iter()
            .map(|h| {
                (
                    h.name().as_str().to_owned(),
                    h.value().to_str().unwrap_or("?").to_owned(),
                )
            })
            .collect();
        assert_eq!(
            pairs,
            [
                ("http-referer".to_owned(), "https://x".to_owned()),
                ("x-team".to_owned(), "ab".to_owned())
            ]
        );
        assert_eq!(parse_custom_headers("  ")?.len(), 0);
        Ok(())
    }

    #[test]
    fn reserved_credential_and_malformed_headers_are_errors() {
        assert_eq!(
            detail(r#"{"Authorization":"x"}"#).as_deref(),
            Some("header_reserved:authorization")
        );
        assert_eq!(
            detail(r#"{"x-goog-api-key":"x"}"#).as_deref(),
            Some("header_reserved:x-goog-api-key")
        );
        assert_eq!(
            detail(r#"{"Bad Name":"x"}"#).as_deref(),
            Some("header_name_invalid")
        );
        assert_eq!(
            detail(r#"{"X-A":"line\nX-B: 1"}"#).as_deref(),
            Some("header_value_invalid:x-a")
        );
        assert_eq!(
            detail(r#"{"X-A":"café"}"#).as_deref(),
            Some("header_value_invalid:x-a")
        );
        assert_eq!(
            detail(r#"{"X-A":1}"#).as_deref(),
            Some("header_value_not_text:x-a")
        );
        assert_eq!(detail("X-A: b").as_deref(), Some("headers_not_object"));
        let many: String = (0..=MAX_CUSTOM_HEADERS)
            .map(|i| format!("\"x-{i}\":\"v\""))
            .collect::<Vec<_>>()
            .join(",");
        assert_eq!(
            detail(&format!("{{{many}}}")).as_deref(),
            Some("too_many_headers")
        );
    }

    #[test]
    fn body_must_be_an_object_and_origin_ignores_paths() {
        assert!(parse_custom_body("").is_ok_and(|b| b.is_none()));
        assert!(parse_custom_body(r#"{"seed":42}"#).is_ok_and(|b| b.is_some()));
        assert!(parse_custom_body("[1]").is_err());
        assert_eq!(
            origin_of("https://api.example.com/v1/"),
            Some("https://api.example.com:443".to_owned())
        );
        assert_eq!(
            origin_of("http://127.0.0.1:11434/v1"),
            Some("http://127.0.0.1:11434".to_owned())
        );
        assert_eq!(origin_of("not a url"), None);
    }
}
