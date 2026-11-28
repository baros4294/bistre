# ADR-0009: Wallet Shield Fixed-Point `MoneyMicros` & WAL-Before-POST Media Idempotency

- Status: Accepted
- Deciders: Bistre Principal Architecture

## Context & Live-Verified Evidence
- Binary floating-point types (`f32`/`f64`) accumulate rounding drift in token/media billing ledgers.
- Async media providers (`fal.ai` Queue API, OpenAPI media queues) bill per submitted job; if a mobile Wi-Fi→5G drop occurs after HTTP POST reaches the server but before the response `request_id` arrives, an automatic network retry double-bills the user.

## Decision
1. Represent all monetary prices, estimates, reserves, and ledger entries strictly as exact integer `MoneyMicros(i64)` (`1 USD = 1_000_000` micros) with checked/saturating arithmetic in `crates/bistre-protocol` and `INTEGER NOT NULL` columns in SQLite `wallet_ledger`.
2. Enforce WAL-before-POST for all paid async media submits: commit `media_job(client_job_id, status = PENDING_SUBMIT, est_cost_micros)` + pre-debit reserve in SQLite BEFORE initiating HTTP POST; pass client idempotency key where supported.
3. On an indeterminate transport drop prior to receiving provider `request_id`, transition to `INDETERMINATE_HALT` and never auto-retry; require explicit user confirmation or provider status reconciliation.
4. Wallet Shield ceilings, paid media Wax Seal gates, and `$0` local model priority unconditionally override the 5-class Self-Healing engine.

## Rejected Alternatives
- Retry-on-timeout for all HTTP POST requests: Causes silent double-billing on paid image/video endpoints.
- `f64` USD pricing: Introduces rounding drift and non-deterministic ceiling checks.

## Consequences & Verification
- Built form of Decision 2 (ADR-0019 Decision 9): the reservation is the write before the POST, and a submitted video job's id is kept in `kv_meta` `media.video_jobs`; there is no `media_job` table.
- Verified via `bistre-protocol` `MoneyMicros` overflow/saturation tests and Wave 2 media state-machine tests asserting zero auto-retry on `INDETERMINATE_HALT`.
