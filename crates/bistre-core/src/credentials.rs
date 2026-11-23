//! Provider credential hygiene and multi-key rotation (Spec 02 / Spec 06).
//!
//! - Pasted keys and custom header values are stripped of `\r`, `\n`, zero-width characters
//!   (`U+200B..U+200D`, `U+2060`), the BOM (`U+FEFF`), and every other control character.
//! - A provider may hold several keys (one per line, or separated by commas/semicolons/spaces);
//!   they are stored together in the OS `SecretVault` entry, never in SQLite.
//! - Requests rotate keys round-robin through a process-wide counter (`API_KEY_RR`); `401` /
//!   `403` / `429` fail over to the remaining keys immediately, before any backoff.
//! - Keys only ever travel in headers; request URLs stay credential-free so they can be logged.

use std::sync::atomic::{AtomicUsize, Ordering};

use zeroize::Zeroizing;

/// Maximum keys accepted per provider.
pub const MAX_KEYS_PER_PROVIDER: usize = 16;

/// Process-wide round-robin cursor shared by every provider key ring.
static API_KEY_RR: AtomicUsize = AtomicUsize::new(0);

fn is_invisible(c: char) -> bool {
    c.is_control()
        || matches!(
            c,
            '\u{200B}' | '\u{200C}' | '\u{200D}' | '\u{2060}' | '\u{FEFF}'
        )
}

/// Removes control and zero-width characters, then trims surrounding whitespace.
pub fn sanitize_secret(raw: &str) -> String {
    raw.chars()
        .filter(|c| !is_invisible(*c))
        .collect::<String>()
        .trim()
        .to_owned()
}

/// Sanitizes a user-supplied custom header value (same rules as keys).
pub fn sanitize_header_value(raw: &str) -> String {
    sanitize_secret(raw)
}

/// Splits pasted text into distinct sanitized keys (order kept, duplicates dropped, capped).
pub fn parse_api_keys(raw: &str) -> Vec<Zeroizing<String>> {
    let mut keys: Vec<Zeroizing<String>> = Vec::new();
    for part in raw.split(|c: char| c.is_whitespace() || c == ',' || c == ';') {
        let clean = sanitize_secret(part);
        if clean.is_empty() || keys.iter().any(|k| k.as_str() == clean) {
            continue;
        }
        keys.push(Zeroizing::new(clean));
        if keys.len() == MAX_KEYS_PER_PROVIDER {
            break;
        }
    }
    keys
}

/// Serializes keys for the single vault entry (newline separated).
pub fn encode_api_keys(keys: &[Zeroizing<String>]) -> Zeroizing<String> {
    Zeroizing::new(
        keys.iter()
            .map(|k| k.as_str())
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

/// Non-secret hint: `••••a1b2`, plus `(+N)` when more keys are stored.
pub fn key_hint_for(keys: &[Zeroizing<String>]) -> String {
    let Some(first) = keys.first() else {
        return String::new();
    };
    let chars: Vec<char> = first.chars().collect();
    let base = if chars.len() <= 4 {
        "••••".to_owned()
    } else {
        format!(
            "••••{}",
            chars[chars.len() - 4..].iter().collect::<String>()
        )
    };
    if keys.len() > 1 {
        format!("{base} (+{})", keys.len() - 1)
    } else {
        base
    }
}

/// Keys for one request, ordered for round-robin start + failover.
#[derive(Debug, Clone, Default)]
pub struct KeyRing {
    keys: Vec<Zeroizing<String>>,
}

impl KeyRing {
    pub fn new(keys: Vec<Zeroizing<String>>) -> Self {
        Self { keys }
    }

    /// Ring from a raw vault entry (possibly multiple keys).
    pub fn from_vault_text(raw: &str) -> Self {
        Self::new(parse_api_keys(raw))
    }

    pub const fn len(&self) -> usize {
        self.keys.len()
    }

    pub const fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// Every key exactly once, starting at the next round-robin position.
    pub fn rotation(&self) -> Vec<&str> {
        if self.keys.is_empty() {
            return Vec::new();
        }
        let start = API_KEY_RR.fetch_add(1, Ordering::Relaxed) % self.keys.len();
        (0..self.keys.len())
            .map(|i| self.keys[(start + i) % self.keys.len()].as_str())
            .collect()
    }
}

/// HTTP statuses that switch to the next key immediately instead of backing off.
pub const fn is_key_failover_status(status: u16) -> bool {
    matches!(status, 401 | 403 | 429)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_pasted_keys_and_splits_multiple() {
        let raw = "\u{FEFF}sk-one\u{200B}\r\n  sk-two ,sk-one; \u{0007}sk-three\n";
        let keys = parse_api_keys(raw);
        let plain: Vec<&str> = keys.iter().map(|k| k.as_str()).collect();
        assert_eq!(plain, vec!["sk-one", "sk-two", "sk-three"]);
        assert_eq!(
            sanitize_header_value("Bistre\r\nX-Evil: 1"),
            "BistreX-Evil: 1"
        );
        assert_eq!(encode_api_keys(&keys).as_str(), "sk-one\nsk-two\nsk-three");
        assert_eq!(key_hint_for(&keys), "••••-one (+2)");
        assert_eq!(key_hint_for(&[]), "");
    }

    #[test]
    fn rotation_visits_every_key_once_and_advances_round_robin() {
        let ring = KeyRing::from_vault_text("a\nb\nc");
        let first = ring.rotation();
        let second = ring.rotation();
        assert_eq!(first.len(), 3);
        let mut sorted = first.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, vec!["a", "b", "c"]);
        assert_ne!(
            first[0], second[0],
            "start key must rotate between requests"
        );
        assert_eq!(KeyRing::default().rotation().len(), 0);
        assert!(is_key_failover_status(429));
        assert!(!is_key_failover_status(500));
    }
}
