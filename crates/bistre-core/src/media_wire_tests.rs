//! Unit tests for `media_wire.rs`.

use super::*;

const PNG: &[u8] = b"\x89PNG\r\n\x1a\nimage";

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn png_data_url() -> String {
    format!("data:image/png;base64,{}", b64(PNG))
}

#[test]
fn chat_frames_yield_images_and_spoken_audio_with_its_transcript() {
    let mut media = MediaCollector::default();
    let image = json!({"choices": [{"delta": {"images": [{"type": "image_url", "image_url": {"url": png_data_url()}}]}}]});
    assert_eq!(media.absorb(ProviderDialect::CustomOpenAi, &image), None);
    let pcm = [1_u8, 0, 2, 0];
    let a = json!({"choices": [{"delta": {"audio": {"id": "a1", "data": b64(&pcm[..2]), "transcript": "Hel"}}}]});
    let b =
        json!({"choices": [{"delta": {"audio": {"data": b64(&pcm[2..]), "transcript": "lo"}}}]});
    assert_eq!(
        media.absorb(ProviderDialect::CustomOpenAi, &a).as_deref(),
        Some("Hel")
    );
    assert_eq!(
        media.absorb(ProviderDialect::CustomOpenAi, &b).as_deref(),
        Some("lo")
    );
    let files = media.finish();
    assert_eq!(files.len(), 2);
    assert_eq!(
        files.first(),
        Some(&GeneratedMedia {
            mime_type: "image/png".to_owned(),
            bytes: PNG.to_vec()
        })
    );
    let wav = files.get(1).map(|f| (f.mime_type.as_str(), f.bytes.len()));
    assert_eq!(wav, Some(("audio/wav", 44 + pcm.len())));
}

#[test]
fn gemini_media_parts_are_kept_and_thought_parts_never() {
    let mut media = MediaCollector::default();
    let frame = json!({"candidates": [{"content": {"parts": [
        {"text": "Here it is"},
        {"thought": true, "inlineData": {"mimeType": "image/png", "data": b64(b"draft")}},
        {"inlineData": {"mimeType": "image/png", "data": b64(PNG)}},
        {"inlineData": {"mimeType": "application/pdf", "data": b64(b"%PDF-")}}
    ]}}]});
    media.absorb(ProviderDialect::GoogleGemini, &frame);
    let delta = json!({"event_type": "step.delta", "delta": {"type": "image", "mime_type": "image/jpeg", "data": b64(b"\xff\xd8\xffjpeg")}});
    media.absorb(ProviderDialect::GoogleGemini, &delta);
    let kinds: Vec<_> = media.finish().into_iter().map(|m| m.mime_type).collect();
    assert_eq!(kinds, vec!["image/png", "image/jpeg"]);
}

#[test]
fn a_reply_keeps_at_most_the_bounded_number_of_files() {
    let mut media = MediaCollector::default();
    let one = json!({"choices": [{"delta": {"images": [{"image_url": {"url": png_data_url()}}]}}]});
    for _ in 0..=MAX_MEDIA_ITEMS {
        media.absorb(ProviderDialect::CustomOpenAi, &one);
    }
    assert!(media.dropped);
    assert_eq!(media.finish().len(), MAX_MEDIA_ITEMS);
}

#[test]
fn chat_requests_ask_for_the_extra_output_kinds_only() {
    let none = chat_output_fields(ModalitySet::default(), true, None);
    assert_eq!(none, Vec::new());
    let image = chat_output_fields(ModalitySet::of(&[Modality::Image]), true, None);
    assert_eq!(image, vec![("modalities", json!(["image", "text"]))]);
    let only_image = chat_output_fields(ModalitySet::of(&[Modality::Image]), false, None);
    assert_eq!(only_image, vec![("modalities", json!(["image"]))]);
    let audio = chat_output_fields(ModalitySet::of(&[Modality::Audio]), true, Some("verse"));
    assert_eq!(
        audio,
        vec![
            ("modalities", json!(["audio", "text"])),
            ("audio", json!({"voice": "verse", "format": "pcm16"}))
        ]
    );
}

#[test]
fn image_requests_and_replies_cover_both_shapes() {
    let (path, body) = image_request(ImageApi::OpenRouter, "m", "a fox", &[png_data_url()]);
    assert_eq!(path, "/images");
    assert_eq!(
        body["input_references"][0]["image_url"]["url"],
        json!(png_data_url())
    );
    let (path, body) = image_request(ImageApi::OpenAi, "m", "a fox", &[]);
    assert_eq!(
        (path, body),
        (
            "/images/generations",
            json!({"model": "m", "prompt": "a fox", "n": 1})
        )
    );

    let reply = json!({"data": [
        {"b64_json": b64(PNG)},
        {"url": "https://cdn.example.com/x.jpeg", "media_type": "image/jpeg"},
        {"url": "file:///etc/passwd"}
    ]});
    assert_eq!(
        image_reply_media(&reply),
        vec![
            MediaRef::Inline(GeneratedMedia {
                mime_type: "image/png".to_owned(),
                bytes: PNG.to_vec()
            }),
            MediaRef::Url {
                url: "https://cdn.example.com/x.jpeg".to_owned(),
                mime_type: Some("image/jpeg".to_owned())
            }
        ]
    );
}

#[test]
fn video_jobs_read_every_status_shape() {
    let (path, body) = VideoApi::Videos.submit("m", "waves", Some("data:image/png;base64,AA=="));
    assert_eq!(path, "/videos");
    assert_eq!(body["frame_images"][0]["frame_type"], json!("first_frame"));
    let (path, body) = VideoApi::Tasks.submit("m", "waves", None);
    assert_eq!(path, "/contents/generations/tasks");
    assert_eq!(body["content"], json!([{"type": "text", "text": "waves"}]));
    assert_eq!(
        VideoApi::Tasks.poll_path("t1"),
        "/contents/generations/tasks/t1"
    );
    assert_eq!(
        VideoApi::Videos.content_path("j1").as_deref(),
        Some("/videos/j1/content")
    );
    assert_eq!(VideoApi::Tasks.content_path("t1"), None);

    assert_eq!(
        job_id(&json!({"id": "abc-123", "status": "pending"})).as_deref(),
        Some("abc-123")
    );
    assert_eq!(
        job_id(&json!({"id": "../x"})),
        None,
        "an id never becomes a path"
    );
    assert_eq!(
        job_state(&json!({"status": "in_progress"})),
        JobState::Pending
    );
    assert_eq!(job_state(&json!({"status": "queued"})), JobState::Pending);
    assert_eq!(
        job_state(
            &json!({"status": "completed", "unsigned_urls": ["https://openrouter.ai/api/v1/videos/j/content?index=0"], "usage": {"cost": 0.25}})
        ),
        JobState::Done {
            media: vec![MediaRef::Url {
                url: "https://openrouter.ai/api/v1/videos/j/content?index=0".to_owned(),
                mime_type: None
            }],
            cost_micros: Some(250_000)
        }
    );
    assert_eq!(
        job_state(
            &json!({"status": "succeeded", "content": {"video_url": "https://cdn.example.com/v.mp4"}})
        ),
        JobState::Done {
            media: vec![MediaRef::Url {
                url: "https://cdn.example.com/v.mp4".to_owned(),
                mime_type: None
            }],
            cost_micros: None
        }
    );
    assert_eq!(
        job_state(&json!({"status": "failed", "error": {"code": "x", "message": "policy"}})),
        JobState::Failed("policy".to_owned())
    );
    assert_eq!(
        job_state(&json!({"status": "expired"})),
        JobState::Failed("expired".to_owned())
    );
}

#[test]
fn gemini_video_replies_skip_thought_steps() {
    let reply = json!({"steps": [
        {"type": "thought", "content": [{"type": "image", "mime_type": "image/png", "data": b64(b"draft")}]},
        {"type": "model_output", "content": [{"type": "video", "mime_type": "video/mp4", "data": b64(b"mp4")}]}
    ]});
    assert_eq!(
        gemini_interaction_media(&reply),
        vec![MediaRef::Inline(GeneratedMedia {
            mime_type: "video/mp4".to_owned(),
            bytes: b"mp4".to_vec()
        })]
    );
    let body = gemini_video_request("models/omni", "waves", None);
    assert_eq!(
        body,
        json!({"model": "omni", "input": "waves", "response_format": {"type": "video"}})
    );
}

fn node(id: &str, role: NodeRole, content: &str, files: &[(&str, &str)]) -> NodeRecord {
    let atts: Vec<Value> = files
        .iter()
        .map(|(name, mime)| {
            json!({"id": name, "name": name, "mime_type": mime, "blob_rel_path": format!("b/{name}"), "size_bytes": 1, "blake3_hex": "00"})
        })
        .collect();
    NodeRecord {
        id: id.to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role,
        content: content.to_owned(),
        provider_meta_json: (!files.is_empty()).then(|| json!({ "attachments": atts }).to_string()),
        created_at_ms: 0,
    }
}

fn names(n: &NodeRecord) -> Vec<String> {
    parse_node_attachments(n.provider_meta_json.as_deref())
        .into_iter()
        .map(|a| a.name)
        .collect()
}

#[test]
fn generated_files_go_back_with_the_next_message_for_kinds_the_model_reads() {
    let history = vec![
        node("u1", NodeRole::User, "a fox", &[]),
        node(
            "a1",
            NodeRole::Assistant,
            "",
            &[("fox.png", "image/png"), ("fox.wav", "audio/wav")],
        ),
        node(
            "u2",
            NodeRole::User,
            "make it red",
            &[("ref.jpg", "image/jpeg")],
        ),
        node(
            "a2",
            NodeRole::Assistant,
            "Here it is.",
            &[("red.png", "image/png")],
        ),
    ];
    let mut seen = history.clone();
    carry_generated_media(
        &mut seen,
        Some(ModalitySet::of(&[Modality::Text, Modality::Image])),
    );
    assert_eq!(seen[1].content, "[Generated files: fox.png, fox.wav]");
    assert_eq!(
        names(&seen[2]),
        ["fox.png", "ref.jpg"],
        "audio the model cannot read stays behind"
    );
    assert_eq!(seen[3].content, "Here it is.", "a reply with text keeps it");
    assert_eq!(
        names(&seen[3]),
        ["red.png"],
        "the newest reply has no next message to carry into"
    );

    let mut text_only = history;
    carry_generated_media(&mut text_only, None);
    assert_eq!(text_only[1].content, "[Generated files: fox.png, fox.wav]");
    assert_eq!(
        names(&text_only[2]),
        ["ref.jpg"],
        "a model with no catalog entry reads text only"
    );
}

#[test]
fn chat_media_settings_keep_only_what_the_model_offers_and_land_in_each_wire() {
    let offered = crate::registry::ModelExtras {
        aspect_ratios: vec!["16:9".to_owned(), "9:19.5".to_owned()],
        resolutions: vec!["2K".to_owned()],
        durations_s: vec![4, 8],
        voice: None,
    };
    let saved = MediaPick {
        aspect_ratio: Some("9:19.5".to_owned()),
        resolution: Some("4K".to_owned()),
        duration_s: Some(8),
    };
    let pick = saved.for_model(Some(&offered));
    assert_eq!(
        pick,
        MediaPick {
            aspect_ratio: Some("9:19.5".to_owned()),
            resolution: None,
            duration_s: Some(8),
        },
        "a size this model does not list is left to the provider"
    );
    assert_eq!(saved.for_model(None), MediaPick::default());

    let applied = |wire| {
        let mut body = json!({"model": "m"});
        pick.apply(wire, &mut body);
        body
    };
    assert_eq!(
        applied(PickWire::Images),
        json!({"model": "m", "aspect_ratio": "9:19.5"})
    );
    assert_eq!(
        applied(PickWire::Videos),
        json!({"model": "m", "aspect_ratio": "9:19.5", "duration": 8})
    );
    assert_eq!(
        applied(PickWire::Tasks),
        json!({"model": "m", "ratio": "9:19.5", "duration": 8})
    );
    assert_eq!(
        applied(PickWire::ChatImage),
        json!({"model": "m", "image_config": {"aspect_ratio": "9:19.5"}})
    );
    assert_eq!(
        applied(PickWire::GeminiImage),
        json!({"model": "m", "response_format": {"type": "image", "aspect_ratio": "9:19.5"}})
    );
    assert_eq!(
        applied(PickWire::GeminiContentImage),
        json!({"model": "m", "generationConfig": {"imageConfig": {"aspectRatio": "9:19.5"}}})
    );
    let mut video = gemini_video_request("omni", "waves", None);
    pick.apply(PickWire::GeminiVideo, &mut video);
    assert_eq!(
        video["response_format"],
        json!({"type": "video", "aspect_ratio": "9:19.5", "duration": "8s"})
    );
    let mut untouched = json!({"model": "m"});
    MediaPick::default().apply(PickWire::GeminiImage, &mut untouched);
    assert_eq!(
        untouched,
        json!({"model": "m"}),
        "no setting sends no field"
    );
}
