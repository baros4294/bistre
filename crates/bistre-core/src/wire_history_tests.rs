//! Unit tests for `wire_history.rs`.

use super::*;
use crate::replay_policy::{TurnOriginMeta, blake3_short_hash};
use bistre_protocol::ProviderDialect;
use std::collections::HashMap;

fn rec(id: &str, role: NodeRole, content: &str, meta: Option<Value>, at: i64) -> NodeRecord {
    NodeRecord {
        id: id.to_owned(),
        thread_id: "t1".to_owned(),
        parent_id: None,
        role,
        content: content.to_owned(),
        provider_meta_json: meta.map(|m| m.to_string()),
        created_at_ms: at,
    }
}

/// Null fields in a stored reasoning item are never sent back.
#[test]
fn replayed_reasoning_items_carry_no_null_fields() {
    let origin = TurnOriginMeta {
        dialect: ProviderDialect::OpenAi,
        provider_id: "p1".to_owned(),
        model_id: "m".to_owned(),
        system_hash: blake3_short_hash(""),
        tools_hash: blake3_short_hash(""),
    };
    let meta = json!({
        "origin": origin,
        "reasoning_blocks": [{
            "kind": "open_ai_reasoning",
            "id": "rs_1",
            "summary": [{ "type": "summary_text", "text": "x", "status": null }],
            "encrypted_content": "enc"
        }]
    });
    let history = vec![
        rec("u1", NodeRole::User, "Hi", None, 1),
        rec("a1", NodeRole::Assistant, "Hello", Some(meta), 2),
        rec("u2", NodeRole::User, "Next", None, 3),
    ];
    let ctx = ReplayContext::new(ProviderDialect::OpenAi, "p1", "m", "", "", Some("t1"));
    let items = build_openai_responses_input_with_ctx(&history, None, Some(&ctx));
    let text = Value::Array(items).to_string();
    assert!(text.contains("\"encrypted_content\":\"enc\""), "{text}");
    assert!(!text.contains("null"), "{text}");
}

#[test]
fn replays_anthropic_thinking_signature_only_when_prefix_matches_and_drops_on_switch() {
    let origin = TurnOriginMeta {
        dialect: ProviderDialect::Anthropic,
        provider_id: "p1".to_owned(),
        model_id: "claude-x".to_owned(),
        system_hash: blake3_short_hash("sys"),
        tools_hash: blake3_short_hash(""),
    };
    let meta = json!({
        "origin": origin,
        "reasoning_blocks": [
            { "kind": "anthropic_thinking", "thinking": "chain", "signature": "sig_123" },
            { "kind": "anthropic_redacted_thinking", "data": "redacted_9" }
        ],
        "thinking_text": "chain"
    })
    .to_string();
    let history = vec![
        NodeRecord {
            id: "u1".to_owned(),
            thread_id: "t1".to_owned(),
            parent_id: None,
            role: NodeRole::User,
            content: "Hi".to_owned(),
            provider_meta_json: None,
            created_at_ms: 1,
        },
        NodeRecord {
            id: "a1".to_owned(),
            thread_id: "t1".to_owned(),
            parent_id: Some("u1".to_owned()),
            role: NodeRole::Assistant,
            content: "Hello".to_owned(),
            provider_meta_json: Some(meta),
            created_at_ms: 2,
        },
        NodeRecord {
            id: "u2".to_owned(),
            thread_id: "t1".to_owned(),
            parent_id: Some("a1".to_owned()),
            role: NodeRole::User,
            content: "Next".to_owned(),
            provider_meta_json: None,
            created_at_ms: 3,
        },
    ];

    // Exact same Anthropic context -> verbatim thinking + redacted_thinking replayed!
    let same = ReplayContext::new(
        ProviderDialect::Anthropic,
        "p1",
        "claude-x",
        "sys",
        "",
        Some("t1"),
    );
    let msgs = build_anthropic_messages_with_ctx(&history, None, Some(&same));
    assert_eq!(msgs[1]["content"][0]["type"], "thinking");
    assert_eq!(msgs[1]["content"][0]["signature"], "sig_123");
    assert_eq!(msgs[1]["content"][1]["type"], "redacted_thinking");
    assert_eq!(msgs[1]["content"][1]["data"], "redacted_9");

    // System prompt mutated mid-chat -> thinking blocks stripped cleanly (zero prefix 400)!
    let changed_sys = ReplayContext::new(
        ProviderDialect::Anthropic,
        "p1",
        "claude-x",
        "new-sys",
        "",
        Some("t1"),
    );
    let msgs_mut = build_anthropic_messages_with_ctx(&history, None, Some(&changed_sys));
    assert_eq!(msgs_mut[1]["content"], "Hello");

    // Switched to OpenAI mid-chat -> zero Anthropic signatures leaked; 8k handoff included!
    let oai_ctx = ReplayContext::new(
        ProviderDialect::OpenAi,
        "p2",
        "oai-x",
        "sys",
        "",
        Some("t1"),
    );
    let oai_in = build_openai_responses_input_with_ctx(&history, None, Some(&oai_ctx));
    let serialized = Value::Array(oai_in).to_string();
    assert!(!serialized.contains("sig_123"));
    assert!(!serialized.contains("redacted_9"));
    assert!(serialized.contains("Prior reasoning summary"));
}

#[test]
fn orphan_tool_call_without_result_is_pruned_before_wire_serialization() {
    let meta = json!({
        "tool_calls": [{ "call_id": "call_orphan", "name": "read", "arguments_json": "{}" }]
    })
    .to_string();
    let history = vec![
        NodeRecord {
            id: "u1".to_owned(),
            thread_id: "t1".to_owned(),
            parent_id: None,
            role: NodeRole::User,
            content: "Check file".to_owned(),
            provider_meta_json: None,
            created_at_ms: 1,
        },
        NodeRecord {
            id: "a1".to_owned(),
            thread_id: "t1".to_owned(),
            parent_id: Some("u1".to_owned()),
            role: NodeRole::Assistant,
            content: "Checking".to_owned(),
            provider_meta_json: Some(meta),
            created_at_ms: 2,
        },
        NodeRecord {
            id: "u2".to_owned(),
            thread_id: "t1".to_owned(),
            parent_id: Some("a1".to_owned()),
            role: NodeRole::User,
            content: "Never mind".to_owned(),
            provider_meta_json: None,
            created_at_ms: 3,
        },
    ];
    let anth = build_anthropic_messages_with_ctx(&history, None, None);
    assert!(!Value::Array(anth).to_string().contains("call_orphan"));
    let oai = build_openai_responses_input_with_ctx(&history, None, None);
    assert!(!Value::Array(oai).to_string().contains("call_orphan"));
}

#[test]
fn image_retention_evicts_oldest_images_past_window_to_text_notes() {
    let history: Vec<NodeRecord> = (0..10)
        .map(|i| NodeRecord {
            id: format!("u{i}"),
            thread_id: "t1".to_owned(),
            parent_id: None,
            role: NodeRole::User,
            content: format!("Turn {i}"),
            provider_meta_json: Some(
                json!({
                    "attachments": [{
                        "id": format!("att_{i}"),
                        "name": format!("img_{i}.png"),
                        "mime_type": "image/png",
                        "blob_rel_path": format!("attachments/img_{i}.png"),
                        "size_bytes": 128,
                        "blake3_hex": "00"
                    }]
                })
                .to_string(),
            ),
            created_at_ms: i,
        })
        .collect();
    let oai = build_openai_responses_input_with_ctx(&history, None, None);
    let first_text = oai[0]["content"].as_str().unwrap_or("");
    let second_text = oai[1]["content"].as_str().unwrap_or("");
    let third_text = oai[2]["content"].as_str().unwrap_or("");
    assert!(first_text.contains("[Earlier image omitted: img_0.png]"));
    assert!(second_text.contains("[Earlier image omitted: img_1.png]"));
    assert!(!third_text.contains("Earlier image omitted"));
}

fn no_uris() -> HashMap<String, String> {
    HashMap::new()
}

/// Arguments the model sent as broken JSON go back raw, next to the error result, never as a
/// call it made with no arguments.
#[test]
fn invalid_tool_arguments_are_replayed_raw_never_as_empty_objects() {
    let raw = r#"{"path": "#;
    let calls = json!({"tool_calls":[{"call_id":"c1","name":"read","arguments_json":raw}]});
    let result = json!({"tool_result":{"call_id":"c1","name":"read","is_error":true}});
    let history = vec![
        rec("u1", NodeRole::User, "Go", None, 1),
        rec("a1", NodeRole::Assistant, "", Some(calls), 2),
        rec("r1", NodeRole::Tool, "invalid arguments", Some(result), 3),
    ];
    let want = json!({ "INVALID_JSON": raw });
    let anth = build_anthropic_messages_with_ctx(&history, None, None);
    assert_eq!(anth[1]["content"][0]["input"], want);
    let generate = build_gemini_generate_contents_with_ctx(&history, None, &no_uris(), None);
    assert_eq!(generate[1]["parts"][0]["functionCall"]["args"], want);
    let interactions =
        build_gemini_interactions_input_with_ctx(&history, None, &no_uris(), None, 0);
    assert_eq!(interactions[1]["content"][0]["arguments"], want);
}

/// Providers that send no call id leave `call_0` on every turn; replayed to a target that
/// needs unique ids, each call and its result get the same new id, distinct per turn. A
/// unique valid id is sent as stored.
#[test]
fn reused_call_ids_across_turns_are_remapped_as_pairs() {
    let call =
        |id: &str| json!({"tool_calls":[{"call_id":id,"name":"read","arguments_json":"{}"}]});
    let res = |id: &str| json!({"tool_result":{"call_id":id,"name":"read"}});
    let history = vec![
        rec("u1", NodeRole::User, "a", None, 1),
        rec("a1", NodeRole::Assistant, "", Some(call("call_0")), 2),
        rec("r1", NodeRole::Tool, "one", Some(res("call_0")), 3),
        rec("a2", NodeRole::Assistant, "", Some(call("call_0")), 4),
        rec("r2", NodeRole::Tool, "two", Some(res("call_0")), 5),
        rec("a3", NodeRole::Assistant, "", Some(call("toolu_01")), 6),
        rec("r3", NodeRole::Tool, "three", Some(res("toolu_01")), 7),
        rec("u2", NodeRole::User, "b", None, 8),
    ];
    let msgs = build_anthropic_messages_with_ctx(&history, None, None);
    let use_id = |i: usize| {
        msgs[i]["content"][0]["id"]
            .as_str()
            .unwrap_or("")
            .to_owned()
    };
    let res_id = |i: usize| {
        msgs[i]["content"][0]["tool_use_id"]
            .as_str()
            .unwrap_or("")
            .to_owned()
    };
    assert_eq!(use_id(1), res_id(2));
    assert_eq!(use_id(3), res_id(4));
    assert_ne!(use_id(1), use_id(3));
    assert_eq!(use_id(5), "toolu_01");
    assert_eq!(res_id(6), "toolu_01");
    let again = build_anthropic_messages_with_ctx(&history, None, None);
    assert_eq!(again, msgs, "the remap is deterministic");
}

/// `OpenRouter` `reasoning_details` go back unmodified on a tool-call turn to the model that
/// made them; after a model switch only the unsigned, unencrypted entries go; and no other
/// target ever receives the field.
#[test]
fn openrouter_reasoning_details_replay_only_to_openrouter() {
    let origin = TurnOriginMeta {
        dialect: ProviderDialect::CustomOpenAi,
        provider_id: "openrouter".to_owned(),
        model_id: "v/m1".to_owned(),
        system_hash: blake3_short_hash(""),
        tools_hash: blake3_short_hash(""),
    };
    let details = json!([
        {"type":"reasoning.text","text":"t","signature":"s","format":"anthropic-claude-v1"},
        {"type":"reasoning.encrypted","id":"c1","data":"E"},
        {"type":"reasoning.summary","summary":"sum"}
    ]);
    let meta = json!({
        "origin": origin,
        "reasoning_blocks": [{"kind": "open_router_details", "details": details}],
        "tool_calls": [{"call_id":"c1","name":"read","arguments_json":"{}"}]
    });
    let result = json!({"tool_result":{"call_id":"c1","name":"read"}});
    let history = vec![
        rec("u1", NodeRole::User, "Go", None, 1),
        rec("a1", NodeRole::Assistant, "", Some(meta), 2),
        rec("r1", NodeRole::Tool, "ok", Some(result), 3),
    ];
    let ctx = |model: &str| {
        ReplayContext::new(
            ProviderDialect::CustomOpenAi,
            "openrouter",
            model,
            "",
            "",
            Some("t1"),
        )
    };
    let same =
        build_openai_compat_messages_with_ctx(&history, None, Some(&ctx("v/m1")), true, None);
    assert_eq!(same[1]["reasoning_details"], details);
    assert_eq!(same[1]["tool_calls"][0]["id"], "c1", "linked ids are kept");
    let switched =
        build_openai_compat_messages_with_ctx(&history, None, Some(&ctx("v/m2")), true, None);
    assert_eq!(
        switched[1]["reasoning_details"],
        json!([{"type":"reasoning.summary","summary":"sum"}])
    );
    let elsewhere =
        build_openai_compat_messages_with_ctx(&history, None, Some(&ctx("v/m1")), false, None);
    assert!(elsewhere[1].get("reasoning_details").is_none());
    let anth = ReplayContext::new(ProviderDialect::Anthropic, "a", "m", "", "", Some("t1"));
    let text = Value::Array(build_anthropic_messages_with_ctx(
        &history,
        None,
        Some(&anth),
    ));
    assert!(!text.to_string().contains("reasoning.encrypted"), "{text}");
}

/// Prompt caches match byte for byte, so a replayed tool call must serialize the same way
/// every turn whatever key order the model streamed: `serde_json` maps are sorted, and this
/// pins it (no `preserve_order`).
#[test]
fn a_replayed_tool_call_serializes_the_same_bytes_every_turn() {
    let call = |args: &str| {
        json!({ "tool_calls": [{ "call_id": "c1", "name": "read", "arguments_json": args }] })
    };
    let result = json!({ "tool_result": { "call_id": "c1", "name": "read" } });
    let turn = |args: &str| {
        vec![
            rec("u1", NodeRole::User, "Hi", None, 1),
            rec("a1", NodeRole::Assistant, "", Some(call(args)), 2),
            rec("r1", NodeRole::Tool, "ok", Some(result.clone()), 3),
        ]
    };
    let anthropic = |history: &[NodeRecord]| {
        Value::Array(build_anthropic_messages_with_ctx(history, None, None)).to_string()
    };
    let streamed = anthropic(&turn(r#"{"path":"a.md","limit":5}"#));
    assert_eq!(streamed, anthropic(&turn(r#"{"limit":5,"path":"a.md"}"#)));
    assert!(
        streamed.contains(r#""input":{"limit":5,"path":"a.md"}"#),
        "{streamed}"
    );
}
