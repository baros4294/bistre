//! Unit tests for `providers.rs`.
use super::*;
use bistre_protocol::NodeRole;

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
    use crate::test_support::{MockServer, Scripted, keys, provider, user_turn};
    let server = MockServer::start(vec![
        Scripted::json(401, &json!({ "error": "bad key" })),
        Scripted::json(
            400,
            &json!({ "error": { "message": "Unknown parameter: stream_options" } }),
        ),
        Scripted::sse(
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",
        ),
    ])
    .await?;
    let http = build_http_client()?;
    let profile = provider(
        ProviderDialect::CustomOpenAi,
        &format!("{}/v1", server.base()),
    );
    // nextest runs each test in its own process, so the round-robin starts at key-a.
    let ring = keys(&["key-a", "key-b"]);
    let cancel = AtomicBool::new(false);
    let outcome = stream_completion(
        &http,
        &profile,
        &ring,
        "m",
        "",
        &user_turn("hello"),
        GenerationParams::default(),
        true,
        &cancel,
        |_| {},
    )
    .await?;
    let seen = server.finish().await;
    assert_eq!(outcome.full_text, "hi");
    assert!(outcome.notices.iter().any(
        |(k, d)| *k == DiagnosticKey::ProviderRequestHealed && d == "heal_strip_stream_options"
    ));
    let auth: Vec<_> = seen.iter().map(|r| r.header("authorization")).collect();
    assert_eq!(
        auth,
        [
            Some("Bearer key-a"),
            Some("Bearer key-b"),
            Some("Bearer key-b")
        ]
    );
    assert!(seen[1].body_json()?.get("stream_options").is_some());
    assert!(
        seen[2].body_json()?.get("stream_options").is_none(),
        "healed resend must drop stream_options"
    );
    Ok(())
}

#[tokio::test]
async fn a_stream_that_breaks_after_output_is_kept_not_retried() -> TestResult {
    use crate::test_support::{MockServer, Scripted, keys, provider, user_turn};
    // Promise far more bytes than are sent, then drop: the body read fails mid-stream.
    let server = MockServer::start(vec![
        Scripted::sse("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n")
            .truncated(100_000),
    ])
    .await?;
    let http = build_http_client()?;
    let profile = provider(
        ProviderDialect::CustomOpenAi,
        &format!("{}/v1", server.base()),
    );
    let cancel = AtomicBool::new(false);
    let outcome = stream_completion(
        &http,
        &profile,
        &keys(&["k"]),
        "m",
        "",
        &user_turn("hello"),
        GenerationParams::default(),
        true,
        &cancel,
        |_| {},
    )
    .await?;
    assert_eq!(server.finish().await.len(), 1, "never retried");
    assert_eq!(outcome.full_text, "partial");
    assert!(
        outcome.interrupted,
        "a broken stream with output is an interrupted reply, not an error"
    );
    Ok(())
}

#[tokio::test(start_paused = true)]
async fn stop_interrupts_a_request_waiting_for_its_first_token() -> TestResult {
    use std::sync::Arc;

    use crate::test_support::{MockServer, Scripted, keys, provider, user_turn};
    // Accepts and reads the request, then never answers (a provider stuck before headers).
    let server = MockServer::start(vec![Scripted::hang()]).await?;
    let http = build_http_client()?;
    let profile = provider(
        ProviderDialect::CustomOpenAi,
        &format!("{}/v1", server.base()),
    );
    let cancel = Arc::new(AtomicBool::new(false));
    let stopper = Arc::clone(&cancel);
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(150)).await;
        stopper.store(true, Ordering::SeqCst);
    });
    // Paused clock: elapsed is virtual time, so the bound is exact rather than load-dependent.
    let started = tokio::time::Instant::now();
    let outcome = stream_completion(
        &http,
        &profile,
        &keys(&["k"]),
        "m",
        "",
        &user_turn("hello"),
        GenerationParams::default(),
        true,
        &cancel,
        |_| {},
    )
    .await?;
    assert!(outcome.cancelled);
    // Stop at 150 ms plus at most one poll interval, far below the 300 s first-token budget.
    assert!(started.elapsed() <= Duration::from_millis(150) + CANCEL_POLL_INTERVAL);
    drop(server.finish().await);
    Ok(())
}

/// Opaque reasoning signatures replayed to another provider or wire format must be stripped
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

#[test]
fn reasoning_effort_reaches_each_dialect_in_its_own_wire_field() {
    use bistre_protocol::ReasoningEffort;
    let history: Vec<NodeRecord> = Vec::new();
    let body = |dialect: ProviderDialect, effort: ReasoningEffort| {
        let params = GenerationParams {
            reasoning_effort: effort,
            ..GenerationParams::default()
        };
        let req = build_stream_request(dialect, "https://x", "m", "", &history, params, false);
        req.body.unwrap_or(Value::Null)
    };

    let openai = body(ProviderDialect::OpenAi, ReasoningEffort::High);
    assert_eq!(openai["reasoning"]["effort"], "high");
    assert_eq!(openai["reasoning"]["summary"], "auto");
    assert_eq!(
        body(ProviderDialect::OpenAi, ReasoningEffort::Off)["reasoning"]["effort"],
        "none"
    );
    assert_eq!(
        body(ProviderDialect::CustomOpenAi, ReasoningEffort::Max)["reasoning_effort"],
        "max"
    );

    let anthropic = body(ProviderDialect::Anthropic, ReasoningEffort::ExtraHigh);
    assert_eq!(anthropic["thinking"]["type"], "adaptive");
    assert_eq!(anthropic["output_config"]["effort"], "xhigh");
    let anthropic_off = body(ProviderDialect::Anthropic, ReasoningEffort::Off);
    assert_eq!(anthropic_off["thinking"]["type"], "disabled");
    assert!(anthropic_off.get("output_config").is_none());

    // Gemini: Interactions (primary) and generateContent (fallback); no `max` level exists.
    let gemini = build_stream_request(
        ProviderDialect::GoogleGemini,
        "https://x",
        "m",
        "",
        &history,
        GenerationParams {
            reasoning_effort: ReasoningEffort::Max,
            ..GenerationParams::default()
        },
        false,
    );
    let primary = gemini.body.clone().unwrap_or(Value::Null);
    assert_eq!(primary["generation_config"]["thinking_level"], "xhigh");
    assert_eq!(primary["generation_config"]["thinking_summaries"], "auto");
    let fallback = gemini.fallback.and_then(|f| f.body).unwrap_or(Value::Null);
    assert_eq!(
        fallback["generationConfig"]["thinkingConfig"]["thinkingLevel"],
        "XHIGH"
    );

    // The model default sends no effort field in any dialect.
    for dialect in [
        ProviderDialect::OpenAi,
        ProviderDialect::CustomOpenAi,
        ProviderDialect::Anthropic,
        ProviderDialect::GoogleGemini,
    ] {
        let b = body(dialect, ReasoningEffort::ModelDefault).to_string();
        for field in ["reasoning", "output_config", "thinking", "thinking_level"] {
            assert!(!b.contains(field), "{dialect:?} sent {field}: {b}");
        }
    }
}

#[test]
fn gemini_generate_content_thoughts_never_leak_into_full_text_and_plain_json_works() {
    let thought_chunk = r#"{"candidates":[{"content":{"parts":[{"thought":true,"text":"secret chain"},{"text":"visible answer"}]}}]}"#;
    assert_eq!(
        extract_sse_thinking_delta(ProviderDialect::GoogleGemini, thought_chunk).as_deref(),
        Some("secret chain")
    );
    assert_eq!(
        extract_sse_delta(ProviderDialect::GoogleGemini, thought_chunk).as_deref(),
        Some("visible answer")
    );

    // Non-streaming plain-JSON fallbacks across OpenAI Responses, Anthropic, and CustomOpenAi.
    let oai_plain = r#"{"id":"resp_1","output":[{"type":"message","content":[{"type":"output_text","text":"Hi OAI"}]}]}"#;
    assert_eq!(
        extract_sse_delta(ProviderDialect::OpenAi, oai_plain).as_deref(),
        Some("Hi OAI")
    );
    let anth_plain = r#"{"type":"message","content":[{"type":"text","text":"Hi Claude"}]}"#;
    assert_eq!(
        extract_sse_delta(ProviderDialect::Anthropic, anth_plain).as_deref(),
        Some("Hi Claude")
    );
    let custom_plain = r#"{"choices":[{"message":{"content":"Hi Local"}}]}"#;
    assert_eq!(
        extract_sse_delta(ProviderDialect::CustomOpenAi, custom_plain).as_deref(),
        Some("Hi Local")
    );
}

/// R6: a provider that redirects to another host never receives a second, keyed request
/// there. reqwest strips `Authorization` across hosts but not `x-api-key` / `x-goog-api-key`,
/// and a 307 re-sends the body, so the provider client follows no redirects at all.
#[tokio::test]
async fn a_cross_host_redirect_never_forwards_the_key_or_the_body() -> TestResult {
    use crate::test_support::{MockServer, Scripted, keys, provider, user_turn};
    let elsewhere = MockServer::start(vec![Scripted::sse(
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
    )])
    .await?;
    let other_port = elsewhere
        .base()
        .rsplit(':')
        .next()
        .unwrap_or_default()
        .to_owned();
    let origin = MockServer::start(vec![Scripted::status(307).with_header(
        "Location",
        &format!("http://localhost:{other_port}/v1/messages"),
    )])
    .await?;
    let http = build_http_client()?;
    let profile = provider(ProviderDialect::Anthropic, &format!("{}/v1", origin.base()));
    let cancel = AtomicBool::new(false);
    let outcome = stream_completion(
        &http,
        &profile,
        &keys(&["sk-ant-secret"]),
        "m",
        "",
        &user_turn("private prompt"),
        GenerationParams::default(),
        true,
        &cancel,
        |_| {},
    )
    .await;
    assert!(outcome.is_err(), "a redirect is an error, not a reply");
    assert_eq!(origin.finish().await.len(), 1);
    let forwarded = elsewhere.finish().await;
    assert!(
        forwarded.is_empty(),
        "redirect target received {} request(s), key header: {:?}",
        forwarded.len(),
        forwarded.first().and_then(|r| r.header("x-api-key"))
    );
    Ok(())
}

/// R8: when the stream buffer cap trips after text was already shown, the reply keeps that
/// text and is marked interrupted. It is never retried (that would show and bill it twice).
#[tokio::test]
async fn a_buffer_cap_after_output_marks_the_reply_interrupted_instead_of_retrying() -> TestResult {
    use crate::test_support::{MockServer, Scripted, keys, provider, user_turn};
    let mut body = String::from("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: ");
    body.push_str(&"a".repeat(crate::sse::MAX_SSE_BUFFER_BYTES + 1024));
    let server = MockServer::start(vec![Scripted::sse(body)]).await?;
    let http = build_http_client()?;
    let profile = provider(
        ProviderDialect::CustomOpenAi,
        &format!("{}/v1", server.base()),
    );
    let cancel = AtomicBool::new(false);
    let outcome = stream_completion(
        &http,
        &profile,
        &keys(&["k"]),
        "m",
        "",
        &user_turn("hello"),
        GenerationParams::default(),
        true,
        &cancel,
        |_| {},
    )
    .await;
    drop(server.finish().await);
    let outcome = outcome?;
    assert_eq!(outcome.full_text, "hi");
    assert!(outcome.interrupted, "kept and marked interrupted");
    Ok(())
}

/// R12: a provider file uploaded for one request under `store: false` is deleted even when
/// the stream then fails, not only on success.
#[tokio::test]
async fn an_ephemeral_upload_is_deleted_when_the_stream_fails() -> TestResult {
    use crate::test_support::{MockServer, Scripted, keys, provider, user_turn};
    let dir = tempfile::tempdir()?;
    let bytes = vec![7_u8; crate::attachments::MAX_INLINE_BYTES + 1];
    let hash = blake3::hash(&bytes).to_hex().to_string();
    std::fs::create_dir_all(dir.path().join("attachments"))?;
    std::fs::write(
        dir.path().join("attachments").join(format!("{hash}.bin")),
        &bytes,
    )?;
    let meta = json!({ "attachments": [{
        "id": "att_1",
        "name": "big.bin",
        "mime_type": "application/octet-stream",
        "blob_rel_path": format!("attachments/{hash}.bin"),
        "size_bytes": bytes.len(),
        "blake3_hex": hash,
    }]});
    let mut history = user_turn("look");
    for node in &mut history {
        if node.role == NodeRole::User {
            node.provider_meta_json = Some(meta.to_string());
        }
    }
    let server = MockServer::start(vec![
        Scripted::json(200, &json!({ "id": "file_1" })),
        Scripted::sse("").truncated(4096),
        Scripted::json(200, &json!({ "deleted": true })),
    ])
    .await?;
    let http = build_http_client()?;
    let profile = provider(ProviderDialect::OpenAi, &format!("{}/v1", server.base()));
    let cancel = AtomicBool::new(false);
    let outcome = stream_completion_with_attachments(
        &http,
        &profile,
        &keys(&["k"]),
        "m",
        "",
        &history,
        GenerationParams::default(),
        true,
        Some(dir.path()),
        &cancel,
        |_| {},
        |_| {},
    )
    .await;
    let seen = server.finish().await;
    assert!(outcome.is_err(), "nothing arrived: the stream failed");
    let calls: Vec<(String, String)> = seen
        .iter()
        .map(|r| (r.method.clone(), r.path.clone()))
        .collect();
    assert!(
        calls.contains(&("DELETE".to_owned(), "/v1/files/file_1".to_owned())),
        "{calls:?}"
    );
    Ok(())
}

/// S4 / P7: a Gemini base URL that already ends in `/v1beta` (the old preset) never produces
/// `/v1beta/v1beta/...`; every dialect's endpoint comes from one descriptor.
#[test]
fn gemini_base_with_version_never_doubles_the_path() {
    use std::collections::HashMap;
    let history = crate::test_support::user_turn("hi");
    let opts = StreamRequestOptions::default();
    for base in [
        "https://generativelanguage.googleapis.com",
        "https://generativelanguage.googleapis.com/",
        "https://generativelanguage.googleapis.com/v1beta",
        "https://generativelanguage.googleapis.com/v1beta/",
    ] {
        let wire = build_stream_request_full(
            ProviderDialect::GoogleGemini,
            base,
            "gemini-x",
            "",
            &history,
            GenerationParams::default(),
            false,
            None,
            &HashMap::<String, String>::new(),
            &opts,
        );
        assert_eq!(
            wire.url, "https://generativelanguage.googleapis.com/v1beta/interactions",
            "{base}"
        );
        let fallback = wire.fallback.map_or_else(String::new, |f| f.url);
        assert_eq!(
            fallback,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-x:streamGenerateContent?alt=sse",
            "{base}"
        );
    }
    assert_eq!(
        ProviderDialect::GoogleGemini.default_endpoint_path(),
        "/v1beta/interactions"
    );
    assert_eq!(
        ProviderDialect::OpenAi.default_endpoint_path(),
        "/responses"
    );
    assert_eq!(
        crate::credentials::resolve_base_url(ProviderDialect::Anthropic, " "),
        ProviderDialect::Anthropic.default_base_url()
    );
}

/// P8: the URLs shown for a provider are the ones it is called at.
#[test]
fn resolved_endpoints_match_the_urls_that_are_called() {
    use crate::credentials::resolve_endpoint;
    let gemini = resolve_endpoint(
        ProviderDialect::GoogleGemini,
        "https://generativelanguage.googleapis.com/v1beta/",
    );
    assert_eq!(
        gemini.chat_url,
        "https://generativelanguage.googleapis.com/v1beta/interactions"
    );
    assert_eq!(
        gemini.models_url,
        "https://generativelanguage.googleapis.com/v1beta/models"
    );
    let custom = resolve_endpoint(ProviderDialect::CustomOpenAi, "");
    assert_eq!(
        custom.chat_url,
        "http://127.0.0.1:11434/v1/chat/completions"
    );
    assert_eq!(custom.models_url, "http://127.0.0.1:11434/v1/models");
}

async fn stream_once(
    script: Vec<crate::test_support::Scripted>,
) -> Result<(BistreResult<StreamOutcome>, usize), Box<dyn std::error::Error>> {
    use crate::test_support::{MockServer, keys, provider, user_turn};
    let server = MockServer::start(script).await?;
    let http = build_http_client()?;
    let profile = provider(
        ProviderDialect::CustomOpenAi,
        &format!("{}/v1", server.base()),
    );
    let cancel = AtomicBool::new(false);
    let res = stream_completion(
        &http,
        &profile,
        &keys(&["k"]),
        "m",
        "",
        &user_turn("hello"),
        GenerationParams::default(),
        true,
        &cancel,
        |_| {},
    )
    .await;
    let seen = server.finish().await.len();
    Ok((res, seen))
}

/// R42 + P4: an HTTP 200 whose body is a plain JSON error fails at once with the provider's
/// reason; it is never classified as a dropped stream and retried for minutes.
#[tokio::test]
async fn a_plain_json_error_body_fails_with_the_providers_reason() -> TestResult {
    use crate::test_support::Scripted;
    let (res, requests) = stream_once(vec![Scripted::json(
        200,
        &json!({ "error": { "message": "model 'm' not found", "code": "model_not_found" } }),
    )])
    .await?;
    let err = res.err().ok_or("must fail")?;
    assert_eq!(err.key, DiagnosticKey::ProviderRequestFailed);
    let detail = err.detail_code.unwrap_or_default();
    assert!(detail.contains("stream_error:model_not_found"), "{detail}");
    assert!(detail.contains("reason=model 'm' not found"), "{detail}");
    assert!(!crate::engine_runs::is_auto_retryable(
        &BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, detail)
    ));
    assert_eq!(requests, 1);
    Ok(())
}

/// R10: a reply cut by the output limit says so (it is not a silent "complete").
#[tokio::test]
async fn a_reply_cut_by_the_output_limit_reports_length() -> TestResult {
    use crate::test_support::Scripted;
    let (res, _) = stream_once(vec![Scripted::sse(
        "data: {\"choices\":[{\"delta\":{\"content\":\"half\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n",
    )])
    .await?;
    let out = res?;
    assert_eq!(out.full_text, "half");
    assert_eq!(out.finish, Some(crate::finish::FinishKind::Length));
    Ok(())
}

/// P4: an HTTP error keeps the provider's own reason in the diagnostic detail.
#[tokio::test]
async fn an_http_error_keeps_the_providers_reason() -> TestResult {
    use crate::test_support::Scripted;
    let (res, _) = stream_once(vec![Scripted::json(
        404,
        &json!({ "error": { "message": "The model `m` does not exist" } }),
    )])
    .await?;
    let detail = res.err().and_then(|e| e.detail_code).unwrap_or_default();
    assert!(
        detail.contains("reason=The model `m` does not exist"),
        "{detail}"
    );
    Ok(())
}

/// G1 (`OpenAI` prompt-caching guide, read 2026-11-26): newer models append top-level
/// `instructions` after `input`, so the system prompt goes first in `input` as a `developer`
/// message, keeping the cached prefix stable. G2: replayed `function_call` items carry the
/// documented `status: "completed"` they had when the API returned them.
#[test]
fn openai_responses_put_the_system_prompt_first_and_replay_call_status() {
    let call_meta = json!({ "tool_calls": [
        { "call_id": "c1", "name": "read", "arguments_json": "{}" }
    ]})
    .to_string();
    let result_meta = json!({ "tool_result": { "call_id": "c1", "name": "read" } }).to_string();
    let node = |id: &str, role, content: &str, meta: Option<String>| NodeRecord {
        id: id.to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role,
        content: content.to_owned(),
        provider_meta_json: meta,
        created_at_ms: 1,
    };
    let history = vec![
        node("u", NodeRole::User, "hi", None),
        node("a", NodeRole::Assistant, "", Some(call_meta)),
        node("r", NodeRole::Tool, "ok", Some(result_meta)),
    ];
    let wire = build_stream_request(
        ProviderDialect::OpenAi,
        "https://example.invalid/v1",
        "m",
        "Be brief.",
        &history,
        GenerationParams::default(),
        false,
    );
    let body = wire.body.unwrap_or_default();
    assert!(body.get("instructions").is_none(), "{body}");
    assert_eq!(body["input"][0]["role"], "developer");
    assert_eq!(body["input"][0]["content"], "Be brief.");
    let call = body["input"]
        .as_array()
        .and_then(|items| items.iter().find(|i| i["type"] == "function_call"))
        .cloned()
        .unwrap_or_default();
    assert_eq!(call["status"], "completed", "{body}");
}

/// R7: a chained `OpenAI` request does not resend the system prompt (it stays in the stored
/// conversation, per the prompt-caching guide) and carries `previous_response_id`.
#[test]
fn a_chained_openai_request_does_not_resend_the_system_prompt() {
    let history = vec![NodeRecord {
        id: "u".to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role: NodeRole::User,
        content: "two".to_owned(),
        provider_meta_json: None,
        created_at_ms: 1,
    }];
    let opts = StreamRequestOptions {
        previous_server_id: Some("resp_1"),
        ..StreamRequestOptions::default()
    };
    let wire = build_stream_request_full(
        ProviderDialect::OpenAi,
        "https://example.invalid/v1",
        "m",
        "Be brief.",
        &history,
        GenerationParams::default(),
        true,
        None,
        &HashMap::<String, String>::new(),
        &opts,
    );
    let body = wire.body.unwrap_or_default();
    assert_eq!(body["previous_response_id"], "resp_1");
    assert_eq!(body["input"].as_array().map(Vec::len), Some(1), "{body}");
    assert_eq!(body["input"][0]["role"], "user");
}

/// R7: chaining right after a tool call still sends the tool's result (its call is in the
/// stored reply, before the chain point).
#[test]
fn a_chained_request_after_a_tool_call_sends_the_result() {
    let call_meta = json!({ "tool_calls": [
        { "call_id": "c1", "name": "read", "arguments_json": "{}" }
    ]})
    .to_string();
    let result_meta = json!({ "tool_result": { "call_id": "c1", "name": "read" } }).to_string();
    let node = |id: &str, role, content: &str, meta: Option<String>| NodeRecord {
        id: id.to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role,
        content: content.to_owned(),
        provider_meta_json: meta,
        created_at_ms: 1,
    };
    let history = vec![
        node("u", NodeRole::User, "hi", None),
        node("a", NodeRole::Assistant, "", Some(call_meta)),
        node("r", NodeRole::Tool, "ok", Some(result_meta)),
    ];
    let opts = StreamRequestOptions {
        previous_server_id: Some("resp_1"),
        chain_first_new_index: 2,
        ..StreamRequestOptions::default()
    };
    let wire = build_stream_request_full(
        ProviderDialect::OpenAi,
        "https://example.invalid/v1",
        "m",
        "",
        &history,
        GenerationParams::default(),
        true,
        None,
        &HashMap::<String, String>::new(),
        &opts,
    );
    let body = wire.body.unwrap_or_default();
    assert_eq!(body["input"].as_array().map(Vec::len), Some(1), "{body}");
    assert_eq!(body["input"][0]["type"], "function_call_output");
    assert_eq!(body["input"][0]["call_id"], "c1");
}

/// A wrong URL (404) is never retried (opencode #52330): it fails at once.
#[tokio::test]
async fn a_not_found_endpoint_is_never_retried() -> TestResult {
    use crate::test_support::Scripted;
    let (res, requests) = stream_once(vec![Scripted::json(404, &json!({}))]).await?;
    let err = res.err().ok_or("must fail")?;
    assert!(!crate::engine_runs::is_auto_retryable(&err), "{err:?}");
    assert_eq!(requests, 1);
    Ok(())
}

/// P19: a stream that went silent while the app was in the background ends when the app comes
/// back (kept as an interrupted reply), instead of waiting out the 90 s idle timeout.
#[tokio::test]
async fn a_stream_stalled_across_a_resume_ends_when_the_app_comes_back() -> TestResult {
    use crate::test_support::Scripted;
    let script = vec![
        Scripted::sse("data: {\"choices\":[{\"delta\":{\"content\":\"half\"}}]}\n\n").then_hang(),
    ];
    let resume = tokio::spawn(async {
        tokio::time::sleep(Duration::from_millis(800)).await;
        note_app_resumed();
    });
    let (res, _) = tokio::time::timeout(Duration::from_secs(10), stream_once(script))
        .await
        .map_err(|_| "the stalled stream was still waiting after the resume")??;
    resume.await?;
    let out = res?;
    assert_eq!(out.full_text, "half");
    assert!(out.interrupted);
    Ok(())
}
