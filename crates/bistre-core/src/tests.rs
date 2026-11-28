//! Integration-style unit tests for `InProcessEngine` (split out of `lib.rs`).

use super::*;
use std::time::Duration;
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

pub(crate) type TestResult = Result<(), Box<dyn std::error::Error>>;

fn spawn_mock_sse_server(listener: TcpListener) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        for turn in 0..2 {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let mut req_buf = [0_u8; 4096];
            assert!(socket.read(&mut req_buf).await.is_ok());
            let req_str = String::from_utf8_lossy(&req_buf);
            let (content_type, body) = if req_str.starts_with("GET ") {
                (
                    "application/json",
                    r#"{"data":[{"id":"local-test-model"}]}"#.to_owned(),
                )
            } else {
                (
                    "text/event-stream",
                    format!(
                        "data: {{\"choices\":[{{\"delta\":{{\"content\":\"Real SSE \"}}}}]}}\n\n\
                         data: {{\"choices\":[{{\"delta\":{{\"content\":\"reply #{turn}\"}}}}]}}\n\n\
                         data: [DONE]\n\n"
                    ),
                )
            };
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            assert!(socket.write_all(resp.as_bytes()).await.is_ok());
        }
    })
}

#[tokio::test]
async fn unconfigured_provider_returns_diagnostic_and_local_sse_streams_real_http() -> TestResult {
    let dir = tempdir()?;

    let engine = InProcessEngine::open_for_test(dir.path(), http_clients::provider_client()?)?;

    let thread = engine
        .create_thread(
            None,
            "Test chat".to_owned(),
            ThreadMode::Chat,
            Some("general".to_owned()),
            None,
        )
        .await?;

    // Zero fake mock replies: without a configured provider/key, returns ProviderNotConfigured.
    let blocked = engine
        .send_and_stream_reply(thread.id.clone(), None, "Hello".to_owned())
        .await;
    assert_eq!(
        blocked.err().map(|e| e.key),
        Some(DiagnosticKey::ProviderNotConfigured)
    );

    // The Big 3 and OpenRouter starters exist (the keyless OpenRouter one was not picked
    // above), and API keys store safely in SecretVault.
    let providers = engine.list_providers().await?;
    assert_eq!(providers.len(), 4);
    let saved_openai = Some(
        engine
            .set_provider_api_key("openai".to_owned(), "sk-test-1234567890abcd".to_owned())
            .await?,
    );
    assert_eq!(saved_openai.as_ref().map(|p| p.has_api_key), Some(true));
    assert_eq!(
        saved_openai.as_ref().map(|p| p.key_hint.as_str()),
        Some("••••abcd")
    );
    let cleared = Some(engine.clear_provider_api_key("openai".to_owned()).await?);
    assert_eq!(cleared.as_ref().map(|p| p.has_api_key), Some(false));

    // Spin up a real local loopback HTTP/SSE server to verify reqwest streaming + DAG commit.
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let server = spawn_mock_sse_server(listener);

    let custom = engine
        .create_custom_provider(
            "Loopback Custom".to_owned(),
            format!("http://{addr}/v1"),
            "local-test-model".to_owned(),
            None,
        )
        .await?;

    // Test live GET /models discovery.
    let models = Some(engine.fetch_provider_models(custom.id.clone()).await?);
    assert_eq!(
        models
            .as_ref()
            .and_then(|m| m.first())
            .map(|m| m.id.as_str()),
        Some("local-test-model")
    );

    let mut settings = engine.load_settings().await?;
    settings.active_provider_id = custom.id;
    settings.active_model_id = "local-test-model".to_owned();
    assert!(engine.save_settings(settings).await.is_ok());

    let mut rx = engine.subscribe_events();
    let user_node = Some(
        engine
            .send_and_stream_reply(thread.id.clone(), None, "Ping loopback".to_owned())
            .await?,
    );
    assert!(user_node.is_some());

    let mut saw_delta = false;
    let mut saw_finished = false;
    for _ in 0..50 {
        if let Ok(Ok(evt)) = tokio::time::timeout(Duration::from_secs(3), rx.recv()).await {
            if let EngineEvent::DeltaBatch { .. } = evt {
                saw_delta = true;
            }
            if let EngineEvent::RunFinished { .. } = evt {
                saw_finished = true;
                break;
            }
        }
    }
    assert!(saw_delta);
    assert!(saw_finished);
    assert!(server.await.is_ok());

    let nodes = engine.list_nodes(thread.id).await?;
    assert_eq!(nodes.len(), 2);
    assert_eq!(
        nodes.last().map(|n| n.content.as_str()),
        Some("Real SSE reply #1")
    );
    assert!(engine.shutdown().await.is_ok());
    Ok(())
}

#[tokio::test]
async fn wallet_shield_enforces_daily_cap_and_unlimited_bypasses_and_ota_checks_loopback()
-> TestResult {
    let dir = tempdir()?;
    let engine = InProcessEngine::open_for_test(dir.path(), http_clients::provider_client()?)?;

    // Save a key on OpenAI (non-loopback) and set daily ceiling to $0.00 to verify Wallet Shield hard block.
    assert!(
        engine
            .set_provider_api_key("openai".to_owned(), "sk-test-wallet-1234".to_owned())
            .await
            .is_ok()
    );
    assert!(
        engine
            .update_provider(
                "openai".to_owned(),
                ProviderPatch {
                    default_model: Some("gpt-4.1".to_owned()),
                    ..ProviderPatch::default()
                }
            )
            .await
            .is_ok()
    );
    let thread = engine
        .create_thread(None, "Budget test".to_owned(), ThreadMode::Chat, None, None)
        .await?;

    let mut settings = engine.load_settings().await?;
    settings.active_provider_id = "openai".to_owned();
    settings.active_model_id = "gpt-4.1".to_owned();
    settings.wallet_daily_ceiling_micros = Some(MoneyMicros::ZERO);
    assert!(engine.save_settings(settings.clone()).await.is_ok());

    let blocked = engine
        .send_and_stream_reply(thread.id.clone(), None, "Should halt".to_owned())
        .await;
    assert_eq!(
        blocked.err().map(|e| e.key),
        Some(DiagnosticKey::WalletCeilingExceeded)
    );

    // Switching to Unlimited (`None`) cleanly passes Wallet Shield (verified via storage stats & OTA).
    settings.wallet_daily_ceiling_micros = None;
    assert!(engine.save_settings(settings).await.is_ok());
    assert_eq!(
        engine.load_settings().await?.wallet_daily_ceiling_micros,
        None
    );

    // Verify the zero-telemetry OTA check against a signed local loopback feed.
    let feed = Some(
        ota::tests::serve_feed(
            ota::tests::FIXTURE_MANIFEST,
            Some(ota::tests::FIXTURE_SIG),
            2,
        )
        .await?,
    );
    assert!(feed.is_some());
    let Some((addr, ota_server)) = feed else {
        return Ok(());
    };
    assert!(
        engine
            .ota_release_key
            .set(ota::tests::FIXTURE_PK.to_owned())
            .is_ok()
    );

    let check = Some(
        engine
            .check_for_updates(Some(format!("http://{addr}/manifest.json")))
            .await?,
    );
    assert!(ota_server.await.is_ok());
    assert_eq!(check.as_ref().map(|c| c.update_available), Some(true));
    assert_eq!(
        check.as_ref().map(|c| c.latest_version.as_str()),
        Some("99.0.0")
    );

    // A UI-forged check (version the core never verified, attacker URL) cannot be staged.
    if let Some(mut forged) = check {
        forged.latest_version = "9.9.9".to_owned();
        forged.download_url = "https://evil.invalid/payload.bin".to_owned();
        let staged = engine.stage_update(forged).await;
        assert_eq!(
            staged.err().and_then(|e| e.detail_code),
            Some("ota_manifest_unverified".to_owned())
        );
    }

    let stats = Some(engine.storage_stats().await?);
    assert_eq!(
        stats.as_ref().map(|s| s.schema_version),
        Some(bistre_storage::CURRENT_SCHEMA_VERSION)
    );
    assert!(engine.shutdown().await.is_ok());
    Ok(())
}

#[tokio::test]
async fn suspend_resume_reconciles_tier2_indeterminate_halt_and_wallet_shield_precedence()
-> TestResult {
    let dir = tempdir()?;
    let engine = InProcessEngine::open_for_test(dir.path(), http_clients::provider_client()?)?;

    let thread = engine
        .create_thread(
            None,
            "Overnight run".to_owned(),
            ThreadMode::Code,
            None,
            None,
        )
        .await?;

    let run1 = Some(engine.storage().create_agent_run(CreateAgentRunParams {
        thread_id: thread.id.clone(),
        parent_run_id: None,
        root_node_id: None,
        mode: ThreadMode::Code,
        max_steps: 20,
        unattended_policy: bistre_protocol::UnattendedPolicy::PauseAndNotify,
        worktree_path: None,
    })?);
    let run2 = Some(engine.storage().create_agent_run(CreateAgentRunParams {
        thread_id: thread.id.clone(),
        parent_run_id: None,
        root_node_id: None,
        mode: ThreadMode::Code,
        max_steps: 20,
        unattended_policy: bistre_protocol::UnattendedPolicy::PauseAndNotify,
        worktree_path: None,
    })?);
    let (Some(run1), Some(run2)) = (run1, run2) else {
        return Ok(());
    };
    let status_of = |id: &str| -> BistreResult<Option<RunStatus>> {
        Ok(engine.storage().get_agent_run(id)?.map(|r| r.status))
    };

    assert!(
        engine
            .storage()
            .record_run_step(
                run2.id.clone(),
                1,
                RunStepKind::ToolCall,
                "shell".to_owned(),
                ToolRiskTier::Tier2ExternalSideEffect,
                "idem-shell-1".to_owned(),
                "running".to_owned(),
                "{\"cmd\":\"deploy\"}".to_owned(),
                "{}".to_owned(),
                0,
                None,
            )
            .is_ok()
    );

    assert!(
        engine
            .notify_power_event(SystemPowerEvent::WillSuspend)
            .await
            .is_ok()
    );
    assert_eq!(status_of(&run1.id)?, Some(RunStatus::SleepPaused));
    assert_eq!(status_of(&run2.id)?, Some(RunStatus::SleepPaused));

    assert_eq!(
        engine
            .notify_power_event(SystemPowerEvent::DidResume)
            .await?,
        2
    );
    assert_eq!(status_of(&run1.id)?, Some(RunStatus::Running));
    assert_eq!(status_of(&run2.id)?, Some(RunStatus::IndeterminateHalt));

    let reconciled = Some(
        engine
            .resolve_indeterminate_run(run2.id.clone(), true)
            .await?,
    );
    assert_eq!(reconciled.map(|r| r.status), Some(RunStatus::Running));

    let mut settings = engine.load_settings().await?;
    settings.wallet_daily_ceiling_micros = Some(MoneyMicros::ZERO);
    assert!(engine.save_settings(settings).await.is_ok());
    assert!(
        engine
            .notify_power_event(SystemPowerEvent::WillSuspend)
            .await
            .is_ok()
    );
    assert!(
        engine
            .notify_power_event(SystemPowerEvent::DidResume)
            .await
            .is_ok()
    );
    assert_eq!(status_of(&run1.id)?, Some(RunStatus::Failed));

    // Verify backoff watchdog respects Retry-After and stops once total budget expires.
    assert!(agent::compute_backoff_wait_ms(0, Some(12), 0, 60, 0).is_some_and(|ms| ms >= 12_000));
    assert_eq!(agent::compute_backoff_wait_ms(4, None, 60, 60, 0), None);
    // A provider asking for longer than the budget left is not retried early.
    assert_eq!(
        agent::compute_backoff_wait_ms(0, Some(400), 0, 300, 0),
        None
    );
    // Jitter differs per run, so runs failing together do not retry together.
    let waits: std::collections::HashSet<u64> = (0..8_u64)
        .filter_map(|seed| agent::compute_backoff_wait_ms(1, None, 0, 300, seed))
        .collect();
    assert!(waits.len() > 1, "{waits:?}");
    assert!(engine.shutdown().await.is_ok());
    Ok(())
}

#[tokio::test]
async fn mid_stream_steering_queue_drives_follow_up_turn_without_cancel() -> TestResult {
    let dir = tempdir()?;
    let engine = InProcessEngine::open_for_test(dir.path(), http_clients::provider_client()?)?;

    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;

    // Serve 2 consecutive SSE turns (initial turn + steered continuation).
    let server = tokio::spawn(async move {
        for turn in 0..2 {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let mut req_buf = [0_u8; 4096];
            assert!(socket.read(&mut req_buf).await.is_ok());
            if turn == 0 {
                tokio::time::sleep(Duration::from_millis(80)).await;
            }
            let body = format!(
                "data: {{\"choices\":[{{\"delta\":{{\"content\":\"Turn {turn} complete\"}}}}]}}\n\n\
                 data: [DONE]\n\n"
            );
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            assert!(socket.write_all(resp.as_bytes()).await.is_ok());
        }
    });

    let custom = engine
        .create_custom_provider(
            "Steer Loopback".to_owned(),
            format!("http://{addr}/v1"),
            "local-model".to_owned(),
            None,
        )
        .await?;
    let mut settings = engine.load_settings().await?;
    settings.active_provider_id = custom.id;
    settings.active_model_id = "local-model".to_owned();
    assert!(engine.save_settings(settings).await.is_ok());

    let thread = engine
        .create_thread(
            None,
            "Steering Test".to_owned(),
            ThreadMode::Chat,
            None,
            None,
        )
        .await?;

    let mut rx = engine.subscribe_events();
    assert!(
        engine
            .send_and_stream_reply(thread.id.clone(), None, "Initial prompt".to_owned())
            .await
            .is_ok()
    );
    // Queue a steering message WHILE turn 0 is streaming!
    assert!(
        engine
            .enqueue_steering(thread.id.clone(), "Also make it concise".to_owned())
            .await
            .is_ok()
    );

    let mut finished = false;
    for _ in 0..80 {
        if let Ok(Ok(EngineEvent::RunFinished { .. })) =
            tokio::time::timeout(Duration::from_secs(3), rx.recv()).await
        {
            finished = true;
            break;
        }
    }
    assert!(server.await.is_ok());
    assert!(finished);

    // Expect 4 nodes: User(initial) -> Assistant(turn 0) -> User(steered) -> Assistant(turn 1).
    let nodes = engine.list_nodes(thread.id.clone()).await?;
    assert_eq!(nodes.len(), 4);
    assert_eq!(nodes[2].content, "Also make it concise");
    assert_eq!(nodes[3].content, "Turn 1 complete");

    // Verify power lease returned cleanly to idle (`active_run_count == 0`).
    let pstatus = Some(engine.power_guard_status().await?);
    assert_eq!(
        pstatus.map(|p| (p.active_run_count, p.keep_awake_active)),
        Some((0, false))
    );
    assert!(engine.shutdown().await.is_ok());
    Ok(())
}

#[tokio::test]
async fn non_read_only_tools_require_an_exact_user_approval() -> BistreResult<()> {
    let dir = tempdir().map_err(|_| BistreError::new(DiagnosticKey::InternalError))?;
    let engine = InProcessEngine::open_for_test(dir.path(), http_clients::provider_client()?)?;
    let ws = dir.path().join("ws");
    std::fs::create_dir_all(&ws).map_err(|_| BistreError::new(DiagnosticKey::InternalError))?;
    std::fs::write(ws.join("a.txt"), "one\n")
        .map_err(|_| BistreError::new(DiagnosticKey::InternalError))?;
    let root = ws.to_string_lossy().into_owned();
    let args = r#"{"path":"a.txt","content":"two\n"}"#.to_owned();

    // Without approval the write is refused before touching the file.
    let denied = engine
        .execute_workspace_tool(root.clone(), "t".into(), "edit".into(), args.clone(), None)
        .await;
    assert_eq!(
        denied.err().map(|e| e.key),
        Some(DiagnosticKey::ToolApprovalRequired)
    );

    // An approval for different arguments cannot be reused.
    let other = engine
        .approve_tool_call(
            "t".into(),
            "edit".into(),
            r#"{"path":"b.txt","start_line":1,"end_line":1,"replacement":"x"}"#.into(),
        )
        .await?;
    let mismatched = engine
        .execute_workspace_tool(
            root.clone(),
            "t".into(),
            "edit".into(),
            args.clone(),
            Some(other),
        )
        .await;
    assert_eq!(
        mismatched.err().map(|e| e.key),
        Some(DiagnosticKey::ToolApprovalRequired)
    );
    assert_eq!(
        std::fs::read_to_string(ws.join("a.txt"))
            .map_err(|_| BistreError::new(DiagnosticKey::InternalError))?,
        "one\n"
    );
    engine.shutdown().await
}

#[tokio::test]
async fn trust_preset_off_denies_all_tools_and_strict_requires_permit_for_reads() -> BistreResult<()>
{
    let tmp = tempdir().map_err(|_| BistreError::new(DiagnosticKey::InternalError))?;
    let ws = tmp.path().join("ws");
    std::fs::create_dir_all(&ws).map_err(|_| BistreError::new(DiagnosticKey::InternalError))?;
    std::fs::write(ws.join("note.txt"), "hello\n")
        .map_err(|_| BistreError::new(DiagnosticKey::InternalError))?;

    let engine = InProcessEngine::open_for_test(tmp.path(), http_clients::provider_client()?)?;
    let root = ws.to_string_lossy().into_owned();
    let read_args = r#"{"path":"note.txt"}"#.to_owned();

    // Off preset fails closed on both approval and execution.
    let mut settings = engine.load_settings().await?;
    settings.trust_preset = bistre_protocol::TrustPreset::Off;
    engine.save_settings(settings.clone()).await?;
    let blocked_approve = engine
        .approve_tool_call("t".into(), "read".into(), read_args.clone())
        .await;
    assert_eq!(
        blocked_approve.err().map(|e| e.key),
        Some(DiagnosticKey::ToolTierBlocked)
    );
    let blocked_exec = engine
        .execute_workspace_tool(
            root.clone(),
            "t".into(),
            "read".into(),
            read_args.clone(),
            None,
        )
        .await;
    assert_eq!(
        blocked_exec.err().map(|e| e.key),
        Some(DiagnosticKey::ToolTierBlocked)
    );

    // Strict preset requires explicit permit even for Tier-0 read.
    settings.trust_preset = bistre_protocol::TrustPreset::Strict;
    engine.save_settings(settings).await?;
    let needs_permit = engine
        .execute_workspace_tool(
            root.clone(),
            "t".into(),
            "read".into(),
            read_args.clone(),
            None,
        )
        .await;
    assert_eq!(
        needs_permit.err().map(|e| e.key),
        Some(DiagnosticKey::ToolApprovalRequired)
    );
    let permit = engine
        .approve_tool_call("t".into(), "read".into(), read_args.clone())
        .await?;
    let allowed = engine
        .execute_workspace_tool(root, "t".into(), "read".into(), read_args, Some(permit))
        .await?;
    assert!(allowed.output_text.contains("hello"));
    engine.shutdown().await
}

/// A reply that ends while the chat's goal is open gets a work check, a marked user turn
/// sending the model back to the goal, at most `MAX_GOAL_CHECKS` times; then the run ends.
#[tokio::test]
async fn an_open_goal_sends_bounded_work_checks() -> TestResult {
    let dir = tempdir()?;
    let engine = InProcessEngine::open_for_test(dir.path(), http_clients::provider_client()?)?;
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let turns = 1 + goal::MAX_GOAL_CHECKS;
    let server = tokio::spawn(async move {
        for turn in 0..turns {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let mut req_buf = [0_u8; 4096];
            assert!(socket.read(&mut req_buf).await.is_ok());
            let body = format!(
                "data: {{\"choices\":[{{\"delta\":{{\"content\":\"Step {turn}\"}}}}]}}\n\n\
                 data: [DONE]\n\n"
            );
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            assert!(socket.write_all(resp.as_bytes()).await.is_ok());
        }
    });
    let custom = engine
        .create_custom_provider(
            "Goal Loopback".to_owned(),
            format!("http://{addr}/v1"),
            "local-model".to_owned(),
            None,
        )
        .await?;
    let mut settings = engine.load_settings().await?;
    settings.active_provider_id = custom.id;
    settings.active_model_id = "local-model".to_owned();
    engine.save_settings(settings).await?;
    let thread = engine
        .create_thread(None, "Goal".to_owned(), ThreadMode::Chat, None, None)
        .await?;
    engine
        .set_thread_goal(thread.id.clone(), "Port the parser".to_owned())
        .await?;
    let mut rx = engine.subscribe_events();
    engine
        .send_and_stream_reply(thread.id.clone(), None, "Start".to_owned())
        .await?;
    let mut finished = false;
    for _ in 0..120 {
        if let Ok(Ok(EngineEvent::RunFinished { .. })) =
            tokio::time::timeout(Duration::from_secs(3), rx.recv()).await
        {
            finished = true;
            break;
        }
    }
    assert!(server.await.is_ok());
    assert!(finished);
    let nodes = engine.list_nodes(thread.id.clone()).await?;
    assert_eq!(
        nodes.len(),
        2 * turns,
        "user, then a reply per turn with a check between"
    );
    let checks: Vec<&NodeRecord> = nodes
        .iter()
        .filter(|n| n.role == NodeRole::User)
        .skip(1)
        .collect();
    assert_eq!(checks.len(), goal::MAX_GOAL_CHECKS);
    assert!(checks.iter().all(|n| {
        n.content == goal::GOAL_CHECK_PROMPT
            && n.provider_meta_json
                .as_deref()
                .is_some_and(|m| m.contains("\"goal_check\":true"))
    }));
    assert_eq!(
        nodes.last().map(|n| n.content.clone()),
        Some(format!("Step {}", turns - 1))
    );
    engine.shutdown().await?;
    Ok(())
}
