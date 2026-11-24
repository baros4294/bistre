//! Wallet Shield spend reservations (Spec 06, ADR-0009).
//!
//! Every paid request first reserves spend on the single SQLite writer, so concurrent runs and
//! sub-agents can never overshoot the daily ceiling together. A [`SpendReservation`] can only
//! be created by [`SpendReservation::reserve`]; dropping it unsettled releases the reservation.

use std::sync::Arc;

use bistre_protocol::{BistreResult, MoneyMicros};
use bistre_storage::StorageHandle;

/// An outstanding spend reservation for one paid request.
#[derive(Debug)]
pub struct SpendReservation {
    storage: Arc<StorageHandle>,
    id: Option<String>,
}

impl SpendReservation {
    /// Checks the ceiling (settled + reserved spend since `since_unix_ms`) and reserves
    /// `estimate`. Fails closed: any storage error denies the request.
    pub fn reserve(
        storage: &Arc<StorageHandle>,
        thread_id: Option<String>,
        provider_id: String,
        model_id: String,
        estimate: MoneyMicros,
        ceiling: Option<MoneyMicros>,
        since_unix_ms: i64,
    ) -> BistreResult<Self> {
        let id = storage.reserve_wallet_spend(
            thread_id,
            provider_id,
            model_id,
            estimate,
            ceiling,
            since_unix_ms,
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
}
