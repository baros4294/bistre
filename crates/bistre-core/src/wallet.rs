//! Wallet Shield spend reservations (Spec 06, ADR-0009).
//!
//! Every paid request first reserves spend on the single SQLite writer, so concurrent runs and
//! sub-agents can never overshoot the daily ceiling together. A [`SpendReservation`] can only
//! be created by [`SpendReservation::reserve`]; dropping it unsettled releases the reservation.

use std::sync::Arc;

use bistre_protocol::{BistreResult, MoneyMicros, UsageMetrics};
use bistre_storage::StorageHandle;

/// An outstanding spend reservation for one paid request.
#[derive(Debug)]
pub struct SpendReservation {
    storage: Arc<StorageHandle>,
    id: Option<String>,
}

impl SpendReservation {
    /// Checks the daily ceiling (settled + reserved spend since `since_unix_ms`) and the
    /// per-chat cap (the chat's whole ledger spend), then reserves `estimate`. Fails closed: any
    /// storage error denies the request.
    pub fn reserve(
        storage: &Arc<StorageHandle>,
        thread_id: Option<String>,
        provider_id: String,
        model_id: String,
        estimate: MoneyMicros,
        ceiling: Option<MoneyMicros>,
        since_unix_ms: i64,
    ) -> BistreResult<Self> {
        Self::reserve_with_chat_cap(
            storage,
            thread_id,
            provider_id,
            model_id,
            estimate,
            ceiling,
            since_unix_ms,
            None,
        )
    }

    /// [`Self::reserve`] with the chat's own cap checked in the same transaction.
    #[expect(
        clippy::too_many_arguments,
        reason = "one reservation needs every ledger dimension at once"
    )]
    pub fn reserve_with_chat_cap(
        storage: &Arc<StorageHandle>,
        thread_id: Option<String>,
        provider_id: String,
        model_id: String,
        estimate: MoneyMicros,
        ceiling: Option<MoneyMicros>,
        since_unix_ms: i64,
        chat_cap: Option<MoneyMicros>,
    ) -> BistreResult<Self> {
        let id = storage.reserve_wallet_spend_with_chat_cap(
            thread_id,
            provider_id,
            model_id,
            estimate,
            ceiling,
            since_unix_ms,
            chat_cap,
        )?;
        Ok(Self {
            storage: Arc::clone(storage),
            id: Some(id),
        })
    }

    /// Replaces the reservation with the exact cost of the finished request.
    pub fn settle(
        self,
        cost: MoneyMicros,
        input_tokens: u64,
        output_tokens: u64,
        status: String,
    ) -> BistreResult<()> {
        self.settle_for_request(None, cost, input_tokens, output_tokens, status)
    }

    /// Replaces the reservation with the exact cost and deduplicates by provider `request_id`.
    pub fn settle_for_request(
        mut self,
        request_id: Option<String>,
        cost: MoneyMicros,
        input_tokens: u64,
        output_tokens: u64,
        status: String,
    ) -> BistreResult<()> {
        let Some(id) = self.id.take() else {
            return Ok(());
        };
        self.storage.settle_wallet_reservation_for_request(
            id,
            request_id,
            cost,
            input_tokens,
            output_tokens,
            status,
        )
    }
}

impl Drop for SpendReservation {
    fn drop(&mut self) {
        if let Some(id) = self.id.take()
            && let Err(err) = self.storage.release_wallet_reservation(id)
        {
            // The startup sweep (`release_all_wallet_reservations`) removes it on next launch.
            tracing::error!(key = err.key.as_key(), "wallet reservation release failed");
        }
    }
}

/// The usage a sent request is billed for (R5).
///
/// Some providers send usage only in their final frame (`OpenAI` Responses `response.completed`,
/// the Chat Completions usage chunk), so a stopped or broken stream carries none. A sent request
/// is never free: when the provider reported nothing, bill the reserved input estimate plus the
/// output counted locally. Returns the usage and whether it was estimated.
pub fn billable_usage(
    reported: &UsageMetrics,
    estimated_input_tokens: u64,
    counted_output_tokens: u64,
) -> (UsageMetrics, bool) {
    let reported_any = reported.input_tokens > 0
        || reported.output_tokens > 0
        || reported.reasoning_tokens > 0
        || reported.cached_input_tokens > 0
        || reported.cache_creation_input_tokens > 0;
    if reported_any {
        return (*reported, false);
    }
    let usage = UsageMetrics {
        input_tokens: estimated_input_tokens,
        output_tokens: counted_output_tokens,
        ..*reported
    };
    (usage, true)
}
#[cfg(test)]
mod tests {
    use super::*;

    fn open() -> Result<(tempfile::TempDir, Arc<StorageHandle>), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("w.sqlite"))?;
        Ok((dir, storage))
    }

    #[test]
    fn concurrent_reservations_cannot_overshoot_the_ceiling()
    -> Result<(), Box<dyn std::error::Error>> {
        let (_dir, storage) = open()?;
        let cap = Some(MoneyMicros::from_micros(1_000));
        // The first run reserves an estimate that reaches the cap; a second concurrent run is
        // denied even though nothing has settled yet.
        let first = SpendReservation::reserve(
            &storage,
            None,
            "p".into(),
            "m".into(),
            MoneyMicros::from_micros(1_000),
            cap,
            0,
        )?;
        let second = SpendReservation::reserve(
            &storage,
            None,
            "p".into(),
            "m".into(),
            MoneyMicros::from_micros(1),
            cap,
            0,
        );
        assert_eq!(
            second.err().map(|e| e.key),
            Some(bistre_protocol::DiagnosticKey::WalletCeilingExceeded)
        );
        // Releasing (drop without settle) frees the budget again.
        drop(first);
        let third = SpendReservation::reserve(
            &storage,
            None,
            "p".into(),
            "m".into(),
            MoneyMicros::from_micros(1),
            cap,
            0,
        )?;
        third.settle(MoneyMicros::from_micros(7), 10, 20, "settled".into())?;
        assert_eq!(
            storage.sum_wallet_spend_since_micros(0)?,
            MoneyMicros::from_micros(7)
        );
        Ok(())
    }

    #[test]
    fn startup_sweep_releases_orphaned_reservations() -> Result<(), Box<dyn std::error::Error>> {
        let (_dir, storage) = open()?;
        let orphan = SpendReservation::reserve(
            &storage,
            None,
            "p".into(),
            "m".into(),
            MoneyMicros::from_micros(500),
            None,
            0,
        )?;
        // Simulate a crash: the guard never runs.
        let _crashed = std::mem::ManuallyDrop::new(orphan);
        assert_eq!(
            storage.sum_wallet_spend_since_micros(0)?,
            MoneyMicros::from_micros(500)
        );
        assert_eq!(storage.release_all_wallet_reservations()?, 1);
        assert_eq!(storage.sum_wallet_spend_since_micros(0)?, MoneyMicros::ZERO);
        Ok(())
    }

    #[test]
    fn duplicate_request_id_settles_spend_once() -> Result<(), Box<dyn std::error::Error>> {
        let (_dir, storage) = open()?;
        let first = SpendReservation::reserve(
            &storage,
            None,
            "p".into(),
            "m".into(),
            MoneyMicros::from_micros(50),
            None,
            0,
        )?;
        first.settle_for_request(
            Some("req_abc123".into()),
            MoneyMicros::from_micros(42),
            100,
            20,
            "settled".into(),
        )?;
        let dup = SpendReservation::reserve(
            &storage,
            None,
            "p".into(),
            "m".into(),
            MoneyMicros::from_micros(50),
            None,
            0,
        )?;
        dup.settle_for_request(
            Some("req_abc123".into()),
            MoneyMicros::from_micros(42),
            100,
            20,
            "settled".into(),
        )?;
        assert_eq!(
            storage.sum_wallet_spend_since_micros(0)?,
            MoneyMicros::from_micros(42)
        );
        Ok(())
    }

    /// R5: a stream stopped before its usage frame is billed as sent, not at $0.
    #[test]
    fn a_request_without_reported_usage_is_billed_from_the_estimate() {
        let (usage, estimated) = billable_usage(&UsageMetrics::default(), 1_200, 340);
        assert!(estimated);
        assert_eq!((usage.input_tokens, usage.output_tokens), (1_200, 340));

        let reported = UsageMetrics {
            input_tokens: 900,
            output_tokens: 50,
            ..UsageMetrics::default()
        };
        let (usage, estimated) = billable_usage(&reported, 1_200, 340);
        assert!(!estimated, "reported usage is always preferred");
        assert_eq!((usage.input_tokens, usage.output_tokens), (900, 50));
    }
}
