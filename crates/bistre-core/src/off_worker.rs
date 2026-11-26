//! Storage calls whose cost grows with the user's data (export, backup, full-text search, a long
//! chat's history) run on Tokio's blocking pool, so a reply streaming on the same async worker
//! never stalls behind them (AGENTS §7: no blocking I/O on async threads). Sub-millisecond
//! lookups stay inline; moving them would cost more than it saves.

use std::sync::Arc;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use bistre_storage::StorageHandle;

/// Runs `f` against `storage` on the blocking pool and returns its result.
pub(crate) async fn off_worker<T, F>(storage: &Arc<StorageHandle>, f: F) -> BistreResult<T>
where
    T: Send + 'static,
    F: FnOnce(&StorageHandle) -> BistreResult<T> + Send + 'static,
{
    let storage = Arc::clone(storage);
    blocking(move || f(&storage)).await
}

/// Runs blocking work (file walks, file reads and writes) on the blocking pool (R20, R21).
pub(crate) async fn blocking<T, F>(f: F) -> BistreResult<T>
where
    T: Send + 'static,
    F: FnOnce() -> BistreResult<T> + Send + 'static,
{
    tokio::task::spawn_blocking(f).await.map_err(|err| {
        BistreError::with_detail(DiagnosticKey::InternalError, format!("blocking_task:{err}"))
    })?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[tokio::test(flavor = "current_thread")]
    async fn long_storage_calls_leave_the_async_worker_free() -> TestResult {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("bistre.sqlite"))?;
        // The storage job waits for a signal that only the async side can send. Run inline on
        // the single worker, it would block that worker until the timeout and fail.
        let (tx, rx) = mpsc::channel::<()>();
        let job = off_worker(&storage, move |_| {
            rx.recv_timeout(Duration::from_secs(5))
                .map_err(|_| BistreError::new(DiagnosticKey::InternalError))
        });
        let signal = async move {
            tokio::task::yield_now().await;
            tx.send(())
        };
        let (job, sent) = tokio::join!(job, signal);
        sent?;
        job?;
        Ok(())
    }
}
