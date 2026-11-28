//! Gemini `thoughtSignature` capture and replay, ported from kelivo's
//! `test/gemini_thought_signature_artifact_test.dart` and `..._repro_test.dart`. Bistre stores typed parts, so kelivo's raw-part cases (unknown future parts,
//! built-in `toolCall` parts) have no counterpart here.

use bistre_protocol::{NodeRecord, NodeRole, ProviderDialect};
use serde_json::{Value, json};

use crate::replay_policy::{ReasoningBlock, ReplayContext, TurnOriginMeta, blake3_short_hash};
use crate::wire_stream::StreamState;

fn stream(frames: &[Value]) -> StreamState {
    let mut st = StreamState::default();
    for frame in frames {
        st.handle_payload(
            ProviderDialect::GoogleGemini,
            &frame.to_string(),
            &mut |_| {},
            &mut |_| {},
        );
    }
    st.finalize(ProviderDialect::GoogleGemini);
    st
}

fn parts(list: &Value) -> Value {
    json!({ "candidates": [{ "content": { "role": "model", "parts": list } }] })
}

/// A reply from Gemini 3 whose signature hangs on a trailing empty text part keeps it.
#[test]
fn the_signature_on_a_trailing_empty_part_is_kept() {
    let st = stream(&[parts(&json!([
        { "text": "Thinking", "thought": true, "thoughtSignature": "sig-thought" },
        { "text": "Answer." },
        { "text": "", "thoughtSignature": "sig-trailing" }
    ]))]);
    assert!(
        st.out.reasoning_blocks.iter().any(|b| matches!(
            b,
            ReasoningBlock::GeminiTextSignature { signature } if signature == "sig-trailing"
        )),
        "{:?}",
        st.out.reasoning_blocks
    );
}

/// Parallel calls: only the first is signed, and the second must not borrow its signature.
#[test]
fn a_parallel_unsigned_call_does_not_borrow_a_signature() {
    let st = stream(&[parts(&json!([
        { "functionCall": { "name": "search_docs", "args": {} }, "thoughtSignature": "sig-search-docs" },
        { "functionCall": { "name": "fetch_markdown", "args": {} } }
    ]))]);
    assert_eq!(st.out.tool_calls.len(), 2);
    assert_eq!(
        st.out.tool_calls[0].thought_signature.as_deref(),
        Some("sig-search-docs")
    );
    assert_eq!(st.out.tool_calls[1].thought_signature, None);
}

fn origin() -> TurnOriginMeta {
    TurnOriginMeta {
        dialect: ProviderDialect::GoogleGemini,
        provider_id: "g".to_owned(),
        model_id: "m".to_owned(),
        system_hash: blake3_short_hash(""),
        tools_hash: blake3_short_hash(""),
    }
}

fn replay_model_turn(content: &str, meta: &Value, with_results: &[&str]) -> Value {
    let rec = |id: &str, role, content: &str, meta: Option<String>| NodeRecord {
        id: id.to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role,
        content: content.to_owned(),
        provider_meta_json: meta,
        created_at_ms: 1,
    };
    let mut history = vec![
        rec("u", NodeRole::User, "Hello", None),
        rec("a", NodeRole::Assistant, content, Some(meta.to_string())),
    ];
    for (i, call) in with_results.iter().enumerate() {
        let res = json!({ "tool_result": { "call_id": call, "name": format!("tool{i}") } });
        history.push(rec(
            &format!("r{i}"),
            NodeRole::Tool,
            "ok",
            Some(res.to_string()),
        ));
    }
    history.push(rec("u2", NodeRole::User, "Go on", None));
    let ctx = ReplayContext::new(ProviderDialect::GoogleGemini, "g", "m", "", "", Some("t"));
    let empty = std::collections::HashMap::<String, String>::new();
    let contents = crate::wire_history::build_gemini_generate_contents_with_ctx(
        &history,
        None,
        &empty,
        Some(&ctx),
    );
    contents[1]["parts"].clone()
}

/// A stored text signature goes back on the text part it came with.
#[test]
fn a_stored_text_signature_is_replayed_on_the_text_part() {
    let meta = json!({
        "origin": origin(),
        "reasoning_blocks": [{ "kind": "gemini_text_signature", "signature": "sig-stored" }]
    });
    assert_eq!(
        replay_model_turn("Earlier answer.", &meta, &[]),
        json!([{ "text": "Earlier answer.", "thoughtSignature": "sig-stored" }])
    );
}

/// Parallel calls replay as one turn: the first signed, the second without a signature.
#[test]
fn parallel_calls_replay_with_only_the_first_signed() {
    let meta = json!({
        "origin": origin(),
        "tool_calls": [
            { "call_id": "c1", "name": "search_docs", "arguments_json": "{}", "thought_signature": "sig-search-docs" },
            { "call_id": "c2", "name": "fetch_markdown", "arguments_json": "{}" }
        ]
    });
    let parts = replay_model_turn("", &meta, &["c1", "c2"]);
    assert_eq!(parts[0]["thoughtSignature"], "sig-search-docs", "{parts}");
    assert_eq!(parts[1]["functionCall"]["name"], "fetch_markdown");
    assert!(parts[1].get("thoughtSignature").is_none(), "{parts}");
}

/// A detached signature part stays a separate part; it is not moved onto the call.
#[test]
fn a_detached_signature_stays_a_separate_part() {
    let meta = json!({
        "origin": origin(),
        "tool_calls": [
            { "call_id": "c1", "name": "fetch_markdown", "arguments_json": "{}", "thought_signature": "sig-fetch-markdown" }
        ],
        "reasoning_blocks": [{ "kind": "gemini_text_signature", "signature": "sig-detached" }]
    });
    let parts = replay_model_turn("", &meta, &["c1"]);
    assert_eq!(
        parts[0]["thoughtSignature"], "sig-fetch-markdown",
        "{parts}"
    );
    assert_eq!(
        parts[1],
        json!({ "text": "", "thoughtSignature": "sig-detached" })
    );
}

/// A picture part's signature is kept, one per picture in order, empty for an unsigned one.
#[test]
fn each_picture_part_keeps_its_signature() {
    let st = stream(&[parts(&json!([
        { "text": "Here it is.", "thoughtSignature": "sig-text" },
        { "inlineData": { "mimeType": "image/png", "data": "iVBORw0K" }, "thoughtSignature": "sig-pic" },
        { "inlineData": { "mimeType": "image/png", "data": "iVBORw0K" } }
    ]))]);
    assert!(
        st.out.reasoning_blocks.iter().any(|b| matches!(
            b,
            ReasoningBlock::GeminiPictureSignatures { signatures }
                if *signatures == ["sig-pic".to_owned(), String::new()]
        )),
        "{:?}",
        st.out.reasoning_blocks
    );
}

/// A signed picture goes back as the model's own part, once: the next user message, which
/// carries the reply's pictures for other models, leaves it out. For another model, or with
/// an unsigned picture, the picture stays on the user message.
#[test]
fn a_signed_picture_is_replayed_as_the_models_own_part() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let picture = crate::attachments::store_attachment_bytes(
        dir.path(),
        "p.png".to_owned(),
        "image/png".to_owned(),
        b"\x89PNG\r\n\x1a\npicture",
    )?;
    let rec = |id: &str, role, meta: Value| NodeRecord {
        id: id.to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role,
        content: "x".to_owned(),
        provider_meta_json: Some(meta.to_string()),
        created_at_ms: 1,
    };
    let contents = |signature: &str, model: &str| {
        let history = vec![
            rec("u", NodeRole::User, json!({})),
            rec(
                "a",
                NodeRole::Assistant,
                json!({
                    "origin": origin(),
                    "attachments": [picture],
                    "reasoning_blocks": [{ "kind": "gemini_picture_signatures", "signatures": [signature] }]
                }),
            ),
            rec("u2", NodeRole::User, json!({ "attachments": [picture] })),
        ];
        let ctx = ReplayContext::new(ProviderDialect::GoogleGemini, "g", model, "", "", Some("t"));
        crate::wire_history::build_gemini_generate_contents_with_ctx(
            &history,
            Some(dir.path()),
            &std::collections::HashMap::<String, String>::new(),
            Some(&ctx),
        )
    };
    let inline = |turn: &Value| {
        turn["parts"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|p| p.get("inline_data").is_some())
            .cloned()
            .collect::<Vec<_>>()
    };
    let own = contents("sig-pic", "m");
    let model_pictures = inline(&own[1]);
    assert_eq!(model_pictures.len(), 1, "{own:?}");
    assert_eq!(model_pictures[0]["thoughtSignature"], "sig-pic");
    assert!(inline(&own[2]).is_empty(), "sent once: {own:?}");
    for other in [contents("sig-pic", "other-model"), contents("", "m")] {
        assert!(inline(&other[1]).is_empty(), "{other:?}");
        assert_eq!(inline(&other[2]).len(), 1, "{other:?}");
    }
    Ok(())
}
