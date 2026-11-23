//! Storage integration tests (split out of `lib.rs`).

use super::*;
use crate::schema::{SCHEMA_V1_SQL, apply_sql_migration};
use bistre_protocol::TrustPreset;
use std::time::Instant;
use tempfile::tempdir;

#[test]
fn dag_branching_draft_persistence_fts5_latency_and_checkpoint() {
    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };
    let db_path = dir.path().join("bistre.sqlite");

    let storage = StorageHandle::open(&db_path).ok();
    assert!(storage.is_some());
    let Some(storage) = storage else { return };

    let health = storage.health().ok();
    assert_eq!(
        health.map(|h| (h.schema_version, h.wal_mode_active)),
        Some((CURRENT_SCHEMA_VERSION, true))
    );

    let thread = storage
        .create_thread(
            None,
            "Vietnamese & Arabic Folio",
            ThreadMode::Code,
            Some("code"),
            Some("bistre_craftsman"),
        )
        .ok();
    assert!(thread.is_some());
    let Some(thread) = thread else { return };

    let root = storage
        .append_node(
            thread.id.clone(),
            None,
            NodeRole::User,
            "Xin chào thế giới! مرحبا بالعالم — root prompt".to_owned(),
            None,
        )
        .ok();
    assert!(root.is_some());
    let Some(root) = root else { return };

    let mut alpha_head = root.id.clone();
    let mut beta_head = root.id.clone();
    for idx in 0..500_u32 {
        let a = storage
            .append_node(
                thread.id.clone(),
                Some(alpha_head.clone()),
                NodeRole::Assistant,
                format!("Branch alpha Vietnamese tiếng Việt entry #{idx} parchment folio"),
                None,
            )
            .ok();
        assert!(a.is_some());
        if let Some(node) = a {
            alpha_head = node.id;
        }

        let b = storage
            .append_node(
                thread.id.clone(),
                Some(beta_head.clone()),
                NodeRole::Assistant,
                format!("Branch beta Arabic كتابة entry #{idx} candlelight ink"),
                None,
            )
            .ok();
        assert!(b.is_some());
        if let Some(node) = b {
            beta_head = node.id;
        }
    }

    let draft_text = "Bản nháp chưa gửi với dấu tiếng Việt و نص عربي";
    assert!(
        storage
            .save_draft(thread.id.clone(), draft_text.to_owned())
            .is_ok()
    );

    let stats = storage.shutdown().ok();
    assert_eq!(stats.map(|s| s.busy), Some(0));
    drop(storage);

    let reopened = StorageHandle::open(&db_path).ok();
    assert!(reopened.is_some());
    let Some(reopened) = reopened else { return };

    let restored_draft = reopened.load_draft(&thread.id).ok().flatten();
    assert_eq!(restored_draft.map(|d| d.text), Some(draft_text.to_owned()));

    let started = Instant::now();
    let hits = reopened
        .search_nodes("tiếng Việt #499", Some(&thread.id), 10)
        .ok();
    let elapsed_ms = started.elapsed().as_millis();
    assert!(elapsed_ms < 50, "FTS5 query took {elapsed_ms}ms");
    assert!(hits.as_ref().is_some_and(|list| !list.is_empty()));

    let nodes = reopened.list_nodes(&thread.id).ok();
    assert_eq!(nodes.map(|n| n.len()), Some(1001));
}

#[test]
fn v1_expand_migration_pinning_assistants_settings_and_delete_cascade() {
    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };
    let db_path = dir.path().join("legacy_v1.sqlite");

    // Create a genuine v1 database first to prove Expand-Contract migration safety.
    {
        let conn = open_writer_connection(&db_path).ok();
        assert!(conn.is_some());
        if let Some(mut conn) = conn {
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

    let storage = StorageHandle::open(&db_path).ok();
    assert!(storage.is_some());
    let Some(storage) = storage else { return };
    assert!(PathBuf::from(format!("{}.pre-v2.bak", db_path.display())).exists());
    assert_eq!(storage.list_assistants().ok().map(|v| v.len()), Some(1));

    let newer = storage
        .create_thread(
            None,
            "Newer Thread",
            ThreadMode::Write,
            Some("writing"),
            None,
        )
        .ok();
    assert!(newer.is_some());
    let Some(newer) = newer else { return };

    // Pin legacy thread and verify it sorts above newer thread.
    let pinned = storage
        .update_thread(
            "t-legacy".to_owned(),
            ThreadPatch {
                is_pinned: Some(true),
                topic: Some("research".to_owned()),
                ..ThreadPatch::default()
            },
        )
        .ok();
    assert!(pinned.is_some());

    let ordered = storage.list_threads(None).ok().unwrap_or_default();
    assert_eq!(ordered.first().map(|t| t.id.as_str()), Some("t-legacy"));
    assert_eq!(ordered.first().map(|t| t.is_pinned), Some(true));

    // Round-trip settings in kv_meta including Unlimited spending (None) & continuous typography.
    let saved = storage
        .save_settings(AppSettings {
            theme: "night".to_owned(),
            trust_preset: TrustPreset::Parchment,
            wallet_daily_ceiling_micros: None,
            font_size_px: 18,
            prose_font_family: "Georgia".to_owned(),
            ..AppSettings::default()
        })
        .ok();
    assert!(saved.is_some());
    let loaded = storage.load_settings().ok();
    assert_eq!(loaded.as_ref().map(|s| s.theme.as_str()), Some("night"));
    assert_eq!(
        loaded.as_ref().map(|s| s.trust_preset),
        Some(TrustPreset::Parchment)
    );
    assert_eq!(
        loaded.as_ref().and_then(|s| s.wallet_daily_ceiling_micros),
        None
    );
    assert_eq!(loaded.as_ref().map(|s| s.font_size_px), Some(18));

    assert!(storage.delete_thread(newer.id).is_ok());
    assert_eq!(storage.list_threads(None).ok().map(|v| v.len()), Some(1));

    // Verify ALL providers (including initial Big 3 starters) are freely deletable and do NOT return on reopen.
    let providers = storage.list_providers().ok().unwrap_or_default();
    assert_eq!(providers.len(), 3);
    let custom_provider = storage
        .create_provider(
            "Local Ollama",
            ProviderDialect::CustomOpenAi,
            "http://127.0.0.1:11434/v1/",
            "llama3.2",
            "ollama",
            "",
        )
        .ok();
    assert!(custom_provider.is_some());
    if let Some(cp) = custom_provider {
        assert_eq!(cp.base_url, "http://127.0.0.1:11434/v1");
        assert_eq!(cp.icon_slug, "ollama");
        assert_eq!(storage.list_providers().ok().map(|v| v.len()), Some(4));
        assert!(storage.delete_provider(cp.id).is_ok());
    }
    assert!(storage.delete_provider("openai".to_owned()).is_ok());
    assert_eq!(storage.list_providers().ok().map(|v| v.len()), Some(2));
    assert!(storage.shutdown().is_ok());
    drop(storage);

    let reopened = StorageHandle::open(&db_path).ok();
    assert!(reopened.is_some());
    if let Some(reopened) = reopened {
        assert_eq!(reopened.list_providers().ok().map(|v| v.len()), Some(2));
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
}

#[test]
fn node_delete_export_and_daily_wallet_spend_work_atomically() {
    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };
    let storage = StorageHandle::open(dir.path().join("ops.sqlite")).ok();
    assert!(storage.is_some());
    let Some(storage) = storage else { return };

    let thread = storage
        .create_thread(None, "Architecture notes", ThreadMode::Chat, None, None)
        .ok();
    assert!(thread.is_some());
    let Some(thread) = thread else { return };

    let n1 = storage
        .append_node(
            thread.id.clone(),
            None,
            NodeRole::User,
            "Hello".to_owned(),
            None,
        )
        .ok();
    assert!(n1.is_some());
    let Some(n1) = n1 else { return };
    let n2 = storage
        .append_node(
            thread.id.clone(),
            Some(n1.id.clone()),
            NodeRole::Assistant,
            "Hi there!".to_owned(),
            None,
        )
        .ok();
    assert!(n2.is_some());
    let Some(n2) = n2 else { return };

    let md = storage.export_thread(&thread.id, "markdown").ok();
    assert!(
        md.as_deref()
            .is_some_and(|s| s.contains("# Architecture notes") && s.contains("Hi there!"))
    );
    let js = storage.export_thread(&thread.id, "json").ok();
    assert!(js.as_deref().is_some_and(|s| s.contains("\"title\"")));

    assert!(storage.delete_node(thread.id.clone(), n2.id).is_ok());
    assert_eq!(
        storage.list_nodes(&thread.id).ok().map(|v| v.len()),
        Some(1)
    );

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
    let since_zero = storage.sum_wallet_spend_since_micros(0).ok();
    assert_eq!(since_zero, Some(MoneyMicros::from_micros(250_000)));
    let future = storage.sum_wallet_spend_since_micros(i64::MAX).ok();
    assert_eq!(future, Some(MoneyMicros::ZERO));
}

#[test]
fn default_assistant_and_crud_invariants() {
    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };
    let storage = StorageHandle::open(dir.path().join("asst.sqlite")).ok();
    assert!(storage.is_some());
    let Some(storage) = storage else { return };

    let assistants = storage.list_assistants().ok().unwrap_or_default();
    assert_eq!(assistants.len(), 1);
    assert_eq!(assistants[0].name, "Default");
    assert!(
        storage
            .delete_assistant(DEFAULT_ASSISTANT_ID.to_owned())
            .is_err()
    );

    let custom = storage
        .create_assistant(
            "Architect",
            "System Design Reviewer",
            "Critique boundaries sharply.",
            ThreadMode::Code,
            "AR",
        )
        .ok();
    assert!(custom.is_some());
    if let Some(a) = custom {
        let edited = storage
            .update_assistant(
                a.id.clone(),
                AssistantPatch {
                    name: Some("Staff Architect".to_owned()),
                    system_prompt: Some("Review invariants strictly.".to_owned()),
                    ..AssistantPatch::default()
                },
            )
            .ok();
        assert_eq!(
            edited.as_ref().map(|e| e.name.as_str()),
            Some("Staff Architect")
        );
        assert!(storage.delete_assistant(a.id).is_ok());
        assert_eq!(storage.list_assistants().ok().map(|v| v.len()), Some(1));
    }
}

#[test]
fn schema_v6_durable_runs_and_steering_queue() {
    use bistre_protocol::{RunStatus, RunStepKind, ToolRiskTier, UnattendedPolicy};

    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };
    let storage = StorageHandle::open(dir.path().join("v6a.sqlite")).ok();
    assert!(storage.is_some());
    let Some(storage) = storage else { return };

    let thread = storage
        .create_thread(None, "Long Horizon", ThreadMode::Code, None, None)
        .ok();
    assert!(thread.is_some());
    let Some(thread) = thread else { return };

    let run = storage
        .create_agent_run(CreateAgentRunParams {
            thread_id: thread.id.clone(),
            parent_run_id: None,
            root_node_id: None,
            mode: ThreadMode::Code,
            max_steps: 25,
            unattended_policy: UnattendedPolicy::DenyTier2AndContinue,
            worktree_path: None,
        })
        .ok();
    assert!(run.is_some());
    let Some(run) = run else { return };
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

    assert_eq!(storage.mark_active_runs_sleep_paused().ok(), Some(1));
    assert_eq!(
        storage
            .get_agent_run(&run.id)
            .ok()
            .flatten()
            .map(|r| r.status),
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
    assert_eq!(
        storage
            .list_pending_steering(&thread.id)
            .ok()
            .map(|v| v.len()),
        Some(1)
    );
    assert_eq!(
        storage
            .drain_pending_steering(thread.id.clone())
            .ok()
            .map(|v| v.len()),
        Some(1)
    );
    assert_eq!(
        storage
            .list_pending_steering(&thread.id)
            .ok()
            .map(|v| v.len()),
        Some(0)
    );
}

#[test]
fn schema_v6_checkpoints_memory_cron_and_event_cursor_replay() {
    use bistre_protocol::{CronJobRecord, EngineEvent, UnattendedPolicy};

    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };
    let storage = StorageHandle::open(dir.path().join("v6b.sqlite")).ok();
    assert!(storage.is_some());
    let Some(storage) = storage else { return };

    let thread = storage
        .create_thread(None, "Checkpoints", ThreadMode::Code, None, None)
        .ok();
    assert!(thread.is_some());
    let Some(thread) = thread else { return };

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
    assert_eq!(
        storage
            .list_workspace_checkpoints(&thread.id)
            .ok()
            .map(|v| v.len()),
        Some(1)
    );

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
    assert_eq!(storage.count_enabled_cron_jobs().ok(), Some(1));

    let c1 = storage
        .append_engine_event_log(
            Some(thread.id.clone()),
            &EngineEvent::RunStarted {
                thread_id: thread.id.clone(),
                node_id: "n1".to_owned(),
            },
        )
        .ok()
        .unwrap_or(0);
    let c2 = storage
        .append_engine_event_log(
            Some(thread.id.clone()),
            &EngineEvent::RunFinished {
                thread_id: thread.id,
                node_id: "n1".to_owned(),
                cancelled: false,
            },
        )
        .ok()
        .unwrap_or(0);
    assert!(c2 > c1);
    assert_eq!(
        storage
            .read_engine_events_after(c1, 10)
            .ok()
            .map(|v| v.len()),
        Some(1)
    );
}

#[test]
fn schema_v7_story_bible_progressions_manuscript_and_time_machine() {
    let dir = tempdir().ok();
    let Some(dir) = dir else { return };
    let storage = StorageHandle::open(dir.path().join("v7.sqlite")).ok();
    let Some(storage) = storage else { return };
    assert_eq!(
        storage.health().ok().map(|h| h.schema_version),
        Some(CURRENT_SCHEMA_VERSION)
    );

    let thread = storage
        .create_thread(None, "Novel Draft", ThreadMode::Write, None, None)
        .ok();
    let Some(thread) = thread else { return };

    let card = storage
        .upsert_character_card(bistre_protocol::CharacterCardRecord {
            name: "Lyra".to_owned(),
            description: "Archivist of the Glass City".to_owned(),
            alternate_greetings: vec!["Rain taps the skylight.".to_owned()],
            ..bistre_protocol::CharacterCardRecord::default()
        })
        .ok();
    let Some(card) = card else { return };
    assert_eq!(
        storage
            .list_story_snapshots("character_card", &card.id, 10)
            .ok()
            .map(|s| s.len()),
        Some(1)
    );

    let entry = storage
        .upsert_story_entry(bistre_protocol::StoryEntryRecord {
            name: "Glass City".to_owned(),
            keys: vec!["glass city".to_owned()],
            content: "A terraced citadel above the salt sea.".to_owned(),
            ..bistre_protocol::StoryEntryRecord::default()
        })
        .ok();
    let Some(entry) = entry else { return };

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
    assert_eq!(
        storage
            .list_story_progressions(Some(&entry.id))
            .ok()
            .map(|p| p.len()),
        Some(1)
    );

    let ch = storage
        .upsert_story_chapter(bistre_protocol::StoryChapterRecord {
            thread_id: thread.id,
            order_index: 1,
            title: "Chapter 1: Salt and Ink".to_owned(),
            ..bistre_protocol::StoryChapterRecord::default()
        })
        .ok();
    let Some(ch) = ch else { return };
    let scene = storage
        .upsert_story_scene(bistre_protocol::StorySceneRecord {
            chapter_id: ch.id,
            order_index: 1,
            title: "Opening".to_owned(),
            beats_text: "- Lyra inspects the lantern.".to_owned(),
            prose_text: "The brass lantern hissed softly.".to_owned(),
            ..bistre_protocol::StorySceneRecord::default()
        })
        .ok();
    assert_eq!(scene.map(|s| s.word_count), Some(5));
}
