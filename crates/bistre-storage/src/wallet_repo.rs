//! Wallet ledger repository (`impl StorageHandle`): reservations, settlement, and spend sums.

use super::{
    BistreError, BistreResult, DiagnosticKey, MoneyMicros, StorageHandle, Uuid, map_sqlite_err,
    now_unix_ms, params,
};
use bistre_protocol::{PurposeUsage, SpendPurpose};

/// Whether `spent + estimate` stays within `cap` (and `spent` has not already reached it).
/// An overflowing sum never fits.
fn fits_under(spent: i64, estimate: MoneyMicros, cap: MoneyMicros) -> bool {
    spent < cap.as_micros()
        && spent
            .checked_add(estimate.as_micros())
            .is_some_and(|after| after <= cap.as_micros())
}

impl StorageHandle {
    /// Records an exact `MoneyMicros` ledger entry with token counts in `wallet_ledger`.
    #[expect(
        clippy::too_many_arguments,
        reason = "Explicit atomic ledger fields keep financial audit writes self-contained."
    )]
    pub fn record_wallet_entry_with_usage(
        &self,
        thread_id: Option<String>,
        provider_id: String,
        model_id: String,
        cost: MoneyMicros,
        input_tokens: u64,
        output_tokens: u64,
        status: String,
        purpose: SpendPurpose,
    ) -> BistreResult<()> {
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();
        let in_tok = i64::try_from(input_tokens).unwrap_or(i64::MAX);
        let out_tok = i64::try_from(output_tokens).unwrap_or(i64::MAX);
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO wallet_ledger (id, thread_id, job_id, provider_id, model_id, cost_micros,
                                            input_tokens, output_tokens, status, created_at_ms, purpose)
                 VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    id,
                    thread_id,
                    provider_id,
                    model_id,
                    cost.as_micros(),
                    in_tok,
                    out_tok,
                    status,
                    now,
                    purpose.as_str()
                ],
            )
            .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Records an exact `MoneyMicros` chat ledger entry in `wallet_ledger`.
    pub fn record_wallet_entry(
        &self,
        thread_id: Option<String>,
        provider_id: String,
        model_id: String,
        cost: MoneyMicros,
        status: String,
    ) -> BistreResult<()> {
        self.record_wallet_entry_with_usage(
            thread_id,
            provider_id,
            model_id,
            cost,
            0,
            0,
            status,
            SpendPurpose::Chat,
        )
    }

    /// Atomically checks the daily ceiling and reserves `estimate` before a paid request.
    ///
    /// Runs on the single writer, so concurrent runs serialize: each sees every settled entry
    /// *and* every outstanding reservation. Returns the reservation id, or
    /// `WalletCeilingExceeded` when today's settled + reserved spend already meets `ceiling` or
    /// adding `estimate` would pass it (checked addition: an overflow is refused too). A negative
    /// estimate is never a reservation. Books the reservation as chat spend.
    pub fn reserve_wallet_spend(
        &self,
        thread_id: Option<String>,
        provider_id: String,
        model_id: String,
        estimate: MoneyMicros,
        ceiling: Option<MoneyMicros>,
        since_unix_ms: i64,
    ) -> BistreResult<String> {
        self.reserve_wallet_spend_with_chat_cap(
            thread_id,
            provider_id,
            model_id,
            estimate,
            ceiling,
            since_unix_ms,
            None,
            SpendPurpose::Chat,
        )
    }

    /// [`Self::reserve_wallet_spend`] plus the per-chat cap: in the same writer transaction,
    /// the chat's whole ledger spend (settled + reserved, all time) plus `estimate` must fit
    /// `chat_cap`, else `WalletCeilingExceeded` with detail `thread_spend_limit`. The row keeps
    /// `purpose` through settlement.
    #[expect(
        clippy::too_many_arguments,
        reason = "one reservation needs every ledger dimension at once"
    )]
    pub fn reserve_wallet_spend_with_chat_cap(
        &self,
        thread_id: Option<String>,
        provider_id: String,
        model_id: String,
        estimate: MoneyMicros,
        ceiling: Option<MoneyMicros>,
        since_unix_ms: i64,
        chat_cap: Option<MoneyMicros>,
        purpose: SpendPurpose,
    ) -> BistreResult<String> {
        if estimate.as_micros() < 0 {
            return Err(BistreError::with_detail(
                DiagnosticKey::WalletCeilingExceeded,
                "negative_estimate",
            ));
        }
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();
        self.write(move |conn| {
            let tx = conn.transaction().map_err(map_sqlite_err)?;
            let spent: i64 = tx
                .query_row(
                    "SELECT COALESCE(SUM(cost_micros), 0) FROM wallet_ledger WHERE created_at_ms >= ?1",
                    [since_unix_ms],
                    |row| row.get(0),
                )
                .map_err(map_sqlite_err)?;
            if let Some(c) = ceiling
                && !fits_under(spent, estimate, c)
            {
                return Err(BistreError::new(DiagnosticKey::WalletCeilingExceeded));
            }
            if let Some(cap) = chat_cap {
                let Some(tid) = thread_id.as_deref() else {
                    return Err(BistreError::with_detail(
                        DiagnosticKey::WalletCeilingExceeded,
                        "thread_spend_limit",
                    ));
                };
                let chat_spent: i64 = tx
                    .query_row(
                        "SELECT COALESCE(SUM(cost_micros), 0) FROM wallet_ledger WHERE thread_id = ?1",
                        [tid],
                        |row| row.get(0),
                    )
                    .map_err(map_sqlite_err)?;
                if !fits_under(chat_spent, estimate, cap) {
                    return Err(BistreError::with_detail(
                        DiagnosticKey::WalletCeilingExceeded,
                        "thread_spend_limit",
                    ));
                }
            }
            tx.execute(
                "INSERT INTO wallet_ledger (id, thread_id, job_id, provider_id, model_id, cost_micros,
                                            input_tokens, output_tokens, status, created_at_ms, purpose)
                 VALUES (?1, ?2, NULL, ?3, ?4, ?5, 0, 0, 'reserved', ?6, ?7)",
                params![
                    id,
                    thread_id,
                    provider_id,
                    model_id,
                    estimate.as_micros(),
                    now,
                    purpose.as_str()
                ],
            )
            .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)?;
            Ok(id)
        })
    }

    /// Replaces a reservation with the exact settled cost and token counts.
    pub fn settle_wallet_reservation(
        &self,
        reservation_id: String,
        cost: MoneyMicros,
        input_tokens: u64,
        output_tokens: u64,
        status: String,
    ) -> BistreResult<()> {
        self.settle_wallet_reservation_for_request(
            reservation_id,
            None,
            cost,
            input_tokens,
            output_tokens,
            status,
        )
    }

    /// Replaces a reservation with the exact settled cost and deduplicates by `request_id`
    /// (`wallet_ledger.job_id`) so retried usage webhooks/callbacks never double-charge.
    pub fn settle_wallet_reservation_for_request(
        &self,
        reservation_id: String,
        request_id: Option<String>,
        cost: MoneyMicros,
        input_tokens: u64,
        output_tokens: u64,
        status: String,
    ) -> BistreResult<()> {
        let in_tok = i64::try_from(input_tokens).unwrap_or(i64::MAX);
        let out_tok = i64::try_from(output_tokens).unwrap_or(i64::MAX);
        let clean_req = request_id
            .map(|r| r.trim().to_owned())
            .filter(|r| !r.is_empty());
        self.write(move |conn| {
            let tx = conn.transaction().map_err(map_sqlite_err)?;
            if let Some(ref req_id) = clean_req {
                let already_settled: i64 = tx
                    .query_row(
                        "SELECT COUNT(*) FROM wallet_ledger WHERE job_id = ?1 AND status != 'reserved'",
                        [req_id],
                        |row| row.get(0),
                    )
                    .map_err(map_sqlite_err)?;
                if already_settled > 0 {
                    tx.execute(
                        "DELETE FROM wallet_ledger WHERE id = ?1 AND status = 'reserved'",
                        [&reservation_id],
                    )
                    .map_err(map_sqlite_err)?;
                    tx.commit().map_err(map_sqlite_err)?;
                    return Ok(());
                }
            }
            let changed = tx
                .execute(
                    "UPDATE wallet_ledger SET job_id = COALESCE(?2, job_id), cost_micros = ?3,
                                              input_tokens = ?4, output_tokens = ?5, status = ?6
                     WHERE id = ?1 AND status = 'reserved'",
                    params![
                        reservation_id,
                        clean_req,
                        cost.as_micros(),
                        in_tok,
                        out_tok,
                        status
                    ],
                )
                .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)?;
            if changed == 1 {
                Ok(())
            } else {
                Err(BistreError::with_detail(DiagnosticKey::StorageNotFound, "wallet_reservation"))
            }
        })
    }

    /// Drops an unsettled reservation (request failed, was cancelled before output, or retried).
    pub fn release_wallet_reservation(&self, reservation_id: String) -> BistreResult<()> {
        self.write(move |conn| {
            conn.execute(
                "DELETE FROM wallet_ledger WHERE id = ?1 AND status = 'reserved'",
                [reservation_id],
            )
            .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Drops every outstanding reservation; called at engine start, when no run can own one.
    pub fn release_all_wallet_reservations(&self) -> BistreResult<usize> {
        self.write(|conn| {
            conn.execute("DELETE FROM wallet_ledger WHERE status = 'reserved'", [])
                .map_err(map_sqlite_err)
        })
    }

    /// Returns total recorded spend across all time in exact `MoneyMicros`.
    pub fn sum_wallet_spend_micros(&self) -> BistreResult<MoneyMicros> {
        let conn = self.open_reader()?;
        let total: i64 = conn
            .query_row(
                "SELECT COALESCE(SUM(cost_micros), 0) FROM wallet_ledger",
                [],
                |row| row.get(0),
            )
            .map_err(map_sqlite_err)?;
        Ok(MoneyMicros::from_micros(total))
    }

    /// Returns recorded spend since `since_unix_ms` (e.g., start of current day) in exact `MoneyMicros`.
    pub fn sum_wallet_spend_since_micros(&self, since_unix_ms: i64) -> BistreResult<MoneyMicros> {
        let conn = self.open_reader()?;
        let total: i64 = conn
            .query_row(
                "SELECT COALESCE(SUM(cost_micros), 0) FROM wallet_ledger WHERE created_at_ms >= ?1",
                [since_unix_ms],
                |row| row.get(0),
            )
            .map_err(map_sqlite_err)?;
        Ok(MoneyMicros::from_micros(total))
    }

    /// Settled spend of one chat, every purpose and all time (open reservations left out).
    pub fn thread_spend_micros(&self, thread_id: &str) -> BistreResult<MoneyMicros> {
        let conn = self.open_reader()?;
        let total: i64 = conn
            .query_row(
                "SELECT COALESCE(SUM(cost_micros), 0) FROM wallet_ledger
                 WHERE thread_id = ?1 AND status != 'reserved'",
                [thread_id],
                |row| row.get(0),
            )
            .map_err(map_sqlite_err)?;
        Ok(MoneyMicros::from_micros(total))
    }

    /// Settled spend since `since_unix_ms`, one entry per purpose that has any rows, in
    /// [`SpendPurpose::ALL`] order. Open reservations are left out; a row whose purpose this
    /// build does not know fails the read rather than being counted as something else.
    pub fn wallet_usage_by_purpose(&self, since_unix_ms: i64) -> BistreResult<Vec<PurposeUsage>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT purpose, COUNT(*), COALESCE(SUM(input_tokens), 0),
                        COALESCE(SUM(output_tokens), 0), COALESCE(SUM(cost_micros), 0)
                 FROM wallet_ledger WHERE created_at_ms >= ?1 AND status != 'reserved'
                 GROUP BY purpose",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([since_unix_ms], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                ))
            })
            .map_err(map_sqlite_err)?;
        let mut usage = Vec::new();
        for row in rows {
            let (raw, requests, input, output, cost) = row.map_err(map_sqlite_err)?;
            let purpose = SpendPurpose::parse(&raw).ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::StorageMigrationFailed, "wallet_purpose")
            })?;
            usage.push(PurposeUsage {
                purpose,
                requests: u64::try_from(requests).unwrap_or(0),
                input_tokens: u64::try_from(input).unwrap_or(0),
                output_tokens: u64::try_from(output).unwrap_or(0),
                cost: MoneyMicros::from_micros(cost),
            });
        }
        usage.sort_by_key(|u| SpendPurpose::ALL.iter().position(|p| *p == u.purpose));
        Ok(usage)
    }
}
