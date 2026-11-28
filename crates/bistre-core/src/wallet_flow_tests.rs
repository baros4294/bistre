//! Engine-level Wallet Shield tests through a paid (non-loopback) provider.
//!
//! The provider URL uses the `paid.test` host, which the test client resolves to a loopback
//! `MockServer`, so the engine treats every request as metered.

use std::sync::Arc;
use std::time::Duration;

use bistre_protocol::{
    DiagnosticKey, EngineEvent, MoneyMicros, ProviderDialect, SpendPurpose, ThreadMode, ThreadPatch,
};
use tokio::sync::broadcast;

use crate::registry::ModelRates;
use crate::test_support::{MockServer, Scripted};

pub(crate) type TestResult = Result<(), Box<dyn std::error::Error>>;

const EVENT_WAIT: Duration = Duration::from_secs(15);
const PAID_HOST: &str = "paid.test";

pub(crate) struct PaidChat {
    pub(crate) dir: tempfile::TempDir,
    pub(crate) engine: Arc<crate::InProcessEngine>,
    pub(crate) provider_id: String,
    pub(crate) thread_id: String,
}

pub(crate) async fn paid_chat(
    server: &MockServer,
    model: &str,
) -> Result<PaidChat, Box<dyn std::error::Error>> {
    let addr: std::net::SocketAddr = server.base().trim_start_matches("http://").parse()?;
    let dir = tempfile::tempdir()?;
    let http = crate::http_clients::provider_client_resolving(PAID_HOST, addr)?;
    let engine = crate::InProcessEngine::open_for_test(dir.path(), http)?;
    let provider = engine
        .create_provider(
            "Paid".to_owned(),
            ProviderDialect::CustomOpenAi,
            format!("http://{PAID_HOST}:{}/v1", addr.port()),
            model.to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("sk-test".to_owned()),
        )
        .await?;
    let thread = engine
        .create_thread(None, "paid".to_owned(), ThreadMode::Chat, None, None)
        .await?;
    engine
        .update_thread(
            thread.id.clone(),
            ThreadPatch {
                provider_id_override: Some(Some(provider.id.clone())),
                model_id_override: Some(Some(model.to_owned())),
                ..ThreadPatch::default()
            },
        )
        .await?;
    Ok(PaidChat {
        dir,
        engine,
        provider_id: provider.id,
        thread_id: thread.id,
    })
}

/// Collects diagnostics until the run of `thread_id` finishes.
pub(crate) async fn run_diagnostics(
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

fn chat_completion_without_usage(text: &str) -> Scripted {
    let chunk = serde_json::json!({
        "choices": [{ "delta": { "content": text }, "finish_reason": "stop" }]
    });
    Scripted::sse(format!("data: {chunk}\n\ndata: [DONE]\n\n"))
}

pub(crate) async fn set_daily_ceiling(engine: &crate::InProcessEngine, micros: i64) -> TestResult {
    let mut settings = engine.load_settings().await?;
    settings.wallet_daily_ceiling_micros = Some(MoneyMicros::from_micros(micros));
    engine.save_settings(settings).await?;
    Ok(())
}

/// While a cap is active, a model with no known price is not sent; "Allow once" lets the
/// chat's next run through.
#[tokio::test]
async fn an_unpriced_request_is_blocked_under_a_cap_until_allowed_once() -> TestResult {
    let server = MockServer::start(vec![chat_completion_without_usage("hi")]).await?;
    let chat = paid_chat(&server, "unpriced-model").await?;
    set_daily_ceiling(&chat.engine, 5_000_000).await?;
    let mut rx = chat.engine.subscribe_events();

    let user = chat
        .engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await?;
    let diags = run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert!(
        diags
            .iter()
            .any(|(k, _)| *k == DiagnosticKey::WalletPriceUnknown),
        "{diags:?}"
    );

    chat.engine
        .allow_unpriced_once(chat.thread_id.clone())
        .await?;
    chat.engine
        .regenerate_reply(chat.thread_id.clone(), user.id)
        .await?;
    let diags = run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert!(
        !diags
            .iter()
            .any(|(k, _)| *k == DiagnosticKey::WalletPriceUnknown),
        "{diags:?}"
    );
    assert_eq!(
        server.finish().await.len(),
        1,
        "only the allowed run was sent"
    );
    Ok(())
}

/// A malformed per-chat cap denies the request instead of meaning "no cap".
#[tokio::test]
async fn a_malformed_chat_cap_denies_the_request() -> TestResult {
    let server = MockServer::start(vec![chat_completion_without_usage("hi")]).await?;
    let chat = paid_chat(&server, "priced-model").await?;
    chat.engine
        .pricing
        .publish(vec![crate::registry::CatalogEntry {
            namespace: None,
            id: "priced-model".to_owned(),
            rates: ModelRates {
                input_per_mtok: 1_000_000,
                output_per_mtok: 2_000_000,
                ..ModelRates::default()
            },
            extras: crate::registry::ModelExtras::default(),
        }]);
    chat.engine
        .set_kv_meta(
            format!("thread_spend_limit:{}", chat.thread_id),
            "five dollars".to_owned(),
        )
        .await?;
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await?;
    let diags = run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert!(
        diags
            .iter()
            .any(|(k, _)| *k == DiagnosticKey::WalletCheckUnavailable),
        "{diags:?}"
    );
    assert!(server.finish().await.is_empty(), "nothing was sent");
    Ok(())
}

/// A reply whose stream carried no usage is billed from the estimate, never at $0.
#[tokio::test]
async fn a_reply_without_usage_is_billed_from_the_estimate() -> TestResult {
    let server = MockServer::start(vec![chat_completion_without_usage(
        "a reasonably long answer that certainly costs some output tokens",
    )])
    .await?;
    let chat = paid_chat(&server, "priced-model").await?;
    chat.engine
        .pricing
        .publish(vec![crate::registry::CatalogEntry {
            namespace: None,
            id: "priced-model".to_owned(),
            rates: ModelRates {
                input_per_mtok: 1_000_000_000,
                output_per_mtok: 2_000_000_000,
                ..ModelRates::default()
            },
            extras: crate::registry::ModelExtras::default(),
        }]);
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello there".to_owned())
        .await?;
    let diags = run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert!(
        diags
            .iter()
            .any(|(k, _)| *k == DiagnosticKey::WalletUsageEstimated),
        "{diags:?}"
    );
    assert!(chat.engine.wallet_spend_micros().await?.as_micros() > 0);
    drop(server.finish().await);
    Ok(())
}

/// Read aloud passes the Wallet Shield: a reached cap blocks it before any request.
#[tokio::test]
async fn read_aloud_is_blocked_when_the_daily_cap_is_reached() -> TestResult {
    let server = MockServer::start(vec![Scripted::status(200)]).await?;
    let chat = paid_chat(&server, "tts-model").await?;
    chat.engine
        .pricing
        .publish(vec![crate::registry::CatalogEntry {
            namespace: None,
            id: "tts-model".to_owned(),
            rates: ModelRates {
                input_per_mtok: 1_000_000,
                output_per_mtok: 1_000_000,
                ..ModelRates::default()
            },
            extras: crate::registry::ModelExtras::default(),
        }]);
    set_daily_ceiling(&chat.engine, 1_000).await?;
    chat.engine.storage.record_wallet_entry(
        None,
        "p".to_owned(),
        "m".to_owned(),
        MoneyMicros::from_micros(1_000),
        "settled".to_owned(),
    )?;
    let provider_id = chat.provider_id.clone();
    let res = chat
        .engine
        .synthesize_speech(
            provider_id,
            "tts-model".to_owned(),
            "hello".to_owned(),
            None,
        )
        .await;
    assert_eq!(
        res.err().map(|e| e.key),
        Some(DiagnosticKey::WalletCeilingExceeded)
    );
    assert!(server.finish().await.is_empty(), "nothing was sent");
    Ok(())
}

/// Under a cap, an unpriced speech model is blocked until "Allow once".
#[tokio::test]
async fn unpriced_read_aloud_under_a_cap_needs_allow_once() -> TestResult {
    let server = MockServer::start(vec![Scripted::status(200)]).await?;
    let chat = paid_chat(&server, "unpriced-tts").await?;
    set_daily_ceiling(&chat.engine, 5_000_000).await?;
    let provider_id = chat.provider_id.clone();
    let speak = || {
        chat.engine.synthesize_speech(
            provider_id.clone(),
            "unpriced-tts".to_owned(),
            "hello".to_owned(),
            None,
        )
    };
    assert_eq!(
        speak().await.err().map(|e| e.key),
        Some(DiagnosticKey::WalletPriceUnknown)
    );
    chat.engine.allow_unpriced_media_once().await?;
    // The request is sent now; whatever the mock answers, the gate let it through.
    let second = speak().await;
    assert!(
        !matches!(
            second.as_ref().err().map(|e| e.key),
            Some(DiagnosticKey::WalletPriceUnknown)
        ),
        "{second:?}"
    );
    let seen = server.finish().await;
    assert_eq!(seen.len(), 1, "{second:?}");
    Ok(())
}

fn chat_completion(delta: &serde_json::Value, finish: &str) -> Scripted {
    let chunk = serde_json::json!({ "choices": [{ "delta": delta, "finish_reason": finish }] });
    let usage = serde_json::json!({
        "choices": [],
        "usage": { "prompt_tokens": 10, "completion_tokens": 5 }
    });
    Scripted::sse(format!(
        "data: {chunk}\n\ndata: {usage}\n\ndata: [DONE]\n\n"
    ))
}

/// A chat run and the helpers it starts are booked apart, so background use can be shown.
#[tokio::test]
async fn a_run_and_its_helpers_are_booked_under_their_own_purpose() -> TestResult {
    let delegate = serde_json::json!({ "tool_calls": [{
        "index": 0,
        "id": "call_1",
        "type": "function",
        "function": {
            "name": "agent_delegate",
            "arguments": serde_json::json!({ "tasks": ["look around"] }).to_string(),
        }
    }]});
    let server = MockServer::start(vec![
        chat_completion(&delegate, "tool_calls"),
        chat_completion(&serde_json::json!({ "content": "nothing here" }), "stop"),
        chat_completion(&serde_json::json!({ "content": "done" }), "stop"),
    ])
    .await?;
    let chat = paid_chat(&server, "priced-model").await?;
    chat.engine
        .pricing
        .publish(vec![crate::registry::CatalogEntry {
            namespace: None,
            id: "priced-model".to_owned(),
            rates: ModelRates {
                input_per_mtok: 1_000_000_000,
                output_per_mtok: 2_000_000_000,
                ..ModelRates::default()
            },
            extras: crate::registry::ModelExtras::default(),
        }]);
    let root = chat.dir.path().join("workspace");
    std::fs::create_dir_all(&root)?;
    for (key, value) in [
        ("agent.workspace_root", root.to_string_lossy().into_owned()),
        (
            "agent.tool_permissions",
            r#"{"agent_delegate":"allow"}"#.to_owned(),
        ),
    ] {
        chat.engine.set_kv_meta(key.to_owned(), value).await?;
    }
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hello".to_owned())
        .await?;
    run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert_eq!(server.finish().await.len(), 3);
    let usage = chat.engine.wallet_usage_by_purpose(0).await?;
    let booked: Vec<_> = usage.iter().map(|u| (u.purpose, u.requests)).collect();
    assert_eq!(
        booked,
        vec![(SpendPurpose::Chat, 2), (SpendPurpose::Helper, 1)]
    );
    assert!(usage.iter().all(|u| u.cost.as_micros() > 0), "{usage:?}");
    Ok(())
}
