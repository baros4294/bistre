//! Storage integration tests (split out of `lib.rs`).

use super::*;
use crate::schema::{SCHEMA_V1_SQL, apply_sql_migration};
use crate::search::{SEARCH_ALL_SQL, SEARCH_IN_THREAD_SQL};
use bistre_protocol::{SpendPurpose, TrustPreset};
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
        "Xin chào thế giới! مرحبا بالعالم: root prompt".to_owned(),
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
    // An unknown preset is the strictest one that still allows tools, never looser.
    assert_eq!(TrustPreset::parse("guided-craft"), TrustPreset::Strict);
    assert_eq!(TrustPreset::parse(""), TrustPreset::Strict);
    assert_eq!(
        loaded.as_ref().and_then(|s| s.wallet_daily_ceiling_micros),
        None
    );
    assert_eq!(loaded.as_ref().map(|s| s.font_size_px), Some(18));

    assert!(storage.delete_thread(newer.id).is_ok());
    assert_eq!(storage.list_threads(None)?.len(), 1);

    // Verify ALL providers (the Big 3 and OpenRouter starters) are freely deletable and do NOT
    // return on reopen.
    let providers = storage.list_providers()?;
    assert_eq!(providers.len(), 4);
    let openrouter = providers.iter().find(|p| p.id == "openrouter");
    assert_eq!(
        openrouter.map(|p| (p.dialect, p.base_url.as_str(), p.icon_slug.as_str())),
        Some((
            ProviderDialect::CustomOpenAi,
            "https://openrouter.ai/api/v1",
            "openrouter"
        ))
    );
    assert!(openrouter.is_some_and(ProviderProfile::requires_api_key));
    assert!(storage.delete_provider("openrouter".to_owned()).is_ok());
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
                SpendPurpose::Chat,
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

/// A reservation is refused when it would carry today's spend past the ceiling, not only
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

/// The per-chat cap is checked on the writer against the wallet ledger (settled and
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
            SpendPurpose::Chat,
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

/// A node's parent must belong to the same thread; a parent from another chat would graft
/// one conversation onto another and corrupt its history graph.
#[test]
fn settled_spend_is_summed_per_purpose_and_reservations_are_left_out() -> TestResult {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("wallet.db"))?;
    let book = |purpose: SpendPurpose, micros: i64, input: u64, output: u64| {
        storage.record_wallet_entry_with_usage(
            None,
            "p".to_owned(),
            "m".to_owned(),
            MoneyMicros::from_micros(micros),
            input,
            output,
            "settled".to_owned(),
            purpose,
        )
    };
    book(SpendPurpose::Title, 300, 10, 2)?;
    book(SpendPurpose::Chat, 5_000, 900, 400)?;
    book(SpendPurpose::Title, 200, 12, 3)?;
    // A reservation keeps its purpose through settlement; an open one is not counted.
    let settled = storage.reserve_wallet_spend_with_chat_cap(
        None,
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(1_000),
        None,
        0,
        None,
        SpendPurpose::Voice,
    )?;
    storage.settle_wallet_reservation(
        settled,
        MoneyMicros::from_micros(700),
        40,
        0,
        "settled".to_owned(),
    )?;
    storage.reserve_wallet_spend_with_chat_cap(
        None,
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(9_000),
        None,
        0,
        None,
        SpendPurpose::Summary,
    )?;
    let usage = storage.wallet_usage_by_purpose(0)?;
    let rows: Vec<_> = usage
        .iter()
        .map(|u| {
            (
                u.purpose,
                u.requests,
                u.input_tokens,
                u.output_tokens,
                u.cost.as_micros(),
            )
        })
        .collect();
    assert_eq!(
        rows,
        vec![
            (SpendPurpose::Chat, 1, 900, 400, 5_000),
            (SpendPurpose::Title, 2, 22, 5, 500),
            (SpendPurpose::Voice, 1, 40, 0, 700),
        ]
    );
    assert_eq!(storage.wallet_usage_by_purpose(i64::MAX)?, Vec::new());
    // One chat's spend counts its settled rows only.
    let thread = storage.create_thread(None, "spend", ThreadMode::Chat, None, None)?;
    storage.record_wallet_entry(
        Some(thread.id.clone()),
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(1_250),
        "settled".to_owned(),
    )?;
    storage.reserve_wallet_spend(
        Some(thread.id.clone()),
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(9_000),
        None,
        0,
    )?;
    assert_eq!(
        storage.thread_spend_micros(&thread.id)?,
        MoneyMicros::from_micros(1_250)
    );
    Ok(())
}
