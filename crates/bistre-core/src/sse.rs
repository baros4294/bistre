//! `SseFramer` and `StreamingTextBuffer` (Spec 02 streaming invariants).
//!
//! - UTF-8 carry-over across network chunks; BOM stripped at stream start only.
//! - A single-line `data:` frame holding complete JSON is dispatched immediately (proxies that
//!   buffer the blank separator line no longer stall the stream); multi-line frames still wait
//!   for the blank line per the SSE spec.
//! - `\r\n`, `\n`, and lone `\r` line endings; a trailing `\r` is held back until the next chunk
//!   so a split `\r` + `\n` never produces a phantom blank line.
//! - Plain-JSON fallback: when the upstream ignores `stream: true` and returns one JSON body, the
//!   whole body is yielded once at EOF.
//! - Hard `64 MiB` cap on buffered, undispatched bytes.

use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};

/// Idle timeout before the first byte (slow-first-token reasoning models).
pub const INITIAL_LINE_TIMEOUT: Duration = Duration::from_secs(300);
/// Idle timeout between chunks once streaming started.
pub const STREAMING_LINE_TIMEOUT: Duration = Duration::from_secs(90);
/// Maximum buffered, not-yet-dispatched bytes.
pub const MAX_SSE_BUFFER_BYTES: usize = 64 * 1024 * 1024;

/// Incremental Server-Sent Events framer.
#[derive(Debug, Default)]
pub struct SseFramer {
    utf8_carry: Vec<u8>,
    pending: String,
    data_lines: Vec<String>,
    started: bool,
    saw_sse_field: bool,
    plain_body: String,
}

fn is_complete_json(text: &str) -> bool {
    let t = text.trim();
    ((t.starts_with('{') && t.ends_with('}')) || (t.starts_with('[') && t.ends_with(']')))
        && serde_json::from_str::<serde::de::IgnoredAny>(t).is_ok()
}

impl SseFramer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feeds network bytes and returns every dispatchable `data` payload.
    pub fn push_bytes(&mut self, bytes: &[u8]) -> BistreResult<Vec<String>> {
        self.utf8_carry.extend_from_slice(bytes);
        self.drain_valid_utf8();
        if self.pending.len() + self.plain_body.len() + self.utf8_carry.len() > MAX_SSE_BUFFER_BYTES
        {
            return Err(BistreError::with_detail(
                DiagnosticKey::ProviderStreamInterrupted,
                "sse_buffer_cap",
            ));
        }
        let mut out = Vec::new();
        self.process_lines(false, &mut out);
        Ok(out)
    }

    /// Flushes at EOF: a pending frame without its blank line, or the plain-JSON fallback body.
    pub fn finish(&mut self) -> Vec<String> {
        if !self.utf8_carry.is_empty() {
            let lossy = String::from_utf8_lossy(&self.utf8_carry).into_owned();
            self.pending.push_str(&lossy);
            self.utf8_carry.clear();
        }
        let mut out = Vec::new();
        self.process_lines(true, &mut out);
        if !self.data_lines.is_empty() {
            out.push(self.data_lines.join("\n"));
            self.data_lines.clear();
        }
        if !self.saw_sse_field && is_complete_json(&self.plain_body) {
            out.push(core::mem::take(&mut self.plain_body).trim().to_owned());
        }
        out
    }

    fn drain_valid_utf8(&mut self) {
        loop {
            match core::str::from_utf8(&self.utf8_carry) {
                Ok(valid) => {
                    self.pending.push_str(valid);
                    self.utf8_carry.clear();
                    break;
                }
                Err(err) => {
                    let valid_up_to = err.valid_up_to();
                    if let Ok(prefix) = core::str::from_utf8(&self.utf8_carry[..valid_up_to]) {
                        self.pending.push_str(prefix);
                    }
                    self.utf8_carry.drain(..valid_up_to);
                    if let Some(bad_len) = err.error_len() {
                        self.pending.push('\u{FFFD}');
                        let end = bad_len.min(self.utf8_carry.len());
                        self.utf8_carry.drain(..end);
                    } else {
                        break;
                    }
                }
            }
        }
        if !self.started && !self.pending.is_empty() {
            self.started = true;
            if let Some(rest) = self.pending.strip_prefix('\u{FEFF}') {
                self.pending = rest.to_owned();
            }
        }
    }

    fn process_lines(&mut self, at_eof: bool, out: &mut Vec<String>) {
        while let Some(idx) = self.pending.find(['\n', '\r']) {
            let is_cr = self.pending.as_bytes()[idx] == b'\r';
            if is_cr && idx + 1 == self.pending.len() && !at_eof {
                // Hold back a trailing `\r`: the matching `\n` may arrive in the next chunk.
                break;
            }
            let terminator_len = if is_cr && self.pending.as_bytes().get(idx + 1) == Some(&b'\n') {
                2
            } else {
                1
            };
            let line: String = self.pending[..idx].to_owned();
            self.pending.drain(..idx + terminator_len);
            self.handle_line(&line, out);
        }
        if at_eof && !self.pending.is_empty() {
            let line = core::mem::take(&mut self.pending);
            self.handle_line(&line, out);
        }
    }

    fn handle_line(&mut self, line: &str, out: &mut Vec<String>) {
        if line.is_empty() {
            if !self.data_lines.is_empty() {
                out.push(self.data_lines.join("\n"));
                self.data_lines.clear();
            }
            return;
        }
        if let Some(value) = line.strip_prefix("data:") {
            self.saw_sse_field = true;
            let value = value.strip_prefix(' ').unwrap_or(value);
            if self.data_lines.is_empty() && (value == "[DONE]" || is_complete_json(value)) {
                out.push(value.to_owned());
            } else {
                self.data_lines.push(value.to_owned());
            }
            return;
        }
        if line.starts_with(':')
            || line.starts_with("event:")
            || line.starts_with("id:")
            || line.starts_with("retry:")
        {
            self.saw_sse_field = true;
            return;
        }
        if !self.saw_sse_field {
            self.plain_body.push_str(line);
            self.plain_body.push('\n');
        }
    }
}

/// Normalizes streamed text deltas to `\n` line endings across chunk boundaries.
///
/// A delta ending in `\r` is held back until the next delta shows whether it was `\r\n`, so the
/// emitted text grows monotonically and never contains a stray `\r`.
#[derive(Debug, Default)]
pub struct StreamingTextBuffer {
    held_cr: bool,
}

impl StreamingTextBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the normalized text that is safe to emit now.
    pub fn push(&mut self, delta: &str) -> String {
        let mut out = String::with_capacity(delta.len() + 1);
        let mut chars = delta.chars().peekable();
        if self.held_cr {
            self.held_cr = false;
            out.push('\n');
            if chars.peek() == Some(&'\n') {
                chars.next();
            }
        }
        while let Some(c) = chars.next() {
            if c == '\r' {
                match chars.peek() {
                    Some('\n') => {
                        chars.next();
                        out.push('\n');
                    }
                    Some(_) => out.push('\n'),
                    None => self.held_cr = true,
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    /// Flushes a held `\r` at end of stream.
    pub fn finish(&mut self) -> String {
        if self.held_cr {
            self.held_cr = false;
            "\n".to_owned()
        } else {
            String::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frames(chunks: &[&[u8]]) -> Vec<String> {
        let mut framer = SseFramer::new();
        let mut out = Vec::new();
        for c in chunks {
            out.extend(framer.push_bytes(c).unwrap_or_default());
        }
        out.extend(framer.finish());
        out
    }

    #[test]
    fn single_line_json_dispatches_without_blank_separator() {
        let mut framer = SseFramer::new();
        let got = framer.push_bytes(b"data: {\"a\":1}\n").unwrap_or_default();
        assert_eq!(got, vec!["{\"a\":1}".to_owned()]);
    }

    #[test]
    fn multi_line_frames_wait_for_blank_line_and_bom_is_stripped_once() {
        let got = frames(&[
            b"\xEF\xBB\xBFdata: {\"a\":\n",
            b"data: 1}\n\n",
            b"data: [DONE]\n\n",
        ]);
        assert_eq!(got, vec!["{\"a\":\n1}".to_owned(), "[DONE]".to_owned()]);
    }

    #[test]
    fn split_crlf_and_split_utf8_never_corrupt_frames() {
        let got = frames(&[
            b"data: {\"t\":\"\xE1",
            b"\xBA\xA1\"}\r",
            b"\n\r\n",
            b": ping\r\n",
        ]);
        assert_eq!(got, vec!["{\"t\":\"\u{1EA1}\"}".to_owned()]);
    }

    #[test]
    fn plain_json_body_fallback_when_stream_is_ignored() {
        let got = frames(&[b"{\"choices\":[{\"message\":", b"{\"content\":\"hi\"}}]}\n"]);
        assert_eq!(got.len(), 1);
        assert!(got[0].contains("\"hi\""));
    }

    #[test]
    fn buffer_cap_is_enforced() {
        let mut framer = SseFramer::new();
        let big = vec![b'x'; MAX_SSE_BUFFER_BYTES + 1];
        assert!(framer.push_bytes(&big).is_err());
    }

    #[test]
    fn streaming_text_buffer_holds_back_split_crlf() {
        let mut buf = StreamingTextBuffer::new();
        let mut text = String::new();
        for d in ["line one\r", "\nline two\r", "line three\r"] {
            text.push_str(&buf.push(d));
        }
        text.push_str(&buf.finish());
        assert_eq!(text, "line one\nline two\nline three\n");
    }
}
