//! The raw request body and response stream of the latest chat requests, kept in memory only
//! (never saved, gone when the core stops) so a reply's More menu can show what was sent and
//! what came back. Keys are never in it: they travel in headers, which are not kept, and a
//! query key is added to the URL only when the request is sent.

use std::collections::VecDeque;
use std::sync::{LazyLock, Mutex};

use bistre_protocol::lock_or_recover;
use serde::{Deserialize, Serialize};

/// Requests kept; the oldest is dropped first.
pub const MAX_RAW_EXCHANGES: usize = 16;
/// Bytes kept of each request body and each response, in UTF-8.
pub const MAX_RAW_BYTES: usize = 256 * 1024;

/// One request as it was built and the bytes its response streamed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawExchange {
    /// The reply's `request_id` metadata (`<run>:llm:<step>`).
    pub request_id: String,
    pub url: String,
    /// The JSON body, pretty-printed, before any automatic repair of a refused request.
    pub request_body: String,
    pub response: String,
    /// Either side passed [`MAX_RAW_BYTES`] and was cut there.
    pub truncated: bool,
}

/// The kept records, oldest first.
#[derive(Debug, Default)]
struct RawLog(Mutex<VecDeque<RawExchange>>);

static LOG: LazyLock<RawLog> = LazyLock::new(RawLog::default);

/// Cuts `text` to at most `max` bytes on a character boundary; `true` when it was cut.
fn clip(text: &mut String, max: usize) -> bool {
    if text.len() <= max {
        return false;
    }
    let end = text.floor_char_boundary(max);
    text.truncate(end);
    true
}

impl RawLog {
    fn record_request(&self, request_id: &str, url: &str, body: &serde_json::Value) {
        let mut request_body = match serde_json::to_string_pretty(body) {
            Ok(text) => text,
            Err(err) => {
                tracing::warn!(%err, "raw request not kept");
                return;
            }
        };
        let truncated = clip(&mut request_body, MAX_RAW_BYTES);
        let mut log = lock_or_recover(&self.0, "raw_exchanges");
        log.retain(|e| e.request_id != request_id);
        if log.len() >= MAX_RAW_EXCHANGES {
            log.pop_front();
        }
        log.push_back(RawExchange {
            request_id: request_id.to_owned(),
            url: url.to_owned(),
            request_body,
            response: String::new(),
            truncated,
        });
    }

    fn append_response(&self, request_id: &str, bytes: &[u8]) {
        let mut log = lock_or_recover(&self.0, "raw_exchanges");
        let Some(entry) = log.iter_mut().rev().find(|e| e.request_id == request_id) else {
            return;
        };
        if entry.response.len() >= MAX_RAW_BYTES {
            entry.truncated = true;
            return;
        }
        entry.response.push_str(&String::from_utf8_lossy(bytes));
        entry.truncated |= clip(&mut entry.response, MAX_RAW_BYTES);
    }

    fn get(&self, request_id: &str) -> Option<RawExchange> {
        lock_or_recover(&self.0, "raw_exchanges")
            .iter()
            .rev()
            .find(|e| e.request_id == request_id)
            .cloned()
    }
}

/// Starts the record of `request_id`; a retried request replaces its earlier record.
pub(crate) fn record_request(request_id: &str, url: &str, body: &serde_json::Value) {
    LOG.record_request(request_id, url, body);
}

/// Adds streamed response bytes to `request_id`'s record, up to [`MAX_RAW_BYTES`].
pub(crate) fn append_response(request_id: &str, bytes: &[u8]) {
    LOG.append_response(request_id, bytes);
}

/// The kept record of `request_id`, if it is still among the latest [`MAX_RAW_EXCHANGES`].
#[must_use]
pub fn get(request_id: &str) -> Option<RawExchange> {
    LOG.get(request_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Records are bounded in count and size, cut on a character boundary, and a retry
    /// replaces its earlier record.
    #[test]
    fn records_are_bounded_and_a_retry_replaces_its_record() -> Result<(), &'static str> {
        let log = RawLog::default();
        let id = |i: usize| format!("run:llm:{i}");
        for i in 0..=MAX_RAW_EXCHANGES {
            log.record_request(
                &id(i),
                "https://example.test/v1",
                &serde_json::json!({ "n": i }),
            );
        }
        assert_eq!(log.get(&id(0)), None, "the oldest is dropped");
        log.record_request(&id(1), "u", &serde_json::json!({ "retry": true }));
        log.append_response(&id(1), "data: \u{e9}".repeat(MAX_RAW_BYTES).as_bytes());
        let kept = log.get(&id(1)).ok_or("kept")?;
        assert!(kept.request_body.contains("retry"));
        assert!(kept.truncated);
        assert!(kept.response.len() <= MAX_RAW_BYTES);
        assert_eq!(
            lock_or_recover(&log.0, "raw_exchanges").len(),
            MAX_RAW_EXCHANGES
        );
        Ok(())
    }
}
