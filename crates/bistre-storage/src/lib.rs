//! Local-first canonical SQLite WAL + FTS5 storage layer (ADR-0004).
//!
//! Architecture invariants:
//! - Dedicated single-writer actor thread behind a bounded `SyncSender` (zero write-write `SQLITE_BUSY`).
//! - Short-lived pooled read-only connections so readers never starve WAL checkpoints.
//! - Expand-Contract additive migrations inside `BEGIN IMMEDIATE` + `PRAGMA foreign_key_check` + `PRAGMA quick_check`.
//! - Explicit `SQLITE_FULL` translation to `DiagnosticKey::StorageDiskFull`.

mod catalog_repo;
pub mod harness;
mod schema;
pub mod story;
#[cfg(test)]
mod tests;

use catalog_repo::normalize_topic;
use schema::{
    configure_connection, ensure_default_assistant_if_empty, ensure_default_workspace,
    open_writer_connection, run_checkpoint_truncate, run_migrations, run_reclaim_storage,
    seed_builtin_providers_once,
};

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{SystemTime, UNIX_EPOCH};

use bistre_protocol::{
    AppSettings, AssistantPatch, AssistantRecord, BistreError, BistreResult, DiagnosticKey,
    DraftRecord, MoneyMicros, NodeRecord, NodeRole, ProviderDialect, ProviderPatch,
    ProviderProfile, SearchHit, ThreadMode, ThreadPatch, ThreadSummary, WorkspaceSummary,
};
use rusqlite::{Connection, ErrorCode, OpenFlags, OptionalExtension, params};
use uuid::Uuid;

pub use harness::{AgentRunUpdate, CreateAgentRunParams};

/// Current canonical SQLite schema version (`PRAGMA user_version`).
pub const CURRENT_SCHEMA_VERSION: u32 = 8;

/// Default assistant identifier seeded strictly when a fresh install has zero assistants.
pub const DEFAULT_ASSISTANT_ID: &str = "default_assistant";
/// Default topic assigned to new threads when unspecified.
pub const DEFAULT_TOPIC: &str = "general";

const WRITER_QUEUE_CAP: usize = 256;
const DEFAULT_WORKSPACE_ID: &str = "00000000-0000-7000-8000-000000000001";
const DEFAULT_WORKSPACE_NAME: &str = "Default Workspace";
const KV_APP_SETTINGS_KEY: &str = "app_settings_v1";
const KV_PROVIDERS_SEEDED_KEY: &str = "providers_seeded_v1";

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
        let task: WriteTask = Box::new(move |conn| {
            let outcome = f(conn);
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

    /// Lists all workspaces ordered by creation timestamp.
    pub fn list_workspaces(&self) -> BistreResult<Vec<WorkspaceSummary>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, name, root_path, created_at_ms FROM workspaces ORDER BY created_at_ms ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([], |row| {
                Ok(WorkspaceSummary {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    root_path: row.get(2)?,
                    created_at_ms: row.get(3)?,
                })
            })
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
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

    /// Creates a new thread inside `workspace_id` (or the default workspace when `None`).
    pub fn create_thread(
        &self,
        workspace_id: Option<String>,
        title: &str,
        mode: ThreadMode,
        topic: Option<&str>,
        assistant_id: Option<&str>,
    ) -> BistreResult<ThreadSummary> {
        let trimmed = title.trim().to_owned();
        if trimmed.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "empty_thread_title",
            ));
        }
        let ws_id = workspace_id.unwrap_or_else(|| DEFAULT_WORKSPACE_ID.to_owned());
        let resolved_topic = normalize_topic(topic);
        let resolved_assistant = assistant_id
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(DEFAULT_ASSISTANT_ID)
            .to_owned();
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();

        self.write(move |conn| {
            conn.execute(
                "INSERT INTO threads (id, workspace_id, title, mode, topic, assistant_id, is_pinned, active_head_node_id, created_at_ms, updated_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, NULL, ?7, ?7)",
                params![
                    id,
                    ws_id,
                    trimmed,
                    mode.as_str(),
                    resolved_topic,
                    resolved_assistant,
                    now
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(ThreadSummary {
                id,
                workspace_id: ws_id,
                title: trimmed,
                mode,
                topic: resolved_topic,
                assistant_id: resolved_assistant,
                is_pinned: false,
                active_head_node_id: None,
                provider_id_override: None,
                model_id_override: None,
                system_prompt_override: None,
                temperature_milli: None,
                max_output_tokens: None,
                top_p_milli: None,
                created_at_ms: now,
                updated_at_ms: now,
            })
        })
    }

    /// Fetches a single thread by ID.
    pub fn get_thread(&self, thread_id: &str) -> BistreResult<Option<ThreadSummary>> {
        let conn = self.open_reader()?;
        conn.query_row(
            "SELECT id, workspace_id, title, mode, topic, assistant_id, is_pinned, active_head_node_id,
                    provider_id_override, model_id_override, system_prompt_override,
                    temperature_milli, max_output_tokens, top_p_milli,
                    created_at_ms, updated_at_ms
             FROM threads WHERE id = ?1",
            [thread_id],
            map_thread_row,
        )
        .optional()
        .map_err(map_sqlite_err)
    }

    /// Updates mutable thread metadata (title, pin, topic, assistant, and per-chat overrides) atomically.
    pub fn update_thread(
        &self,
        thread_id: String,
        patch: ThreadPatch,
    ) -> BistreResult<ThreadSummary> {
        let now = now_unix_ms();
        self.write(move |conn| {
            let existing = conn
                .query_row(
                    "SELECT id, workspace_id, title, mode, topic, assistant_id, is_pinned, active_head_node_id,
                            provider_id_override, model_id_override, system_prompt_override,
                            temperature_milli, max_output_tokens, top_p_milli,
                            created_at_ms, updated_at_ms
                     FROM threads WHERE id = ?1",
                    [&thread_id],
                    map_thread_row,
                )
                .optional()
                .map_err(map_sqlite_err)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;

            let next_title = match patch.title {
                Some(raw) => {
                    let t = raw.trim().to_owned();
                    if t.is_empty() {
                        return Err(BistreError::with_detail(
                            DiagnosticKey::InvalidInput,
                            "empty_thread_title",
                        ));
                    }
                    t
                }
                None => existing.title,
            };
            let next_pinned = patch.is_pinned.unwrap_or(existing.is_pinned);
            let next_topic = patch
                .topic
                .as_deref()
                .map(|t| normalize_topic(Some(t)))
                .unwrap_or(existing.topic);
            let next_mode = patch.mode.unwrap_or(existing.mode);
            let next_assistant = patch
                .assistant_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map_or(existing.assistant_id, ToOwned::to_owned);
            let next_provider_ov = patch
                .provider_id_override
                .map_or(existing.provider_id_override, clean_opt_string);
            let next_model_ov = patch
                .model_id_override
                .map_or(existing.model_id_override, clean_opt_string);
            let next_prompt_ov = patch
                .system_prompt_override
                .map_or(existing.system_prompt_override, clean_opt_string);
            let next_temp = patch
                .temperature_milli
                .unwrap_or(existing.temperature_milli)
                .map(|v| v.clamp(0, 2000));
            let next_max_tokens = patch
                .max_output_tokens
                .unwrap_or(existing.max_output_tokens)
                .map(|v| v.clamp(1, 1_000_000));
            let next_top_p = patch
                .top_p_milli
                .unwrap_or(existing.top_p_milli)
                .map(|v| v.clamp(0, 1000));

            conn.execute(
                "UPDATE threads
                 SET title = ?1, is_pinned = ?2, topic = ?3, mode = ?4, assistant_id = ?5,
                     provider_id_override = ?6, model_id_override = ?7, system_prompt_override = ?8,
                     temperature_milli = ?9, max_output_tokens = ?10, top_p_milli = ?11,
                     updated_at_ms = ?12
                 WHERE id = ?13",
                params![
                    next_title,
                    i64::from(next_pinned),
                    next_topic,
                    next_mode.as_str(),
                    next_assistant,
                    next_provider_ov,
                    next_model_ov,
                    next_prompt_ov,
                    next_temp.map(i64::from),
                    next_max_tokens.map(i64::from),
                    next_top_p.map(i64::from),
                    now,
                    thread_id
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(ThreadSummary {
                id: existing.id,
                workspace_id: existing.workspace_id,
                title: next_title,
                mode: next_mode,
                topic: next_topic,
                assistant_id: next_assistant,
                is_pinned: next_pinned,
                active_head_node_id: existing.active_head_node_id,
                provider_id_override: next_provider_ov,
                model_id_override: next_model_ov,
                system_prompt_override: next_prompt_ov,
                temperature_milli: next_temp,
                max_output_tokens: next_max_tokens,
                top_p_milli: next_top_p,
                created_at_ms: existing.created_at_ms,
                updated_at_ms: now,
            })
        })
    }

    /// Deletes a thread (and cascades its nodes and draft via FK constraints).
    pub fn delete_thread(&self, thread_id: String) -> BistreResult<()> {
        self.write(move |conn| {
            let deleted = conn
                .execute("DELETE FROM threads WHERE id = ?1", [&thread_id])
                .map_err(map_sqlite_err)?;
            if deleted == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            Ok(())
        })
    }

    /// Lists threads ordered pinned first, then newest-updated first.
    pub fn list_threads(&self, workspace_id: Option<&str>) -> BistreResult<Vec<ThreadSummary>> {
        let conn = self.open_reader()?;
        if let Some(ws_id) = workspace_id {
            let mut stmt = conn
                .prepare(
                    "SELECT id, workspace_id, title, mode, topic, assistant_id, is_pinned, active_head_node_id,
                            provider_id_override, model_id_override, system_prompt_override,
                            temperature_milli, max_output_tokens, top_p_milli,
                            created_at_ms, updated_at_ms
                     FROM threads WHERE workspace_id = ?1
                     ORDER BY is_pinned DESC, updated_at_ms DESC",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt
                .query_map([ws_id], map_thread_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        } else {
            let mut stmt = conn
                .prepare(
                    "SELECT id, workspace_id, title, mode, topic, assistant_id, is_pinned, active_head_node_id,
                            provider_id_override, model_id_override, system_prompt_override,
                            temperature_milli, max_output_tokens, top_p_milli,
                            created_at_ms, updated_at_ms
                     FROM threads
                     ORDER BY is_pinned DESC, updated_at_ms DESC",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt.query_map([], map_thread_row).map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        }
    }

    /// Appends a new canonical DAG node to `thread_id`, updating `active_head_node_id` and `updated_at_ms` atomically.
    pub fn append_node(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        role: NodeRole,
        content: String,
        provider_meta_json: Option<String>,
    ) -> BistreResult<NodeRecord> {
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();

        self.write(move |conn| {
            let tx = conn.transaction().map_err(map_sqlite_err)?;
            tx.execute(
                "INSERT INTO nodes (id, thread_id, parent_id, role, content, provider_meta_json, created_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    id,
                    thread_id,
                    parent_id,
                    role.as_str(),
                    content,
                    provider_meta_json,
                    now
                ],
            )
            .map_err(map_sqlite_err)?;
            let updated = tx
                .execute(
                    "UPDATE threads SET active_head_node_id = ?1, updated_at_ms = ?2 WHERE id = ?3",
                    params![id, now, thread_id],
                )
                .map_err(map_sqlite_err)?;
            if updated == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            tx.commit().map_err(map_sqlite_err)?;

            Ok(NodeRecord {
                id,
                thread_id,
                parent_id,
                role,
                content,
                provider_meta_json,
                created_at_ms: now,
            })
        })
    }

    /// Lists all DAG nodes belonging to `thread_id` ordered chronologically by insertion (`rowid ASC`).
    pub fn list_nodes(&self, thread_id: &str) -> BistreResult<Vec<NodeRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, thread_id, parent_id, role, content, provider_meta_json, created_at_ms
                 FROM nodes WHERE thread_id = ?1 ORDER BY rowid ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([thread_id], |row| {
                let role_raw: String = row.get(3)?;
                Ok(NodeRecord {
                    id: row.get(0)?,
                    thread_id: row.get(1)?,
                    parent_id: row.get(2)?,
                    role: NodeRole::parse(&role_raw),
                    content: row.get(4)?,
                    provider_meta_json: row.get(5)?,
                    created_at_ms: row.get(6)?,
                })
            })
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Deletes a single DAG node cleanly, reparenting direct children and updating `active_head_node_id`.
    pub fn delete_node(&self, thread_id: String, node_id: String) -> BistreResult<()> {
        let now = now_unix_ms();
        self.write(move |conn| {
            let tx = conn
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(map_sqlite_err)?;
            let parent_id: Option<String> = tx
                .query_row(
                    "SELECT parent_id FROM nodes WHERE id = ?1 AND thread_id = ?2",
                    params![&node_id, &thread_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(map_sqlite_err)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;

            tx.execute(
                "UPDATE nodes SET parent_id = ?1 WHERE parent_id = ?2 AND thread_id = ?3",
                params![&parent_id, &node_id, &thread_id],
            )
            .map_err(map_sqlite_err)?;

            tx.execute(
                "DELETE FROM nodes WHERE id = ?1 AND thread_id = ?2",
                params![&node_id, &thread_id],
            )
            .map_err(map_sqlite_err)?;

            let latest_id: Option<String> = tx
                .query_row(
                    "SELECT id FROM nodes WHERE thread_id = ?1 ORDER BY rowid DESC LIMIT 1",
                    [&thread_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(map_sqlite_err)?;

            tx.execute(
                "UPDATE threads SET active_head_node_id = ?1, updated_at_ms = ?2 WHERE id = ?3",
                params![latest_id, now, &thread_id],
            )
            .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)
        })
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
            Some(json) => Ok(serde_json::from_str::<AppSettings>(&json).unwrap_or_default()),
            None => Ok(AppSettings::default()),
        }
    }

    /// Saves validated application settings atomically in `kv_meta`.
    pub fn save_settings(&self, mut settings: AppSettings) -> BistreResult<AppSettings> {
        settings.font_scale_bps = settings.font_scale_bps.clamp(7_000, 19_000);
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
    ) -> BistreResult<()> {
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();
        let in_tok = i64::try_from(input_tokens).unwrap_or(i64::MAX);
        let out_tok = i64::try_from(output_tokens).unwrap_or(i64::MAX);
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO wallet_ledger (id, thread_id, job_id, provider_id, model_id, cost_micros,
                                            input_tokens, output_tokens, status, created_at_ms)
                 VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    id,
                    thread_id,
                    provider_id,
                    model_id,
                    cost.as_micros(),
                    in_tok,
                    out_tok,
                    status,
                    now
                ],
            )
            .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Records an exact `MoneyMicros` ledger entry in `wallet_ledger`.
    pub fn record_wallet_entry(
        &self,
        thread_id: Option<String>,
        provider_id: String,
        model_id: String,
        cost: MoneyMicros,
        status: String,
    ) -> BistreResult<()> {
        self.record_wallet_entry_with_usage(thread_id, provider_id, model_id, cost, 0, 0, status)
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
        let snapshot = self.write(move |conn| {
            conn.execute("VACUUM INTO ?1", [&tmp_str])
                .map_err(map_sqlite_err)?;
            Ok(())
        });
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

    /// Full-text searches canonical nodes via SQLite FTS5, returning ranked snippets.
    pub fn search_nodes(
        &self,
        query: &str,
        thread_id: Option<&str>,
        limit: u32,
    ) -> BistreResult<Vec<SearchHit>> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        let fts_query = sanitize_fts_query(trimmed);
        let capped_limit = i64::from(limit.clamp(1, 200));
        let conn = self.open_reader()?;

        let map_row = |row: &rusqlite::Row<'_>| -> rusqlite::Result<SearchHit> {
            let role_raw: String = row.get(2)?;
            Ok(SearchHit {
                node_id: row.get(0)?,
                thread_id: row.get(1)?,
                role: NodeRole::parse(&role_raw),
                snippet: row.get(3)?,
                created_at_ms: row.get(4)?,
            })
        };

        if let Some(tid) = thread_id {
            let mut stmt = conn
                .prepare(
                    "SELECT n.id, n.thread_id, n.role,
                            snippet(nodes_fts, 0, '[', ']', '...', 16),
                            n.created_at_ms
                     FROM nodes_fts
                     JOIN nodes n ON n.rowid = nodes_fts.rowid
                     WHERE nodes_fts MATCH ?1 AND n.thread_id = ?2
                     ORDER BY bm25(nodes_fts)
                     LIMIT ?3",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt
                .query_map(params![fts_query, tid, capped_limit], map_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        } else {
            let mut stmt = conn
                .prepare(
                    "SELECT n.id, n.thread_id, n.role,
                            snippet(nodes_fts, 0, '[', ']', '...', 16),
                            n.created_at_ms
                     FROM nodes_fts
                     JOIN nodes n ON n.rowid = nodes_fts.rowid
                     WHERE nodes_fts MATCH ?1
                     ORDER BY bm25(nodes_fts)
                     LIMIT ?2",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt
                .query_map(params![fts_query, capped_limit], map_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        }
    }

    /// Runs `PRAGMA wal_checkpoint(TRUNCATE)` on the writer thread to reclaim WAL space.
    pub fn checkpoint_truncate(&self) -> BistreResult<CheckpointStats> {
        self.write(|conn| run_checkpoint_truncate(conn))
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
        if let Ok(mut guard) = self.writer_thread.lock()
            && let Some(handle) = guard.take()
        {
            join_writer(handle);
        }
        stats
    }
}

impl Drop for StorageHandle {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.writer_thread.lock()
            && let Some(handle) = guard.take()
        {
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

/// Quotes user terms safely for FTS5 MATCH so punctuation/operators never cause SQL errors.
fn sanitize_fts_query(raw: &str) -> String {
    raw.split_whitespace()
        .map(|token| {
            let escaped = token.replace('"', "\"\"");
            format!("\"{escaped}\"*")
        })
        .collect::<Vec<_>>()
        .join(" ")
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
