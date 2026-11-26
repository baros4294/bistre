//! Full-text search over messages (Spec 01 section 8): the ranked word index, the trigram
//! index for CJK and substrings (D6), the bounded scan used while an index is stale or the
//! query is shorter than a trigram, and the one-time rebuild at open after corruption (G3).

use rusqlite::{Connection, OptionalExtension, params};

use bistre_protocol::{BistreResult, DiagnosticKey, NodeRole, SearchHit};

use crate::{StorageHandle, map_sqlite_err, schema};

/// Full-text search within one thread: ?1 FTS query, ?2 thread id, ?3 limit.
pub(crate) const SEARCH_IN_THREAD_SQL: &str = "SELECT n.id, n.thread_id, n.role,
        snippet(nodes_fts, 0, '[', ']', '...', 16),
        n.created_at_ms
 FROM nodes_fts
 JOIN nodes n ON n.rowid = nodes_fts.rowid
 WHERE nodes_fts MATCH ?1 AND n.thread_id = ?2
 ORDER BY bm25(nodes_fts)
 LIMIT ?3";

/// Full-text search across every thread: ?1 FTS query, ?2 limit.
pub(crate) const SEARCH_ALL_SQL: &str = "SELECT n.id, n.thread_id, n.role,
        snippet(nodes_fts, 0, '[', ']', '...', 16),
        n.created_at_ms
 FROM nodes_fts
 JOIN nodes n ON n.rowid = nodes_fts.rowid
 WHERE nodes_fts MATCH ?1
 ORDER BY bm25(nodes_fts)
 LIMIT ?2";

/// D6 trigram search (CJK and mid-word substrings), in one thread: ?1 quoted phrase, ?2 thread, ?3 limit.
const SEARCH_TRI_IN_THREAD_SQL: &str = "SELECT n.id, n.thread_id, n.role,
        snippet(nodes_fts_tri, 0, '[', ']', '...', 16),
        n.created_at_ms
 FROM nodes_fts_tri
 JOIN nodes n ON n.rowid = nodes_fts_tri.rowid
 WHERE nodes_fts_tri MATCH ?1 AND n.thread_id = ?2
 ORDER BY bm25(nodes_fts_tri)
 LIMIT ?3";

/// D6 trigram search across every thread: ?1 quoted phrase, ?2 limit.
const SEARCH_TRI_ALL_SQL: &str = "SELECT n.id, n.thread_id, n.role,
        snippet(nodes_fts_tri, 0, '[', ']', '...', 16),
        n.created_at_ms
 FROM nodes_fts_tri
 JOIN nodes n ON n.rowid = nodes_fts_tri.rowid
 WHERE nodes_fts_tri MATCH ?1
 ORDER BY bm25(nodes_fts_tri)
 LIMIT ?2";

impl StorageHandle {
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
        let stale: Option<String> = conn
            .query_row(
                "SELECT value FROM kv_meta WHERE key = 'search.fts_stale'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(map_sqlite_err)?;
        if stale.as_deref() == Some("1") {
            return search_nodes_by_scan(&conn, trimmed, thread_id, capped_limit);
        }

        // D6: the word index first (ranked); then the trigram index for CJK and mid-word
        // substrings; queries shorter than a trigram use a bounded scan.
        let words = run_fts_search(
            &conn,
            (SEARCH_IN_THREAD_SQL, SEARCH_ALL_SQL),
            &fts_query,
            thread_id,
            capped_limit,
        )?;
        if !words.is_empty() {
            return Ok(words);
        }
        if trimmed.chars().count() < 3 {
            return search_nodes_by_scan(&conn, trimmed, thread_id, capped_limit);
        }
        let phrase = format!("\"{}\"", trimmed.replace('"', "\"\""));
        run_fts_search(
            &conn,
            (SEARCH_TRI_IN_THREAD_SQL, SEARCH_TRI_ALL_SQL),
            &phrase,
            thread_id,
            capped_limit,
        )
    }
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

/// G3 fallback while the FTS index is stale: a bounded `LIKE` scan (`%` and `_` escaped) with a
/// short snippet around the first match.
fn search_nodes_by_scan(
    conn: &Connection,
    query: &str,
    thread_id: Option<&str>,
    limit: i64,
) -> BistreResult<Vec<SearchHit>> {
    let escaped: String = query
        .chars()
        .flat_map(|c| match c {
            '%' | '_' | '\\' => vec!['\\', c],
            other => vec![other],
        })
        .collect();
    let pattern = format!("%{escaped}%");
    let mut stmt = conn
        .prepare(
            "SELECT id, thread_id, role, content, created_at_ms FROM nodes
             WHERE content LIKE ?1 ESCAPE '\\' AND (?2 IS NULL OR thread_id = ?2)
             ORDER BY rowid DESC LIMIT ?3",
        )
        .map_err(map_sqlite_err)?;
    let needle = query.to_lowercase();
    let rows = stmt
        .query_map(params![pattern, thread_id, limit], |row| {
            let role_raw: String = row.get(2)?;
            let content: String = row.get(3)?;
            Ok(SearchHit {
                node_id: row.get(0)?,
                thread_id: row.get(1)?,
                role: NodeRole::parse(&role_raw),
                snippet: scan_snippet(&content, &needle),
                created_at_ms: row.get(4)?,
            })
        })
        .map_err(map_sqlite_err)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
}

/// About 80 characters around the first case-insensitive match, char-boundary safe.
fn scan_snippet(content: &str, needle_lower: &str) -> String {
    let lower = content.to_lowercase();
    let at = lower.find(needle_lower).unwrap_or(0);
    let chars: Vec<char> = content.chars().collect();
    let at_chars = lower[..at.min(lower.len())].chars().count();
    let start = at_chars.saturating_sub(40);
    let end = (at_chars + needle_lower.chars().count() + 40).min(chars.len());
    chars[start.min(end)..end].iter().collect()
}

/// Runs one FTS query (`(in_thread_sql, all_sql)`) and maps rows to hits.
fn run_fts_search(
    conn: &Connection,
    (in_thread_sql, all_sql): (&str, &str),
    query: &str,
    thread_id: Option<&str>,
    limit: i64,
) -> BistreResult<Vec<SearchHit>> {
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
        let mut stmt = conn.prepare(in_thread_sql).map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map(params![query, tid, limit], map_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    } else {
        let mut stmt = conn.prepare(all_sql).map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map(params![query, limit], map_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }
}

/// G3: when the search index was marked stale, rebuild both full-text indexes from `nodes`
/// and restore their triggers, once, at open (before any write; never live). A failed
/// rebuild is logged and search stays on the plain scan; opening never fails for it.
pub(crate) fn rebuild_stale_search_index(conn: &mut Connection) {
    let stale = conn
        .query_row(
            "SELECT value FROM kv_meta WHERE key = 'search.fts_stale'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional();
    match stale {
        Ok(Some(flag)) if flag == "1" => {}
        Ok(_) => return,
        Err(err) => {
            tracing::error!(error = %err, "search index state unreadable; rebuild skipped");
            return;
        }
    }
    let rebuilt = conn.transaction().and_then(|tx| {
        tx.execute_batch(schema::SEARCH_TRIGGERS_SQL)?;
        tx.execute_batch(
            "INSERT INTO nodes_fts(nodes_fts) VALUES('rebuild');
             INSERT INTO nodes_fts_tri(nodes_fts_tri) VALUES('rebuild');
             DELETE FROM kv_meta WHERE key = 'search.fts_stale';",
        )?;
        tx.commit()
    });
    match rebuilt {
        Ok(()) => tracing::info!("search index rebuilt"),
        Err(err) => tracing::error!(
            key = DiagnosticKey::StorageSearchIndexCorrupt.as_key(),
            error = %err,
            "search index rebuild failed; search keeps using a plain scan"
        ),
    }
}
