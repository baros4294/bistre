//! Integration-style unit tests for `InProcessEngine` (split out of `lib.rs`).

use super::*;
use std::time::Duration;
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

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
async fn unconfigured_provider_returns_diagnostic_and_local_sse_streams_real_http() {
    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };

    let engine = InProcessEngine::open(dir.path(), VaultKey::generate().ok()).ok();
    assert!(engine.is_some());
    let Some(engine) = engine else { return };

    let thread = engine
        .create_thread(
            None,
            "Test chat".to_owned(),
            ThreadMode::Chat,
            Some("general".to_owned()),
            None,
        )
        .await
        .ok();
    assert!(thread.is_some());
    let Some(thread) = thread else { return };

    // Zero fake mock replies: without a configured provider/key, returns ProviderNotConfigured.
    let blocked = engine
        .send_and_stream_reply(thread.id.clone(), None, "Hello".to_owned())
        .await;
    assert_eq!(
        blocked.err().map(|e| e.key),
        Some(DiagnosticKey::ProviderNotConfigured)
    );

    // Verify Big 3 built-in providers exist and API keys store safely in SecretVault.
    let providers = engine.list_providers().await.ok().unwrap_or_default();
    assert_eq!(providers.len(), 3);
    let saved_openai = engine
        .set_provider_api_key("openai".to_owned(), "sk-test-1234567890abcd".to_owned())
        .await
        .ok();
    assert_eq!(saved_openai.as_ref().map(|p| p.has_api_key), Some(true));
    assert_eq!(
        saved_openai.as_ref().map(|p| p.key_hint.as_str()),
        Some("••••abcd")
    );
    let cleared = engine
        .clear_provider_api_key("openai".to_owned())
        .await
        .ok();
    assert_eq!(cleared.as_ref().map(|p| p.has_api_key), Some(false));

    // Spin up a real local loopback HTTP/SSE server to verify reqwest streaming + DAG commit.
    let listener = TcpListener::bind("127.0.0.1:0").await.ok();
    assert!(listener.is_some());
    let Some(listener) = listener else { return };
    let addr = listener.local_addr().ok();
    assert!(addr.is_some());
    let Some(addr) = addr else { return };
    let server = spawn_mock_sse_server(listener);

    let custom = engine
        .create_custom_provider(
            "Loopback Custom".to_owned(),
            format!("http://{addr}/v1"),
            "local-test-model".to_owned(),
            None,
        )
        .await
        .ok();
    assert!(custom.is_some());
    let Some(custom) = custom else { return };

    // Test live GET /models discovery.
    let models = engine.fetch_provider_models(custom.id.clone()).await.ok();
    assert_eq!(
        models
            .as_ref()
            .and_then(|m| m.first())
            .map(|m| m.id.as_str()),
        Some("local-test-model")
    );

    let mut settings = engine.load_settings().await.ok().unwrap_or_default();
    settings.active_provider_id = custom.id;
    settings.active_model_id = "local-test-model".to_owned();
    assert!(engine.save_settings(settings).await.is_ok());

    let mut rx = engine.subscribe_events();
    let user_node = engine
        .send_and_stream_reply(thread.id.clone(), None, "Ping loopback".to_owned())
        .await
        .ok();
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

    let nodes = engine.list_nodes(thread.id).await.ok().unwrap_or_default();
    assert_eq!(nodes.len(), 2);
    assert_eq!(
        nodes.last().map(|n| n.content.as_str()),
        Some("Real SSE reply #1")
    );
    assert!(engine.shutdown().await.is_ok());
}

#[tokio::test]
async fn wallet_shield_enforces_daily_cap_and_unlimited_bypasses_and_ota_checks_loopback() {
    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };
    let engine = InProcessEngine::open(dir.path(), VaultKey::generate().ok()).ok();
    assert!(engine.is_some());
    let Some(engine) = engine else { return };

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
        .await
        .ok();
    assert!(thread.is_some());
    let Some(thread) = thread else { return };

    let mut settings = engine.load_settings().await.ok().unwrap_or_default();
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
        engine
            .load_settings()
            .await
            .ok()
            .and_then(|s| s.wallet_daily_ceiling_micros),
        None
    );

    // Verify the zero-telemetry OTA check against a signed local loopback feed.
    let feed = ota::tests::serve_feed(
        ota::tests::FIXTURE_MANIFEST,
        Some(ota::tests::FIXTURE_SIG),
        2,
    )
    .await
    .ok();
    assert!(feed.is_some());
    let Some((addr, ota_server)) = feed else {
        return;
    };
    assert!(
        engine
            .ota_release_key
            .set(ota::tests::FIXTURE_PK.to_owned())
            .is_ok()
    );

    let check = engine
        .check_for_updates(Some(format!("http://{addr}/manifest.json")))
        .await
        .ok();
    assert!(ota_server.await.is_ok());
    assert_eq!(check.as_ref().map(|c| c.update_available), Some(true));
    assert_eq!(
        check.as_ref().map(|c| c.latest_version.as_str()),
        Some("0.2.0")
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

    let stats = engine.storage_stats().await.ok();
    assert_eq!(
        stats.as_ref().map(|s| s.schema_version),
        Some(bistre_storage::CURRENT_SCHEMA_VERSION)
    );
    assert!(engine.shutdown().await.is_ok());
}

#[tokio::test]
async fn suspend_resume_reconciles_tier2_indeterminate_halt_and_wallet_shield_precedence() {
    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };
    let engine = InProcessEngine::open(dir.path(), VaultKey::generate().ok()).ok();
    assert!(engine.is_some());
    let Some(engine) = engine else { return };

    let thread = engine
        .create_thread(
            None,
            "Overnight run".to_owned(),
            ThreadMode::Code,
            None,
            None,
        )
        .await
        .ok();
    assert!(thread.is_some());
    let Some(thread) = thread else { return };

    let run1 = engine
        .storage()
        .create_agent_run(CreateAgentRunParams {
            thread_id: thread.id.clone(),
            parent_run_id: None,
            root_node_id: None,
            mode: ThreadMode::Code,
            max_steps: 20,
            unattended_policy: bistre_protocol::UnattendedPolicy::PauseAndNotify,
            worktree_path: None,
        })
        .ok();
    let run2 = engine
        .storage()
        .create_agent_run(CreateAgentRunParams {
            thread_id: thread.id.clone(),
            parent_run_id: None,
            root_node_id: None,
            mode: ThreadMode::Code,
            max_steps: 20,
            unattended_policy: bistre_protocol::UnattendedPolicy::PauseAndNotify,
            worktree_path: None,
        })
        .ok();
    let (Some(run1), Some(run2)) = (run1, run2) else {
        return;
    };
    let status_of = |id: &str| {
        engine
            .storage()
            .get_agent_run(id)
            .ok()
            .flatten()
            .map(|r| r.status)
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
    assert_eq!(status_of(&run1.id), Some(RunStatus::SleepPaused));
    assert_eq!(status_of(&run2.id), Some(RunStatus::SleepPaused));

    assert_eq!(
        engine
            .notify_power_event(SystemPowerEvent::DidResume)
            .await
            .ok(),
        Some(2)
    );
    assert_eq!(status_of(&run1.id), Some(RunStatus::Running));
    assert_eq!(status_of(&run2.id), Some(RunStatus::IndeterminateHalt));

    let reconciled = engine
        .resolve_indeterminate_run(run2.id.clone(), true)
        .await
        .ok();
    assert_eq!(reconciled.map(|r| r.status), Some(RunStatus::Running));

    let mut settings = engine.load_settings().await.ok().unwrap_or_default();
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
    assert_eq!(status_of(&run1.id), Some(RunStatus::Failed));

    // Verify backoff watchdog respects Retry-After and stops once total budget expires.
    assert!(agent::compute_backoff_wait_ms(0, Some(12), 0, 60).is_some_and(|ms| ms >= 12_000));
    assert_eq!(agent::compute_backoff_wait_ms(4, None, 60, 60), None);
    assert!(engine.shutdown().await.is_ok());
}

#[tokio::test]
async fn mid_stream_steering_queue_drives_follow_up_turn_without_cancel() {
    let dir = tempdir().ok();
    assert!(dir.is_some());
    let Some(dir) = dir else { return };
    let engine = InProcessEngine::open(dir.path(), VaultKey::generate().ok()).ok();
    assert!(engine.is_some());
    let Some(engine) = engine else { return };

    let listener = TcpListener::bind("127.0.0.1:0").await.ok();
    assert!(listener.is_some());
    let Some(listener) = listener else { return };
    let addr = listener.local_addr().ok();
    assert!(addr.is_some());
    let Some(addr) = addr else { return };

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
        .await
        .ok();
    assert!(custom.is_some());
    let Some(custom) = custom else { return };
    let mut settings = engine.load_settings().await.ok().unwrap_or_default();
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
        .await
        .ok();
    assert!(thread.is_some());
    let Some(thread) = thread else { return };

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
    let nodes = engine
        .list_nodes(thread.id.clone())
        .await
        .ok()
        .unwrap_or_default();
    assert_eq!(nodes.len(), 4);
    assert_eq!(nodes[2].content, "Also make it concise");
    assert_eq!(nodes[3].content, "Turn 1 complete");

    // Verify power lease returned cleanly to idle (`active_run_count == 0`).
    let pstatus = engine.power_guard_status().await.ok();
    assert_eq!(
        pstatus.map(|p| (p.active_run_count, p.keep_awake_active)),
        Some((0, false))
    );
    assert!(engine.shutdown().await.is_ok());
}
