# ADR-0013: Sleep Immunity, Durable Run Journaling & Active-Scoped Desktop Daemon

- **Status**: Accepted
- **Date**: 2026-11-22
- **Deciders**: Bistre Principal Architecture

## Context
Long-horizon AI agent runs across Windows, Linux, and Android frequently fail when laptops enter Modern Standby (S0ix), screens lock, mobile OSes Doze, Wi-Fi switches to cellular, or users close the GUI window mid-task. At the same time, keeping a background daemon permanently resident when idle wastes RAM and battery, and aggressive wake locks on laptop battery violate user trust unless explicitly opted in.

## Decision
1. **SQLite WAL Durable Run State Machine (Schema v6)**: Persist every agent run, individual step (`idempotency_key`, `risk_tier`, `status`), mid-stream steering queue (`steering_queue`), cursor-indexed event replay log (`engine_events_log`), workspace edit checkpoints (`workspace_checkpoints`), cross-chat memory (`memory_entries`), and scheduled background jobs (`cron_jobs`) atomically in SQLite WAL.
2. **Active-Scoped `bistre-daemon` Lifecycle**: On Windows (`\\.\pipe\bistre-<user>`) and Linux (`$XDG_RUNTIME_DIR/bistre/daemon.sock`), `bistre-daemon` stays alive after GUI close **strictly while an agent run or due scheduled job is active**, and exits cleanly once idle (zero permanent background RAM burn).
3. **Cross-Platform OS Sleep Guard (`PowerCoordinator` & `PowerRunLease`)**:
   - **Windows**: `PowerCreateRequest` / `PowerSetRequest` (`PowerRequestSystemRequired` by default while `active_runs > 0`; optional `PowerRequestDisplayRequired` for S0ix Modern Standby on battery **strictly gated by opt-in `windows_keep_awake_on_battery` setting, default `false`**) + `PowerRegisterSuspendResumeNotification` delivering `SystemPowerEvent::Suspend` / `Resume` directly into run reconciliation.
   - **Linux**: `systemd-inhibit --what=sleep:idle --mode=block` child guard strictly scoped to active run lifetimes (`KILL_ON_DROP`), with clean fallback if unavailable.
   - **Android**: Run-scoped `BistreAgentService` (`specialUse`) + `AgentRecoveryWorker` (`ADR-0012`).
4. **Tier-2 Safety & Mid-Stream Steering**: On suspend/drop, Tier-0/1 steps auto-resume cleanly on wake, while Tier-2 side-effecting steps transition to `indeterminate_halt` requiring explicit user confirmation (Wallet Shield always wins). Users can enqueue mid-stream steering messages (`steering_queue`) injected cleanly at step boundaries without cancelling active generations.

## Rejected Alternatives
- **Always-resident desktop daemon**: Violates zero-waste idle RAM discipline when no tasks or schedules are active.
- **Unconditional `PowerRequestDisplayRequired` on Windows battery**: Drains user laptop batteries unexpectedly; gating behind an opt-in Settings toggle respects user autonomy.
- **Blind retry of Tier-2 actions after sleep wake**: Risks duplicate paid API calls, shell mutations, or double-billing.

## Consequences & Verification
- Long-horizon agent sessions survive sleep, suspend, network hops, and GUI closure without losing state or leaking wake locks.
- Verified via `bistre-storage` (`schema_v6_durable_runs_and_steering_queue`, `schema_v6_checkpoints_memory_cron_and_event_cursor_replay`), `bistre-core` (`suspend_resume_reconciles_tier2_indeterminate_halt_and_wallet_shield_precedence`, `mid_stream_steering_queue_drives_follow_up_turn_without_cancel`, `evaluates_intervals_and_five_field_cron_and_polls_due_jobs`), and live FRB E2E tests (`ffi_roundtrip_test.dart`).
