//! Unit tests for `providers.rs`.
#![expect(
    clippy::disallowed_methods,
    reason = "tests map errors to empty values that the following assertions reject"
)]
use super::*;

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn terminal_events_per_dialect() {
    assert!(is_terminal_event(
        ProviderDialect::OpenAi,
        r#"{"type":"response.completed"}"#
    ));
    assert!(!is_terminal_event(
        ProviderDialect::OpenAi,
        r#"{"type":"response.output_text.delta","delta":"x"}"#
    ));
    assert!(is_terminal_event(
        ProviderDialect::Anthropic,
        r#"{"type":"message_stop"}"#
    ));
    assert!(is_terminal_event(
        ProviderDialect::GoogleGemini,
        r#"{"event_type":"interaction.completed","interaction":{"status":"completed"}}"#
    ));
    assert!(is_terminal_event(
        ProviderDialect::GoogleGemini,
        r#"{"candidates":[{"finishReason":"STOP"}]}"#
    ));
    assert!(!is_terminal_event(
        ProviderDialect::GoogleGemini,
        r#"{"event_type":"step.stop","index":0}"#
    ));
    assert!(is_terminal_event(
        ProviderDialect::CustomOpenAi,
        r#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
    ));
    assert!(!is_terminal_event(
        ProviderDialect::CustomOpenAi,
        r#"{"choices":[{"delta":{"content":"x"},"finish_reason":null}]}"#
    ));
    assert!(is_terminal_event(ProviderDialect::CustomOpenAi, "[DONE]"));

    let mut usage = UsageMetrics::default();
    merge_sse_usage(
        ProviderDialect::GoogleGemini,
        r#"{"event_type":"interaction.completed","interaction":{"usage":{"total_input_tokens":12,"total_output_tokens":34,"total_cached_tokens":5}}}"#,
        &mut usage,
    );
    assert_eq!(
        (
            usage.input_tokens,
            usage.output_tokens,
            usage.cached_input_tokens
        ),
        (12, 34, 5)
    );
}

#[test]
fn extracts_sse_deltas_for_all_big_three_and_custom_dialects() {
    assert_eq!(
        extract_sse_delta(
            ProviderDialect::OpenAi,
            r#"{"type":"response.output_text.delta","delta":"hello "}"#
        )
        .as_deref(),
        Some("hello ")
    );
    assert_eq!(
        extract_sse_delta(
            ProviderDialect::GoogleGemini,
            r#"{"candidates":[{"content":{"parts":[{"text":"gemini fallback"}]}}]}"#
        )
        .as_deref(),
        Some("gemini fallback")
    );
    assert_eq!(
        extract_sse_delta(
            ProviderDialect::Anthropic,
            r#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"claude chunk"}}"#
        )
        .as_deref(),
        Some("claude chunk")
    );
    assert_eq!(
        extract_sse_delta(
            ProviderDialect::CustomOpenAi,
            r#"{"choices":[{"delta":{"content":"custom chunk"}}]}"#
        )
        .as_deref(),
        Some("custom chunk")
    );
}

#[test]
fn parses_live_models_payloads_without_hardcoding() {
    let openai = json!({ "data": [{ "id": "gpt-4.1" }, { "id": "o4-mini" }] });
    let parsed = parse_models_payload(ProviderDialect::OpenAi, &openai);
    assert_eq!(parsed.len(), 2);

    let gemini =
        json!({ "models": [{ "name": "models/gemini-2.5-pro", "displayName": "Gemini 2.5 Pro" }] });
    let g = parse_models_payload(ProviderDialect::GoogleGemini, &gemini);
    assert_eq!(g.first().map(|m| m.id.as_str()), Some("gemini-2.5-pro"));

    let ollama = json!({ "models": [{ "name": "qwen2.5-coder:7b" }] });
    let o = parse_models_payload(ProviderDialect::CustomOpenAi, &ollama);
    assert_eq!(o.first().map(|m| m.id.as_str()), Some("qwen2.5-coder:7b"));
}

#[test]
fn merges_sse_usage_tokens_across_all_dialects() {
    let mut oa = UsageMetrics::default();
    merge_sse_usage(
        ProviderDialect::OpenAi,
        r#"{"type":"response.completed","response":{"usage":{"input_tokens":120,"output_tokens":45}}}"#,
        &mut oa,
    );
    assert_eq!((oa.input_tokens, oa.output_tokens), (120, 45));

    let mut ant = UsageMetrics::default();
    merge_sse_usage(
        ProviderDialect::Anthropic,
        r#"{"type":"message_start","message":{"usage":{"input_tokens":80}}}"#,
        &mut ant,
    );
    merge_sse_usage(
        ProviderDialect::Anthropic,
        r#"{"type":"message_delta","usage":{"output_tokens":32}}"#,
        &mut ant,
    );
    assert_eq!((ant.input_tokens, ant.output_tokens), (80, 32));

    let mut gem = UsageMetrics::default();
    merge_sse_usage(
        ProviderDialect::GoogleGemini,
        r#"{"usageMetadata":{"promptTokenCount":50,"candidatesTokenCount":25}}"#,
        &mut gem,
    );
    assert_eq!((gem.input_tokens, gem.output_tokens), (50, 25));
}

#[test]
fn extracts_thinking_deltas_across_all_dialects() {
    assert_eq!(
        extract_sse_thinking_delta(
            ProviderDialect::OpenAi,
            r#"{"type":"response.reasoning_summary_text.delta","delta":"step 1"}"#
        )
        .as_deref(),
        Some("step 1")
    );
    assert_eq!(
        extract_sse_thinking_delta(
            ProviderDialect::Anthropic,
            r#"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"pondering"}}"#
        )
        .as_deref(),
        Some("pondering")
    );
    assert_eq!(
        extract_sse_thinking_delta(
            ProviderDialect::GoogleGemini,
            r#"{"candidates":[{"content":{"parts":[{"thought":true,"text":"gem thought"}]}}]}"#
        )
        .as_deref(),
        Some("gem thought")
    );
    assert_eq!(
        extract_sse_thinking_delta(
            ProviderDialect::CustomOpenAi,
            r#"{"choices":[{"delta":{"reasoning_content":"deepseek chain"}}]}"#
        )
        .as_deref(),
        Some("deepseek chain")
    );
}

#[tokio::test]
async fn dispatch_fails_over_keys_then_heals_http_400_once_per_step() -> TestResult {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let Ok(addr) = listener.local_addr() else {
        return Ok(());
    };
    let server = tokio::spawn(async move {
        let mut seen = Vec::new();
        for _ in 0..3 {
            let Ok((mut sock, _)) = listener.accept().await else {
                break;
            };
            let mut buf = vec![0_u8; 16 * 1024];
            let n = sock.read(&mut buf).await.unwrap_or(0);
            let req = String::from_utf8_lossy(&buf[..n]).to_ascii_lowercase();
            seen.push(req.clone());
            let (status, body) = if req.contains("bearer key-a") {
                ("401 Unauthorized", r#"{"error":"bad key"}"#)
            } else if req.contains("stream_options") {
                (
                    "400 Bad Request",
                    r#"{"error":{"message":"Unknown parameter: stream_options"}}"#,
                )
            } else {
                (
                    "200 OK",
                    "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",
                )
            };
            let resp = format!(
                "HTTP/1.1 {status}\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            assert!(sock.write_all(resp.as_bytes()).await.is_ok());
        }
        seen
    });

    let http = build_http_client()?;
    let provider = ProviderProfile {
        id: "p".to_owned(),
        name: "Local".to_owned(),
        dialect: ProviderDialect::CustomOpenAi,
        base_url: format!("http://{addr}/v1"),
        default_model: "m".to_owned(),
        key_hint: String::new(),
        has_api_key: true,
        is_enabled: true,
        is_builtin: false,
        use_server_state_cache: false,
        icon_slug: String::new(),
        custom_icon_path: String::new(),
        created_at_ms: 0,
        updated_at_ms: 0,
    };
    // nextest runs each test in its own process, so the round-robin starts at key-a.
    let ring = KeyRing::new(vec![
        zeroize::Zeroizing::new("key-a".to_owned()),
        zeroize::Zeroizing::new("key-b".to_owned()),
    ]);
    let cancel = AtomicBool::new(false);
    let history = vec![NodeRecord {
        id: "u".to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role: NodeRole::User,
        content: "hello".to_owned(),
        provider_meta_json: None,
        created_at_ms: 0,
    }];
    let outcome = stream_completion(
        &http,
        &provider,
        &ring,
        "m",
        "",
        &history,
        GenerationParams::default(),
        true,
        &cancel,
        |_| {},
    )
    .await;
    let seen = server.await.unwrap_or_default();
    let (text, notices) = outcome.map_or_else(
        |_| (String::new(), Vec::new()),
        |o| (o.full_text, o.notices),
    );
    assert_eq!(text, "hi");
    assert!(notices.iter().any(
        |(k, d)| *k == DiagnosticKey::ProviderRequestHealed && d == "heal_strip_stream_options"
    ));
    assert!(
        !seen.last().is_some_and(|r| r.contains("stream_options")),
        "healed resend must drop stream_options"
    );
    Ok(())
}

#[tokio::test]
async fn a_stream_that_breaks_after_output_is_kept_not_retried()
-> Result<(), Box<dyn std::error::Error>> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let server = tokio::spawn(async move {
        if let Ok((mut sock, _)) = listener.accept().await {
            let mut buf = [0_u8; 8192];
            let _read = sock.read(&mut buf).await;
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n";
            // Promise far more bytes than are sent, then drop: the body read fails mid-stream.
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 100000\r\n\r\n";
            let _w = sock.write_all(head.as_bytes()).await;
            let _w = sock.write_all(body.as_bytes()).await;
            let _f = sock.flush().await;
        }
    });
    let http = build_http_client()?;
    let provider = ProviderProfile {
        id: "p".to_owned(),
        name: "Local".to_owned(),
        dialect: ProviderDialect::CustomOpenAi,
        base_url: format!("http://{addr}/v1"),
        default_model: "m".to_owned(),
        key_hint: String::new(),
        has_api_key: true,
        is_enabled: true,
        is_builtin: false,
        use_server_state_cache: false,
        icon_slug: String::new(),
        custom_icon_path: String::new(),
        created_at_ms: 0,
        updated_at_ms: 0,
    };
    let ring = KeyRing::new(vec![zeroize::Zeroizing::new("k".to_owned())]);
    let cancel = AtomicBool::new(false);
    let history = vec![NodeRecord {
        id: "u".to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role: NodeRole::User,
        content: "hello".to_owned(),
        provider_meta_json: None,
        created_at_ms: 0,
    }];
    let outcome = stream_completion(
        &http,
        &provider,
        &ring,
        "m",
        "",
        &history,
        GenerationParams::default(),
        true,
        &cancel,
        |_| {},
    )
    .await?;
    server.await?;
    assert_eq!(outcome.full_text, "partial");
    assert!(
        outcome.interrupted,
        "a broken stream with output is an interrupted reply, not an error"
    );
    Ok(())
}

#[tokio::test]
async fn stop_interrupts_a_request_waiting_for_its_first_token()
-> Result<(), Box<dyn std::error::Error>> {
    use std::sync::Arc;
    use tokio::io::AsyncReadExt;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    // Accepts and reads the request, then never answers (a provider stuck before headers).
    let server = tokio::spawn(async move {
        if let Ok((mut sock, _)) = listener.accept().await {
            let mut buf = [0_u8; 8192];
            let _read = sock.read(&mut buf).await;
            tokio::time::sleep(Duration::from_secs(30)).await;
        }
    });
    let http = build_http_client()?;
    let provider = ProviderProfile {
        id: "p".to_owned(),
        name: "Local".to_owned(),
        dialect: ProviderDialect::CustomOpenAi,
        base_url: format!("http://{addr}/v1"),
        default_model: "m".to_owned(),
        key_hint: String::new(),
        has_api_key: true,
        is_enabled: true,
        is_builtin: false,
        use_server_state_cache: false,
        icon_slug: String::new(),
        custom_icon_path: String::new(),
        created_at_ms: 0,
        updated_at_ms: 0,
    };
    let ring = KeyRing::new(vec![zeroize::Zeroizing::new("k".to_owned())]);
    let cancel = Arc::new(AtomicBool::new(false));
    let history = vec![NodeRecord {
        id: "u".to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role: NodeRole::User,
        content: "hello".to_owned(),
        provider_meta_json: None,
        created_at_ms: 0,
    }];
    let stopper = Arc::clone(&cancel);
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(150)).await;
        stopper.store(true, Ordering::SeqCst);
    });
    let started = std::time::Instant::now();
    let outcome = stream_completion(
        &http,
        &provider,
        &ring,
        "m",
        "",
        &history,
        GenerationParams::default(),
        true,
        &cancel,
        |_| {},
    )
    .await?;
    assert!(outcome.cancelled);
    // Stop at 150 ms plus at most one poll interval, far below the 300 s first-token budget.
    assert!(started.elapsed() < Duration::from_millis(150) + CANCEL_POLL_INTERVAL * 4);
    server.abort();
    Ok(())
}

/// Parchment `c7f9ca55`/`39fdc2e4`/`83592e4f`: opaque reasoning signatures replayed to another
/// provider or step caused HTTP 400s. Bistre replays text only; this pins that down for every
/// dialect, including a reply produced by a different provider.
#[test]
fn replay_never_carries_reasoning_signatures_or_provider_metadata() {
    let secret_meta = serde_json::json!({
        "thinking_signature": "SIG-OPAQUE-123",
        "thought_signature": "SIG-OPAQUE-123",
        "reasoning_content": "hidden chain SIG-OPAQUE-123",
        "provider": "anthropic"
    })
    .to_string();
    let history = vec![
        NodeRecord {
            id: "u1".to_owned(),
            thread_id: "t".to_owned(),
            parent_id: None,
            role: NodeRole::User,
            content: "question".to_owned(),
            provider_meta_json: None,
            created_at_ms: 0,
        },
        NodeRecord {
            id: "a1".to_owned(),
            thread_id: "t".to_owned(),
            parent_id: Some("u1".to_owned()),
            role: NodeRole::Assistant,
            content: "answer".to_owned(),
            provider_meta_json: Some(secret_meta),
            created_at_ms: 1,
        },
        NodeRecord {
            id: "u2".to_owned(),
            thread_id: "t".to_owned(),
            parent_id: Some("a1".to_owned()),
            role: NodeRole::User,
            content: "follow-up".to_owned(),
            provider_meta_json: None,
            created_at_ms: 2,
        },
    ];
    for dialect in [
        ProviderDialect::OpenAi,
        ProviderDialect::GoogleGemini,
        ProviderDialect::Anthropic,
        ProviderDialect::CustomOpenAi,
    ] {
        let wire = build_stream_request(
            dialect,
            "https://example.invalid/v1",
            "m",
            "",
            &history,
            GenerationParams::default(),
            false,
        );
        let mut bodies = vec![wire.body.map_or_else(String::new, |b| b.to_string())];
        if let Some(fallback) = wire.fallback {
            bodies.push(fallback.body.map_or_else(String::new, |b| b.to_string()));
        }
        for body in bodies {
            assert!(
                body.contains("answer"),
                "{dialect:?} must replay the reply text"
            );
            assert!(
                !body.contains("SIG-OPAQUE-123"),
                "{dialect:?} leaked provider metadata"
            );
        }
    }
}
