//! One backoff per provider shared by every run: when one run is told to
//! wait, the others sending to the same provider wait too instead of each retrying it on its
//! own. Bounded: one entry per provider id, expired entries dropped on each note.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The most providers tracked at once (entries are dropped when they expire).
const MAX_TRACKED_PROVIDERS: usize = 256;

#[derive(Debug, Default)]
pub struct ProviderBackoff {
    not_before: Mutex<HashMap<String, Instant>>,
}

impl ProviderBackoff {
    /// Records that `provider_id` should not be sent to for `wait`, from `now`.
    pub fn note(&self, provider_id: &str, now: Instant, wait: Duration) {
        let until = now + wait;
        let mut map = bistre_protocol::lock_or_recover(&self.not_before, "provider_backoff");
        map.retain(|_, t| *t > now);
        if map.len() >= MAX_TRACKED_PROVIDERS && !map.contains_key(provider_id) {
            return;
        }
        let slot = map.entry(provider_id.to_owned()).or_insert(until);
        if *slot < until {
            *slot = until;
        }
    }

    /// How long a new request to `provider_id` should wait, if at all.
    pub fn remaining(&self, provider_id: &str, now: Instant) -> Option<Duration> {
        let map = bistre_protocol::lock_or_recover(&self.not_before, "provider_backoff");
        map.get(provider_id)
            .and_then(|t| t.checked_duration_since(now))
            .filter(|d| !d.is_zero())
    }

    /// `Retry now`: the user asked to send again at once.
    pub fn clear(&self, provider_id: &str) {
        bistre_protocol::lock_or_recover(&self.not_before, "provider_backoff").remove(provider_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_run_sees_the_longest_wait_for_its_provider() {
        let backoff = ProviderBackoff::default();
        let now = Instant::now();
        backoff.note("p1", now, Duration::from_secs(30));
        backoff.note("p1", now, Duration::from_secs(5));
        assert_eq!(backoff.remaining("p1", now), Some(Duration::from_secs(30)));
        assert_eq!(
            backoff.remaining("p2", now),
            None,
            "other providers are not held"
        );
        assert_eq!(backoff.remaining("p1", now + Duration::from_secs(31)), None);
        backoff.clear("p1");
        assert_eq!(backoff.remaining("p1", now), None);
    }
}
