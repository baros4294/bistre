//! The `web_fetch` and `web_search` tools (split out of `tools.rs`).

use crate::tools::ToolExecutionOutput;
use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, ToolRiskTier};
use regex::Regex;
use std::time::Instant;

/// Maximum bytes read from the network for one `web_fetch` (socket-level stream cap).
pub(crate) const MAX_WEB_FETCH_NETWORK_BYTES: usize = 2 * 1024 * 1024;
/// Maximum readable text returned to the model from one `web_fetch`.
pub(crate) const MAX_WEB_FETCH_TEXT_BYTES: usize = 64 * 1024;

/// Fetches a public HTTP(S) URL through `PublicWebTransport` (public-IP pinning, validated
/// redirects, streamed body cap) and returns readable text with HTML tags stripped.
pub async fn tool_web_fetch(
    web: &crate::ssrf::PublicWebTransport,
    url: &str,
) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    let clean_url = url.trim();
    let fetched = web.get(clean_url, MAX_WEB_FETCH_NETWORK_BYTES).await?;
    let body = String::from_utf8_lossy(&fetched.body);
    let mut capped = strip_html_tags(&body);
    if capped.len() > MAX_WEB_FETCH_TEXT_BYTES || fetched.truncated {
        truncate_utf8_in_place(&mut capped, MAX_WEB_FETCH_TEXT_BYTES);
        capped.push_str("...[truncated]");
    }

    Ok(ToolExecutionOutput {
        tool_name: "web_fetch".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: (200..300).contains(&fetched.status),
        summary: format!("fetch {} ({})", fetched.final_url, fetched.status),
        output_text: capped,
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
        media_attachments: Vec::new(),
    })
}

/// Searches the public web through `PublicWebTransport` (SSRF-safe, public-IP pinned, zero API
/// keys required) and returns structured title/URL/snippet results.
pub async fn tool_web_search(
    web: &crate::ssrf::PublicWebTransport,
    query: &str,
    max_results: usize,
) -> BistreResult<ToolExecutionOutput> {
    tool_web_search_with_endpoint(web, query, max_results, "duckduckgo").await
}

/// [`tool_web_search`] against a configured search endpoint (`"duckduckgo"` or custom HTTP(S) URL).
pub async fn tool_web_search_with_endpoint(
    web: &crate::ssrf::PublicWebTransport,
    query: &str,
    max_results: usize,
    endpoint: &str,
) -> BistreResult<ToolExecutionOutput> {
    let started = Instant::now();
    let clean_query = query.trim();
    if clean_query.is_empty() {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "empty_search_query",
        ));
    }
    let limit = max_results.clamp(1, 10);
    let encoded: String = clean_query
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            b' ' => "+".to_owned(),
            other => format!("%{other:02X}"),
        })
        .collect();
    let url = crate::agent_context::build_web_search_url(endpoint, &encoded)?;
    let fetched = web.get(&url, 512 * 1024).await?;
    let body = String::from_utf8_lossy(&fetched.body);

    let mut results = Vec::new();
    match Regex::new(r#"(?is)<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#) {
        Err(err) => tracing::warn!(%err, "web_search result pattern invalid; page text returned"),
        Ok(link_re) => {
            for cap in link_re.captures_iter(&body) {
                if results.len() >= limit {
                    break;
                }
                let raw_href = cap.get(1).map_or("", |m| m.as_str()).trim();
                let title = strip_html_tags(cap.get(2).map_or("", |m| m.as_str()));
                if title.is_empty() {
                    continue;
                }
                let href = raw_href
                    .split("uddg=")
                    .nth(1)
                    .and_then(|rest| rest.split('&').next())
                    .map_or_else(|| raw_href.to_owned(), percent_decode_url);
                results.push(format!("{}. {}: {}", results.len() + 1, title, href));
            }
        }
    }
    let count = results.len();
    let output_text = if results.is_empty() {
        strip_html_tags(&body).chars().take(4_000).collect()
    } else {
        results.join("\n")
    };
    Ok(ToolExecutionOutput {
        tool_name: "web_search".to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: (200..300).contains(&fetched.status),
        summary: format!("search `{clean_query}` ({count} results)"),
        output_text,
        diff_text: None,
        checkpoint_id: None,
        duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(0),
        media_attachments: Vec::new(),
    })
}

pub(crate) fn percent_decode_url(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3])
            && let Ok(val) = u8::from_str_radix(hex, 16)
        {
            out.push(val);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub(crate) fn truncate_utf8_in_place(text: &mut String, max_bytes: usize) {
    text.truncate(text.floor_char_boundary(max_bytes));
}

pub(crate) fn strip_html_tags(raw: &str) -> String {
    let tag_re = match Regex::new(r"(?is)<(?:script|style)[^>]*>.*?</(?:script|style)>|<[^>]+>") {
        Ok(re) => re,
        Err(err) => {
            tracing::warn!(%err, "html tag pattern invalid; text returned unstripped");
            return raw.to_owned();
        }
    };
    let no_tags = tag_re.replace_all(raw, " ");
    no_tags.split_whitespace().collect::<Vec<_>>().join(" ")
}
