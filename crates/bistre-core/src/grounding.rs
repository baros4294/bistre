//! Web sources a reply used (A-W 4c / B2): parsed once at the protocol boundary into typed,
//! bounded values and stored with the reply. Wire shapes checked 2026-11-25 against the
//! official docs:
//! - Gemini `generateContent`: `candidates[].groundingMetadata.groundingChunks[].web.{uri,title}`;
//!   a streamed chunk carries only chunks not sent before, so they accumulate.
//! - Gemini Interactions and `OpenAI` Responses: `url_citation` annotations `{url, title}` on output
//!   text (`OpenAI`: `message.content[].annotations[]`, read from the completed items).
//! - Anthropic: `web_search_tool_result` blocks list `web_search_result {url, title}`; text
//!   blocks cite `web_search_result_location {url, title, cited_text}`. The streamed
//!   `citations_delta` form is read the same way [UNVERIFIED against a live stream].
//!
//! Sources are UI data: replay never sends them back to a model (`wire_history` reads only the
//! fields it needs from the node metadata).

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// At most this many sources are kept per reply.
pub const MAX_SOURCES_PER_TURN: usize = 64;
/// Format version of the stored `{"grounding": {"v": .., "sources": [..]}}` metadata.
pub const GROUNDING_META_VERSION: u64 = 1;
const MAX_TITLE_CHARS: usize = 300;
const MAX_CITED_CHARS: usize = 500;
const MAX_URL_BYTES: usize = 2048;
/// Bounds on the scan of one frame (depth and visited values).
const MAX_SCAN_DEPTH: usize = 12;
const MAX_SCAN_NODES: usize = 4096;

/// One web page a reply used. Only `http`/`https` URLs exist; text fields are bounded.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroundingSource {
    url: String,
    title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cited_text: Option<String>,
}

impl GroundingSource {
    /// Parses one source; `None` for anything but a well-formed `http(s)` URL.
    pub fn parse(url: &str, title: &str, cited_text: Option<&str>) -> Option<Self> {
        let url = url.trim();
        if url.is_empty() || url.len() > MAX_URL_BYTES {
            return None;
        }
        let parsed = reqwest::Url::parse(url).ok()?;
        if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
            return None;
        }
        let title = bounded(title, MAX_TITLE_CHARS);
        let cited_text = cited_text
            .map(|t| bounded(t, MAX_CITED_CHARS))
            .filter(|t| !t.is_empty());
        Some(Self {
            url: parsed.to_string(),
            title,
            cited_text,
        })
    }

    pub fn url(&self) -> &str {
        &self.url
    }
    pub fn title(&self) -> &str {
        &self.title
    }
    pub fn cited_text(&self) -> Option<&str> {
        self.cited_text.as_deref()
    }
}

fn bounded(text: &str, max_chars: usize) -> String {
    let clean: String = text
        .chars()
        .filter(|c| !c.is_control() || *c == ' ')
        .collect();
    clean.trim().chars().take(max_chars).collect()
}

/// Collects sources from streamed frames of any dialect: deduplicated by URL (a later entry
/// may add the cited text), capped at [`MAX_SOURCES_PER_TURN`].
#[derive(Debug, Default)]
pub(crate) struct GroundingCollector {
    sources: Vec<GroundingSource>,
    seen: HashSet<String>,
}

impl GroundingCollector {
    pub(crate) fn absorb_frame(&mut self, frame: &Value) {
        let mut budget = MAX_SCAN_NODES;
        self.scan(frame, 0, &mut budget);
    }

    pub(crate) fn into_sources(self) -> Vec<GroundingSource> {
        self.sources
    }

    fn scan(&mut self, value: &Value, depth: usize, budget: &mut usize) {
        if depth > MAX_SCAN_DEPTH || *budget == 0 {
            return;
        }
        *budget -= 1;
        match value {
            Value::Object(map) => {
                if let Some("url_citation" | "web_search_result" | "web_search_result_location") =
                    map.get("type").and_then(Value::as_str)
                {
                    // Chat Completions nests the fields under `url_citation` [UNVERIFIED].
                    let fields = map
                        .get("url_citation")
                        .and_then(Value::as_object)
                        .unwrap_or(map);
                    let url = fields.get("url").and_then(Value::as_str).unwrap_or("");
                    let title = fields.get("title").and_then(Value::as_str).unwrap_or("");
                    let cited = map.get("cited_text").and_then(Value::as_str);
                    self.push(url, title, cited);
                }
                if let Some(Value::Array(chunks)) = map.get("groundingChunks") {
                    for chunk in chunks {
                        if let Some(web) = chunk.get("web") {
                            let url = web.get("uri").and_then(Value::as_str).unwrap_or("");
                            let title = web.get("title").and_then(Value::as_str).unwrap_or("");
                            self.push(url, title, None);
                        }
                    }
                }
                for child in map.values() {
                    self.scan(child, depth + 1, budget);
                }
            }
            Value::Array(items) => {
                for child in items {
                    self.scan(child, depth + 1, budget);
                }
            }
            _ => {}
        }
    }

    fn push(&mut self, url: &str, title: &str, cited: Option<&str>) {
        let Some(source) = GroundingSource::parse(url, title, cited) else {
            return;
        };
        if self.seen.contains(source.url()) {
            if let Some(existing) = self.sources.iter_mut().find(|s| s.url == source.url) {
                if existing.cited_text.is_none() {
                    existing.cited_text = source.cited_text;
                }
                if existing.title.is_empty() {
                    existing.title = source.title;
                }
            }
            return;
        }
        if self.sources.len() >= MAX_SOURCES_PER_TURN {
            return;
        }
        self.seen.insert(source.url.clone());
        self.sources.push(source);
    }
}

/// The stored form: `{"v": 1, "sources": [...]}`.
pub(crate) fn grounding_meta(sources: &[GroundingSource]) -> Value {
    serde_json::json!({ "v": GROUNDING_META_VERSION, "sources": sources })
}

/// Reads the sources stored with a node; another format version reads as none.
pub fn parse_grounding_meta(provider_meta_json: Option<&str>) -> Vec<GroundingSource> {
    let Some(raw) = provider_meta_json else {
        return Vec::new();
    };
    let Ok(meta) = serde_json::from_str::<Value>(raw) else {
        return Vec::new();
    };
    let Some(g) = meta.get("grounding") else {
        return Vec::new();
    };
    if g.get("v").and_then(Value::as_u64) != Some(GROUNDING_META_VERSION) {
        return Vec::new();
    }
    let Some(items) = g.get("sources").and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| {
            GroundingSource::parse(
                item.get("url").and_then(Value::as_str).unwrap_or(""),
                item.get("title").and_then(Value::as_str).unwrap_or(""),
                item.get("cited_text").and_then(Value::as_str),
            )
        })
        .take(MAX_SOURCES_PER_TURN)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect(frames: &[&str]) -> Vec<GroundingSource> {
        let mut c = GroundingCollector::default();
        for f in frames {
            if let Ok(v) = serde_json::from_str::<Value>(f) {
                c.absorb_frame(&v);
            }
        }
        c.into_sources()
    }

    #[test]
    fn gemini_grounding_chunks_accumulate_across_stream_frames() {
        let got = collect(&[
            r#"{"candidates":[{"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://a.example/x","title":"A"}}]}}]}"#,
            r#"{"candidates":[{"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://b.example/","title":"B"}}]}}]}"#,
        ]);
        let urls: Vec<&str> = got.iter().map(GroundingSource::url).collect();
        assert_eq!(urls, ["https://a.example/x", "https://b.example/"]);
    }

    #[test]
    fn openai_url_citations_in_a_completed_message() {
        let got = collect(&[
            r#"{"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"t","annotations":[{"type":"url_citation","start_index":0,"end_index":1,"url":"https://news.example/a","title":"News"}]}]}}"#,
            r#"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","annotations":[{"type":"url_citation","url":"https://news.example/a","title":"News"}]}]}]}}"#,
        ]);
        assert_eq!(
            got.len(),
            1,
            "the repeat in response.completed is deduplicated"
        );
        assert_eq!(got[0].title(), "News");
    }

    #[test]
    fn anthropic_results_and_citations_merge_by_url() {
        let got = collect(&[
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","url":"https://en.wikipedia.org/wiki/Claude_Shannon","title":"Claude Shannon - Wikipedia","encrypted_content":"x","page_age":"April 30, 2025"}]}}"#,
            r#"{"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://en.wikipedia.org/wiki/Claude_Shannon","title":"Claude Shannon - Wikipedia","encrypted_index":"y","cited_text":"Claude Elwood Shannon (April 30, 1916 \u2013 February 24, 2001)"}}}"#,
        ]);
        assert_eq!(got.len(), 1);
        assert_eq!(
            got[0].cited_text(),
            Some("Claude Elwood Shannon (April 30, 1916 \u{2013} February 24, 2001)")
        );
    }

    #[test]
    fn only_web_urls_are_kept_and_the_list_is_capped() {
        assert!(GroundingSource::parse("javascript:alert(1)", "x", None).is_none());
        assert!(GroundingSource::parse("file:///C:/secret.txt", "x", None).is_none());
        assert!(GroundingSource::parse("https://", "x", None).is_none());
        let many: String = (0..100)
            .map(|i| {
                format!(r#"{{"type":"url_citation","url":"https://s{i}.example/","title":"t"}}"#)
            })
            .collect::<Vec<_>>()
            .join(",");
        let got = collect(&[&format!("[{many}]")]);
        assert_eq!(got.len(), MAX_SOURCES_PER_TURN);
        let long_title = "t".repeat(1000);
        let s = GroundingSource::parse("https://x.example/", &long_title, None);
        assert_eq!(s.map(|s| s.title().chars().count()), Some(300));
    }

    #[test]
    fn stored_sources_round_trip_and_other_versions_read_as_none() {
        let sources =
            collect(&[r#"{"type":"url_citation","url":"https://a.example/","title":"A"}"#]);
        let meta = serde_json::json!({ "grounding": grounding_meta(&sources) }).to_string();
        assert_eq!(parse_grounding_meta(Some(&meta)), sources);
        let v2 = r#"{"grounding":{"v":2,"sources":[{"url":"https://a.example/","title":"A"}]}}"#;
        assert_eq!(parse_grounding_meta(Some(v2)), Vec::new());
    }
}
