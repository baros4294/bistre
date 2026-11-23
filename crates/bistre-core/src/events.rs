//! Explicit handling for engine event broadcasts and best-effort bookkeeping writes.
//!
//! `let _ =` is banned (`AGENTS.md` §2, `just guard`); these helpers name *why* an outcome may be
//! ignored and make every non-fatal failure visible in the trace log.

use bistre_protocol::{BistreResult, EngineEvent};
use bistre_storage::StorageHandle;
use tokio::sync::broadcast;

/// Broadcasts `ev`. A broadcast send fails only when no UI is subscribed, which is not an error.
pub(crate) fn emit(events_tx: &broadcast::Sender<EngineEvent>, ev: EngineEvent) {
    if events_tx.send(ev).is_err() {
        tracing::trace!("engine event had no subscribers");
    }
}

/// Appends `ev` to the durable per-thread event log, then broadcasts it. A failed append is
/// logged with its diagnostic key; the live UI still receives the event.
pub(crate) fn emit_logged(
    storage: &StorageHandle,
    events_tx: &broadcast::Sender<EngineEvent>,
    thread_id: Option<String>,
    ev: EngineEvent,
) {
    note_write(
        "engine_event_log",
        storage.append_engine_event_log(thread_id, &ev),
    );
    emit(events_tx, ev);
}

/// Records the failure of a best-effort bookkeeping write (run checkpoints, step records, draft
/// clears) whose loss never corrupts canonical history. Returns the value on success.
pub(crate) fn note_write<T>(what: &'static str, result: BistreResult<T>) -> Option<T> {
    match result {
        Ok(value) => Some(value),
        Err(err) => {
            tracing::warn!(
                what,
                key = err.key.as_key(),
                detail = err.detail_code.as_deref().unwrap_or(""),
                "best-effort write failed"
            );
            None
        }
    }
}
