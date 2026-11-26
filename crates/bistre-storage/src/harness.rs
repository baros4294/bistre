//! Schema v6 durable long-horizon harness persistence (`agent_runs`, `run_steps`, `steering_queue`,
//! `workspace_checkpoints`, `attachments`, `memory_entries`, `cron_jobs`, and `engine_events_log`).

use bistre_protocol::{
    AgentRunRecord, AttachmentRecord, BistreError, BistreResult, CronJobRecord, CursorEventRecord,
    DiagnosticKey, EngineEvent, MemoryEntryRecord, MoneyMicros, RunStatus, RunStepKind,
    RunStepRecord, SteeringMessage, ThreadMode, ToolRiskTier, UnattendedPolicy,
    WorkspaceCheckpointRecord,
};
use rusqlite::{OptionalExtension, params};
use uuid::Uuid;

use crate::{StorageHandle, map_sqlite_err, now_unix_ms};

const MAX_RETAINED_EVENT_LOG_ROWS: i64 = 4096;

/// Additive Expand-Contract Schema v6 DDL (readable by N-1 binaries).
/// Schema v8 (additive): pinned-chat partial index and spill column for oversized step output.
pub(crate) const SCHEMA_V8_EXPAND_SQL: &str = r"
CREATE INDEX IF NOT EXISTS idx_threads_pinned_recent
    ON threads (updated_at_ms DESC) WHERE is_pinned = 1;
ALTER TABLE run_steps ADD COLUMN result_overflow BLOB;
";

/// Step output above this size is spilled to `run_steps.result_overflow`; `output_json` keeps a
/// small JSON preview so lists never load large tool results.
pub const MAX_INLINE_STEP_OUTPUT_BYTES: usize = 64 * 1024;
const STEP_OUTPUT_PREVIEW_CHARS: usize = 4 * 1024;

/// Splits an oversized output into `(inline preview JSON, overflow blob)`.
pub fn spill_step_output(output_json: String) -> (String, Option<Vec<u8>>) {
    if output_json.len() <= MAX_INLINE_STEP_OUTPUT_BYTES {
        return (output_json, None);
    }
    let preview: String = output_json
        .chars()
        .take(STEP_OUTPUT_PREVIEW_CHARS)
        .collect();
    let inline = serde_json::json!({
        "overflow": true,
        "bytes": output_json.len(),
        "preview": preview,
    })
    .to_string();
    (inline, Some(output_json.into_bytes()))
}

pub(crate) const SCHEMA_V6_EXPAND_SQL: &str = r"
CREATE TABLE IF NOT EXISTS agent_runs (
    id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL,
    parent_run_id TEXT,
    root_node_id TEXT,
    mode TEXT NOT NULL DEFAULT 'chat',
    status TEXT NOT NULL DEFAULT 'running',
    step_index INTEGER NOT NULL DEFAULT 0,
    max_steps INTEGER NOT NULL DEFAULT 40,
    unattended_policy TEXT NOT NULL DEFAULT 'pause_and_notify',
    worktree_path TEXT,
    retry_after_ms INTEGER,
    last_heartbeat_ms INTEGER NOT NULL,
    partial_text_buffer TEXT NOT NULL DEFAULT '',
    partial_thinking_buffer TEXT NOT NULL DEFAULT '',
    cost_micros INTEGER NOT NULL DEFAULT 0,
    error_key TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_agent_runs_status_updated
    ON agent_runs (status, updated_at_ms DESC);
CREATE INDEX IF NOT EXISTS idx_agent_runs_thread_updated
    ON agent_runs (thread_id, updated_at_ms DESC);

CREATE TABLE IF NOT EXISTS run_steps (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL,
    step_index INTEGER NOT NULL,
    kind TEXT NOT NULL,
    tool_name TEXT NOT NULL DEFAULT '',
    risk_tier INTEGER NOT NULL DEFAULT 0,
    idempotency_key TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    input_json TEXT NOT NULL DEFAULT '{}',
    output_json TEXT NOT NULL DEFAULT '{}',
    duration_ms INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL,
    completed_at_ms INTEGER,
    FOREIGN KEY (run_id) REFERENCES agent_runs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_run_steps_run_idx
    ON run_steps (run_id, step_index ASC, created_at_ms ASC);

CREATE TABLE IF NOT EXISTS steering_queue (
    id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL,
    run_id TEXT,
    content TEXT NOT NULL,
    attachments_json TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'pending',
    created_at_ms INTEGER NOT NULL,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_steering_queue_thread_status
    ON steering_queue (thread_id, status, created_at_ms ASC);

CREATE TABLE IF NOT EXISTS workspace_checkpoints (
    id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL,
    run_id TEXT,
    node_id TEXT,
    file_path TEXT NOT NULL,
    before_blake3 TEXT NOT NULL,
    after_blake3 TEXT NOT NULL DEFAULT '',
    pre_image_blob BLOB NOT NULL,
    created_at_ms INTEGER NOT NULL,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_workspace_checkpoints_thread
    ON workspace_checkpoints (thread_id, created_at_ms DESC);

CREATE TABLE IF NOT EXISTS attachments (
    id TEXT PRIMARY KEY,
    thread_id TEXT NOT NULL,
    node_id TEXT,
    kind TEXT NOT NULL,
    filename TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    byte_len INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    storage_rel_path TEXT NOT NULL,
    extracted_text TEXT NOT NULL DEFAULT '',
    created_at_ms INTEGER NOT NULL,
    FOREIGN KEY (thread_id) REFERENCES threads(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_attachments_thread_node
    ON attachments (thread_id, node_id, created_at_ms ASC);

CREATE TABLE IF NOT EXISTS memory_entries (
    id TEXT PRIMARY KEY,
    scope TEXT NOT NULL DEFAULT 'global',
    scope_id TEXT NOT NULL DEFAULT '',
    key TEXT NOT NULL,
    content TEXT NOT NULL,
    source_thread_id TEXT,
    pinned INTEGER NOT NULL DEFAULT 0,
    updated_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_memory_entries_scope_pinned
    ON memory_entries (scope, scope_id, pinned DESC, updated_at_ms DESC);

CREATE TABLE IF NOT EXISTS cron_jobs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    workspace_id TEXT NOT NULL,
    assistant_id TEXT NOT NULL,
    schedule_expr TEXT NOT NULL,
    prompt TEXT NOT NULL,
    mode TEXT NOT NULL DEFAULT 'code',
    unattended_policy TEXT NOT NULL DEFAULT 'deny_tier2_and_continue',
    use_worktree INTEGER NOT NULL DEFAULT 1,
    enabled INTEGER NOT NULL DEFAULT 1,
    next_run_ms INTEGER NOT NULL DEFAULT 0,
    last_run_id TEXT,
    last_status TEXT NOT NULL DEFAULT 'idle'
);

CREATE INDEX IF NOT EXISTS idx_cron_jobs_enabled_next
    ON cron_jobs (enabled, next_run_ms ASC);

CREATE TABLE IF NOT EXISTS engine_events_log (
    cursor INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id TEXT,
    event_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_engine_events_log_thread
    ON engine_events_log (thread_id, cursor ASC);
";

/// Input parameters for creating a durable `agent_runs` record.
#[derive(Debug, Clone)]
pub struct CreateAgentRunParams {
    pub thread_id: String,
    pub parent_run_id: Option<String>,
    pub root_node_id: Option<String>,
    pub mode: ThreadMode,
    pub max_steps: u32,
    pub unattended_policy: UnattendedPolicy,
    pub worktree_path: Option<String>,
}

/// Optional patch for atomically updating an `agent_runs` record.
#[derive(Debug, Clone, Default)]
pub struct AgentRunUpdate {
    pub status: Option<RunStatus>,
    pub step_index: Option<u32>,
    pub retry_after_ms: Option<Option<i64>>,
    pub partial_text_buffer: Option<String>,
    pub partial_thinking_buffer: Option<String>,
    pub cost_micros: Option<MoneyMicros>,
    pub error_key: Option<Option<String>>,
    pub worktree_path: Option<Option<String>>,
}

impl StorageHandle {
    /// Creates and persists a new durable `agent_runs` row in SQLite WAL.
    pub fn create_agent_run(&self, input: CreateAgentRunParams) -> BistreResult<AgentRunRecord> {
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();
        let max_steps = input.max_steps.clamp(1, 200);

        self.write(move |conn| {
            conn.execute(
                "INSERT INTO agent_runs (
                    id, thread_id, parent_run_id, root_node_id, mode, status,
                    step_index, max_steps, unattended_policy, worktree_path,
                    retry_after_ms, last_heartbeat_ms, partial_text_buffer,
                    partial_thinking_buffer, cost_micros, error_key,
                    created_at_ms, updated_at_ms
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7, ?8, ?9, NULL, ?10, '', '', 0, NULL, ?10, ?10)",
                params![
                    id,
                    input.thread_id,
                    input.parent_run_id,
                    input.root_node_id,
                    input.mode.as_str(),
                    RunStatus::Running.as_str(),
                    i64::from(max_steps),
                    input.unattended_policy.as_str(),
                    input.worktree_path,
                    now
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(AgentRunRecord {
                id,
                thread_id: input.thread_id,
                parent_run_id: input.parent_run_id,
                root_node_id: input.root_node_id,
                mode: input.mode,
                status: RunStatus::Running,
                step_index: 0,
                max_steps,
                unattended_policy: input.unattended_policy,
                worktree_path: input.worktree_path,
                retry_after_ms: None,
                last_heartbeat_ms: now,
                partial_text_buffer: String::new(),
                partial_thinking_buffer: String::new(),
                cost_micros: MoneyMicros::ZERO,
                error_key: None,
                created_at_ms: now,
                updated_at_ms: now,
            })
        })
    }

    /// Updates status, heartbeat, buffers, retry timer, or cost of an `agent_runs` record atomically.
    /// Appends streamed text to a run's partial buffer (checkpoints write only the new suffix).
    pub fn append_agent_run_partial_text(
        &self,
        run_id: String,
        suffix: String,
    ) -> BistreResult<()> {
        let now = now_unix_ms();
        self.write(move |conn| {
            conn.execute(
                "UPDATE agent_runs SET partial_text_buffer = partial_text_buffer || ?2,
                                       last_heartbeat_ms = ?3
                 WHERE id = ?1",
                params![run_id, suffix, now],
            )
            .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    pub fn update_agent_run(
        &self,
        run_id: String,
        patch: AgentRunUpdate,
    ) -> BistreResult<AgentRunRecord> {
        let now = now_unix_ms();
        self.write(move |conn| {
            let existing = conn
                .query_row(
                    "SELECT id, thread_id, parent_run_id, root_node_id, mode, status, step_index, max_steps,
                            unattended_policy, worktree_path, retry_after_ms, last_heartbeat_ms,
                            partial_text_buffer, partial_thinking_buffer, cost_micros, error_key,
                            created_at_ms, updated_at_ms
                     FROM agent_runs WHERE id = ?1",
                    [&run_id],
                    map_agent_run_row,
                )
                .optional()
                .map_err(map_sqlite_err)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;

            let next_status = patch.status.unwrap_or(existing.status);
            let next_step = patch.step_index.unwrap_or(existing.step_index);
            let next_retry = patch.retry_after_ms.unwrap_or(existing.retry_after_ms);
            let next_partial_text = patch
                .partial_text_buffer
                .unwrap_or(existing.partial_text_buffer);
            let next_partial_thinking = patch
                .partial_thinking_buffer
                .unwrap_or(existing.partial_thinking_buffer);
            let next_cost = patch.cost_micros.unwrap_or(existing.cost_micros);
            let next_error = patch.error_key.unwrap_or(existing.error_key);
            let next_worktree = patch.worktree_path.unwrap_or(existing.worktree_path);

            conn.execute(
                "UPDATE agent_runs
                 SET status = ?1, step_index = ?2, retry_after_ms = ?3,
                     last_heartbeat_ms = ?4, partial_text_buffer = ?5,
                     partial_thinking_buffer = ?6, cost_micros = ?7,
                     error_key = ?8, worktree_path = ?9, updated_at_ms = ?4
                 WHERE id = ?10",
                params![
                    next_status.as_str(),
                    i64::from(next_step),
                    next_retry,
                    now,
                    next_partial_text,
                    next_partial_thinking,
                    next_cost.as_micros(),
                    next_error,
                    next_worktree,
                    run_id
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(AgentRunRecord {
                id: existing.id,
                thread_id: existing.thread_id,
                parent_run_id: existing.parent_run_id,
                root_node_id: existing.root_node_id,
                mode: existing.mode,
                status: next_status,
                step_index: next_step,
                max_steps: existing.max_steps,
                unattended_policy: existing.unattended_policy,
                worktree_path: next_worktree,
                retry_after_ms: next_retry,
                last_heartbeat_ms: now,
                partial_text_buffer: next_partial_text,
                partial_thinking_buffer: next_partial_thinking,
                cost_micros: next_cost,
                error_key: next_error,
                created_at_ms: existing.created_at_ms,
                updated_at_ms: now,
            })
        })
    }

    /// Fetches a single durable run record by ID.
    pub fn get_agent_run(&self, run_id: &str) -> BistreResult<Option<AgentRunRecord>> {
        let conn = self.open_reader()?;
        conn.query_row(
            "SELECT id, thread_id, parent_run_id, root_node_id, mode, status, step_index, max_steps,
                    unattended_policy, worktree_path, retry_after_ms, last_heartbeat_ms,
                    partial_text_buffer, partial_thinking_buffer, cost_micros, error_key,
                    created_at_ms, updated_at_ms
             FROM agent_runs WHERE id = ?1",
            [run_id],
            map_agent_run_row,
        )
        .optional()
        .map_err(map_sqlite_err)
    }

    /// Lists recent durable agent runs (optionally filtered to active/recoverable statuses).
    pub fn list_agent_runs(
        &self,
        thread_id: Option<&str>,
        only_active: bool,
        limit: u32,
    ) -> BistreResult<Vec<AgentRunRecord>> {
        let conn = self.open_reader()?;
        let capped = i64::from(limit.clamp(1, 200));
        let sql = match (thread_id.is_some(), only_active) {
            (true, true) => {
                "SELECT id, thread_id, parent_run_id, root_node_id, mode, status, step_index, max_steps,
                        unattended_policy, worktree_path, retry_after_ms, last_heartbeat_ms,
                        partial_text_buffer, partial_thinking_buffer, cost_micros, error_key,
                        created_at_ms, updated_at_ms
                 FROM agent_runs
                 WHERE thread_id = ?1
                   AND status IN ('running', 'waiting_approval', 'backoff_wait', 'sleep_paused', 'indeterminate_halt')
                 ORDER BY updated_at_ms DESC LIMIT ?2"
            }
            (true, false) => {
                "SELECT id, thread_id, parent_run_id, root_node_id, mode, status, step_index, max_steps,
                        unattended_policy, worktree_path, retry_after_ms, last_heartbeat_ms,
                        partial_text_buffer, partial_thinking_buffer, cost_micros, error_key,
                        created_at_ms, updated_at_ms
                 FROM agent_runs
                 WHERE thread_id = ?1
                 ORDER BY updated_at_ms DESC LIMIT ?2"
            }
            (false, true) => {
                "SELECT id, thread_id, parent_run_id, root_node_id, mode, status, step_index, max_steps,
                        unattended_policy, worktree_path, retry_after_ms, last_heartbeat_ms,
                        partial_text_buffer, partial_thinking_buffer, cost_micros, error_key,
                        created_at_ms, updated_at_ms
                 FROM agent_runs
                 WHERE status IN ('running', 'waiting_approval', 'backoff_wait', 'sleep_paused', 'indeterminate_halt')
                 ORDER BY updated_at_ms DESC LIMIT ?1"
            }
            (false, false) => {
                "SELECT id, thread_id, parent_run_id, root_node_id, mode, status, step_index, max_steps,
                        unattended_policy, worktree_path, retry_after_ms, last_heartbeat_ms,
                        partial_text_buffer, partial_thinking_buffer, cost_micros, error_key,
                        created_at_ms, updated_at_ms
                 FROM agent_runs
                 ORDER BY updated_at_ms DESC LIMIT ?1"
            }
        };
        let mut stmt = conn.prepare(sql).map_err(map_sqlite_err)?;
        if let Some(tid) = thread_id {
            let rows = stmt
                .query_map(params![tid, capped], map_agent_run_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        } else {
            let rows = stmt
                .query_map(params![capped], map_agent_run_row)
                .map_err(map_sqlite_err)?;
            rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
        }
    }

    /// Marks all `running` or `backoff_wait` runs as `sleep_paused` prior to OS suspend/timeout.
    pub fn mark_active_runs_sleep_paused(&self) -> BistreResult<u32> {
        let now = now_unix_ms();
        self.write(move |conn| {
            let changed = conn
                .execute(
                    "UPDATE agent_runs
                     SET status = 'sleep_paused', last_heartbeat_ms = ?1, updated_at_ms = ?1
                     WHERE status IN ('running', 'backoff_wait')",
                    [now],
                )
                .map_err(map_sqlite_err)?;
            Ok(u32::try_from(changed).unwrap_or(u32::MAX))
        })
    }

    /// Records a journaled execution step with deterministic idempotency key.
    #[expect(
        clippy::too_many_arguments,
        reason = "Explicit step journal columns mapped cleanly into run_steps table."
    )]
    pub fn record_run_step(
        &self,
        run_id: String,
        step_index: u32,
        kind: RunStepKind,
        tool_name: String,
        risk_tier: ToolRiskTier,
        idempotency_key: String,
        status: String,
        input_json: String,
        output_json: String,
        duration_ms: i64,
        completed_at_ms: Option<i64>,
    ) -> BistreResult<RunStepRecord> {
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();
        let (output_json, overflow) = spill_step_output(output_json);
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO run_steps (
                    id, run_id, step_index, kind, tool_name, risk_tier,
                    idempotency_key, status, input_json, output_json,
                    duration_ms, created_at_ms, completed_at_ms, result_overflow
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    id,
                    run_id,
                    i64::from(step_index),
                    kind.as_str(),
                    tool_name,
                    i64::from(risk_tier.as_u8()),
                    idempotency_key,
                    status,
                    input_json,
                    output_json,
                    duration_ms,
                    now,
                    completed_at_ms,
                    overflow
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(RunStepRecord {
                id,
                run_id,
                step_index,
                kind,
                tool_name,
                risk_tier,
                idempotency_key,
                status,
                input_json,
                output_json,
                duration_ms,
                created_at_ms: now,
                completed_at_ms,
            })
        })
    }

    /// Updates a `run_steps` row once a tool or LLM step settles.
    pub fn complete_run_step(
        &self,
        step_id: String,
        status: String,
        output_json: String,
        duration_ms: i64,
    ) -> BistreResult<()> {
        let now = now_unix_ms();
        let (output_json, overflow) = spill_step_output(output_json);
        self.write(move |conn| {
            conn.execute(
                "UPDATE run_steps
                 SET status = ?1, output_json = ?2, duration_ms = ?3, completed_at_ms = ?4,
                     result_overflow = ?5
                 WHERE id = ?6",
                params![status, output_json, duration_ms, now, overflow, step_id],
            )
            .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

    /// Lazily hydrates a step's full output (the overflow blob when spilled, else `output_json`).
    pub fn load_run_step_output(&self, step_id: &str) -> BistreResult<Option<String>> {
        let conn = self.open_reader()?;
        let row: Option<(String, Option<Vec<u8>>)> = conn
            .query_row(
                "SELECT output_json, result_overflow FROM run_steps WHERE id = ?1",
                [step_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(map_sqlite_err)?;
        Ok(row.map(|(inline, blob)| {
            blob.map_or(inline, |b| String::from_utf8_lossy(&b).into_owned())
        }))
    }

    /// Lists all steps for an `agent_runs` execution in order.
    pub fn list_run_steps(&self, run_id: &str) -> BistreResult<Vec<RunStepRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, run_id, step_index, kind, tool_name, risk_tier, idempotency_key,
                        status, input_json, output_json, duration_ms, created_at_ms, completed_at_ms
                 FROM run_steps WHERE run_id = ?1
                 ORDER BY step_index ASC, created_at_ms ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([run_id], map_run_step_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Enqueues a mid-stream user steering message persisted in SQLite WAL.
    pub fn enqueue_steering_message(
        &self,
        thread_id: String,
        run_id: Option<String>,
        content: &str,
        attachments_json: String,
    ) -> BistreResult<SteeringMessage> {
        let clean = content.trim().to_owned();
        if clean.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "empty_steering_message",
            ));
        }
        let id = Uuid::now_v7().to_string();
        let now = now_unix_ms();
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO steering_queue (id, thread_id, run_id, content, attachments_json, status, created_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, 'pending', ?6)",
                params![id, thread_id, run_id, clean, attachments_json, now],
            )
            .map_err(map_sqlite_err)?;
            Ok(SteeringMessage {
                id,
                thread_id,
                run_id,
                content: clean,
                attachments_json,
                status: "pending".to_owned(),
                created_at_ms: now,
            })
        })
    }

    /// Lists pending steering messages for a thread in FIFO order.
    pub fn list_pending_steering(&self, thread_id: &str) -> BistreResult<Vec<SteeringMessage>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, thread_id, run_id, content, attachments_json, status, created_at_ms
                 FROM steering_queue
                 WHERE thread_id = ?1 AND status = 'pending'
                 ORDER BY created_at_ms ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([thread_id], map_steering_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Atomically pops all pending steering messages for a thread and marks them `injected`.
    pub fn drain_pending_steering(&self, thread_id: String) -> BistreResult<Vec<SteeringMessage>> {
        self.write(move |conn| {
            let mut stmt = conn
                .prepare(
                    "SELECT id, thread_id, run_id, content, attachments_json, status, created_at_ms
                     FROM steering_queue
                     WHERE thread_id = ?1 AND status = 'pending'
                     ORDER BY created_at_ms ASC",
                )
                .map_err(map_sqlite_err)?;
            let mut items = stmt
                .query_map([&thread_id], map_steering_row)
                .map_err(map_sqlite_err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(map_sqlite_err)?;
            drop(stmt);
            if !items.is_empty() {
                conn.execute(
                    "UPDATE steering_queue SET status = 'injected'
                     WHERE thread_id = ?1 AND status = 'pending'",
                    [&thread_id],
                )
                .map_err(map_sqlite_err)?;
                for item in &mut items {
                    "injected".clone_into(&mut item.status);
                }
            }
            Ok(items)
        })
    }

    /// Cancels and removes a pending steering message before it is injected.
    pub fn delete_steering_message(&self, steering_id: String) -> BistreResult<()> {
        self.write(move |conn| {
            conn.execute(
                "UPDATE steering_queue SET status = 'cancelled' WHERE id = ?1",
                [&steering_id],
            )
            .map_err(map_sqlite_err)?;
            Ok(())
        })
    }

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

    /// Appends an `EngineEvent` into the bounded monotonic `engine_events_log` table and returns its cursor.
    pub fn append_engine_event_log(
        &self,
        thread_id: Option<String>,
        event: &EngineEvent,
    ) -> BistreResult<u64> {
        // R31: the log keeps ids and states only; bodies stay in their own tables.
        let event_json = serde_json::to_string(&event.without_content()).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InternalError, "event_serialize")
        })?;
        let now = now_unix_ms();
        self.write(move |conn| {
            conn.execute(
                "INSERT INTO engine_events_log (thread_id, event_json, created_at_ms)
                 VALUES (?1, ?2, ?3)",
                params![thread_id, event_json, now],
            )
            .map_err(map_sqlite_err)?;
            let cursor = conn.last_insert_rowid();
            if cursor > MAX_RETAINED_EVENT_LOG_ROWS && cursor % 128 == 0 {
                let prune_before = cursor.saturating_sub(MAX_RETAINED_EVENT_LOG_ROWS);
                conn.execute(
                    "DELETE FROM engine_events_log WHERE cursor <= ?1",
                    [prune_before],
                )
                .map_err(map_sqlite_err)?;
            }
            Ok(u64::try_from(cursor).unwrap_or(0))
        })
    }

    /// Replays persisted engine events strictly newer than `after_cursor` (`resume_after_cursor`).
    pub fn read_engine_events_after(
        &self,
        after_cursor: u64,
        limit: u32,
    ) -> BistreResult<Vec<CursorEventRecord>> {
        let conn = self.open_reader()?;
        let cursor_i64 = i64::try_from(after_cursor).unwrap_or(i64::MAX);
        let capped = i64::from(limit.clamp(1, 500));
        let mut stmt = conn
            .prepare(
                "SELECT cursor, thread_id, event_json, created_at_ms
                 FROM engine_events_log
                 WHERE cursor > ?1
                 ORDER BY cursor ASC
                 LIMIT ?2",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map(params![cursor_i64, capped], |row| {
                let cursor_raw: i64 = row.get(0)?;
                let thread_id: Option<String> = row.get(1)?;
                let event_json: String = row.get(2)?;
                let created_at_ms: i64 = row.get(3)?;
                Ok((cursor_raw, thread_id, event_json, created_at_ms))
            })
            .map_err(map_sqlite_err)?;

        let mut out = Vec::new();
        for item in rows {
            let (cursor_raw, thread_id, event_json, created_at_ms) =
                item.map_err(map_sqlite_err)?;
            if let Ok(event) = serde_json::from_str::<EngineEvent>(&event_json) {
                out.push(CursorEventRecord {
                    cursor: u64::try_from(cursor_raw).unwrap_or(0),
                    thread_id,
                    event,
                    created_at_ms,
                });
            }
        }
        Ok(out)
    }

    /// Returns the latest persisted event cursor (`0` if empty).
    pub fn latest_event_cursor(&self) -> BistreResult<u64> {
        let conn = self.open_reader()?;
        let max_cursor: Option<i64> = conn
            .query_row("SELECT MAX(cursor) FROM engine_events_log", [], |r| {
                r.get(0)
            })
            .map_err(map_sqlite_err)?;
        Ok(max_cursor.and_then(|v| u64::try_from(v).ok()).unwrap_or(0))
    }
}

fn map_agent_run_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentRunRecord> {
    let mode_raw: String = row.get(4)?;
    let status_raw: String = row.get(5)?;
    let step_idx: i64 = row.get(6)?;
    let max_steps: i64 = row.get(7)?;
    let policy_raw: String = row.get(8)?;
    let cost_raw: i64 = row.get(14)?;
    Ok(AgentRunRecord {
        id: row.get(0)?,
        thread_id: row.get(1)?,
        parent_run_id: row.get(2)?,
        root_node_id: row.get(3)?,
        mode: ThreadMode::parse(&mode_raw),
        status: RunStatus::parse(&status_raw),
        step_index: u32::try_from(step_idx).unwrap_or(0),
        max_steps: u32::try_from(max_steps).unwrap_or(40),
        unattended_policy: UnattendedPolicy::parse(&policy_raw),
        worktree_path: row.get(9)?,
        retry_after_ms: row.get(10)?,
        last_heartbeat_ms: row.get(11)?,
        partial_text_buffer: row.get(12)?,
        partial_thinking_buffer: row.get(13)?,
        cost_micros: MoneyMicros::from_micros(cost_raw),
        error_key: row.get(15)?,
        created_at_ms: row.get(16)?,
        updated_at_ms: row.get(17)?,
    })
}

fn map_run_step_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RunStepRecord> {
    let step_idx: i64 = row.get(2)?;
    let kind_raw: String = row.get(3)?;
    let risk_raw: i64 = row.get(5)?;
    Ok(RunStepRecord {
        id: row.get(0)?,
        run_id: row.get(1)?,
        step_index: u32::try_from(step_idx).unwrap_or(0),
        kind: RunStepKind::parse(&kind_raw),
        tool_name: row.get(4)?,
        risk_tier: ToolRiskTier::from_u8(u8::try_from(risk_raw).unwrap_or(3)),
        idempotency_key: row.get(6)?,
        status: row.get(7)?,
        input_json: row.get(8)?,
        output_json: row.get(9)?,
        duration_ms: row.get(10)?,
        created_at_ms: row.get(11)?,
        completed_at_ms: row.get(12)?,
    })
}

fn map_steering_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SteeringMessage> {
    Ok(SteeringMessage {
        id: row.get(0)?,
        thread_id: row.get(1)?,
        run_id: row.get(2)?,
        content: row.get(3)?,
        attachments_json: row.get(4)?,
        status: row.get(5)?,
        created_at_ms: row.get(6)?,
    })
}

fn map_checkpoint_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<WorkspaceCheckpointRecord> {
    Ok(WorkspaceCheckpointRecord {
        id: row.get(0)?,
        thread_id: row.get(1)?,
        run_id: row.get(2)?,
        node_id: row.get(3)?,
        file_path: row.get(4)?,
        before_blake3: row.get(5)?,
        after_blake3: row.get(6)?,
        pre_image_blob: row.get(7)?,
        created_at_ms: row.get(8)?,
    })
}

fn map_attachment_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AttachmentRecord> {
    let byte_len: i64 = row.get(6)?;
    Ok(AttachmentRecord {
        id: row.get(0)?,
        thread_id: row.get(1)?,
        node_id: row.get(2)?,
        kind: row.get(3)?,
        filename: row.get(4)?,
        mime_type: row.get(5)?,
        byte_len: u64::try_from(byte_len).unwrap_or(0),
        sha256: row.get(7)?,
        storage_rel_path: row.get(8)?,
        extracted_text: row.get(9)?,
        created_at_ms: row.get(10)?,
    })
}

fn map_memory_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<MemoryEntryRecord> {
    let pinned: i64 = row.get(6)?;
    Ok(MemoryEntryRecord {
        id: row.get(0)?,
        scope: row.get(1)?,
        scope_id: row.get(2)?,
        key: row.get(3)?,
        content: row.get(4)?,
        source_thread_id: row.get(5)?,
        pinned: pinned != 0,
        updated_at_ms: row.get(7)?,
    })
}

fn map_cron_job_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CronJobRecord> {
    let mode_raw: String = row.get(6)?;
    let policy_raw: String = row.get(7)?;
    let use_worktree: i64 = row.get(8)?;
    let enabled: i64 = row.get(9)?;
    Ok(CronJobRecord {
        id: row.get(0)?,
        name: row.get(1)?,
        workspace_id: row.get(2)?,
        assistant_id: row.get(3)?,
        schedule_expr: row.get(4)?,
        prompt: row.get(5)?,
        mode: ThreadMode::parse(&mode_raw),
        unattended_policy: UnattendedPolicy::parse(&policy_raw),
        use_worktree: use_worktree != 0,
        enabled: enabled != 0,
        next_run_ms: row.get(10)?,
        last_run_id: row.get(11)?,
        last_status: row.get(12)?,
    })
}

#[cfg(test)]
mod spill_tests {
    use super::*;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn oversized_step_output_spills_to_overflow_blob_and_hydrates_lazily() {
        let small = "{\"ok\":true}".to_owned();
        assert_eq!(spill_step_output(small.clone()), (small, None));
        let big = format!(
            "{{\"text\":\"{}\"}}",
            "x".repeat(MAX_INLINE_STEP_OUTPUT_BYTES + 10)
        );
        let (inline, blob) = spill_step_output(big.clone());
        assert!(inline.len() < 8 * 1024);
        assert!(inline.contains("\"overflow\":true"));
        assert_eq!(blob.map(String::from_utf8), Some(Ok(big)));
    }

    #[test]
    fn spilled_step_output_round_trips_through_v8_schema() -> TestResult {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("v8.sqlite"))?;
        let thread = storage.create_thread(None, "Spill", ThreadMode::Code, None, None)?;
        let run = storage.create_agent_run(CreateAgentRunParams {
            thread_id: thread.id,
            parent_run_id: None,
            root_node_id: None,
            mode: ThreadMode::Code,
            max_steps: 4,
            unattended_policy: UnattendedPolicy::PauseAndNotify,
            worktree_path: None,
        })?;
        let step = storage.record_run_step(
            run.id.clone(),
            0,
            RunStepKind::ToolCall,
            "shell".to_owned(),
            ToolRiskTier::Tier2ExternalSideEffect,
            "k0".to_owned(),
            "running".to_owned(),
            "{}".to_owned(),
            "{}".to_owned(),
            0,
            None,
        )?;
        let big = format!(
            "{{\"stdout\":\"{}\"}}",
            "y".repeat(MAX_INLINE_STEP_OUTPUT_BYTES * 2)
        );
        assert!(
            storage
                .complete_run_step(step.id.clone(), "completed".to_owned(), big.clone(), 5)
                .is_ok()
        );
        let listed = storage.list_run_steps(&run.id);
        assert!(listed.is_ok_and(|steps| {
            steps
                .first()
                .is_some_and(|s| s.output_json.len() < 8 * 1024)
        }));
        assert_eq!(storage.load_run_step_output(&step.id)?, Some(big));
        Ok(())
    }
}
