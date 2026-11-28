//! Storage tests for threads, node deletion, search, the writer, and branch walks.

use super::*;
use tempfile::tempdir;

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn a_parent_from_another_thread_is_refused() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("graph.db"))?;
    let a = storage.create_thread(None, "A", ThreadMode::Chat, None, None)?;
    let b = storage.create_thread(None, "B", ThreadMode::Chat, None, None)?;
    let in_a = storage.append_node(a.id.clone(), None, NodeRole::User, "a".to_owned(), None)?;
    let crossed = storage.append_node(
        b.id.clone(),
        Some(in_a.id.clone()),
        NodeRole::User,
        "b".to_owned(),
        None,
    );
    assert_eq!(
        crossed.err().map(|e| e.key),
        Some(DiagnosticKey::StorageParentThreadMismatch)
    );
    let missing = storage.append_node(
        b.id.clone(),
        Some("no-such-node".to_owned()),
        NodeRole::User,
        "b".to_owned(),
        None,
    );
    assert!(missing.is_err(), "an unknown parent is refused too");
    assert_eq!(storage.list_nodes(&b.id)?, [] as [NodeRecord; 0]);
    assert!(
        storage
            .append_node(
                a.id.clone(),
                Some(in_a.id),
                NodeRole::Assistant,
                "ok".to_owned(),
                None
            )
            .is_ok()
    );
    Ok(())
}

/// Deleting a chat deletes everything derived from it (event log rows, run journal and
/// steps), and the event log never keeps message text in the first place.
#[test]
fn deleting_a_chat_removes_its_event_log_and_run_journal() -> TestResult {
    use crate::harness::CreateAgentRunParams;
    use bistre_protocol::{EngineEvent, UnattendedPolicy};
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("events.db"))?;
    let thread = storage.create_thread(None, "private", ThreadMode::Chat, None, None)?;
    let node = storage.append_node(
        thread.id.clone(),
        None,
        NodeRole::User,
        "my secret plan".to_owned(),
        None,
    )?;
    storage.append_engine_event_log(
        Some(thread.id.clone()),
        &EngineEvent::NodeCommitted { node: node.clone() },
    )?;
    let logged = storage.read_engine_events_after(0, 10)?;
    let text = serde_json::to_string(&logged.iter().map(|r| &r.event).collect::<Vec<_>>())?;
    assert!(
        !text.contains("my secret plan"),
        "the log keeps ids, not text: {text}"
    );
    assert!(text.contains(&node.id), "the node id is kept for replay");

    let run = storage.create_agent_run(CreateAgentRunParams {
        thread_id: thread.id.clone(),
        parent_run_id: None,
        root_node_id: Some(node.id.clone()),
        mode: ThreadMode::Chat,
        max_steps: 4,
        unattended_policy: UnattendedPolicy::default(),
        worktree_path: None,
    })?;
    storage.append_agent_run_partial_text(run.id.clone(), "partial secret".to_owned())?;

    storage.delete_thread(thread.id.clone())?;
    assert_eq!(
        storage.read_engine_events_after(0, 10)?,
        [] as [bistre_protocol::CursorEventRecord; 0]
    );
    assert_eq!(
        storage.list_agent_runs(Some(&thread.id), false, 10)?,
        [] as [bistre_protocol::AgentRunRecord; 0]
    );
    Ok(())
}

/// The one-time cleanup clears the v0.1.2 event log (it held message
/// bodies) and the run journals of chats deleted earlier, and adds the child-by-parent index
/// that a node delete's foreign-key check needs.
#[test]
fn v10_migration_clears_old_event_bodies_and_indexes_parents() -> TestResult {
    let dir = tempdir()?;
    let db = dir.path().join("v9.db");
    {
        let storage = StorageHandle::open(&db)?;
        storage.shutdown()?;
    }
    {
        let conn = Connection::open(&db)?;
        // Legacy rows written before v10 (foreign keys off to plant an orphaned journal).
        conn.execute_batch(
            "PRAGMA foreign_keys = OFF;
             DROP INDEX IF EXISTS idx_nodes_parent;
             INSERT INTO engine_events_log (thread_id, event_json, created_at_ms)
                 VALUES ('t-old', '{\"kind\":\"node_committed\",\"content\":\"old secret\"}', 1);
             INSERT INTO agent_runs (id, thread_id, mode, status, step_index, max_steps,
                 unattended_policy, last_heartbeat_ms, partial_text_buffer,
                 partial_thinking_buffer, cost_micros, created_at_ms, updated_at_ms)
                 VALUES ('r-old', 't-deleted', 'chat', 'cancelled', 0, 4,
                 'deny_tier2_and_continue', 0, 'orphan secret', '', 0, 1, 1);
             PRAGMA user_version = 9;",
        )?;
    }
    let storage = StorageHandle::open(&db)?;
    assert_eq!(
        storage.read_engine_events_after(0, 10)?,
        [] as [bistre_protocol::CursorEventRecord; 0]
    );
    assert_eq!(
        storage.list_agent_runs(Some("t-deleted"), false, 10)?,
        [] as [bistre_protocol::AgentRunRecord; 0]
    );
    let conn = storage.open_reader()?;
    let plan: String = conn.query_row(
        "EXPLAIN QUERY PLAN SELECT id FROM nodes WHERE parent_id = 'x'",
        [],
        |row| row.get(3),
    )?;
    assert!(plan.contains("idx_nodes_parent"), "{plan}");
    Ok(())
}

/// Deleting a 25,000-message chat completes and removes every node.
#[test]
fn deleting_a_25k_message_chat_removes_every_node() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("big.db"))?;
    let thread = storage.create_thread(None, "long", ThreadMode::Chat, None, None)?;
    let mut parent: Option<String> = None;
    for i in 0..25_000 {
        let role = if i % 2 == 0 {
            NodeRole::User
        } else {
            NodeRole::Assistant
        };
        let node = storage.append_node(thread.id.clone(), parent, role, format!("m{i}"), None)?;
        parent = Some(node.id);
    }
    storage.delete_thread(thread.id.clone())?;
    assert_eq!(storage.list_nodes(&thread.id)?, [] as [NodeRecord; 0]);
    Ok(())
}

/// Deleting a chat deletes what was kept for it alone (keys ending in `:<chat id>`: its
/// checklist, reply prefill, last-viewed mark); other chats' keys and global keys stay.
#[test]
fn deleting_a_chat_deletes_its_own_saved_values() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("kv.db"))?;
    let gone = storage.create_thread(None, "gone", ThreadMode::Chat, None, None)?;
    let kept = storage.create_thread(None, "kept", ThreadMode::Chat, None, None)?;
    for chat in [&gone.id, &kept.id] {
        storage.set_kv_meta(format!("thread_todos:{chat}"), "[]".to_owned())?;
        storage.set_kv_meta(format!("thread_reply_prefill:{chat}"), "hi".to_owned())?;
        storage.set_kv_meta(format!("thread.last_viewed_rev:{chat}"), "3".to_owned())?;
    }
    storage.set_kv_meta("agent.web_search".to_owned(), "off".to_owned())?;
    storage.delete_thread(gone.id.clone())?;
    for prefix in [
        "thread_todos",
        "thread_reply_prefill",
        "thread.last_viewed_rev",
    ] {
        assert_eq!(storage.get_kv_meta(&format!("{prefix}:{}", gone.id))?, None);
        assert!(
            storage
                .get_kv_meta(&format!("{prefix}:{}", kept.id))?
                .is_some()
        );
    }
    assert!(storage.get_kv_meta("agent.web_search")?.is_some());
    Ok(())
}

/// A compaction summary can be rewritten in place; its kept-message link and its place in the
/// chat stay, search finds the new words, and no other kind of message can be rewritten.
#[test]
fn only_a_compaction_summary_can_be_rewritten() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("sum.db"))?;
    let thread = storage.create_thread(None, "t", ThreadMode::Chat, None, None)?;
    let user = storage.append_node(
        thread.id.clone(),
        None,
        NodeRole::User,
        "hello".to_owned(),
        None,
    )?;
    let meta = r#"{"compaction":true,"first_kept_node_id":"x"}"#.to_owned();
    let summary = storage.append_node(
        thread.id.clone(),
        Some(user.id.clone()),
        NodeRole::CompactionSummary,
        "old recap".to_owned(),
        Some(meta.clone()),
    )?;
    let edited =
        storage.rewrite_compaction_summary(&thread.id, &summary.id, "kept the parser decision")?;
    assert_eq!(edited.content, "kept the parser decision");
    assert_eq!(edited.provider_meta_json, Some(meta));
    assert_eq!(edited.parent_id, Some(user.id.clone()));
    assert_eq!(storage.list_nodes(&thread.id)?.last(), Some(&edited));
    assert_eq!(
        storage.search_nodes("parser", Some(&thread.id), 10)?.len(),
        1
    );

    let refused = storage
        .rewrite_compaction_summary(&thread.id, &user.id, "changed")
        .err();
    assert_eq!(
        refused.and_then(|e| e.detail_code).as_deref(),
        Some("not_a_compaction_node")
    );
    let other = storage.create_thread(None, "o", ThreadMode::Chat, None, None)?;
    assert!(
        storage
            .rewrite_compaction_summary(&other.id, &summary.id, "x")
            .is_err()
    );
    assert_eq!(storage.list_nodes(&thread.id)?[0].content, "hello");
    Ok(())
}

/// A corrupt full-text index must never block saving messages. Writes
/// drop the search triggers and mark the index stale in the same transaction, then succeed;
/// search keeps working through a plain scan until the index is rebuilt.
#[test]
fn a_corrupt_search_index_never_blocks_writes_and_search_falls_back() -> TestResult {
    let dir = tempdir()?;
    let db = dir.path().join("fts.db");
    let storage = StorageHandle::open(&db)?;
    let thread = storage.create_thread(None, "t", ThreadMode::Chat, None, None)?;
    let first = storage.append_node(
        thread.id.clone(),
        None,
        NodeRole::User,
        "the quick brown fox".to_owned(),
        None,
    )?;
    {
        let conn = Connection::open(&db)?;
        // A missing structure record makes every FTS5 write fail with SQLITE_CORRUPT_VTAB.
        conn.execute("DELETE FROM nodes_fts_data WHERE id = 1", [])?;
    }
    let second = storage.append_node(
        thread.id.clone(),
        Some(first.id.clone()),
        NodeRole::Assistant,
        "jumps over the lazy dog".to_owned(),
        None,
    );
    assert!(second.is_ok(), "writes survive a corrupt index: {second:?}");
    assert_eq!(
        storage.get_kv_meta("search.fts_stale")?.as_deref(),
        Some("1")
    );
    let hits = storage.search_nodes("lazy dog", Some(&thread.id), 10)?;
    assert_eq!(hits.len(), 1, "stale index: search falls back to a scan");
    storage.delete_node(thread.id.clone(), first.id)?;
    assert_eq!(storage.list_nodes(&thread.id)?.len(), 1);
    Ok(())
}

/// CJK text and mid-word substrings are found (trigram index; queries shorter than three
/// characters use a bounded scan), and Latin words keep the word index with ranking.
#[test]
fn search_finds_cjk_and_substrings() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("tri.db"))?;
    let thread = storage.create_thread(None, "t", ThreadMode::Chat, None, None)?;
    let mut parent = None;
    for text in [
        "我爱北京天安门",
        "the quick brownfox jumps",
        "Xin chào thế giới",
    ] {
        let node = storage.append_node(
            thread.id.clone(),
            parent,
            NodeRole::User,
            text.to_owned(),
            None,
        )?;
        parent = Some(node.id);
    }
    let found = |q: &str| -> Result<usize, Box<dyn std::error::Error>> {
        Ok(storage.search_nodes(q, Some(&thread.id), 10)?.len())
    };
    assert_eq!(found("北京天")?, 1, "CJK via trigram");
    assert_eq!(found("北京")?, 1, "two CJK characters via scan");
    assert_eq!(found("brownfo")?, 1, "mid-word substring via trigram");
    assert_eq!(found("thế giới")?, 1, "Vietnamese words");
    assert_eq!(found("quick")?, 1, "Latin word via the word index");
    Ok(())
}

/// A stale search index is rebuilt once at the next open (never live, during writes),
/// restoring indexed search and both sets of triggers.
#[test]
fn a_stale_search_index_is_rebuilt_at_the_next_open() -> TestResult {
    let dir = tempdir()?;
    let db = dir.path().join("rebuild.db");
    let thread_id = {
        let storage = StorageHandle::open(&db)?;
        let thread = storage.create_thread(None, "t", ThreadMode::Chat, None, None)?;
        let first = storage.append_node(
            thread.id.clone(),
            None,
            NodeRole::User,
            "alpha beta".to_owned(),
            None,
        )?;
        {
            let conn = Connection::open(&db)?;
            conn.execute("DELETE FROM nodes_fts_data WHERE id = 1", [])?;
        }
        storage.append_node(
            thread.id.clone(),
            Some(first.id),
            NodeRole::Assistant,
            "gamma delta".to_owned(),
            None,
        )?;
        assert_eq!(
            storage.get_kv_meta("search.fts_stale")?.as_deref(),
            Some("1")
        );
        storage.shutdown()?;
        thread.id
    };
    let storage = StorageHandle::open(&db)?;
    assert_eq!(storage.get_kv_meta("search.fts_stale")?, None);
    let conn = storage.open_reader()?;
    let indexed: i64 = conn.query_row(
        "SELECT COUNT(*) FROM nodes_fts WHERE nodes_fts MATCH 'gamma'",
        [],
        |row| row.get(0),
    )?;
    assert_eq!(
        indexed, 1,
        "the word index holds the row written while stale"
    );
    let triggers: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'nodes_%'",
        [],
        |row| row.get(0),
    )?;
    assert_eq!(triggers, 6, "word and trigram triggers are back");
    assert_eq!(
        storage.search_nodes("gamma", Some(&thread_id), 10)?.len(),
        1
    );
    Ok(())
}

/// opencode #59189: after a disk I/O error (for example once the machine wakes from sleep) the
/// writer reopens its connection, so the next write works instead of failing forever.
#[test]
fn the_writer_reopens_its_connection_after_an_io_error() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("io.db"))?;
    // Simulate a dead handle: swap in a connection to nowhere and fail with an I/O error.
    let failed: BistreResult<()> = storage.write(|conn| {
        *conn = Connection::open_in_memory().map_err(map_sqlite_err)?;
        Err(BistreError::new(DiagnosticKey::StorageIoError))
    });
    assert_eq!(
        failed.err().map(|e| e.key),
        Some(DiagnosticKey::StorageIoError)
    );
    let thread = storage.create_thread(None, "after wake", ThreadMode::Chat, None, None);
    assert!(
        thread.is_ok(),
        "the next write reaches the database: {thread:?}"
    );
    Ok(())
}

/// A backup never occupies the single writer, so runs keep saving while it copies. Here
/// the writer is held busy; the backup must still finish.
#[test]
fn a_backup_does_not_wait_for_the_writer() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("live.db"))?;
    storage.create_thread(None, "t", ThreadMode::Chat, None, None)?;
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let (held_tx, held_rx) = mpsc::channel::<()>();
    let busy = Arc::clone(&storage);
    let holder = thread::spawn(move || {
        busy.write(move |_| {
            held_tx
                .send(())
                .map_err(|_| BistreError::new(DiagnosticKey::InternalError))?;
            release_rx
                .recv_timeout(std::time::Duration::from_secs(10))
                .map_err(|_| BistreError::new(DiagnosticKey::InternalError))
        })
    });
    held_rx.recv_timeout(std::time::Duration::from_secs(5))?;
    let (done_tx, done_rx) = mpsc::channel();
    let snap = Arc::clone(&storage);
    let dest = dir.path().join("backup.db");
    let backup = thread::spawn(move || done_tx.send(snap.backup_database(&dest)));
    let outcome = done_rx.recv_timeout(std::time::Duration::from_secs(5));
    release_tx.send(())?;
    holder.join().map_err(|_| "holder panicked")??;
    backup.join().map_err(|_| "backup panicked")??;
    assert!(
        matches!(outcome, Ok(Ok(()))),
        "the backup finished while the writer was busy: {outcome:?}"
    );
    Ok(())
}

/// The branch walk returns exactly the leaf's ancestry, root first, skipping siblings.
#[test]
fn the_branch_walk_returns_only_the_leafs_ancestry() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("b.sqlite"))?;
    let thread = storage.create_thread(None, "t", ThreadMode::Chat, None, None)?;
    let root = storage.append_node(
        thread.id.clone(),
        None,
        NodeRole::User,
        "root".to_owned(),
        None,
    )?;
    let a = storage.append_node(
        thread.id.clone(),
        Some(root.id.clone()),
        NodeRole::Assistant,
        "a".to_owned(),
        None,
    )?;
    let sibling = storage.append_node(
        thread.id.clone(),
        Some(root.id.clone()),
        NodeRole::Assistant,
        "other".to_owned(),
        None,
    )?;
    let leaf = storage.append_node(
        thread.id.clone(),
        Some(a.id.clone()),
        NodeRole::User,
        "leaf".to_owned(),
        None,
    )?;
    let branch = storage.list_branch(&thread.id, &leaf.id)?;
    let ids: Vec<&str> = branch.iter().map(|n| n.id.as_str()).collect();
    assert_eq!(ids, vec![root.id.as_str(), a.id.as_str(), leaf.id.as_str()]);
    assert!(!ids.contains(&sibling.id.as_str()));
    assert_eq!(storage.list_branch(&thread.id, "missing")?.len(), 0);
    Ok(())
}

#[test]
fn list_nodes_window_paginates_chronologically_and_tracks_history_rev() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("window.sqlite"))?;
    let thread = storage.create_thread(None, "win", ThreadMode::Chat, None, None)?;
    assert_eq!(storage.thread_history_rev(&thread.id)?, 0);

    let mut parent = None;
    let mut ids = Vec::new();
    for i in 0..6 {
        let n = storage.append_node(
            thread.id.clone(),
            parent.clone(),
            if i % 2 == 0 {
                NodeRole::User
            } else {
                NodeRole::Assistant
            },
            format!("msg-{i}"),
            None,
        )?;
        parent = Some(n.id.clone());
        ids.push(n.id);
    }
    let rev = storage.thread_history_rev(&thread.id)?;
    assert!(rev >= 6);

    let contents =
        |page: &[NodeRecord]| -> Vec<String> { page.iter().map(|n| n.content.clone()).collect() };
    let newest_three = storage.list_nodes_window(&thread.id, None, 3)?;
    assert_eq!(contents(&newest_three), ["msg-3", "msg-4", "msg-5"]);
    // The next page starts before the oldest node shown, even when timestamps tie.
    let anchor = newest_three
        .first()
        .map(|n| n.id.clone())
        .ok_or("empty page")?;
    let older = storage.list_nodes_window(&thread.id, Some(&anchor), 3)?;
    assert_eq!(contents(&older), ["msg-0", "msg-1", "msg-2"]);
    let anchor = older.first().map(|n| n.id.clone()).ok_or("empty page")?;
    assert_eq!(
        storage.list_nodes_window(&thread.id, Some(&anchor), 3)?,
        Vec::new()
    );
    let other = storage.create_thread(None, "other", ThreadMode::Chat, None, None)?;
    assert_eq!(
        storage
            .list_nodes_window(&other.id, Some(&anchor), 3)
            .err()
            .map(|e| e.key),
        Some(DiagnosticKey::StorageNotFound)
    );
    Ok(())
}

#[test]
fn a_branch_copies_into_a_new_chat_and_a_turn_deletes_with_what_follows() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("graph.db"))?;
    let chat = storage.create_thread(None, "Trip", ThreadMode::Chat, None, None)?;
    let tid = chat.id.clone();
    let q1 = storage.append_node(tid.clone(), None, NodeRole::User, "q1".to_owned(), None)?;
    let a1 = storage.append_node(
        tid.clone(),
        Some(q1.id.clone()),
        NodeRole::Assistant,
        "a1".to_owned(),
        Some(format!(r#"{{"answers":"{}"}}"#, q1.id)),
    )?;
    storage.append_node(
        tid.clone(),
        Some(a1.id.clone()),
        NodeRole::User,
        "q2b".to_owned(),
        None,
    )?;
    let q2 = storage.append_node(
        tid.clone(),
        Some(a1.id.clone()),
        NodeRole::User,
        "q2".to_owned(),
        None,
    )?;
    // The last message written is the chat's active head.
    storage.append_node(
        tid.clone(),
        Some(q2.id.clone()),
        NodeRole::Assistant,
        "a2".to_owned(),
        None,
    )?;
    storage.save_attachment(
        tid.clone(),
        Some(q1.id.clone()),
        "file".to_owned(),
        "map.txt".to_owned(),
        "text/plain".to_owned(),
        3,
        "abc".to_owned(),
        "files/map.txt".to_owned(),
        String::new(),
    )?;

    // Branch at the first reply: two messages with new ids, the reference remapped, and the
    // carried per-chat values copied with the same rewrite (others stay behind).
    storage.set_kv_meta(format!("carry:{tid}"), format!("[\"{}\"]", a1.id))?;
    storage.set_kv_meta(format!("stay:{tid}"), "x".to_owned())?;
    let fork = storage.fork_thread(&tid, &a1.id, &["carry:"])?;
    assert_eq!(fork.title, "Trip");
    let copied = storage.list_nodes(&fork.id)?;
    let contents: Vec<&str> = copied.iter().map(|n| n.content.as_str()).collect();
    assert_eq!(contents, vec!["q1", "a1"]);
    assert!(copied.iter().all(|n| n.id != q1.id && n.id != a1.id));
    assert_eq!(
        fork.active_head_node_id.as_deref(),
        Some(copied[1].id.as_str())
    );
    assert_eq!(copied[1].parent_id.as_deref(), Some(copied[0].id.as_str()));
    let meta = copied[1].provider_meta_json.clone().unwrap_or_default();
    assert!(
        meta.contains(&copied[0].id) && !meta.contains(&q1.id),
        "{meta}"
    );
    let files = storage.list_attachments(&fork.id)?;
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].node_id.as_deref(), Some(copied[0].id.as_str()));
    assert_eq!(
        storage.get_kv_meta(&format!("carry:{}", fork.id))?,
        Some(format!("[\"{}\"]", copied[1].id))
    );
    assert_eq!(storage.get_kv_meta(&format!("stay:{}", fork.id))?, None);
    assert!(storage.fork_thread(&tid, "no-such-node", &[]).is_err());

    // Removing the second question removes its reply too; the other branch stays.
    storage.delete_from_node(tid.clone(), q2.id.clone())?;
    let left: Vec<String> = storage
        .list_nodes(&tid)?
        .into_iter()
        .map(|n| n.content)
        .collect();
    assert_eq!(left, vec!["q1", "a1", "q2b"]);
    let head = storage
        .get_thread(&tid)?
        .and_then(|t| t.active_head_node_id);
    assert_eq!(head.as_deref(), Some(a1.id.as_str()));
    assert!(
        storage
            .delete_from_node(tid.clone(), q2.id.clone())
            .is_err()
    );

    // Clearing keeps the chat and its title, with no messages or message files left.
    storage.clear_thread_messages(tid.clone())?;
    assert_eq!(storage.list_nodes(&tid)?.len(), 0);
    assert_eq!(storage.list_attachments(&tid)?.len(), 0);
    let kept = storage.get_thread(&tid)?;
    assert_eq!(
        kept.map(|t| (t.title, t.active_head_node_id)),
        Some(("Trip".to_owned(), None))
    );
    assert_eq!(storage.list_nodes(&fork.id)?.len(), 2);
    Ok(())
}

/// A summary opens a new chat with the source's title and settings, its one message the
/// summary; a blank summary or an unknown chat is refused.
#[test]
fn a_summary_opens_a_new_chat_with_the_source_settings() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("resume.sqlite"))?;
    let source = storage.create_thread(None, "Plan", ThreadMode::Code, None, None)?;
    let resumed =
        storage.resume_from_summary(&source.id, " Decisions so far ", "{\"compaction\":true}")?;
    assert_ne!(resumed.id, source.id);
    assert_eq!(
        (resumed.title.as_str(), resumed.mode),
        ("Plan", ThreadMode::Code)
    );
    let nodes = storage.list_nodes(&resumed.id)?;
    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0].role, NodeRole::CompactionSummary);
    assert_eq!(nodes[0].content, "Decisions so far");
    assert_eq!(
        resumed.active_head_node_id.as_deref(),
        Some(nodes[0].id.as_str())
    );
    assert!(storage.resume_from_summary(&source.id, "  ", "{}").is_err());
    assert!(
        storage
            .resume_from_summary("missing", "text", "{}")
            .is_err()
    );
    Ok(())
}
