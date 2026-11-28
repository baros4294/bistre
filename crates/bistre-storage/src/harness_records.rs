//! Workspace checkpoints, attachments, memory entries, and schedules (`impl StorageHandle`).

use super::{
    AttachmentRecord, BistreResult, CronJobRecord, MemoryEntryRecord, OptionalExtension,
    StorageHandle, Uuid, WorkspaceCheckpointRecord, map_attachment_row, map_checkpoint_row,
    map_cron_job_row, map_memory_row, map_sqlite_err, now_unix_ms, params,
};

impl StorageHandle {
    /// Stores a pre-edit workspace file snapshot (`workspace_checkpoints`) for instant 1-click Rewind.
    #[expect(
        clippy::too_many_arguments,
        reason = "Explicit workspace checkpoint columns persisted atomically."
    )]
    pub fn save_workspace_checkpoint(
        &self,
        thread_id: String,
        run_id: Option<String>,
        node_id: Option<String>,
        file_path: String,
        before_blake3: String,
        after_blake3: String,
        pre_image_blob: Vec<u8>,
    ) -> BistreResult<WorkspaceCheckpointRecord> {
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO workspace_checkpoints (
                    id, thread_id, run_id, node_id, file_path, before_blake3, after_blake3, pre_image_blob, created_at_ms
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    id,
                    thread_id,
                    run_id,
                    node_id,
                    file_path,
                    before_blake3,
                    after_blake3,
                    pre_image_blob,
                    now
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(WorkspaceCheckpointRecord {
                id,
                thread_id,
                run_id,
                node_id,
                file_path,
                before_blake3,
                after_blake3,
                pre_image_blob,
                created_at_ms: now,
            })
        })
    }

    /// Lists pre-image checkpoints for a thread (most recent first).
    pub fn list_workspace_checkpoints(
        &self,
        thread_id: &str,
    ) -> BistreResult<Vec<WorkspaceCheckpointRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, thread_id, run_id, node_id, file_path, before_blake3, after_blake3, pre_image_blob, created_at_ms
                 FROM workspace_checkpoints WHERE thread_id = ?1
                 ORDER BY created_at_ms DESC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([thread_id], map_checkpoint_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Fetches a single workspace checkpoint by ID.
    pub fn get_workspace_checkpoint(
        &self,
        checkpoint_id: &str,
    ) -> BistreResult<Option<WorkspaceCheckpointRecord>> {
        let conn = self.open_reader()?;
        conn.query_row(
            "SELECT id, thread_id, run_id, node_id, file_path, before_blake3, after_blake3, pre_image_blob, created_at_ms
             FROM workspace_checkpoints WHERE id = ?1",
            [checkpoint_id],
            map_checkpoint_row,
        )
        .optional()
        .map_err(map_sqlite_err)
    }

    /// Persists multimodal attachment metadata linked to a thread/node.
    #[expect(
        clippy::too_many_arguments,
        reason = "Explicit attachment metadata fields persisted atomically."
    )]
    pub fn save_attachment(
        &self,
        thread_id: String,
        node_id: Option<String>,
        kind: String,
        filename: String,
        mime_type: String,
        byte_len: u64,
        sha256: String,
        storage_rel_path: String,
        extracted_text: String,
    ) -> BistreResult<AttachmentRecord> {
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();
        let byte_len_i64 = i64::try_from(byte_len).unwrap_or(i64::MAX);
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO attachments (
                    id, thread_id, node_id, kind, filename, mime_type, byte_len, sha256, storage_rel_path, extracted_text, created_at_ms
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    id,
                    thread_id,
                    node_id,
                    kind,
                    filename,
                    mime_type,
                    byte_len_i64,
                    sha256,
                    storage_rel_path,
                    extracted_text,
                    now
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(AttachmentRecord {
                id,
                thread_id,
                node_id,
                kind,
                filename,
                mime_type,
                byte_len,
                sha256,
                storage_rel_path,
                extracted_text,
                created_at_ms: now,
            })
        })
    }

    /// Lists attachments belonging to a thread.
    pub fn list_attachments(&self, thread_id: &str) -> BistreResult<Vec<AttachmentRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, thread_id, node_id, kind, filename, mime_type, byte_len, sha256, storage_rel_path, extracted_text, created_at_ms
                 FROM attachments WHERE thread_id = ?1
                 ORDER BY created_at_ms ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([thread_id], map_attachment_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Upserts a persistent cross-chat / workspace / assistant memory item.
    #[expect(
        clippy::too_many_arguments,
        reason = "Explicit memory_entries columns persisted atomically."
    )]
    pub fn upsert_memory_entry(
        &self,
        id: Option<String>,
        scope: String,
        scope_id: String,
        key: String,
        content: String,
        source_thread_id: Option<String>,
        pinned: bool,
    ) -> BistreResult<MemoryEntryRecord> {
        let entry_id = id
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| Uuid::now_v7().to_string());
        let now = now_unix_ms();
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO memory_entries (id, scope, scope_id, key, content, source_thread_id, pinned, updated_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(id) DO UPDATE SET
                    scope = excluded.scope,
                    scope_id = excluded.scope_id,
                    key = excluded.key,
                    content = excluded.content,
                    source_thread_id = excluded.source_thread_id,
                    pinned = excluded.pinned,
                    updated_at_ms = excluded.updated_at_ms",
                params![
                    entry_id,
                    scope,
                    scope_id,
                    key,
                    content,
                    source_thread_id,
                    i64::from(pinned),
                    now
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(MemoryEntryRecord {
                id: entry_id,
                scope,
                scope_id,
                key,
                content,
                source_thread_id,
                pinned,
                updated_at_ms: now,
            })
        })
    }

    /// Lists persistent memory entries (optionally filtered by scope).
    pub fn list_memory_entries(&self, scope: Option<&str>) -> BistreResult<Vec<MemoryEntryRecord>> {
        let conn = self.open_reader()?;
        if let Some(sc) = scope {
            let mut stmt = conn
                .prepare(
                    "SELECT id, scope, scope_id, key, content, source_thread_id, pinned, updated_at_ms
                     FROM memory_entries WHERE scope = ?1
                     ORDER BY pinned DESC, updated_at_ms DESC",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt
                .query_map([sc], map_memory_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        } else {
            let mut stmt = conn
                .prepare(
                    "SELECT id, scope, scope_id, key, content, source_thread_id, pinned, updated_at_ms
                     FROM memory_entries
                     ORDER BY pinned DESC, updated_at_ms DESC",
                )
                .map_err(map_sqlite_err)?;
            let rows = stmt.query_map([], map_memory_row).map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        }
    }

    /// Deletes a memory entry by ID.
    pub fn delete_memory_entry(&self, entry_id: String) -> BistreResult<()> {
        self.write(move |conn| {
            conn.execute("DELETE FROM memory_entries WHERE id = ?1", [&entry_id])
                .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Upserts a scheduled cron/timer automation job.
    pub fn upsert_cron_job(&self, mut job: CronJobRecord) -> BistreResult<CronJobRecord> {
        if job.id.trim().is_empty() {
            job.id = Uuid::now_v7().to_string();
        }
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO cron_jobs (
                    id, name, workspace_id, assistant_id, schedule_expr, prompt, mode,
                    unattended_policy, use_worktree, enabled, next_run_ms, last_run_id, last_status
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                 ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    workspace_id = excluded.workspace_id,
                    assistant_id = excluded.assistant_id,
                    schedule_expr = excluded.schedule_expr,
                    prompt = excluded.prompt,
                    mode = excluded.mode,
                    unattended_policy = excluded.unattended_policy,
                    use_worktree = excluded.use_worktree,
                    enabled = excluded.enabled,
                    next_run_ms = excluded.next_run_ms,
                    last_run_id = excluded.last_run_id,
                    last_status = excluded.last_status",
                params![
                    job.id,
                    job.name,
                    job.workspace_id,
                    job.assistant_id,
                    job.schedule_expr,
                    job.prompt,
                    job.mode.as_str(),
                    job.unattended_policy.as_str(),
                    i64::from(job.use_worktree),
                    i64::from(job.enabled),
                    job.next_run_ms,
                    job.last_run_id,
                    job.last_status
                ],
            )
            .map_err(map_sqlite_err)?;
            Ok(job)
        })
    }

    /// Lists all configured scheduled cron jobs.
    pub fn list_cron_jobs(&self) -> BistreResult<Vec<CronJobRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, name, workspace_id, assistant_id, schedule_expr, prompt, mode,
                        unattended_policy, use_worktree, enabled, next_run_ms, last_run_id, last_status
                 FROM cron_jobs ORDER BY enabled DESC, next_run_ms ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([], map_cron_job_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Deletes a scheduled cron job by ID.
    pub fn delete_cron_job(&self, job_id: String) -> BistreResult<()> {
        self.write(move |conn| {
            conn.execute("DELETE FROM cron_jobs WHERE id = ?1", [&job_id])
                .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Counts currently enabled scheduled cron jobs (used by active-scoped daemon lifecycle).
    pub fn count_enabled_cron_jobs(&self) -> BistreResult<u32> {
        let conn = self.open_reader()?;
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM cron_jobs WHERE enabled != 0",
                [],
                |row| row.get(0),
            )
            .map_err(map_sqlite_err)?;
        Ok(u32::try_from(count).unwrap_or(0))
    }
}
