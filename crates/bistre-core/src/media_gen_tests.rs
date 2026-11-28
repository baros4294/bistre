//! Media-only models through a paid provider (`paid.test` resolves to a `MockServer`).

use base64::Engine as _;
use bistre_protocol::{DiagnosticKey, NodeRole, ProviderDialect};
use serde_json::json;

use super::*;
use crate::registry::{CatalogEntry, ModalitySet};
use crate::test_support::{MockServer, Scripted};
use crate::wallet_flow_tests::{TestResult, paid_chat, run_diagnostics, set_daily_ceiling};

const PNG: &[u8] = b"\x89PNG\r\n\x1a\ngenerated";
const MP4: &[u8] = b"\x00\x00\x00\x18ftypisom-video";

fn catalog(model: &str, rates: ModelRates) -> Vec<CatalogEntry> {
    vec![CatalogEntry {
        namespace: None,
        id: model.to_owned(),
        rates,
        extras: crate::registry::ModelExtras::default(),
    }]
}

fn writes(out: &[Modality]) -> ModalitySet {
    ModalitySet::of(out)
}

async fn reply_attachments(
    chat: &crate::wallet_flow_tests::PaidChat,
) -> Result<Vec<StoredAttachment>, Box<dyn std::error::Error>> {
    let nodes = chat.engine.list_nodes(chat.thread_id.clone()).await?;
    let reply = nodes
        .iter()
        .rev()
        .find(|n| n.role == NodeRole::Assistant)
        .ok_or("no reply")?;
    Ok(crate::attachments::parse_node_attachments(
        reply.provider_meta_json.as_deref(),
    ))
}

#[test]
fn a_model_that_writes_no_text_takes_its_media_route() {
    let rates = |out: &[Modality]| ModelRates {
        output_modalities: Some(writes(out)),
        ..ModelRates::default()
    };
    let route = |d, r: &ModelRates| MediaRoute::of(d, Some(r));
    let custom = ProviderDialect::CustomOpenAi;
    assert_eq!(
        route(custom, &rates(&[Modality::Image])),
        Some(MediaRoute::Image)
    );
    assert_eq!(
        route(custom, &rates(&[Modality::Video, Modality::Image])),
        Some(MediaRoute::Video)
    );
    assert_eq!(
        route(custom, &rates(&[Modality::Audio])),
        Some(MediaRoute::Speech)
    );
    assert_eq!(
        route(custom, &rates(&[Modality::Image, Modality::Text])),
        None
    );
    assert_eq!(MediaRoute::of(custom, Some(&ModelRates::default())), None);
    assert_eq!(MediaRoute::of(custom, None), None);
    // Gemini image models answer in chat; Gemini video and speech have their own APIs.
    let gemini = ProviderDialect::GoogleGemini;
    assert_eq!(route(gemini, &rates(&[Modality::Image])), None);
    assert_eq!(
        route(gemini, &rates(&[Modality::Video])),
        Some(MediaRoute::Video)
    );
    assert_eq!(
        route(ProviderDialect::Anthropic, &rates(&[Modality::Image])),
        None
    );
}

#[test]
fn a_speaking_openai_model_goes_through_chat_completions() {
    let provider = crate::test_support::provider(ProviderDialect::OpenAi, "");
    let speaks = ModelRates {
        output_modalities: Some(writes(&[Modality::Text, Modality::Audio])),
        ..ModelRates::default()
    };
    let wired = chat_wire_for(provider.clone(), Some(&speaks));
    assert_eq!(wired.dialect, ProviderDialect::CustomOpenAi);
    assert_eq!(wired.base_url, ProviderDialect::OpenAi.default_base_url());
    assert_eq!(
        chat_wire_for(provider, None).dialect,
        ProviderDialect::OpenAi
    );
}

#[tokio::test]
async fn an_image_model_reply_is_a_stored_picture_billed_at_the_catalog_price() -> TestResult {
    let reply =
        json!({"data": [{"b64_json": base64::engine::general_purpose::STANDARD.encode(PNG)}]});
    let server = MockServer::start(vec![Scripted::json(200, &reply)]).await?;
    let chat = paid_chat(&server, "painter").await?;
    chat.engine.pricing.publish(catalog(
        "painter",
        ModelRates {
            output_modalities: Some(writes(&[Modality::Image])),
            per_image_micros: Some(40_000),
            ..ModelRates::default()
        },
    ));
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "a red fox".to_owned())
        .await?;
    let diags = run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert!(diags.is_empty(), "{diags:?}");

    let requests = server.finish().await;
    let sent = requests.first().ok_or("no request")?;
    assert_eq!(sent.path, "/v1/images/generations");
    assert_eq!(sent.header("authorization"), Some("Bearer sk-test"));
    assert_eq!(sent.body_json()?["prompt"], json!("a red fox"));

    let atts = reply_attachments(&chat).await?;
    assert_eq!(atts.len(), 1);
    let att = atts.first().ok_or("no attachment")?;
    assert_eq!(att.mime_type, "image/png");
    let stored = crate::attachments::read_attachment_bytes(chat.dir.path(), att, 1024);
    assert_eq!(stored.as_deref(), Some(PNG));
    assert_eq!(
        chat.engine
            .thread_spend_micros(chat.thread_id.clone())
            .await?
            .as_micros(),
        40_000
    );
    Ok(())
}

/// An `OpenAI`-shaped provider without `/videos` is asked on the task API; the job is polled
/// until done, its file downloaded with the key, and the provider's own cost booked.
#[tokio::test]
async fn a_video_job_is_polled_downloaded_and_billed() -> TestResult {
    // The finished job names a file on the provider's own host (`paid.test`).
    let server = MockServer::start_with(|port| {
        let video_url = format!("http://paid.test:{port}/v1/files/v.mp4");
        vec![
            Scripted::status(404),
            Scripted::json(200, &json!({"id": "task-1", "status": "queued"})),
            Scripted::json(
                200,
                &json!({"id": "task-1", "status": "succeeded", "content": {"video_url": video_url}, "usage": {"cost": "0.5"}}),
            ),
            Scripted::bytes(MP4),
        ]
    })
    .await?;
    let chat = paid_chat(&server, "filmer").await?;
    chat.engine.pricing.publish(catalog(
        "filmer",
        ModelRates {
            output_modalities: Some(writes(&[Modality::Video])),
            per_video_second_micros: Some(100_000),
            max_video_seconds: Some(10),
            ..ModelRates::default()
        },
    ));
    set_daily_ceiling(&chat.engine, 5_000_000).await?;
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "waves at dusk".to_owned())
        .await?;
    let diags = run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert!(diags.is_empty(), "{diags:?}");

    let paths: Vec<_> = server
        .finish()
        .await
        .into_iter()
        .map(|r| {
            let auth = r.header("authorization").map(ToOwned::to_owned);
            (r.method, r.path, auth)
        })
        .collect();
    let key = Some("Bearer sk-test".to_owned());
    assert_eq!(
        paths,
        vec![
            ("POST".to_owned(), "/v1/videos".to_owned(), key.clone()),
            (
                "POST".to_owned(),
                "/v1/contents/generations/tasks".to_owned(),
                key.clone()
            ),
            (
                "GET".to_owned(),
                "/v1/contents/generations/tasks/task-1".to_owned(),
                key.clone()
            ),
            ("GET".to_owned(), "/v1/files/v.mp4".to_owned(), key),
        ]
    );
    let atts = reply_attachments(&chat).await?;
    assert_eq!(
        atts.first().map(|a| a.mime_type.as_str()),
        Some("video/mp4")
    );
    assert_eq!(
        chat.engine
            .thread_spend_micros(chat.thread_id.clone())
            .await?
            .as_micros(),
        500_000,
        "the provider's reported cost replaces the 1 USD bound"
    );
    Ok(())
}

/// A video job whose wait broke is kept, booked once: Try again on the same message polls
/// that job instead of paying for a new one, and the day's spend counts it once.
#[tokio::test]
async fn try_again_fetches_a_broken_video_job_instead_of_paying_again() -> TestResult {
    let server = MockServer::start_with(|port| {
        let video_url = format!("http://paid.test:{port}/v1/files/v.mp4");
        vec![
            Scripted::json(200, &json!({"id": "vid-1", "status": "queued"})),
            Scripted::status(500),
            Scripted::json(
                200,
                &json!({"id": "vid-1", "status": "completed", "urls": [video_url]}),
            ),
            Scripted::bytes(MP4),
        ]
    })
    .await?;
    let chat = paid_chat(&server, "filmer").await?;
    chat.engine.pricing.publish(catalog(
        "filmer",
        ModelRates {
            output_modalities: Some(writes(&[Modality::Video])),
            per_video_second_micros: Some(100_000),
            max_video_seconds: Some(10),
            ..ModelRates::default()
        },
    ));
    set_daily_ceiling(&chat.engine, 5_000_000).await?;
    let mut rx = chat.engine.subscribe_events();
    let user = chat
        .engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "waves at dusk".to_owned())
        .await?;
    let diags = run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert!(
        diags.iter().any(|(_, d)| d
            .as_deref()
            .is_some_and(|d| d.starts_with("media_http_500"))),
        "{diags:?}"
    );
    chat.engine
        .regenerate_reply(chat.thread_id.clone(), user.id)
        .await?;
    let diags = run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert!(diags.is_empty(), "{diags:?}");
    let paths: Vec<_> = server
        .finish()
        .await
        .into_iter()
        .map(|r| (r.method, r.path))
        .collect();
    let poll = ("GET".to_owned(), "/v1/videos/vid-1".to_owned());
    assert_eq!(
        paths,
        vec![
            ("POST".to_owned(), "/v1/videos".to_owned()),
            poll.clone(),
            poll,
            ("GET".to_owned(), "/v1/files/v.mp4".to_owned()),
        ]
    );
    assert_eq!(
        reply_attachments(&chat)
            .await?
            .first()
            .map(|a| a.mime_type.as_str()),
        Some("video/mp4")
    );
    assert_eq!(
        chat.engine
            .thread_spend_micros(chat.thread_id.clone())
            .await?
            .as_micros(),
        1_000_000,
        "the job is billed once, at its reservation"
    );
    Ok(())
}

#[tokio::test]
async fn an_unpriced_media_model_is_not_sent_under_a_cap() -> TestResult {
    let server = MockServer::start(vec![Scripted::status(500)]).await?;
    let chat = paid_chat(&server, "painter").await?;
    chat.engine.pricing.publish(catalog(
        "painter",
        ModelRates {
            output_modalities: Some(writes(&[Modality::Image])),
            ..ModelRates::default()
        },
    ));
    set_daily_ceiling(&chat.engine, 5_000_000).await?;
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "a fox".to_owned())
        .await?;
    let diags = run_diagnostics(&mut rx, &chat.thread_id).await?;
    assert!(
        diags
            .iter()
            .any(|(k, _)| *k == DiagnosticKey::WalletPriceUnknown),
        "{diags:?}"
    );
    assert!(server.finish().await.is_empty(), "nothing was sent");
    Ok(())
}

/// A chat model that also draws: the request asks for images, and the streamed picture is
/// stored on the reply beside its text.
#[tokio::test]
async fn a_chat_reply_keeps_the_pictures_it_streamed() -> TestResult {
    let url = format!(
        "data:image/png;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(PNG)
    );
    let text = json!({"choices": [{"delta": {"content": "Here you go."}}]});
    let image = json!({"choices": [{"delta": {"images": [{"type": "image_url", "image_url": {"url": url}}]}, "finish_reason": "stop"}]});
    let server = MockServer::start(vec![Scripted::sse(format!(
        "data: {text}\n\ndata: {image}\n\ndata: [DONE]\n\n"
    ))])
    .await?;
    let chat = paid_chat(&server, "chat-painter").await?;
    chat.engine.pricing.publish(catalog(
        "chat-painter",
        ModelRates {
            input_per_mtok: 1,
            output_per_mtok: 1,
            output_modalities: Some(writes(&[Modality::Text, Modality::Image])),
            ..ModelRates::default()
        },
    ));
    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "draw a fox".to_owned())
        .await?;
    run_diagnostics(&mut rx, &chat.thread_id).await?;
    let body = server
        .finish()
        .await
        .first()
        .ok_or("no request")?
        .body_json()?;
    assert_eq!(body["modalities"], json!(["image", "text"]));
    let atts = reply_attachments(&chat).await?;
    assert_eq!(
        atts.first().map(|a| a.mime_type.as_str()),
        Some("image/png")
    );
    Ok(())
}
