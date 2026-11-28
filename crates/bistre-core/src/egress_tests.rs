//! Engine-level egress tests (custom headers pinned to the provider).

use std::time::Duration;

use bistre_protocol::{DiagnosticKey, EngineEvent, ProviderDialect, ThreadMode, ThreadPatch};
use tokio::sync::broadcast;

use crate::test_support::{MockServer, Scripted};

pub(crate) type TestResult = Result<(), Box<dyn std::error::Error>>;

const EVENT_WAIT: Duration = Duration::from_secs(15);

pub(crate) fn chat_reply(text: &str) -> Scripted {
    let chunk = serde_json::json!({
        "choices": [{ "delta": { "content": text }, "finish_reason": "stop" }],
        "usage": { "prompt_tokens": 3, "completion_tokens": 1 }
    });
    Scripted::sse(format!("data: {chunk}\n\ndata: [DONE]\n\n"))
}

pub(crate) async fn diagnostics_until_finished(
    rx: &mut broadcast::Receiver<EngineEvent>,
    thread_id: &str,
) -> Result<Vec<(DiagnosticKey, Option<String>)>, Box<dyn std::error::Error>> {
    let deadline = tokio::time::Instant::now() + EVENT_WAIT;
    let mut seen = Vec::new();
    loop {
        match tokio::time::timeout_at(deadline, rx.recv()).await?? {
            EngineEvent::DiagnosticRaised { key, detail_code } => seen.push((key, detail_code)),
            EngineEvent::RunFinished { thread_id: t, .. } if t == thread_id => return Ok(seen),
            _ => {}
        }
    }
}

pub(crate) struct LocalChat {
    dir: tempfile::TempDir,
    pub(crate) engine: std::sync::Arc<crate::InProcessEngine>,
    pub(crate) provider_id: String,
    pub(crate) thread_id: String,
}

pub(crate) async fn local_chat(
    server: &MockServer,
) -> Result<LocalChat, Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let engine =
        crate::InProcessEngine::open_for_test(dir.path(), crate::http_clients::provider_client()?)?;
    let provider = engine
        .create_provider(
            "Local".to_owned(),
            ProviderDialect::CustomOpenAi,
            format!("{}/v1", server.base()),
            "m".to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("k".to_owned()),
        )
        .await?;
    let thread = engine
        .create_thread(None, "t".to_owned(), ThreadMode::Chat, None, None)
        .await?;
    engine
        .update_thread(
            thread.id.clone(),
            ThreadPatch {
                provider_id_override: Some(Some(provider.id.clone())),
                model_id_override: Some(Some("m".to_owned())),
                ..ThreadPatch::default()
            },
        )
        .await?;
    Ok(LocalChat {
        dir,
        engine,
        provider_id: provider.id,
        thread_id: thread.id,
    })
}

/// A stored custom header that is not a valid header stops the request with a
/// diagnostic instead of being dropped silently.
#[tokio::test]
async fn an_invalid_stored_header_stops_the_request_instead_of_being_dropped() -> TestResult {
    let server = MockServer::start(vec![chat_reply("hi")]).await?;
    let chat = local_chat(&server).await?;
    let headers = serde_json::json!({ "X-Team": "a\u{200b}b\nX-Injected: 1" }).to_string();
    chat.engine
        .set_kv_meta(
            format!("provider.overrides:{}", chat.provider_id),
            serde_json::json!({ "headers_json": headers, "body_json": "" }).to_string(),
        )
        .await?;
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await?;
    let diags = diagnostics_until_finished(&mut rx, &chat.thread_id).await?;
    assert!(
        diags
            .iter()
            .any(|(k, _)| *k == DiagnosticKey::ProviderHeadersInvalid),
        "{diags:?}"
    );
    assert!(server.finish().await.is_empty(), "nothing was sent");
    Ok(())
}

/// Headers are validated when saved, and a new provider origin clears them.
#[tokio::test]
async fn headers_are_validated_on_save_and_cleared_when_the_origin_changes() -> TestResult {
    let server = MockServer::start(Vec::new()).await?;
    let chat = local_chat(&server).await?;
    let refused = chat
        .engine
        .save_provider_overrides(
            chat.provider_id.clone(),
            r#"{"Authorization":"Bearer stolen"}"#.to_owned(),
            String::new(),
        )
        .await;
    assert_eq!(
        refused.err().map(|e| e.key),
        Some(DiagnosticKey::ProviderHeadersInvalid)
    );
    chat.engine
        .save_provider_overrides(
            chat.provider_id.clone(),
            r#"{"X-Team":"blue"}"#.to_owned(),
            r#"{"seed":1}"#.to_owned(),
        )
        .await?;
    let stored = |engine: &crate::InProcessEngine| {
        crate::provider_prefs::load_provider_overrides(&engine.storage, &chat.provider_id)
    };
    assert_eq!(stored(&chat.engine)?.headers.len(), 1);

    chat.engine
        .update_provider(
            chat.provider_id.clone(),
            bistre_protocol::ProviderPatch {
                base_url: Some("https://other.example/v1".to_owned()),
                ..bistre_protocol::ProviderPatch::default()
            },
        )
        .await?;
    let after = stored(&chat.engine)?;
    assert!(
        after.headers.is_empty(),
        "headers never follow a new origin"
    );
    assert!(after.body_fields.is_some(), "body fields are kept");
    drop(server.finish().await);
    Ok(())
}

/// A chat pinned to a provider that is turned off fails with a clear notice; it never
/// falls back to another (possibly paid) provider.
#[tokio::test]
async fn a_pinned_provider_that_is_off_never_falls_back_to_another() -> TestResult {
    let pinned = MockServer::start(Vec::new()).await?;
    let other = MockServer::start(vec![chat_reply("from the fallback")]).await?;
    let chat = local_chat(&pinned).await?;
    chat.engine
        .create_provider(
            "Other".to_owned(),
            ProviderDialect::CustomOpenAi,
            format!("{}/v1", other.base()),
            "m".to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("k2".to_owned()),
        )
        .await?;
    chat.engine
        .update_provider(
            chat.provider_id.clone(),
            bistre_protocol::ProviderPatch {
                is_enabled: Some(false),
                ..bistre_protocol::ProviderPatch::default()
            },
        )
        .await?;
    let sent = chat
        .engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await;
    assert_eq!(
        sent.err().map(|e| e.key),
        Some(DiagnosticKey::ProviderPinnedUnavailable)
    );
    assert!(
        other.finish().await.is_empty(),
        "nothing went to another provider"
    );
    drop(pinned.finish().await);
    Ok(())
}

/// Shutdown wakes a run waiting in backoff, so it records its final state before
/// storage closes instead of being aborted mid-wait.
#[tokio::test]
async fn shutdown_wakes_a_run_waiting_in_backoff() -> TestResult {
    let server = MockServer::start(vec![
        Scripted::json(429, &serde_json::json!({ "error": "slow down" }))
            .with_header("retry-after", "60"),
    ])
    .await?;
    let chat = local_chat(&server).await?;
    let db = chat.dir.path().join("bistre.sqlite");
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await?;
    // Wait until the run is in its backoff wait.
    let deadline = tokio::time::Instant::now() + EVENT_WAIT;
    loop {
        if let EngineEvent::DiagnosticRaised { key, detail_code } =
            tokio::time::timeout_at(deadline, rx.recv()).await??
            && key == DiagnosticKey::RunBackoffWaiting
        {
            // The notice says which try this is.
            let detail = detail_code.unwrap_or_default();
            assert!(detail.contains(";attempt=1;"), "{detail}");
            break;
        }
    }
    chat.engine.shutdown().await?;
    let storage = bistre_storage::StorageHandle::open(&db)?;
    let runs = storage.list_agent_runs(Some(&chat.thread_id), false, 10)?;
    assert!(
        runs.iter()
            .all(|r| r.status != bistre_protocol::RunStatus::Running
                && r.status != bistre_protocol::RunStatus::BackoffWait),
        "the run recorded a final state: {:?}",
        runs.iter().map(|r| r.status).collect::<Vec<_>>()
    );
    drop(server.finish().await);
    Ok(())
}

/// Regenerate during a stream stops the old run completely before the new one starts,
/// so the old run can never commit after (or over) the new reply.
#[tokio::test]
async fn regenerate_mid_stream_finishes_the_old_run_before_starting_the_new() -> TestResult {
    let partial = serde_json::json!({ "choices": [{ "delta": { "content": "old " } }] });
    let server = MockServer::start(vec![
        Scripted::sse(format!("data: {partial}\n\n")).then_hang(),
        chat_reply("new"),
    ])
    .await?;
    let chat = local_chat(&server).await?;
    let mut rx = chat.engine.subscribe_events();
    let user = chat
        .engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await?;
    // Wait for the first run to start; then give it time to send its request and read the
    // stalled partial stream (the last delta of a stalled stream is not flushed yet).
    let deadline = tokio::time::Instant::now() + EVENT_WAIT;
    let mut order: Vec<String> = Vec::new();
    loop {
        if let EngineEvent::RunStarted { node_id, .. } =
            tokio::time::timeout_at(deadline, rx.recv()).await??
        {
            order.push(format!("start:{node_id}"));
            break;
        }
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    chat.engine
        .regenerate_reply(chat.thread_id.clone(), user.id)
        .await?;
    let mut finished = 0;
    while finished < 2 {
        match tokio::time::timeout_at(deadline, rx.recv()).await?? {
            EngineEvent::RunStarted { node_id, .. } => order.push(format!("start:{node_id}")),
            EngineEvent::RunFinished { node_id, .. } => {
                order.push(format!("finish:{node_id}"));
                finished += 1;
            }
            _ => {}
        }
    }
    let first = order
        .first()
        .and_then(|s| s.strip_prefix("start:"))
        .ok_or("no first run")?
        .to_owned();
    let first_finished = order
        .iter()
        .position(|e| *e == format!("finish:{first}"))
        .ok_or("first run never finished")?;
    let second_started = order
        .iter()
        .skip(1)
        .position(|e| e.starts_with("start:"))
        .map(|p| p + 1)
        .ok_or("second run never started")?;
    assert!(
        first_finished < second_started,
        "the old run must finish before the new one starts: {order:?}"
    );
    drop(server.finish().await);
    Ok(())
}

/// Web sources in a reply are stored with it, listed for the chat, and never sent back to
/// a model when the history is replayed.
#[tokio::test]
async fn reply_sources_are_kept_for_the_chat_and_never_replayed() -> TestResult {
    let cited = serde_json::json!({
        "choices": [{
            "delta": {
                "content": "It rained.",
                "annotations": [{
                    "type": "url_citation",
                    "url_citation": { "url": "https://weather.example/today", "title": "Weather" }
                }]
            },
            "finish_reason": "stop"
        }],
        "usage": { "prompt_tokens": 3, "completion_tokens": 2 }
    });
    let server = MockServer::start(vec![
        Scripted::sse(format!("data: {cited}\n\ndata: [DONE]\n\n")),
        chat_reply("ok"),
    ])
    .await?;
    let chat = local_chat(&server).await?;
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "weather?".to_owned())
        .await?;
    diagnostics_until_finished(&mut rx, &chat.thread_id).await?;
    let listed = chat
        .engine
        .list_thread_grounding(chat.thread_id.clone())
        .await?;
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].sources[0].url(), "https://weather.example/today");
    assert_eq!(listed[0].sources[0].title(), "Weather");

    let head = chat
        .engine
        .list_nodes(chat.thread_id.clone())
        .await?
        .last()
        .map(|n| n.id.clone());
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), head, "and tomorrow?".to_owned())
        .await?;
    diagnostics_until_finished(&mut rx, &chat.thread_id).await?;
    let seen = server.finish().await;
    let replay = String::from_utf8_lossy(&seen.get(1).ok_or("second request")?.body).into_owned();
    assert!(
        replay.contains("It rained."),
        "the reply text is replayed: {replay}"
    );
    assert!(
        !replay.contains("weather.example") && !replay.contains("grounding"),
        "sources are UI data only: {replay}"
    );
    Ok(())
}

/// A reply cut by the output limit is kept and says so (the app offers Continue).
#[tokio::test]
async fn a_truncated_reply_raises_the_truncated_notice() -> TestResult {
    let chunk = serde_json::json!({
        "choices": [{ "delta": { "content": "half" }, "finish_reason": "length" }],
        "usage": { "prompt_tokens": 3, "completion_tokens": 1 }
    });
    let server = MockServer::start(vec![Scripted::sse(format!(
        "data: {chunk}\n\ndata: [DONE]\n\n"
    ))])
    .await?;
    let chat = local_chat(&server).await?;
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await?;
    let diags = diagnostics_until_finished(&mut rx, &chat.thread_id).await?;
    assert!(
        diags
            .iter()
            .any(|(k, _)| *k == DiagnosticKey::ProviderReplyTruncated),
        "{diags:?}"
    );
    drop(server.finish().await);
    Ok(())
}

fn anthropic_frames(text: &str, stop: &str) -> String {
    format!(
        "data: {}

data: {}

data: {}

data: {}

data: {}

",
        serde_json::json!({"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":3,"output_tokens":0}}}),
        serde_json::json!({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
        serde_json::json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":text}}),
        serde_json::json!({"type":"message_delta","delta":{"stop_reason":stop},"usage":{"output_tokens":2}}),
        serde_json::json!({"type":"message_stop"}),
    )
}

/// A chat on a local Anthropic-format provider; returns the temp dir (keep it alive), the
/// engine, and the chat id.
async fn anthropic_chat(
    server: &MockServer,
) -> Result<
    (
        tempfile::TempDir,
        std::sync::Arc<crate::InProcessEngine>,
        String,
    ),
    Box<dyn std::error::Error>,
> {
    let dir = tempfile::tempdir()?;
    let engine =
        crate::InProcessEngine::open_for_test(dir.path(), crate::http_clients::provider_client()?)?;
    let provider = engine
        .create_provider(
            "Local Anthropic".to_owned(),
            ProviderDialect::Anthropic,
            format!("{}/v1", server.base()),
            "m".to_owned(),
            "claude".to_owned(),
            String::new(),
            Some("k".to_owned()),
        )
        .await?;
    let thread = engine
        .create_thread(None, "t".to_owned(), ThreadMode::Chat, None, None)
        .await?;
    engine
        .update_thread(
            thread.id.clone(),
            ThreadPatch {
                provider_id_override: Some(Some(provider.id.clone())),
                model_id_override: Some(Some("m".to_owned())),
                ..ThreadPatch::default()
            },
        )
        .await?;
    Ok((dir, engine, thread.id))
}

/// Anthropic `pause_turn` resumes by itself: the paused reply goes back as the last
/// assistant turn and the model continues it.
#[tokio::test]
async fn a_paused_anthropic_turn_resumes_by_itself() -> TestResult {
    let server = MockServer::start(vec![
        Scripted::sse(anthropic_frames("Searching...", "pause_turn")),
        Scripted::sse(anthropic_frames(" found it.", "end_turn")),
    ])
    .await?;
    let (_dir, engine, thread_id) = anthropic_chat(&server).await?;
    let mut rx = engine.subscribe_events();
    engine
        .send_and_stream_reply(thread_id.clone(), None, "find it".to_owned())
        .await?;
    // Two runs' worth of streams end in one RunFinished once the turn completes.
    diagnostics_until_finished(&mut rx, &thread_id).await?;
    let seen = server.finish().await;
    assert_eq!(seen.len(), 2, "the paused turn was sent back once");
    let second = String::from_utf8_lossy(&seen[1].body).into_owned();
    assert!(
        second.contains("Searching..."),
        "the paused reply is resent: {second}"
    );
    Ok(())
}

/// A run stopped by the step limit says so; it never ends as a silent "complete".
#[tokio::test]
async fn a_run_stopped_by_the_step_limit_says_so() -> TestResult {
    let steps = usize::try_from(crate::engine_runs::MAX_RUN_STEPS)? + 1;
    let script = (0..steps)
        .map(|_| Scripted::sse(anthropic_frames("more", "pause_turn")))
        .collect();
    let server = MockServer::start(script).await?;
    let (_dir, engine, thread_id) = anthropic_chat(&server).await?;
    let mut rx = engine.subscribe_events();
    engine
        .send_and_stream_reply(thread_id.clone(), None, "go".to_owned())
        .await?;
    let diags = diagnostics_until_finished(&mut rx, &thread_id).await?;
    assert!(
        diags
            .iter()
            .any(|(k, _)| *k == DiagnosticKey::RunStepLimitReached),
        "{diags:?}"
    );
    drop(server.finish().await);
    Ok(())
}

/// The last text of a burst is shown within a frame even when the provider then pauses;
/// it never waits for the next chunk (or the 90 s idle timeout).
#[tokio::test]
async fn the_last_text_before_a_pause_is_shown_at_once() -> TestResult {
    let frame = |t: &str| {
        format!(
            "data: {}\n\n",
            serde_json::json!({ "choices": [{ "delta": { "content": t } }] })
        )
    };
    let server = MockServer::start(vec![
        Scripted::sse(format!("{}{}", frame("first "), frame("second"))).then_hang(),
    ])
    .await?;
    let chat = local_chat(&server).await?;
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let mut shown = String::new();
    while !shown.contains("second") {
        let Ok(ev) = tokio::time::timeout_at(deadline, rx.recv()).await else {
            break;
        };
        if let EngineEvent::DeltaBatch { chunks, .. } = ev? {
            for c in chunks {
                shown.push_str(&c.text_delta);
            }
        }
    }
    chat.engine
        .cancel_active_run(chat.thread_id.clone())
        .await?;
    assert!(shown.contains("second"), "shown so far: {shown:?}");
    drop(server.finish().await);
    Ok(())
}

/// A due scheduled job starts a real run: a chat named after the job, sent its prompt.
#[tokio::test]
async fn a_due_scheduled_job_starts_a_run_with_its_prompt() -> TestResult {
    let server = MockServer::start(vec![chat_reply("digest ready")]).await?;
    let chat = local_chat(&server).await?;
    let job = bistre_protocol::CronJobRecord {
        id: "job-1".to_owned(),
        name: "Morning digest".to_owned(),
        workspace_id: "default".to_owned(),
        assistant_id: String::new(),
        schedule_expr: "every 1d".to_owned(),
        prompt: "Summarize my open tasks".to_owned(),
        mode: ThreadMode::Chat,
        unattended_policy: bistre_protocol::UnattendedPolicy::PauseAndNotify,
        use_worktree: false,
        enabled: true,
        next_run_ms: 0,
        last_run_id: None,
        last_status: "idle".to_owned(),
    };
    let mut rx = chat.engine.subscribe_events();
    let thread_id = chat.engine.start_scheduled_run(job.clone()).await?;
    diagnostics_until_finished(&mut rx, &thread_id).await?;
    let threads = chat.engine.list_threads(None).await?;
    assert!(
        threads
            .iter()
            .any(|t| t.id == thread_id && t.title == "Morning digest")
    );
    let seen = server.finish().await;
    let body = String::from_utf8_lossy(&seen.first().ok_or("no request")?.body).into_owned();
    assert!(body.contains("Summarize my open tasks"), "{body}");
    Ok(())
}

/// for a chat whose own settings and assistant name no model, the
/// model under Settings > Default models wins over the model last picked in the picker.
#[tokio::test]
async fn the_default_model_setting_wins_over_the_last_pick() -> TestResult {
    let picked = MockServer::start(vec![chat_reply("from the last pick")]).await?;
    let default = MockServer::start(vec![chat_reply("from the default")]).await?;
    let chat = local_chat(&picked).await?;
    let default_provider = chat
        .engine
        .create_provider(
            "Default".to_owned(),
            ProviderDialect::CustomOpenAi,
            format!("{}/v1", default.base()),
            "d".to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("k".to_owned()),
        )
        .await?;
    let mut settings = chat.engine.load_settings().await?;
    settings.active_provider_id.clone_from(&chat.provider_id);
    "m".clone_into(&mut settings.active_model_id);
    chat.engine.save_settings(settings).await?;
    chat.engine
        .set_kv_meta(
            "settings.default_models".to_owned(),
            serde_json::json!({ "globalProviderId": default_provider.id, "globalModelId": "d" })
                .to_string(),
        )
        .await?;
    let thread = chat
        .engine
        .create_thread(None, "new".to_owned(), ThreadMode::Chat, None, None)
        .await?;
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(thread.id.clone(), None, "hello".to_owned())
        .await?;
    diagnostics_until_finished(&mut rx, &thread.id).await?;
    let seen = default.finish().await;
    assert_eq!(seen.len(), 1, "the default provider got the request");
    assert!(String::from_utf8_lossy(&seen[0].body).contains("\"model\":\"d\""));
    assert_eq!(picked.finish().await.len(), 0);
    Ok(())
}

/// Per-model overrides feed the context breakdown limit and the wire reply limit.
#[tokio::test]
async fn provider_advanced_model_overrides_feed_limits() -> TestResult {
    let server = MockServer::start(vec![chat_reply("ok")]).await?;
    let chat = local_chat(&server).await?;
    chat.engine
        .set_kv_meta(
            format!("provider.adv:{}", chat.provider_id),
            serde_json::json!({
                "modelOverrides": {
                    "m": {
                        "contextLimit": 64_000,
                        "maxOutputTokens": 1234,
                        "inputPerMillion": "10.00",
                        "outputPerMillion": "20.00"
                    }
                }
            })
            .to_string(),
        )
        .await?;
    let mut rx = chat.engine.subscribe_events();
    let user_node = chat
        .engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await?;
    diagnostics_until_finished(&mut rx, &chat.thread_id).await?;
    let seen = server.finish().await;
    let body: serde_json::Value = serde_json::from_slice(&seen.first().ok_or("no request")?.body)?;
    assert_eq!(body["max_tokens"], 1234, "{body}");
    let breakdown = chat
        .engine
        .context_breakdown(chat.thread_id.clone(), user_node.id.clone(), String::new())
        .await?;
    assert_eq!(breakdown.limit_tokens, Some(64_000));
    assert_eq!(breakdown.reserve_tokens, 9_600, "the default point is 85 %");

    // The user's auto-shorten point sets what stays free; out-of-range values clamp.
    for (at_percent, reserve) in [(60, 25_600), (5, 32_000), (100, 3_200)] {
        let mut settings = chat.engine.load_settings().await?;
        settings.auto_compact_at_percent = at_percent;
        chat.engine.save_settings(settings).await?;
        let breakdown = chat
            .engine
            .context_breakdown(chat.thread_id.clone(), user_node.id.clone(), String::new())
            .await?;
        assert_eq!(breakdown.reserve_tokens, reserve, "at {at_percent} %");
    }
    Ok(())
}

/// A provider's default thinking effort applies when the global effort is left at Auto.
#[tokio::test]
async fn provider_advanced_default_thinking_effort_reaches_the_wire() -> TestResult {
    let server = MockServer::start(vec![chat_reply("ok")]).await?;
    let chat = local_chat(&server).await?;
    chat.engine
        .set_kv_meta(
            format!("provider.adv:{}", chat.provider_id),
            serde_json::json!({ "defaultThinkingEffort": "high" }).to_string(),
        )
        .await?;
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "think".to_owned())
        .await?;
    diagnostics_until_finished(&mut rx, &chat.thread_id).await?;
    let seen = server.finish().await;
    let body: serde_json::Value = serde_json::from_slice(&seen.first().ok_or("no request")?.body)?;
    assert_eq!(body["reasoning_effort"], "high", "{body}");
    Ok(())
}

/// Fetching models honors Advanced > Authentication (and a Custom provider's API format).
#[tokio::test]
async fn provider_advanced_fetch_models_uses_auth_mode_and_custom_dialect() -> TestResult {
    let server = MockServer::start(vec![Scripted::json(
        200,
        &serde_json::json!({ "data": [{ "id": "m1", "display_name": "Model One" }] }),
    )])
    .await?;
    let chat = local_chat(&server).await?;
    chat.engine
        .set_kv_meta(
            format!("provider.adv:{}", chat.provider_id),
            serde_json::json!({
                "customDialect": "anthropic_messages",
                "authHeaderMode": "query_param"
            })
            .to_string(),
        )
        .await?;
    let models = chat.engine.fetch_provider_models(chat.provider_id).await?;
    assert_eq!(models.len(), 1);
    assert_eq!(models[0].id, "m1");
    let seen = server.finish().await;
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].path, "/v1/models?key=k");
    assert_eq!(seen[0].header("authorization"), None);
    assert_eq!(seen[0].header("x-api-key"), None);
    assert!(seen[0].header("anthropic-version").is_some());
    Ok(())
}
