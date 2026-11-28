//! Erasing everything Bistre keeps in its data folder (chats, files, settings, keys, caches).
//! The request is a marker file; the erase runs at the next engine start, under the folder's
//! single-writer lock and before the database opens, since an open database cannot be erased.

use std::path::Path;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};

use crate::{BoxFuture, InProcessEngine};

/// The marker that asks the next engine start to erase the data folder.
const WIPE_MARKER: &str = "erase-on-start";
/// The single-writer lock this process holds while it erases (`daemon_launch`).
const KEPT_LOCK: &str = "daemon.lock";
/// Most entries one erase removes from the data folder's top level.
const MAX_TOP_ENTRIES: usize = 10_000;

fn io_err(detail: &'static str) -> impl Fn(std::io::Error) -> BistreError {
    move |err| {
        tracing::warn!(error = %err, detail, "data erase step failed");
        BistreError::with_detail(DiagnosticKey::InternalError, detail)
    }
}

/// Erases the data folder when a request is pending. The marker is removed first, so a
/// file that cannot be removed (logged) never makes every later start erase again. Returns
/// whether an erase ran.
pub(crate) fn run_pending(data_dir: &Path) -> BistreResult<bool> {
    let marker = data_dir.join(WIPE_MARKER);
    if !marker.exists() {
        return Ok(false);
    }
    std::fs::remove_file(&marker).map_err(io_err("erase_marker"))?;
    let entries = std::fs::read_dir(data_dir).map_err(io_err("erase_list"))?;
    let mut left = 0_usize;
    for entry in entries.take(MAX_TOP_ENTRIES) {
        let entry = entry.map_err(io_err("erase_list"))?;
        if entry.file_name() == KEPT_LOCK {
            continue;
        }
        let path = entry.path();
        let removed = match entry.file_type() {
            Ok(kind) if kind.is_dir() => std::fs::remove_dir_all(&path),
            Ok(_) => std::fs::remove_file(&path),
            Err(err) => Err(err),
        };
        if let Err(err) = removed {
            left = left.saturating_add(1);
            tracing::warn!(error = %err, "a data folder entry could not be erased");
        }
    }
    tracing::info!(left, "data folder erased");
    Ok(true)
}

impl InProcessEngine {
    /// Asks the next start to erase everything Bistre keeps on this device.
    pub fn request_data_wipe(&self) -> BoxFuture<'_, BistreResult<()>> {
        let marker = self.data_dir.join(WIPE_MARKER);
        Box::pin(crate::off_worker::blocking(move || {
            std::fs::write(marker, b"").map_err(io_err("erase_request"))
        }))
    }

    /// Withdraws a pending erase; returns whether one was pending.
    pub fn cancel_data_wipe(&self) -> BoxFuture<'_, BistreResult<bool>> {
        let marker = self.data_dir.join(WIPE_MARKER);
        Box::pin(crate::off_worker::blocking(move || {
            if !marker.exists() {
                return Ok(false);
            }
            std::fs::remove_file(marker).map_err(io_err("erase_cancel"))?;
            Ok(true)
        }))
    }

    /// Whether an erase waits for the next start.
    pub fn data_wipe_pending(&self) -> BoxFuture<'_, BistreResult<bool>> {
        let marker = self.data_dir.join(WIPE_MARKER);
        Box::pin(crate::off_worker::blocking(move || Ok(marker.exists())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    /// A pending erase removes the folder's contents once and keeps the writer lock; with no
    /// request nothing is touched.
    #[test]
    fn an_erase_runs_once_and_keeps_the_writer_lock() -> TestResult {
        let dir = tempdir()?;
        std::fs::write(dir.path().join("bistre.sqlite"), b"db")?;
        std::fs::create_dir_all(dir.path().join("attachments"))?;
        std::fs::write(dir.path().join("attachments").join("a.png"), b"x")?;
        std::fs::write(dir.path().join(KEPT_LOCK), b"")?;
        assert!(!run_pending(dir.path())?);
        assert!(dir.path().join("bistre.sqlite").exists());

        std::fs::write(dir.path().join(WIPE_MARKER), b"")?;
        assert!(run_pending(dir.path())?);
        let left: Vec<_> = std::fs::read_dir(dir.path())?
            .flatten()
            .map(|e| e.file_name())
            .collect();
        assert_eq!(left, [std::ffi::OsString::from(KEPT_LOCK)]);
        assert!(!run_pending(dir.path())?);
        Ok(())
    }
}
