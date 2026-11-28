//! Thread and message-tree repository (`impl StorageHandle`): threads, nodes, branches, and compaction summaries.

use super::{
    BistreError, BistreResult, Connection, DEFAULT_ASSISTANT_ID, DEFAULT_WORKSPACE_ID,
    DiagnosticKey, MAX_BRANCH_DEPTH, NodeRecord, NodeRole, OptionalExtension, StorageHandle,
    ThreadMode, ThreadPatch, ThreadSummary, Uuid, clean_opt_string, map_sqlite_err, map_thread_row,
    normalize_topic, now_unix_ms, params, schema,
};

impl StorageHandle {
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
    /// Runs a write that changes `nodes` (and so fires the FTS triggers). If the full-text index
    /// is corrupt, the search triggers are dropped and the index marked stale in one
    /// transaction, and the write is retried once: saving messages never depends on search.
    /// The index is never rebuilt live; search falls back to a plain scan meanwhile.
    pub(crate) fn write_node_change<T, F>(&self, mut op: F) -> BistreResult<T>
    where
        T: Send + 'static,
        F: FnMut(&mut Connection) -> BistreResult<T> + Send + 'static,
    {
        self.write(move |conn| match op(conn) {
            Err(err) if err.key == DiagnosticKey::StorageSearchIndexCorrupt => {
                tracing::error!(
                    key = err.key.as_key(),
                    "search index corrupt: search triggers dropped and index marked stale"
                );
                let tx = conn.transaction().map_err(map_sqlite_err)?;
                tx.execute_batch(schema::DROP_SEARCH_TRIGGERS_SQL)
                    .map_err(map_sqlite_err)?;
                tx.execute(
                    "INSERT OR REPLACE INTO kv_meta (key, value) VALUES ('search.fts_stale', '1')",
                    [],
                )
                .map_err(map_sqlite_err)?;
                tx.commit().map_err(map_sqlite_err)?;
                op(conn)
            }
            other => other,
        })
    }
    /// Deletes a chat and everything derived from it: nodes (cascade), its event-log rows, and
    /// its run journal with steps, in one transaction.
    pub fn delete_thread(&self, thread_id: String) -> BistreResult<()> {
        self.write_node_change(move |conn| {
            let tx = conn.transaction().map_err(map_sqlite_err)?;
            tx.execute(
                "DELETE FROM run_steps WHERE run_id IN (SELECT id FROM agent_runs WHERE thread_id = ?1)",
                [&thread_id],
            )
            .map_err(map_sqlite_err)?;
            tx.execute("DELETE FROM agent_runs WHERE thread_id = ?1", [&thread_id])
                .map_err(map_sqlite_err)?;
            tx.execute(
                "DELETE FROM engine_events_log WHERE thread_id = ?1",
                [&thread_id],
            )
            .map_err(map_sqlite_err)?;
            let deleted = tx
                .execute("DELETE FROM threads WHERE id = ?1", [&thread_id])
                .map_err(map_sqlite_err)?;
            if deleted == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            // Values kept for this chat alone end in `:<chat id>` (checklist, reply prefill,
            // last-viewed mark); an exact suffix match, so no other chat's key can match.
            tx.execute(
                "DELETE FROM kv_meta WHERE substr(key, -length(?1) - 1) = ':' || ?1",
                [&thread_id],
            )
            .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)
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

        self.write_node_change(move |conn| {
            let tx = conn.transaction().map_err(map_sqlite_err)?;
            // A parent from another thread (or a missing one) would graft one chat onto
            // another; refuse it in the same transaction as the insert.
            if let Some(pid) = parent_id.as_deref() {
                let parent_thread: Option<String> = tx
                    .query_row("SELECT thread_id FROM nodes WHERE id = ?1", [pid], |row| row.get(0))
                    .optional()
                    .map_err(map_sqlite_err)?;
                if parent_thread.as_deref() != Some(thread_id.as_str()) {
                    return Err(BistreError::new(DiagnosticKey::StorageParentThreadMismatch));
                }
            }
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
                id: id.clone(),
                thread_id: thread_id.clone(),
                parent_id: parent_id.clone(),
                role,
                content: content.clone(),
                provider_meta_json: provider_meta_json.clone(),
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

    /// The newest `limit` (1..=500) of `thread_id`'s messages that carry files, newest first,
    /// with their text left out (`content` is empty).
    pub fn list_nodes_with_files(
        &self,
        thread_id: &str,
        limit: usize,
    ) -> BistreResult<Vec<NodeRecord>> {
        let cap = i64::try_from(limit.clamp(1, 500)).unwrap_or(500);
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, thread_id, parent_id, role, provider_meta_json, created_at_ms
                 FROM nodes WHERE thread_id = ?1 AND provider_meta_json LIKE '%\"attachments\"%'
                 ORDER BY rowid DESC LIMIT ?2",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map(params![thread_id, cap], |row| {
                let role_raw: String = row.get(3)?;
                Ok(NodeRecord {
                    id: row.get(0)?,
                    thread_id: row.get(1)?,
                    parent_id: row.get(2)?,
                    role: NodeRole::parse(&role_raw),
                    content: String::new(),
                    provider_meta_json: row.get(4)?,
                    created_at_ms: row.get(5)?,
                })
            })
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// A page of `thread_id`'s nodes, oldest first: the newest `limit` (1..=500) written before
    /// the node `before_node_id`, or the newest overall without it. Paging by write order never
    /// skips nodes that share a timestamp. A `before_node_id` that is not in the thread is
    /// `StorageNotFound`.
    pub fn list_nodes_window(
        &self,
        thread_id: &str,
        before_node_id: Option<&str>,
        limit: usize,
    ) -> BistreResult<Vec<NodeRecord>> {
        let cap = i64::try_from(limit.clamp(1, 500)).unwrap_or(500);
        let conn = self.open_reader()?;
        let before_rowid: i64 = match before_node_id {
            Some(id) => conn
                .query_row(
                    "SELECT rowid FROM nodes WHERE id = ?1 AND thread_id = ?2",
                    params![id, thread_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(map_sqlite_err)?
                .ok_or_else(|| {
                    BistreError::with_detail(DiagnosticKey::StorageNotFound, "window_anchor")
                })?,
            None => i64::MAX,
        };
        let mut stmt = conn
            .prepare(
                "SELECT id, thread_id, parent_id, role, content, provider_meta_json, created_at_ms
                 FROM nodes WHERE thread_id = ?1 AND rowid < ?2
                 ORDER BY rowid DESC LIMIT ?3",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map(params![thread_id, before_rowid, cap], |row| {
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
        let mut nodes = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(map_sqlite_err)?;
        nodes.reverse();
        Ok(nodes)
    }

    /// Returns a monotonic history revision (`MAX(rowid)`, or `0` when empty) for `thread_id`,
    /// enabling lag-free unread badges (`last_viewed_rev` vs `history_rev`) without reloading nodes.
    pub fn thread_history_rev(&self, thread_id: &str) -> BistreResult<i64> {
        let conn = self.open_reader()?;
        conn.query_row(
            "SELECT COALESCE(MAX(rowid), 0) FROM nodes WHERE thread_id = ?1",
            [thread_id],
            |row| row.get(0),
        )
        .map_err(map_sqlite_err)
    }

    /// The branch that ends at `leaf_id`, root first: a recursive walk up the parent
    /// links in SQLite, so a step reads only its own branch, not every node of the thread.
    /// Bounded by [`MAX_BRANCH_DEPTH`]; a cycle stops at the depth cap.
    pub fn list_branch(&self, thread_id: &str, leaf_id: &str) -> BistreResult<Vec<NodeRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "WITH RECURSIVE branch(id, depth) AS (
                     SELECT id, 0 FROM nodes WHERE id = ?2 AND thread_id = ?1
                     UNION ALL
                     SELECT n.parent_id, b.depth + 1
                     FROM branch b JOIN nodes n ON n.id = b.id
                     WHERE n.parent_id IS NOT NULL AND b.depth < ?3
                 )
                 SELECT n.id, n.thread_id, n.parent_id, n.role, n.content,
                        n.provider_meta_json, n.created_at_ms
                 FROM branch b JOIN nodes n ON n.id = b.id AND n.thread_id = ?1
                 ORDER BY b.depth DESC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map(
                rusqlite::params![thread_id, leaf_id, MAX_BRANCH_DEPTH],
                |row| {
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
                },
            )
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Deletes a single DAG node cleanly, reparenting direct children and updating `active_head_node_id`.
    pub fn delete_node(&self, thread_id: String, node_id: String) -> BistreResult<()> {
        let now = now_unix_ms();
        self.write_node_change(move |conn| {
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

            let current_head: Option<String> = tx
                .query_row(
                    "SELECT active_head_node_id FROM threads WHERE id = ?1",
                    [&thread_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(map_sqlite_err)?
                .flatten();

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

            // Preserve the user's current branch whenever another branch was NOT deleted.
            // Only move `active_head_node_id` if the deleted node itself was the active head.
            let next_head = if current_head.as_deref() == Some(node_id.as_str()) {
                if parent_id.is_some() {
                    parent_id
                } else {
                    tx.query_row(
                        "SELECT id FROM nodes WHERE thread_id = ?1 ORDER BY rowid DESC LIMIT 1",
                        [&thread_id],
                        |row| row.get(0),
                    )
                    .optional()
                    .map_err(map_sqlite_err)?
                }
            } else {
                current_head
            };

            tx.execute(
                "UPDATE threads SET active_head_node_id = ?1, updated_at_ms = ?2 WHERE id = ?3",
                params![next_head, now, &thread_id],
            )
            .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)
        })
    }

    /// Rewrites the text of a compaction summary in `thread_id`, keeping its place in the chat
    /// and its link to the messages it keeps. Summaries stand in for saved messages and may be
    /// corrected; every other message is never rewritten (`not_a_compaction_node`).
    pub fn rewrite_compaction_summary(
        &self,
        thread_id: &str,
        node_id: &str,
        content: &str,
    ) -> BistreResult<NodeRecord> {
        let (thread_id, node_id, content) =
            (thread_id.to_owned(), node_id.to_owned(), content.to_owned());
        let now = now_unix_ms();
        self.write_node_change(move |conn| {
            let tx = conn.transaction().map_err(map_sqlite_err)?;
            let node = tx
                .query_row(
                    "UPDATE nodes SET content = ?3 WHERE id = ?2 AND thread_id = ?1 AND role = ?4
                     RETURNING id, thread_id, parent_id, role, content, provider_meta_json, created_at_ms",
                    params![
                        &thread_id,
                        &node_id,
                        &content,
                        NodeRole::CompactionSummary.as_str()
                    ],
                    |row| {
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
                    },
                )
                .optional()
                .map_err(map_sqlite_err)?
                .ok_or_else(|| {
                    BistreError::with_detail(DiagnosticKey::StorageNotFound, "not_a_compaction_node")
                })?;
            tx.execute(
                "UPDATE threads SET updated_at_ms = ?1 WHERE id = ?2",
                params![now, &thread_id],
            )
            .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)?;
            Ok(node)
        })
    }

    /// Copies the branch that ends at `leaf_id` into a new chat with the source chat's title
    /// and settings, and returns it. Every message gets a new id, references to the old ids
    /// in its metadata are rewritten to the new ones, and the files sent with the messages
    /// are shared (attachment rows are copied; the stored files are never deleted per chat).
    /// Each `kv_meta` value at `<prefix><thread_id>` for a prefix in `carried_kv` is copied
    /// to `<prefix><new id>` with the same rewrite.
    pub fn fork_thread(
        &self,
        thread_id: &str,
        leaf_id: &str,
        carried_kv: &[&str],
    ) -> BistreResult<ThreadSummary> {
        let branch = self.list_branch(thread_id, leaf_id)?;
        let Some(head) = branch.last() else {
            return Err(BistreError::new(DiagnosticKey::StorageNotFound));
        };
        if head.id != leaf_id {
            return Err(BistreError::new(DiagnosticKey::StorageNotFound));
        }
        let new_ids: Vec<String> = branch.iter().map(|_| Uuid::now_v7().to_string()).collect();
        let new_thread_id = Uuid::now_v7().to_string();
        let (source_id, thread_out) = (thread_id.to_owned(), new_thread_id.clone());
        let carried: Vec<String> = carried_kv.iter().map(|p| (*p).to_owned()).collect();
        let now = now_unix_ms();
        self.write_node_change(move |conn| {
            let tx = conn
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(map_sqlite_err)?;
            let head_id = new_ids.last().cloned();
            let rewrite = |text: String| {
                branch
                    .iter()
                    .zip(&new_ids)
                    .fold(text, |acc, (old, new)| acc.replace(&old.id, new))
            };
            let copied = tx
                .execute(
                    "INSERT INTO threads (id, workspace_id, title, mode, topic, assistant_id, is_pinned,
                         active_head_node_id, provider_id_override, model_id_override,
                         system_prompt_override, temperature_milli, max_output_tokens, top_p_milli,
                         created_at_ms, updated_at_ms)
                     SELECT ?1, workspace_id, title, mode, topic, assistant_id, 0, ?2,
                         provider_id_override, model_id_override, system_prompt_override,
                         temperature_milli, max_output_tokens, top_p_milli, ?3, ?3
                     FROM threads WHERE id = ?4",
                    params![&new_thread_id, head_id, now, &source_id],
                )
                .map_err(map_sqlite_err)?;
            if copied == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            for (i, node) in branch.iter().enumerate() {
                let parent = i.checked_sub(1).and_then(|p| new_ids.get(p));
                let meta = node.provider_meta_json.clone().map(rewrite);
                tx.execute(
                    "INSERT INTO nodes (id, thread_id, parent_id, role, content, provider_meta_json, created_at_ms)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        new_ids.get(i),
                        &new_thread_id,
                        parent,
                        node.role.as_str(),
                        &node.content,
                        meta,
                        node.created_at_ms
                    ],
                )
                .map_err(map_sqlite_err)?;
                let mut stmt = tx
                    .prepare(
                        "SELECT kind, filename, mime_type, byte_len, sha256, storage_rel_path,
                                extracted_text, created_at_ms
                         FROM attachments WHERE thread_id = ?1 AND node_id = ?2",
                    )
                    .map_err(map_sqlite_err)?;
                let files = stmt
                    .query_map(params![&source_id, &node.id], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, i64>(3)?,
                            row.get::<_, String>(4)?,
                            row.get::<_, String>(5)?,
                            row.get::<_, String>(6)?,
                            row.get::<_, i64>(7)?,
                        ))
                    })
                    .map_err(map_sqlite_err)?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(map_sqlite_err)?;
                drop(stmt);
                for (kind, name, mime, len, sha, path, text, at) in files {
                    tx.execute(
                        "INSERT INTO attachments (id, thread_id, node_id, kind, filename, mime_type,
                             byte_len, sha256, storage_rel_path, extracted_text, created_at_ms)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                        params![
                            Uuid::now_v7().to_string(),
                            &new_thread_id,
                            new_ids.get(i),
                            kind,
                            name,
                            mime,
                            len,
                            sha,
                            path,
                            text,
                            at
                        ],
                    )
                    .map_err(map_sqlite_err)?;
                }
            }
            carry_kv(&tx, &carried, &source_id, &new_thread_id, rewrite)?;
            tx.commit().map_err(map_sqlite_err)
        })?;
        self.get_thread(&thread_out)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))
    }

    /// Opens a new chat with `thread_id`'s title and settings whose history is one summary
    /// message (`summary`, metadata `meta`), and returns it.
    pub fn resume_from_summary(
        &self,
        thread_id: &str,
        summary: &str,
        meta: &str,
    ) -> BistreResult<ThreadSummary> {
        let text = summary.trim().to_owned();
        if text.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "empty_summary",
            ));
        }
        let (source_id, new_thread_id, node_id) = (
            thread_id.to_owned(),
            Uuid::now_v7().to_string(),
            Uuid::now_v7().to_string(),
        );
        let (thread_out, meta) = (new_thread_id.clone(), meta.to_owned());
        let now = now_unix_ms();
        self.write_node_change(move |conn| {
            let tx = conn
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(map_sqlite_err)?;
            let copied = tx
                .execute(
                    "INSERT INTO threads (id, workspace_id, title, mode, topic, assistant_id, is_pinned,
                         active_head_node_id, provider_id_override, model_id_override,
                         system_prompt_override, temperature_milli, max_output_tokens, top_p_milli,
                         created_at_ms, updated_at_ms)
                     SELECT ?1, workspace_id, title, mode, topic, assistant_id, 0, ?2,
                         provider_id_override, model_id_override, system_prompt_override,
                         temperature_milli, max_output_tokens, top_p_milli, ?3, ?3
                     FROM threads WHERE id = ?4",
                    params![&new_thread_id, &node_id, now, &source_id],
                )
                .map_err(map_sqlite_err)?;
            if copied == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            tx.execute(
                "INSERT INTO nodes (id, thread_id, parent_id, role, content, provider_meta_json, created_at_ms)
                 VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6)",
                params![
                    &node_id,
                    &new_thread_id,
                    NodeRole::CompactionSummary.as_str(),
                    &text,
                    &meta,
                    now
                ],
            )
            .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)
        })?;
        self.get_thread(&thread_out)?
            .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))
    }

    /// Deletes `node_id` with every message after it (all its replies and their branches) and
    /// the attachment rows of those messages, in one transaction. The active head moves to the
    /// node's parent when it was among them.
    pub fn delete_from_node(&self, thread_id: String, node_id: String) -> BistreResult<()> {
        let now = now_unix_ms();
        self.write_node_change(move |conn| {
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
            tx.execute_batch("CREATE TEMP TABLE IF NOT EXISTS doomed_nodes (id TEXT PRIMARY KEY); DELETE FROM doomed_nodes;")
                .map_err(map_sqlite_err)?;
            tx.execute(
                "WITH RECURSIVE sub(id, depth) AS (
                     SELECT id, 0 FROM nodes WHERE id = ?1 AND thread_id = ?2
                     UNION
                     SELECT n.id, s.depth + 1 FROM nodes n JOIN sub s ON n.parent_id = s.id
                     WHERE n.thread_id = ?2 AND s.depth < ?3
                 )
                 INSERT OR IGNORE INTO doomed_nodes (id) SELECT id FROM sub",
                params![&node_id, &thread_id, MAX_BRANCH_DEPTH],
            )
            .map_err(map_sqlite_err)?;
            let head_gone: bool = tx
                .query_row(
                    "SELECT EXISTS (SELECT 1 FROM threads t JOIN doomed_nodes d
                         ON d.id = t.active_head_node_id WHERE t.id = ?1)",
                    [&thread_id],
                    |row| row.get(0),
                )
                .map_err(map_sqlite_err)?;
            tx.execute(
                "DELETE FROM attachments WHERE thread_id = ?1 AND node_id IN (SELECT id FROM doomed_nodes)",
                [&thread_id],
            )
            .map_err(map_sqlite_err)?;
            tx.execute(
                "DELETE FROM nodes WHERE thread_id = ?1 AND id IN (SELECT id FROM doomed_nodes)",
                [&thread_id],
            )
            .map_err(map_sqlite_err)?;
            tx.execute("DELETE FROM doomed_nodes", [])
                .map_err(map_sqlite_err)?;
            if head_gone {
                tx.execute(
                    "UPDATE threads SET active_head_node_id = ?1 WHERE id = ?2",
                    params![&parent_id, &thread_id],
                )
                .map_err(map_sqlite_err)?;
            }
            tx.execute(
                "UPDATE threads SET updated_at_ms = ?1 WHERE id = ?2",
                params![now, &thread_id],
            )
            .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)
        })
    }

    /// Deletes every message of a chat and their attachment rows, keeping the chat itself
    /// with its title and settings.
    pub fn clear_thread_messages(&self, thread_id: String) -> BistreResult<()> {
        let now = now_unix_ms();
        self.write_node_change(move |conn| {
            let tx = conn
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(map_sqlite_err)?;
            let updated = tx
                .execute(
                    "UPDATE threads SET active_head_node_id = NULL, updated_at_ms = ?1 WHERE id = ?2",
                    params![now, &thread_id],
                )
                .map_err(map_sqlite_err)?;
            if updated == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            tx.execute(
                "DELETE FROM attachments WHERE thread_id = ?1 AND node_id IS NOT NULL",
                [&thread_id],
            )
            .map_err(map_sqlite_err)?;
            tx.execute("DELETE FROM nodes WHERE thread_id = ?1", [&thread_id])
                .map_err(map_sqlite_err)?;
            tx.commit().map_err(map_sqlite_err)
        })
    }
}

/// Copies each `<prefix><source_id>` value in `kv_meta` to `<prefix><new_id>`, passed through
/// `rewrite` (old message ids to new ones).
fn carry_kv(
    tx: &rusqlite::Transaction<'_>,
    prefixes: &[String],
    source_id: &str,
    new_id: &str,
    rewrite: impl Fn(String) -> String,
) -> BistreResult<()> {
    for prefix in prefixes {
        let value: Option<String> = tx
            .query_row(
                "SELECT value FROM kv_meta WHERE key = ?1",
                [format!("{prefix}{source_id}")],
                |row| row.get(0),
            )
            .optional()
            .map_err(map_sqlite_err)?;
        if let Some(value) = value {
            tx.execute(
                "INSERT INTO kv_meta (key, value) VALUES (?1, ?2)",
                params![format!("{prefix}{new_id}"), rewrite(value)],
            )
            .map_err(map_sqlite_err)?;
        }
    }
    Ok(())
}
