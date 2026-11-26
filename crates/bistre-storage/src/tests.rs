//! Storage integration tests (split out of `lib.rs`).

use super::*;
use crate::schema::{SCHEMA_V1_SQL, apply_sql_migration};
use crate::search::{SEARCH_ALL_SQL, SEARCH_IN_THREAD_SQL};
use bistre_protocol::TrustPreset;
use tempfile::tempdir;

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn dag_branching_draft_persistence_fts5_index_plan_and_checkpoint() -> TestResult {
    let dir = tempdir()?;
    let db_path = dir.path().join("bistre.sqlite");

    let storage = StorageHandle::open(&db_path)?;

    let health = Some(storage.health()?);
    assert_eq!(
        health.map(|h| (h.schema_version, h.wal_mode_active)),
        Some((CURRENT_SCHEMA_VERSION, true))
    );

    let thread = storage.create_thread(
        None,
        "Vietnamese & Arabic Folio",
        ThreadMode::Code,
        Some("code"),
        Some("bistre_craftsman"),
    )?;

    let root = storage.append_node(
        thread.id.clone(),
        None,
        NodeRole::User,
        "Xin chào thế giới! مرحبا بالعالم — root prompt".to_owned(),
        None,
    )?;

    let mut alpha_head = root.id.clone();
    let mut beta_head = root.id.clone();
    for idx in 0..500_u32 {
        let node = storage.append_node(
            thread.id.clone(),
            Some(alpha_head.clone()),
            NodeRole::Assistant,
            format!("Branch alpha Vietnamese tiếng Việt entry #{idx} sepia note"),
            None,
        )?;
        {
            alpha_head = node.id;
        }

        let node = storage.append_node(
            thread.id.clone(),
            Some(beta_head.clone()),
            NodeRole::Assistant,
            format!("Branch beta Arabic كتابة entry #{idx} candlelight ink"),
            None,
        )?;
        {
            beta_head = node.id;
        }
    }

    let draft_text = "Bản nháp chưa gửi với dấu tiếng Việt و نص عربي";
    assert!(
        storage
            .save_draft(thread.id.clone(), draft_text.to_owned())
            .is_ok()
    );

    let stats = Some(storage.shutdown()?);
    assert_eq!(stats.map(|s| s.busy), Some(0));
    drop(storage);

    let reopened = StorageHandle::open(&db_path)?;

    let restored_draft = reopened.load_draft(&thread.id)?;
    assert_eq!(restored_draft.map(|d| d.text), Some(draft_text.to_owned()));

    let hits = Some(reopened.search_nodes("tiếng Việt #499", Some(&thread.id), 10)?);
    assert!(hits.as_ref().is_some_and(|list| !list.is_empty()));
    // Speed is measured by `just perf`; here we prove the plan uses the FTS index, never a scan.
    let conn = reopened.open_reader()?;
    let plan_of = |sql: &str, args: &[&dyn rusqlite::ToSql]| -> BistreResult<Vec<String>> {
        let mut stmt = conn
            .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
            .map_err(map_sqlite_err)?;
        stmt.query_map(args, |row| row.get::<_, String>(3))
            .map_err(map_sqlite_err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(map_sqlite_err)
    };
    for plan in [
        plan_of(SEARCH_IN_THREAD_SQL, params!["x", thread.id, 10_i64])?,
        plan_of(SEARCH_ALL_SQL, params!["x", 10_i64])?,
    ] {
        assert!(
            plan.iter().any(|step| step.contains("VIRTUAL TABLE INDEX")),
            "search must use the FTS index: {plan:?}"
        );
        assert!(
            !plan
                .iter()
                .any(|step| step == "SCAN n" || step.starts_with("SCAN n ")),
            "search must not scan nodes: {plan:?}"
        );
    }

    let nodes = Some(reopened.list_nodes(&thread.id)?);
    assert_eq!(nodes.map(|n| n.len()), Some(1001));
    Ok(())
}

#[test]
fn v1_expand_migration_pinning_assistants_settings_and_delete_cascade() -> TestResult {
    let dir = tempdir()?;
    let db_path = dir.path().join("legacy_v1.sqlite");

    // Create a genuine v1 database first to prove Expand-Contract migration safety.
    {
        let mut conn = open_writer_connection(&db_path)?;
        {
            assert!(configure_connection(&conn, true).is_ok());
            assert!(apply_sql_migration(&mut conn, SCHEMA_V1_SQL, 1, "v0_to_v1").is_ok());
            assert!(ensure_default_workspace(&conn).is_ok());
            assert!(
                conn.execute(
                    "INSERT INTO threads (id, workspace_id, title, mode, active_head_node_id, created_at_ms, updated_at_ms)
                     VALUES ('t-legacy', ?1, 'Legacy Folio', 'chat', NULL, 100, 100)",
                    [DEFAULT_WORKSPACE_ID],
                )
                .is_ok()
            );
        }
    }

    let storage = StorageHandle::open(&db_path)?;
    assert!(PathBuf::from(format!("{}.pre-v2.bak", db_path.display())).exists());
    assert_eq!(storage.list_assistants()?.len(), 1);

    let newer = storage.create_thread(
        None,
        "Newer Thread",
        ThreadMode::Write,
        Some("writing"),
        None,
    )?;

    // Pin legacy thread and verify it sorts above newer thread.
    let pinned = Some(storage.update_thread(
        "t-legacy".to_owned(),
        ThreadPatch {
            is_pinned: Some(true),
            topic: Some("research".to_owned()),
            ..ThreadPatch::default()
        },
    )?);
    assert!(pinned.is_some());

    let ordered = storage.list_threads(None)?;
    assert_eq!(ordered.first().map(|t| t.id.as_str()), Some("t-legacy"));
    assert_eq!(ordered.first().map(|t| t.is_pinned), Some(true));

    // Round-trip settings in kv_meta including Unlimited spending (None) & continuous typography.
    let saved = Some(storage.save_settings(AppSettings {
        theme: "night".to_owned(),
        trust_preset: TrustPreset::Strict,
        wallet_daily_ceiling_micros: None,
        font_size_px: 18,
        prose_font_family: "Georgia".to_owned(),
        ..AppSettings::default()
    })?);
    assert!(saved.is_some());
    let loaded = Some(storage.load_settings()?);
    assert_eq!(loaded.as_ref().map(|s| s.theme.as_str()), Some("night"));
    assert_eq!(
        loaded.as_ref().map(|s| s.trust_preset),
        Some(TrustPreset::Strict)
    );
    assert_eq!(TrustPreset::parse("parchment"), TrustPreset::Strict);
    assert_eq!(TrustPreset::parse("parchment_safe"), TrustPreset::Strict);
    assert_eq!(TrustPreset::parse("off"), TrustPreset::Off);
    // A-S7: an unknown preset is the strictest one that still allows tools, never looser.
    assert_eq!(TrustPreset::parse("guided-craft"), TrustPreset::Strict);
    assert_eq!(TrustPreset::parse(""), TrustPreset::Strict);
    assert_eq!(
        loaded.as_ref().and_then(|s| s.wallet_daily_ceiling_micros),
        None
    );
    assert_eq!(loaded.as_ref().map(|s| s.font_size_px), Some(18));

    assert!(storage.delete_thread(newer.id).is_ok());
    assert_eq!(storage.list_threads(None)?.len(), 1);

    // Verify ALL providers (including initial Big 3 starters) are freely deletable and do NOT return on reopen.
    let providers = storage.list_providers()?;
    assert_eq!(providers.len(), 3);
    let cp = storage.create_provider(
        "Local Ollama",
        ProviderDialect::CustomOpenAi,
        "http://127.0.0.1:11434/v1/",
        "llama3.2",
        "ollama",
        "",
    )?;
    {
        assert_eq!(cp.base_url, "http://127.0.0.1:11434/v1");
        assert_eq!(cp.icon_slug, "ollama");
        assert_eq!(storage.list_providers()?.len(), 4);
        assert!(storage.delete_provider(cp.id).is_ok());
    }
    assert!(storage.delete_provider("openai".to_owned()).is_ok());
    assert_eq!(storage.list_providers()?.len(), 2);
    assert!(storage.shutdown().is_ok());
    drop(storage);

    let reopened = StorageHandle::open(&db_path)?;
    {
        assert_eq!(reopened.list_providers()?.len(), 2);
        let backup_file = dir.path().join("snapshot.sqlite");
        assert!(reopened.backup_database(&backup_file).is_ok());
        assert!(backup_file.exists());
        // Overwriting an existing backup is atomic and leaves no temp files behind.
        assert!(reopened.backup_database(&backup_file).is_ok());
        let leftovers = std::fs::read_dir(dir.path()).map_or(usize::MAX, |it| {
            it.flatten()
                .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
                .count()
        });
        assert_eq!(leftovers, 0);
    }
    Ok(())
}

#[test]
fn node_delete_export_and_daily_wallet_spend_work_atomically() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("ops.sqlite"))?;

    let thread = storage.create_thread(None, "Architecture notes", ThreadMode::Chat, None, None)?;

    let n1 = storage.append_node(
        thread.id.clone(),
        None,
        NodeRole::User,
        "Hello".to_owned(),
        None,
    )?;
    let n2 = storage.append_node(
        thread.id.clone(),
        Some(n1.id.clone()),
        NodeRole::Assistant,
        "Hi there!".to_owned(),
        None,
    )?;

    let md = Some(storage.export_thread(&thread.id, "markdown")?);
    assert!(
        md.as_deref()
            .is_some_and(|s| s.contains("# Architecture notes") && s.contains("Hi there!"))
    );
    let js = Some(storage.export_thread(&thread.id, "json")?);
    assert!(js.as_deref().is_some_and(|s| s.contains("\"title\"")));

    assert!(storage.delete_node(thread.id.clone(), n2.id).is_ok());
    assert_eq!(storage.list_nodes(&thread.id)?.len(), 1);

    assert!(
        storage
            .record_wallet_entry_with_usage(
                Some(thread.id),
                "openai".to_owned(),
                "gpt-4.1".to_owned(),
                MoneyMicros::from_micros(250_000),
                100,
                200,
                "settled".to_owned(),
            )
            .is_ok()
    );
    let since_zero = Some(storage.sum_wallet_spend_since_micros(0)?);
    assert_eq!(since_zero, Some(MoneyMicros::from_micros(250_000)));
    let future = Some(storage.sum_wallet_spend_since_micros(i64::MAX)?);
    assert_eq!(future, Some(MoneyMicros::ZERO));
    Ok(())
}

#[test]
fn default_assistant_and_crud_invariants() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("asst.sqlite"))?;

    let assistants = storage.list_assistants()?;
    assert_eq!(assistants.len(), 1);
    assert_eq!(assistants[0].name, "Default");
    assert!(
        storage
            .delete_assistant(DEFAULT_ASSISTANT_ID.to_owned())
            .is_err()
    );

    let a = storage.create_assistant(
        "Architect",
        "System Design Reviewer",
        "Critique boundaries sharply.",
        ThreadMode::Code,
        "AR",
    )?;
    {
        let edited = Some(storage.update_assistant(
            a.id.clone(),
            AssistantPatch {
                name: Some("Staff Architect".to_owned()),
                system_prompt: Some("Review invariants strictly.".to_owned()),
                ..AssistantPatch::default()
            },
        )?);
        assert_eq!(
            edited.as_ref().map(|e| e.name.as_str()),
            Some("Staff Architect")
        );
        assert!(storage.delete_assistant(a.id).is_ok());
        assert_eq!(storage.list_assistants()?.len(), 1);
    }
    Ok(())
}

#[test]
fn schema_v6_durable_runs_and_steering_queue() -> TestResult {
    use bistre_protocol::{RunStatus, RunStepKind, ToolRiskTier, UnattendedPolicy};

    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("v6a.sqlite"))?;

    let thread = storage.create_thread(None, "Long Horizon", ThreadMode::Code, None, None)?;

    let run = storage.create_agent_run(CreateAgentRunParams {
        thread_id: thread.id.clone(),
        parent_run_id: None,
        root_node_id: None,
        mode: ThreadMode::Code,
        max_steps: 25,
        unattended_policy: UnattendedPolicy::DenyTier2AndContinue,
        worktree_path: None,
    })?;
    assert_eq!(run.status, RunStatus::Running);

    assert!(
        storage
            .record_run_step(
                run.id.clone(),
                0,
                RunStepKind::ToolCall,
                "shell".to_owned(),
                ToolRiskTier::Tier2ExternalSideEffect,
                "idem-step-0".to_owned(),
                "running".to_owned(),
                "{\"cmd\":\"cargo test\"}".to_owned(),
                "{}".to_owned(),
                0,
                None,
            )
            .is_ok()
    );

    assert_eq!(storage.mark_active_runs_sleep_paused()?, 1);
    assert_eq!(
        storage.get_agent_run(&run.id)?.map(|r| r.status),
        Some(RunStatus::SleepPaused)
    );

    assert!(
        storage
            .enqueue_steering_message(
                thread.id.clone(),
                Some(run.id),
                "Also add edge-case tests",
                "[]".to_owned(),
            )
            .is_ok()
    );
    assert_eq!(storage.list_pending_steering(&thread.id)?.len(), 1);
    assert_eq!(storage.drain_pending_steering(thread.id.clone())?.len(), 1);
    assert_eq!(storage.list_pending_steering(&thread.id)?.len(), 0);
    Ok(())
}

#[test]
fn schema_v6_checkpoints_memory_cron_and_event_cursor_replay() -> TestResult {
    use bistre_protocol::{CronJobRecord, EngineEvent, UnattendedPolicy};

    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("v6b.sqlite"))?;

    let thread = storage.create_thread(None, "Checkpoints", ThreadMode::Code, None, None)?;

    assert!(
        storage
            .save_workspace_checkpoint(
                thread.id.clone(),
                None,
                None,
                "src/lib.rs".to_owned(),
                "aaa".to_owned(),
                "bbb".to_owned(),
                b"fn main() {}".to_vec(),
            )
            .is_ok()
    );
    assert_eq!(storage.list_workspace_checkpoints(&thread.id)?.len(), 1);

    assert!(
        storage
            .upsert_memory_entry(
                None,
                "global".to_owned(),
                String::new(),
                "style".to_owned(),
                "Prefer pure Rust".to_owned(),
                Some(thread.id.clone()),
                true,
            )
            .is_ok()
    );

    assert!(
        storage
            .upsert_cron_job(CronJobRecord {
                id: String::new(),
                name: "Nightly audit".to_owned(),
                workspace_id: DEFAULT_WORKSPACE_ID.to_owned(),
                assistant_id: DEFAULT_ASSISTANT_ID.to_owned(),
                schedule_expr: "0 3 * * *".to_owned(),
                prompt: "Run checks".to_owned(),
                mode: ThreadMode::Code,
                unattended_policy: UnattendedPolicy::DenyTier2AndContinue,
                use_worktree: true,
                enabled: true,
                next_run_ms: 1000,
                last_run_id: None,
                last_status: "idle".to_owned(),
            })
            .is_ok()
    );
    assert_eq!(storage.count_enabled_cron_jobs()?, 1);

    let c1 = storage.append_engine_event_log(
        Some(thread.id.clone()),
        &EngineEvent::RunStarted {
            thread_id: thread.id.clone(),
            node_id: "n1".to_owned(),
        },
    )?;
    let c2 = storage.append_engine_event_log(
        Some(thread.id.clone()),
        &EngineEvent::RunFinished {
            thread_id: thread.id,
            node_id: "n1".to_owned(),
            cancelled: false,
        },
    )?;
    assert!(c2 > c1);
    assert_eq!(storage.read_engine_events_after(c1, 10)?.len(), 1);
    Ok(())
}

#[test]
fn schema_v7_story_bible_progressions_manuscript_and_time_machine() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("v7.sqlite"))?;
    assert_eq!(storage.health()?.schema_version, CURRENT_SCHEMA_VERSION);

    let thread = storage.create_thread(None, "Novel Draft", ThreadMode::Write, None, None)?;

    let card = storage.upsert_character_card(bistre_protocol::CharacterCardRecord {
        name: "Lyra".to_owned(),
        description: "Archivist of the Glass City".to_owned(),
        alternate_greetings: vec!["Rain taps the skylight.".to_owned()],
        ..bistre_protocol::CharacterCardRecord::default()
    })?;
    assert_eq!(
        storage
            .list_story_snapshots("character_card", &card.id, 10)?
            .len(),
        1
    );

    let entry = storage.upsert_story_entry(bistre_protocol::StoryEntryRecord {
        name: "Glass City".to_owned(),
        keys: vec!["glass city".to_owned()],
        content: "A terraced citadel above the salt sea.".to_owned(),
        ..bistre_protocol::StoryEntryRecord::default()
    })?;

    assert!(
        storage
            .add_story_progression(bistre_protocol::StoryProgressionRecord {
                entry_id: entry.id.clone(),
                chapter_order: 3,
                scene_order: 1,
                delta_text: "The North Spire cracked after the storm.".to_owned(),
                ..bistre_protocol::StoryProgressionRecord::default()
            })
            .is_ok()
    );
    assert_eq!(storage.list_story_progressions(Some(&entry.id))?.len(), 1);

    let ch = storage.upsert_story_chapter(bistre_protocol::StoryChapterRecord {
        thread_id: thread.id,
        order_index: 1,
        title: "Chapter 1: Salt and Ink".to_owned(),
        ..bistre_protocol::StoryChapterRecord::default()
    })?;
    let scene = Some(
        storage.upsert_story_scene(bistre_protocol::StorySceneRecord {
            chapter_id: ch.id,
            order_index: 1,
            title: "Opening".to_owned(),
            beats_text: "- Lyra inspects the lantern.".to_owned(),
            prose_text: "The brass lantern hissed softly.".to_owned(),
            ..bistre_protocol::StorySceneRecord::default()
        })?,
    );
    assert_eq!(scene.map(|s| s.word_count), Some(5));
    Ok(())
}

#[test]
fn schema_v9_perf_indexes_eliminate_temp_sorts_and_ledger_scans() -> TestResult {
    let dir = tempdir()?;
    let db_path = dir.path().join("v9_plan.sqlite");
    let storage = StorageHandle::open(&db_path)?;
    assert_eq!(storage.health()?.schema_version, CURRENT_SCHEMA_VERSION);

    let conn = Connection::open(&db_path)?;
    let explain = |sql: &str| -> Result<String, rusqlite::Error> {
        let mut stmt = conn.prepare(&format!("EXPLAIN QUERY PLAN {sql}"))?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(3))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows.join(" | "))
    };

    let nodes_plan = explain("SELECT id FROM nodes WHERE thread_id = 't1' ORDER BY rowid ASC")?;
    assert!(
        nodes_plan.contains("idx_nodes_thread_rowid"),
        "expected idx_nodes_thread_rowid in plan, got: {nodes_plan}"
    );
    assert!(
        !nodes_plan.contains("TEMP B-TREE"),
        "unexpected temp B-tree sort in nodes plan: {nodes_plan}"
    );

    let threads_plan = explain(
        "SELECT id FROM threads WHERE workspace_id = 'w1' ORDER BY is_pinned DESC, updated_at_ms DESC",
    )?;
    assert!(
        threads_plan.contains("idx_threads_ws_pinned_updated"),
        "expected idx_threads_ws_pinned_updated in plan, got: {threads_plan}"
    );
    assert!(
        !threads_plan.contains("TEMP B-TREE"),
        "unexpected temp B-tree sort in threads plan: {threads_plan}"
    );

    let job_plan = explain(
        "SELECT COUNT(*) FROM wallet_ledger WHERE job_id = 'req-1' AND status != 'reserved'",
    )?;
    assert!(
        job_plan.contains("idx_wallet_ledger_job"),
        "expected idx_wallet_ledger_job in plan, got: {job_plan}"
    );

    let reserved_plan = explain("DELETE FROM wallet_ledger WHERE status = 'reserved'")?;
    assert!(
        reserved_plan.contains("idx_wallet_ledger_reserved"),
        "expected idx_wallet_ledger_reserved in plan, got: {reserved_plan}"
    );
    Ok(())
}

/// R4: a reservation is refused when it would carry today's spend past the ceiling, not only
/// when the ceiling is already reached.
#[test]
fn a_reservation_that_would_exceed_the_ceiling_is_refused() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("wallet.db"))?;
    let ceiling = Some(MoneyMicros::from_micros(1_000_000));
    storage.record_wallet_entry(
        None,
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(990_000),
        "settled".to_owned(),
    )?;
    let over = storage.reserve_wallet_spend(
        None,
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(4_000_000),
        ceiling,
        0,
    );
    assert_eq!(
        over.err().map(|e| e.key),
        Some(DiagnosticKey::WalletCeilingExceeded),
        "$0.99 spent + $4.00 estimate must not fit a $1.00 ceiling"
    );
    // Exactly reaching the ceiling still fits; anything past it, or a full ceiling, does not.
    let fits = storage.reserve_wallet_spend(
        None,
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(10_000),
        ceiling,
        0,
    );
    assert!(fits.is_ok(), "{fits:?}");
    let full = storage.reserve_wallet_spend(
        None,
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(0),
        ceiling,
        0,
    );
    assert_eq!(
        full.err().map(|e| e.key),
        Some(DiagnosticKey::WalletCeilingExceeded)
    );
    let negative = storage.reserve_wallet_spend(
        None,
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(-5),
        None,
        0,
    );
    assert!(
        negative.is_err(),
        "a negative estimate is never a reservation"
    );
    Ok(())
}

/// A-S1: the per-chat cap is checked on the writer against the wallet ledger (settled and
/// reserved spend of that chat), together with the new estimate.
#[test]
fn a_chat_cap_counts_the_chats_ledger_spend_and_the_estimate() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("wallet.db"))?;
    let thread = storage.create_thread(None, "capped", ThreadMode::Chat, None, None)?;
    let other = storage.create_thread(None, "other", ThreadMode::Chat, None, None)?;
    storage.record_wallet_entry(
        Some(thread.id.clone()),
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(900_000),
        "settled".to_owned(),
    )?;
    let cap = Some(MoneyMicros::from_micros(1_000_000));
    let reserve = |tid: &str, micros: i64| {
        storage.reserve_wallet_spend_with_chat_cap(
            Some(tid.to_owned()),
            "p".to_owned(),
            "m".to_owned(),
            MoneyMicros::from_micros(micros),
            None,
            0,
            cap,
        )
    };
    assert_eq!(
        reserve(&thread.id, 200_000)
            .err()
            .map(|e| (e.key, e.detail_code)),
        Some((
            DiagnosticKey::WalletCeilingExceeded,
            Some("thread_spend_limit".to_owned())
        ))
    );
    assert!(
        reserve(&thread.id, 100_000).is_ok(),
        "exactly reaching the cap fits"
    );
    assert!(
        reserve(&thread.id, 1).is_err(),
        "the outstanding reservation counts toward the cap"
    );
    assert!(
        reserve(&other.id, 500_000).is_ok(),
        "another chat has its own spend"
    );
    Ok(())
}

/// U1: a node's parent must belong to the same thread; a parent from another chat would graft
/// one conversation onto another and corrupt its history graph.
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

/// R31: deleting a chat deletes everything derived from it (event log rows, run journal and
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

/// R31 + R38 (v9 -> v10): the one-time cleanup clears the v0.1.2 event log (it held message
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

/// R38 (kelivo #1539): deleting a 25,000-message chat completes and removes every node.
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

/// G3 (Hermes #153688): a corrupt full-text index must never block saving messages. Writes
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

/// D6: CJK text and mid-word substrings are found (trigram index; queries shorter than three
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

/// G3: a stale search index is rebuilt once at the next open (never live, during writes),
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

/// R20: a backup never occupies the single writer, so runs keep saving while it copies. Here
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

/// R37: the branch walk returns exactly the leaf's ancestry, root first, skipping siblings.
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
