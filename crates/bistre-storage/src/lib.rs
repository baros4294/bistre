//! Local-first canonical SQLite WAL + FTS5 storage layer (ADR-0004).
//!
//! Architecture invariants:
//! - Dedicated single-writer actor thread behind a bounded `SyncSender` (zero write-write `SQLITE_BUSY`).
//! - Short-lived read-only connections, opened per read and dropped at once, so readers never starve
//!   WAL checkpoints. Opening one is a small fraction of a typical read, so there is no pool
//!   (measured in Spec 11).
//! - Expand-Contract additive migrations inside `BEGIN IMMEDIATE` + `PRAGMA foreign_key_check` + `PRAGMA quick_check`.
//! - Explicit `SQLITE_FULL` translation to `DiagnosticKey::StorageDiskFull`.

mod catalog_repo;
pub mod harness;
mod project_repo;
mod schema;
mod search;
pub mod story;
#[cfg(test)]
mod tests;
mod thread_repo;
#[cfg(test)]
mod thread_tests;
mod wallet_repo;

use bistre_protocol::lock_or_recover;
use catalog_repo::normalize_topic;
use schema::{
    configure_connection, ensure_default_assistant_if_empty, ensure_default_workspace,
    open_writer_connection, run_migrations, run_reclaim_storage, seed_builtin_providers_once,
};

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{SystemTime, UNIX_EPOCH};

use bistre_protocol::{
    AppSettings, AssistantPatch, AssistantRecord, BistreError, BistreResult, DiagnosticKey,
    DraftRecord, MoneyMicros, NodeRecord, NodeRole, ProjectRecord, ProviderDialect, ProviderPatch,
    ProviderProfile, ThreadMode, ThreadPatch, ThreadSummary,
};
use rusqlite::{Connection, ErrorCode, OpenFlags, OptionalExtension, params};
use uuid::Uuid;

pub use harness::{AgentRunUpdate, CreateAgentRunParams};

/// Current canonical SQLite schema version (`PRAGMA user_version`).
pub const CURRENT_SCHEMA_VERSION: u32 = 12;

/// Default assistant identifier seeded strictly when a fresh install has zero assistants.
pub const DEFAULT_ASSISTANT_ID: &str = "default_assistant";
/// Default topic assigned to new threads when unspecified.
pub const DEFAULT_TOPIC: &str = "general";

const WRITER_QUEUE_CAP: usize = 256;
/// The workspace that holds every chat outside a project.
pub const DEFAULT_WORKSPACE_ID: &str = "00000000-0000-7000-8000-000000000001";
const DEFAULT_WORKSPACE_NAME: &str = "Default Workspace";
const KV_APP_SETTINGS_KEY: &str = "app_settings_v1";
const KV_PROVIDERS_SEEDED_KEY: &str = "providers_seeded_v1";
const KV_OPENROUTER_SEEDED_KEY: &str = "providers_seeded_openrouter";

/// Result of a `PRAGMA wal_checkpoint(TRUNCATE)` invocation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CheckpointStats {
    pub busy: i64,
    pub log_frames: i64,
    pub checkpointed_frames: i64,
}

/// Summary metrics reported by storage for engine health snapshots.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StorageHealth {
    pub schema_version: u32,
    pub wal_mode_active: bool,
    pub thread_count: u64,
    pub node_count: u64,
}

type WriteTask = Box<dyn FnOnce(&mut Connection) + Send + 'static>;

enum WriterMessage {
    Execute(WriteTask),
    Shutdown(mpsc::SyncSender<BistreResult<CheckpointStats>>),
}
/// Deepest branch [`StorageHandle::list_branch`] walks (a guard against cycles).
pub const MAX_BRANCH_DEPTH: i64 = 100_000;

/// Thread-safe handle to the local Bistre SQLite WAL database.
#[derive(Debug)]
pub struct StorageHandle {
    db_path: PathBuf,
    writer_tx: mpsc::SyncSender<WriterMessage>,
    writer_thread: Mutex<Option<JoinHandle<()>>>,
}

impl StorageHandle {
    /// Opens or creates the canonical SQLite WAL database at `db_path`,
    /// applies tuned WAL PRAGMAs, and executes Expand-Contract migrations.
    pub fn open(db_path: impl AsRef<Path>) -> BistreResult<Arc<Self>> {
        let db_path = db_path.as_ref().to_path_buf();
        if let Some(parent) = db_path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent).map_err(|_| {
                BistreError::with_detail(DiagnosticKey::InternalError, "create_storage_dir")
            })?;
        }

        let mut writer_conn = open_writer_connection(&db_path)?;
        configure_connection(&writer_conn, true)?;
        run_migrations(&mut writer_conn, &db_path)?;
        ensure_default_workspace(&writer_conn)?;
        ensure_default_assistant_if_empty(&writer_conn)?;
        seed_builtin_providers_once(&writer_conn)?;
        search::rebuild_stale_search_index(&mut writer_conn);

        let (writer_tx, writer_rx) = mpsc::sync_channel::<WriterMessage>(WRITER_QUEUE_CAP);
        let handle = thread::Builder::new()
            .name("bistre-sqlite-writer".to_owned())
            .spawn(move || {
                while let Ok(msg) = writer_rx.recv() {
                    match msg {
                        WriterMessage::Execute(task) => task(&mut writer_conn),
                        WriterMessage::Shutdown(reply) => {
                            let res = run_reclaim_storage(&writer_conn);
                            if reply.send(res).is_err() {
                                tracing::debug!(
                                    "shutdown caller stopped waiting for the checkpoint"
                                );
                            }
                            break;
                        }
                    }
                }
            })
            .map_err(|_| {
                BistreError::with_detail(DiagnosticKey::InternalError, "spawn_writer_thread")
            })?;

        Ok(Arc::new(Self {
            db_path,
            writer_tx,
            writer_thread: Mutex::new(Some(handle)),
        }))
    }

    /// Executes a synchronous write closure on the single-writer actor thread.
    fn write<T, F>(&self, f: F) -> BistreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&mut Connection) -> BistreResult<T> + Send + 'static,
    {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        let db_path = self.db_path.clone();
        let task: WriteTask = Box::new(move |conn| {
            let outcome = f(conn);
            if outcome
                .as_ref()
                .is_err_and(|e| e.key == DiagnosticKey::StorageIoError)
            {
                reopen_writer(conn, &db_path);
            }
            if reply_tx.send(outcome).is_err() {
                tracing::debug!("storage caller stopped waiting for the write result");
            }
        });
        self.writer_tx
            .send(WriterMessage::Execute(task))
            .map_err(|_| BistreError::new(DiagnosticKey::RuntimeNotInitialized))?;
        reply_rx
            .recv()
            .map_err(|_| BistreError::new(DiagnosticKey::InternalError))?
    }

    /// Opens a short-lived read-only connection; callers must drop it immediately after query.
    fn open_reader(&self) -> BistreResult<Connection> {
        let flags = OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_URI;
        let conn = Connection::open_with_flags(&self.db_path, flags).map_err(map_sqlite_err)?;
        configure_connection(&conn, false)?;
        Ok(conn)
    }

    /// Returns live WAL and count diagnostics.
    pub fn health(&self) -> BistreResult<StorageHealth> {
        let conn = self.open_reader()?;
        let schema_version: u32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .map_err(map_sqlite_err)?;
        let journal_mode: String = conn
            .pragma_query_value(None, "journal_mode", |row| row.get(0))
            .map_err(map_sqlite_err)?;
        let thread_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM threads", [], |row| row.get(0))
            .map_err(map_sqlite_err)?;
        let node_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM nodes", [], |row| row.get(0))
            .map_err(map_sqlite_err)?;
        Ok(StorageHealth {
            schema_version,
            wal_mode_active: journal_mode.eq_ignore_ascii_case("wal"),
            thread_count: u64::try_from(thread_count).unwrap_or(0),
            node_count: u64::try_from(node_count).unwrap_or(0),
        })
    }

    /// Returns the filesystem path of the SQLite database file.
    pub fn db_path(&self) -> &Path {
        &self.db_path
    }

    /// Computes total on-disk bytes consumed by the SQLite DB plus WAL/SHM sidecar files.
    pub fn storage_file_size_bytes(&self) -> u64 {
        let mut total = std::fs::metadata(&self.db_path).map_or(0, |m| m.len());
        let wal = PathBuf::from(format!("{}-wal", self.db_path.display()));
        let shm = PathBuf::from(format!("{}-shm", self.db_path.display()));
        total = total.saturating_add(std::fs::metadata(wal).map_or(0, |m| m.len()));
        total = total.saturating_add(std::fs::metadata(shm).map_or(0, |m| m.len()));
        total
    }

    /// Upserts a persistent unsent draft for `thread_id`.
    pub fn save_draft(&self, thread_id: String, text: String) -> BistreResult<DraftRecord> {
        let now = now_unix_ms();
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO drafts (thread_id, text, updated_at_ms)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(thread_id) DO UPDATE SET text = excluded.text, updated_at_ms = excluded.updated_at_ms",
                params![thread_id, text, now],
            )
            .map_err(map_sqlite_err)?;
            Ok(DraftRecord {
                thread_id,
                text,
                updated_at_ms: now,
            })
        })
    }

    /// Loads the persisted unsent draft for `thread_id`, if present.
    pub fn load_draft(&self, thread_id: &str) -> BistreResult<Option<DraftRecord>> {
        let conn = self.open_reader()?;
        conn.query_row(
            "SELECT thread_id, text, updated_at_ms FROM drafts WHERE thread_id = ?1",
            [thread_id],
            |row| {
                Ok(DraftRecord {
                    thread_id: row.get(0)?,
                    text: row.get(1)?,
                    updated_at_ms: row.get(2)?,
                })
            },
        )
        .optional()
        .map_err(map_sqlite_err)
    }

    /// Loads persisted application settings from `kv_meta`, returning defaults when absent.
    pub fn load_settings(&self) -> BistreResult<AppSettings> {
        let conn = self.open_reader()?;
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM kv_meta WHERE key = ?1",
                [KV_APP_SETTINGS_KEY],
                |row| row.get(0),
            )
            .optional()
            .map_err(map_sqlite_err)?;
        match raw {
            // Corrupt settings must not silently reset safety settings (such as the spending
            // limit) to defaults; the error surfaces and saving new settings replaces the row.
            Some(json) => serde_json::from_str::<AppSettings>(&json).map_err(|_| {
                BistreError::with_detail(DiagnosticKey::InvalidInput, "settings_json_corrupt")
            }),
            None => Ok(AppSettings::default()),
        }
    }

    /// Saves validated application settings atomically in `kv_meta`.
    pub fn save_settings(&self, mut settings: AppSettings) -> BistreResult<AppSettings> {
        settings.font_size_px = settings.font_size_px.clamp(12, 28);
        settings.line_height_bps = settings.line_height_bps.clamp(13_000, 20_000);
        settings.reading_width_px = settings.reading_width_px.clamp(600, 1120);
        if let Some(ceiling) = settings.wallet_daily_ceiling_micros
            && ceiling.as_micros() < 0
        {
            settings.wallet_daily_ceiling_micros = Some(MoneyMicros::ZERO);
        }
        let encoded = serde_json::to_string(&settings).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InternalError, "serialize_settings")
        })?;
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO kv_meta (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![KV_APP_SETTINGS_KEY, encoded],
            )
            .map_err(map_sqlite_err)?;
            Ok(settings)
        })
    }

    /// Reads an arbitrary JSON/text metadata value from `kv_meta`.
    pub fn get_kv_meta(&self, key: &str) -> BistreResult<Option<String>> {
        let conn = self.open_reader()?;
        conn.query_row("SELECT value FROM kv_meta WHERE key = ?1", [key], |row| {
            row.get(0)
        })
        .optional()
        .map_err(map_sqlite_err)
    }

    /// Writes an arbitrary JSON/text metadata value into `kv_meta`.
    pub fn set_kv_meta(&self, key: String, value: String) -> BistreResult<()> {
        if key.trim().is_empty() {
            return Err(BistreError::new(DiagnosticKey::InvalidInput));
        }
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO kv_meta (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )
            .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Deletes a key from `kv_meta`.
    pub fn delete_kv_meta(&self, key: String) -> BistreResult<()> {
        self.write(move |conn| {
            conn.execute("DELETE FROM kv_meta WHERE key = ?1", [key])
                .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Exports a conversation thread cleanly as Markdown or JSON.
    pub fn export_thread(&self, thread_id: &str, format: &str) -> BistreResult<String> {
        let thread = self
            .get_thread(thread_id)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;
        let nodes = self.list_nodes(thread_id)?;
        if format.eq_ignore_ascii_case("json") {
            let payload = serde_json::json!({
                "thread": thread,
                "nodes": nodes,
            });
            return serde_json::to_string_pretty(&payload)
                .map_err(|_| BistreError::new(DiagnosticKey::ExportFailed));
        }

        let mut md = format!("# {}\n\n", thread.title);
        for node in &nodes {
            // Empty assistant stubs (cancelled before any output) are not part of the transcript.
            if node.role == NodeRole::Assistant && node.content.trim().is_empty() {
                continue;
            }
            let heading = match node.role {
                NodeRole::User => "## You",
                NodeRole::Assistant => "## Assistant",
                NodeRole::System => "## System",
                NodeRole::Tool => "## Tool",
                NodeRole::CompactionSummary => "## Summary",
            };
            md.push_str(heading);
            md.push_str("\n\n");
            md.push_str(node.content.trim());
            md.push_str("\n\n---\n\n");
        }
        Ok(md)
    }

    /// Writes an atomic, WAL-consistent SQLite backup snapshot to `dest_path` using `VACUUM INTO`.
    pub fn backup_database(&self, dest_path: &Path) -> BistreResult<()> {
        let dest = dest_path.to_path_buf();
        if let Some(parent) = dest.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)
                .map_err(|_| BistreError::with_detail(DiagnosticKey::ExportFailed, "backup_dir"))?;
        }
        // Atomic: snapshot into a unique sibling temp file, fsync, then rename over the
        // destination. An existing backup is never deleted before the new one is complete.
        let tmp = dest.with_file_name(format!(
            ".{}.{}.tmp",
            dest.file_name()
                .map_or_else(|| "backup".into(), |n| n.to_string_lossy()),
            Uuid::now_v7()
        ));
        let tmp_str = tmp.to_string_lossy().into_owned();
        // The snapshot comes from its own read-only connection (a consistent WAL read),
        // never the single writer, so runs keep saving while a large backup copies.
        // `query_only` stays off: it would refuse `VACUUM INTO`'s write to the new file.
        let snapshot = Connection::open_with_flags(
            &self.db_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY
                | OpenFlags::SQLITE_OPEN_NO_MUTEX
                | OpenFlags::SQLITE_OPEN_URI,
        )
        .and_then(|conn| {
            conn.busy_timeout(std::time::Duration::from_secs(5))?;
            conn.execute("VACUUM INTO ?1", [&tmp_str])
        })
        .map(|_| ())
        .map_err(map_sqlite_err);
        let finished = snapshot
            .and_then(|()| {
                std::fs::OpenOptions::new()
                    .write(true)
                    .open(&tmp)
                    .and_then(|f| f.sync_all())
                    .map_err(|_| {
                        BistreError::with_detail(DiagnosticKey::ExportFailed, "backup_sync")
                    })
            })
            .and_then(|()| {
                std::fs::rename(&tmp, &dest).map_err(|_| {
                    BistreError::with_detail(DiagnosticKey::ExportFailed, "backup_rename")
                })
            });
        if finished.is_err() && tmp.exists() && std::fs::remove_file(&tmp).is_err() {
            tracing::debug!("could not remove partial backup temp file");
        }
        finished
    }

    /// `reclaim_storage()`: `wal_checkpoint(TRUNCATE)` + `PRAGMA optimize` (also run at shutdown).
    pub fn reclaim_storage(&self) -> BistreResult<CheckpointStats> {
        self.write(|conn| run_reclaim_storage(conn))
    }

    /// Cleanly drains the single-writer actor and truncates the WAL file.
    pub fn shutdown(&self) -> BistreResult<CheckpointStats> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        if self
            .writer_tx
            .send(WriterMessage::Shutdown(reply_tx))
            .is_err()
        {
            tracing::debug!("storage writer already stopped");
        }
        let stats = reply_rx
            .recv()
            .unwrap_or_else(|_| Err(BistreError::new(DiagnosticKey::RuntimeNotInitialized)));
        let mut guard = lock_or_recover(&self.writer_thread, "writer_thread");
        if let Some(handle) = guard.take() {
            join_writer(handle);
        }
        stats
    }
}

impl Drop for StorageHandle {
    fn drop(&mut self) {
        let mut guard = lock_or_recover(&self.writer_thread, "writer_thread");
        if let Some(handle) = guard.take() {
            let (reply_tx, _reply_rx) = mpsc::sync_channel(1);
            if self
                .writer_tx
                .send(WriterMessage::Shutdown(reply_tx))
                .is_err()
            {
                tracing::debug!("storage writer already stopped");
            }
            join_writer(handle);
        }
    }
}

fn clean_opt_string(opt: Option<String>) -> Option<String> {
    opt.map(|s| s.trim().to_owned()).filter(|s| !s.is_empty())
}

fn opt_i64_to_u32(val: Option<i64>) -> Option<u32> {
    val.and_then(|v| u32::try_from(v).ok())
}

fn map_thread_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ThreadSummary> {
    let mode_raw: String = row.get(3)?;
    let pinned_int: i64 = row.get(6)?;
    let temp: Option<i64> = row.get(11)?;
    let max_tok: Option<i64> = row.get(12)?;
    let top_p: Option<i64> = row.get(13)?;
    Ok(ThreadSummary {
        id: row.get(0)?,
        workspace_id: row.get(1)?,
        title: row.get(2)?,
        mode: ThreadMode::parse(&mode_raw),
        topic: row.get(4)?,
        assistant_id: row.get(5)?,
        is_pinned: pinned_int != 0,
        active_head_node_id: row.get(7)?,
        provider_id_override: row.get(8)?,
        model_id_override: row.get(9)?,
        system_prompt_override: row.get(10)?,
        temperature_milli: opt_i64_to_u32(temp),
        max_output_tokens: opt_i64_to_u32(max_tok),
        top_p_milli: opt_i64_to_u32(top_p),
        created_at_ms: row.get(14)?,
        updated_at_ms: row.get(15)?,
    })
}

fn now_unix_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}

/// Joins the single-writer thread; a panic there is reported, never swallowed.
fn join_writer(handle: JoinHandle<()>) {
    if handle.join().is_err() {
        tracing::error!("storage writer thread panicked");
    }
}

#[expect(
    clippy::needless_pass_by_value,
    reason = "Passed directly as Result::map_err callback."
)]
fn map_sqlite_err(err: rusqlite::Error) -> BistreError {
    if let rusqlite::Error::SqliteFailure(ffi_err, _) = &err {
        return match ffi_err.code {
            ErrorCode::DiskFull => BistreError::new(DiagnosticKey::StorageDiskFull),
            ErrorCode::SystemIoFailure => BistreError::with_detail(
                DiagnosticKey::StorageIoError,
                format!("sqlite_{}", ffi_err.extended_code),
            ),
            // SQLITE_CORRUPT_VTAB: the FTS5 index (a virtual table), not the canonical data.
            ErrorCode::DatabaseCorrupt if ffi_err.extended_code == 267 => {
                BistreError::new(DiagnosticKey::StorageSearchIndexCorrupt)
            }
            ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked => {
                BistreError::new(DiagnosticKey::StorageBusy)
            }
            _ => BistreError::with_detail(
                DiagnosticKey::InternalError,
                format!("sqlite_{}", ffi_err.extended_code),
            ),
        };
    }
    BistreError::with_detail(DiagnosticKey::InternalError, "sqlite_error")
}

/// opencode #59189: replaces the writer connection after a disk I/O error so later writes
/// reach the database again. The failed write itself is not retried (its commit state is
/// unknown); if the reopen fails, the old handle stays and the next I/O error tries again.
fn reopen_writer(conn: &mut Connection, db_path: &Path) {
    match open_writer_connection(db_path).and_then(|fresh| {
        configure_connection(&fresh, true)?;
        Ok(fresh)
    }) {
        Ok(fresh) => {
            *conn = fresh;
            tracing::warn!(
                key = DiagnosticKey::StorageIoError.as_key(),
                "storage writer reopened after a disk I/O error"
            );
        }
        Err(err) => tracing::error!(
            key = err.key.as_key(),
            "storage writer could not reopen after a disk I/O error"
        ),
    }
}
