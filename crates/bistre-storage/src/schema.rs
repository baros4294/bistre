//! Connection configuration, Expand-Contract migrations, seeding, and schema DDL.

use super::{
    BistreError, BistreResult, CheckpointStats, Connection, DEFAULT_ASSISTANT_ID,
    DEFAULT_WORKSPACE_ID, DEFAULT_WORKSPACE_NAME, DiagnosticKey, KV_PROVIDERS_SEEDED_KEY,
    OpenFlags, OptionalExtension, Path, PathBuf, ProviderDialect, harness, map_sqlite_err,
    now_unix_ms, params, story,
};

pub(crate) fn open_writer_connection(db_path: &Path) -> BistreResult<Connection> {
    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
        | OpenFlags::SQLITE_OPEN_CREATE
        | OpenFlags::SQLITE_OPEN_NO_MUTEX
        | OpenFlags::SQLITE_OPEN_URI;
    Connection::open_with_flags(db_path, flags).map_err(map_sqlite_err)
}

pub(crate) fn configure_connection(conn: &Connection, is_writer: bool) -> BistreResult<()> {
    conn.pragma_update(None, "busy_timeout", 5000_i64)
        .map_err(map_sqlite_err)?;
    conn.pragma_update(None, "foreign_keys", "ON")
        .map_err(map_sqlite_err)?;
    conn.pragma_update(None, "temp_store", "MEMORY")
        .map_err(map_sqlite_err)?;
    if is_writer {
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(map_sqlite_err)?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(map_sqlite_err)?;
        // Bounded WAL (Spec 11 §3): truncate to 8 MiB after checkpoints, checkpoint every 1000 pages.
        conn.pragma_update(None, "journal_size_limit", 8_388_608_i64)
            .map_err(map_sqlite_err)?;
        conn.pragma_update(None, "wal_autocheckpoint", 1000_i64)
            .map_err(map_sqlite_err)?;
    }
    Ok(())
}

pub(crate) fn run_migrations(conn: &mut Connection, db_path: &Path) -> BistreResult<()> {
    let version: u32 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(map_sqlite_err)?;

    if version < 1 {
        apply_sql_migration(conn, SCHEMA_V1_SQL, 1, "v0_to_v1")?;
        verify_db_integrity(conn)?;
    }

    if version < 2 {
        if version == 1 {
            backup_before_migration(conn, db_path, 1)?;
        }
        apply_v2_expand_migration(conn)?;
        verify_db_integrity(conn)?;
    }

    if version < 3 {
        if version == 2 {
            backup_before_migration(conn, db_path, 2)?;
        }
        apply_sql_migration(conn, SCHEMA_V3_EXPAND_SQL, 3, "v2_to_v3")?;
        verify_db_integrity(conn)?;
    }

    if version < 4 {
        if version == 3 {
            backup_before_migration(conn, db_path, 3)?;
        }
        apply_sql_migration(conn, SCHEMA_V4_CLEANUP_SQL, 4, "v3_to_v4")?;
        verify_db_integrity(conn)?;
    }

    if version < 5 {
        if version == 4 {
            backup_before_migration(conn, db_path, 4)?;
        }
        apply_v5_expand_migration(conn)?;
        verify_db_integrity(conn)?;
    }

    if version < 6 {
        if version == 5 {
            backup_before_migration(conn, db_path, 5)?;
        }
        apply_sql_migration(conn, harness::SCHEMA_V6_EXPAND_SQL, 6, "v5_to_v6")?;
        verify_db_integrity(conn)?;
    }

    if version < 7 {
        if version == 6 {
            backup_before_migration(conn, db_path, 6)?;
        }
        apply_sql_migration(conn, story::SCHEMA_V7_EXPAND_SQL, 7, "v6_to_v7")?;
        verify_db_integrity(conn)?;
    }

    if version < 8 {
        if version == 7 {
            backup_before_migration(conn, db_path, 7)?;
        }
        apply_sql_migration(conn, harness::SCHEMA_V8_EXPAND_SQL, 8, "v7_to_v8")?;
        verify_db_integrity(conn)?;
    }

    Ok(())
}

pub(crate) fn apply_sql_migration(
    conn: &mut Connection,
    sql: &str,
    target_version: u32,
    code: &str,
) -> BistreResult<()> {
    let tx = conn
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(map_sqlite_err)?;
    tx.execute_batch(sql).map_err(|err| {
        tracing::error!(error = %err, migration = code, "sqlite migration failed");
        BistreError::with_detail(DiagnosticKey::StorageMigrationFailed, code)
    })?;
    tx.pragma_update(None, "user_version", target_version)
        .map_err(map_sqlite_err)?;
    tx.commit().map_err(map_sqlite_err)
}

pub(crate) fn apply_v2_expand_migration(conn: &mut Connection) -> BistreResult<()> {
    let has_is_pinned = table_has_column(conn, "threads", "is_pinned")?;
    let has_topic = table_has_column(conn, "threads", "topic")?;
    let has_assistant = table_has_column(conn, "threads", "assistant_id")?;

    let tx = conn
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(map_sqlite_err)?;
    if !has_is_pinned {
        tx.execute(
            "ALTER TABLE threads ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0",
            [],
        )
        .map_err(map_sqlite_err)?;
    }
    if !has_topic {
        tx.execute(
            "ALTER TABLE threads ADD COLUMN topic TEXT NOT NULL DEFAULT 'general'",
            [],
        )
        .map_err(map_sqlite_err)?;
    }
    if !has_assistant {
        tx.execute(
            "ALTER TABLE threads ADD COLUMN assistant_id TEXT NOT NULL DEFAULT 'bistre_archivist'",
            [],
        )
        .map_err(map_sqlite_err)?;
    }
    tx.execute_batch(SCHEMA_V2_EXPAND_SQL).map_err(|err| {
        tracing::error!(error = %err, "sqlite migration v1_to_v2 failed");
        BistreError::with_detail(DiagnosticKey::StorageMigrationFailed, "v1_to_v2")
    })?;
    tx.pragma_update(None, "user_version", 2_u32)
        .map_err(map_sqlite_err)?;
    tx.commit().map_err(map_sqlite_err)
}

pub(crate) fn add_column_if_missing(
    conn: &Connection,
    table: &str,
    column: &str,
    alter_sql: &str,
) -> BistreResult<()> {
    if !table_has_column(conn, table, column)? {
        conn.execute(alter_sql, []).map_err(map_sqlite_err)?;
    }
    Ok(())
}

pub(crate) fn apply_v5_expand_migration(conn: &mut Connection) -> BistreResult<()> {
    let alters: [(&str, &str, &str); 16] = [
        (
            "providers",
            "icon_slug",
            "ALTER TABLE providers ADD COLUMN icon_slug TEXT NOT NULL DEFAULT ''",
        ),
        (
            "providers",
            "custom_icon_path",
            "ALTER TABLE providers ADD COLUMN custom_icon_path TEXT NOT NULL DEFAULT ''",
        ),
        (
            "assistants",
            "icon_slug",
            "ALTER TABLE assistants ADD COLUMN icon_slug TEXT NOT NULL DEFAULT ''",
        ),
        (
            "assistants",
            "default_provider_id",
            "ALTER TABLE assistants ADD COLUMN default_provider_id TEXT NOT NULL DEFAULT ''",
        ),
        (
            "assistants",
            "default_model_id",
            "ALTER TABLE assistants ADD COLUMN default_model_id TEXT NOT NULL DEFAULT ''",
        ),
        (
            "assistants",
            "temperature_milli",
            "ALTER TABLE assistants ADD COLUMN temperature_milli INTEGER",
        ),
        (
            "assistants",
            "max_output_tokens",
            "ALTER TABLE assistants ADD COLUMN max_output_tokens INTEGER",
        ),
        (
            "assistants",
            "top_p_milli",
            "ALTER TABLE assistants ADD COLUMN top_p_milli INTEGER",
        ),
        (
            "threads",
            "provider_id_override",
            "ALTER TABLE threads ADD COLUMN provider_id_override TEXT",
        ),
        (
            "threads",
            "model_id_override",
            "ALTER TABLE threads ADD COLUMN model_id_override TEXT",
        ),
        (
            "threads",
            "system_prompt_override",
            "ALTER TABLE threads ADD COLUMN system_prompt_override TEXT",
        ),
        (
            "threads",
            "temperature_milli",
            "ALTER TABLE threads ADD COLUMN temperature_milli INTEGER",
        ),
        (
            "threads",
            "max_output_tokens",
            "ALTER TABLE threads ADD COLUMN max_output_tokens INTEGER",
        ),
        (
            "threads",
            "top_p_milli",
            "ALTER TABLE threads ADD COLUMN top_p_milli INTEGER",
        ),
        (
            "wallet_ledger",
            "input_tokens",
            "ALTER TABLE wallet_ledger ADD COLUMN input_tokens INTEGER NOT NULL DEFAULT 0",
        ),
        (
            "wallet_ledger",
            "output_tokens",
            "ALTER TABLE wallet_ledger ADD COLUMN output_tokens INTEGER NOT NULL DEFAULT 0",
        ),
    ];

    let tx = conn
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(map_sqlite_err)?;
    for (table, column, sql) in alters {
        add_column_if_missing(&tx, table, column, sql)?;
    }
    tx.execute_batch(
        "UPDATE providers SET icon_slug = 'openai' WHERE dialect = 'openai' AND icon_slug = '';
         UPDATE providers SET icon_slug = 'gemini' WHERE dialect = 'google_gemini' AND icon_slug = '';
         UPDATE providers SET icon_slug = 'anthropic' WHERE dialect = 'anthropic' AND icon_slug = '';",
    )
    .map_err(map_sqlite_err)?;
    tx.pragma_update(None, "user_version", 5_u32)
        .map_err(map_sqlite_err)?;
    tx.commit().map_err(map_sqlite_err)
}

pub(crate) fn table_has_column(conn: &Connection, table: &str, column: &str) -> BistreResult<bool> {
    let sql = format!("PRAGMA table_info({table})");
    let mut stmt = conn.prepare(&sql).map_err(map_sqlite_err)?;
    let cols = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(map_sqlite_err)?;
    for col in cols {
        if col.map_err(map_sqlite_err)? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(crate) fn verify_db_integrity(conn: &Connection) -> BistreResult<()> {
    let fk_violations: i64 = conn
        .query_row("SELECT COUNT(*) FROM pragma_foreign_key_check", [], |r| {
            r.get(0)
        })
        .map_err(map_sqlite_err)?;
    if fk_violations != 0 {
        return Err(BistreError::with_detail(
            DiagnosticKey::StorageMigrationFailed,
            "foreign_key_check",
        ));
    }
    let quick_check: String = conn
        .pragma_query_value(None, "quick_check", |r| r.get(0))
        .map_err(map_sqlite_err)?;
    if !quick_check.eq_ignore_ascii_case("ok") {
        return Err(BistreError::with_detail(
            DiagnosticKey::StorageMigrationFailed,
            "quick_check",
        ));
    }
    Ok(())
}

pub(crate) fn ensure_default_workspace(conn: &Connection) -> BistreResult<()> {
    let now = now_unix_ms();
    conn.execute(
        "INSERT OR IGNORE INTO workspaces (id, name, root_path, created_at_ms)
         VALUES (?1, ?2, NULL, ?3)",
        params![DEFAULT_WORKSPACE_ID, DEFAULT_WORKSPACE_NAME, now],
    )
    .map_err(map_sqlite_err)?;
    Ok(())
}

/// Seeds a single neutral Default assistant strictly when a fresh install has zero assistants.
pub(crate) fn ensure_default_assistant_if_empty(conn: &Connection) -> BistreResult<()> {
    let existing_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM assistants", [], |r| r.get(0))
        .map_err(map_sqlite_err)?;
    if existing_count > 0 {
        return Ok(());
    }
    let now = now_unix_ms();
    conn.execute(
        "INSERT INTO assistants (id, name, role_subtitle, system_prompt, default_mode, badge_code, is_builtin, created_at_ms)
         VALUES (?1, 'Default', '', '', 'chat', 'DF', 1, ?2)",
        params![DEFAULT_ASSISTANT_ID, now],
    )
    .map_err(map_sqlite_err)?;
    Ok(())
}

/// Seeds initial Big 3 starter templates strictly once on a brand-new database.
/// Once seeded, users may freely delete any provider and it will never be forced back on restart.
pub(crate) fn seed_builtin_providers_once(conn: &Connection) -> BistreResult<()> {
    const STARTER_PROVIDERS: [(&str, &str, ProviderDialect); 3] = [
        ("openai", "OpenAI", ProviderDialect::OpenAi),
        (
            "google_gemini",
            "Google Gemini",
            ProviderDialect::GoogleGemini,
        ),
        ("anthropic", "Anthropic", ProviderDialect::Anthropic),
    ];

    let already_seeded: Option<String> = conn
        .query_row(
            "SELECT value FROM kv_meta WHERE key = ?1",
            [KV_PROVIDERS_SEEDED_KEY],
            |r| r.get(0),
        )
        .optional()
        .map_err(map_sqlite_err)?;
    if already_seeded.is_some() {
        return Ok(());
    }

    for (idx, (id, name, dialect)) in STARTER_PROVIDERS.iter().enumerate() {
        let ts = i64::try_from(idx).unwrap_or(0) + 1;
        conn.execute(
            "INSERT OR IGNORE INTO providers (id, name, dialect, base_url, default_model, key_hint,
                                              is_enabled, is_builtin, use_server_state_cache,
                                              icon_slug, custom_icon_path, created_at_ms, updated_at_ms)
             VALUES (?1, ?2, ?3, ?4, '', '', 1, 1, 0, ?5, '', ?6, ?6)",
            params![
                id,
                name,
                dialect.as_str(),
                dialect.default_base_url(),
                dialect.default_icon_slug(),
                ts
            ],
        )
        .map_err(map_sqlite_err)?;
    }
    conn.execute(
        "INSERT OR REPLACE INTO kv_meta (key, value) VALUES (?1, '1')",
        [KV_PROVIDERS_SEEDED_KEY],
    )
    .map_err(map_sqlite_err)?;
    Ok(())
}

pub(crate) fn run_reclaim_storage(conn: &Connection) -> BistreResult<CheckpointStats> {
    let stats = run_checkpoint_truncate(conn)?;
    conn.execute_batch("PRAGMA optimize;")
        .map_err(map_sqlite_err)?;
    Ok(stats)
}

/// Before migrating an existing file from `from`, checkpoints the WAL and keeps a one-time
/// `.pre-v{from+1}.bak` copy. Without a backup the migration does not run.
fn backup_before_migration(conn: &Connection, db_path: &Path, from: u32) -> BistreResult<()> {
    if !db_path.exists() {
        return Ok(());
    }
    run_checkpoint_truncate(conn)?;
    let backup_path = PathBuf::from(format!("{}.pre-v{}.bak", db_path.display(), from + 1));
    if !backup_path.exists() {
        std::fs::copy(db_path, &backup_path).map_err(|_| {
            BistreError::with_detail(
                DiagnosticKey::StorageMigrationFailed,
                format!("backup_v{from}"),
            )
        })?;
    }
    Ok(())
}

pub(crate) fn run_checkpoint_truncate(conn: &Connection) -> BistreResult<CheckpointStats> {
    conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
        Ok(CheckpointStats {
            busy: row.get(0)?,
            log_frames: row.get(1)?,
            checkpointed_frames: row.get(2)?,
        })
    })
    .map_err(map_sqlite_err)
}

pub(crate) const SCHEMA_V1_SQL: &str = r"
CREATE TABLE IF NOT EXISTS workspaces (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    root_path TEXT,
    created_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS threads (
    id TEXT PRIMARY KEY,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    mode TEXT NOT NULL,
    active_head_node_id TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_threads_workspace_updated
    ON threads (workspace_id, updated_at_ms DESC);

CREATE TABLE IF NOT EXISTS nodes (
    rowid INTEGER PRIMARY KEY,
    id TEXT UNIQUE NOT NULL,
    thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
    parent_id TEXT REFERENCES nodes(id),
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    provider_meta_json TEXT,
    created_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_nodes_thread_parent
    ON nodes (thread_id, parent_id);

CREATE TABLE IF NOT EXISTS drafts (
    thread_id TEXT PRIMARY KEY REFERENCES threads(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    updated_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS wallet_ledger (
    id TEXT PRIMARY KEY,
    thread_id TEXT,
    job_id TEXT,
    provider_id TEXT NOT NULL,
    model_id TEXT NOT NULL,
    cost_micros INTEGER NOT NULL,
    status TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_wallet_ledger_created
    ON wallet_ledger (created_at_ms DESC);

CREATE TABLE IF NOT EXISTS ota_state (
    slot TEXT PRIMARY KEY,
    active_version TEXT NOT NULL,
    last_healthy_version TEXT,
    boot_attempts INTEGER NOT NULL DEFAULT 0,
    updated_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS kv_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
    content,
    content='nodes',
    content_rowid='rowid',
    tokenize='unicode61'
);

CREATE TRIGGER IF NOT EXISTS nodes_ai AFTER INSERT ON nodes BEGIN
    INSERT INTO nodes_fts(rowid, content) VALUES (new.rowid, new.content);
END;

CREATE TRIGGER IF NOT EXISTS nodes_ad AFTER DELETE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, content) VALUES('delete', old.rowid, old.content);
END;

CREATE TRIGGER IF NOT EXISTS nodes_au AFTER UPDATE OF content ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, content) VALUES('delete', old.rowid, old.content);
    INSERT INTO nodes_fts(rowid, content) VALUES (new.rowid, new.content);
END;
";

pub(crate) const SCHEMA_V2_EXPAND_SQL: &str = r"
CREATE TABLE IF NOT EXISTS assistants (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    role_subtitle TEXT NOT NULL,
    system_prompt TEXT NOT NULL,
    default_mode TEXT NOT NULL,
    badge_code TEXT NOT NULL,
    is_builtin INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_threads_pinned_updated
    ON threads (is_pinned DESC, updated_at_ms DESC);
";

pub(crate) const SCHEMA_V3_EXPAND_SQL: &str = r"
CREATE TABLE IF NOT EXISTS providers (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    dialect TEXT NOT NULL,
    base_url TEXT NOT NULL,
    default_model TEXT NOT NULL DEFAULT '',
    key_hint TEXT NOT NULL DEFAULT '',
    is_enabled INTEGER NOT NULL DEFAULT 1,
    is_builtin INTEGER NOT NULL DEFAULT 0,
    use_server_state_cache INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
);
";

pub(crate) const SCHEMA_V4_CLEANUP_SQL: &str = r"
DELETE FROM assistants
WHERE is_builtin = 1
  AND id IN ('bistre_craftsman', 'bistre_scribe', 'bistre_linguist');

UPDATE assistants
SET id = 'default_assistant',
    name = 'Default',
    role_subtitle = '',
    system_prompt = '',
    default_mode = 'chat',
    badge_code = 'DF'
WHERE id = 'bistre_archivist' AND is_builtin = 1;

UPDATE threads
SET assistant_id = 'default_assistant'
WHERE assistant_id IN ('bistre_archivist', 'bistre_craftsman', 'bistre_scribe', 'bistre_linguist');

UPDATE threads
SET title = 'New chat'
WHERE title = 'First Folio'
  AND NOT EXISTS (SELECT 1 FROM nodes WHERE nodes.thread_id = threads.id);
";
