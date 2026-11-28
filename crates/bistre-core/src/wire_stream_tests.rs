//! Unit tests for `wire_stream.rs`.

use super::*;

/// `OpenAI` Responses repeats a `function_call` in `response.completed` after
/// `output_item.done`. It must be captured once, or the tool (a shell command, an edit, an
/// MCP call) runs twice.
#[test]
fn a_function_call_repeated_in_response_completed_is_captured_once() {
    let mut st = StreamState::default();
    let item = r#"{"type":"function_call","id":"fc_1","call_id":"call_42","name":"shell","arguments":"{\"command\":\"echo hi\"}"}"#;
    let frames = [
        format!(r#"{{"type":"response.output_item.done","item":{item}}}"#),
        format!(
            r#"{{"type":"response.completed","response":{{"id":"resp_1","output":[{item}]}}}}"#
        ),
    ];
    for f in &frames {
        st.handle_payload(ProviderDialect::OpenAi, f, &mut |_| {}, &mut |_| {});
    }
    st.finalize(ProviderDialect::OpenAi);
    let ids: Vec<&str> = st
        .out
        .tool_calls
        .iter()
        .map(|c| c.call_id.as_str())
        .collect();
    assert_eq!(ids, ["call_42"], "one call, not a renamed duplicate");
}

/// Two different provider ids that sanitize to the same text stay two calls.
#[test]
fn distinct_raw_ids_that_sanitize_alike_stay_distinct() {
    let mut st = StreamState::default();
    for raw in ["call.1", "call:1"] {
        let item = format!(
            r#"{{"type":"function_call","call_id":"{raw}","name":"read","arguments":"{{}}"}}"#
        );
        let frame = format!(r#"{{"type":"response.output_item.done","item":{item}}}"#);
        st.handle_payload(ProviderDialect::OpenAi, &frame, &mut |_| {}, &mut |_| {});
    }
    assert_eq!(st.out.tool_calls.len(), 2);
}

#[test]
fn captures_anthropic_thinking_signature_and_redacted_thinking_and_tool_use() {
    let mut st = StreamState::default();
    let frames = [
        r#"{"type":"message_start","message":{"id":"msg_123"}}"#,
        r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan A"}}"#,
        r#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_part1"}}"#,
        r#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"_part2"}}"#,
        r#"{"type":"content_block_stop","index":0}"#,
        r#"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque_redacted_1"}}"#,
        r#"{"type":"content_block_stop","index":1}"#,
        r#"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01","name":"read"}}"#,
        r#"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a.rs\"}"}}"#,
        r#"{"type":"content_block_stop","index":2}"#,
        r#"{"type":"message_stop"}"#,
    ];
    for f in frames {
        st.handle_payload(ProviderDialect::Anthropic, f, &mut |_| {}, &mut |_| {});
    }
    st.finalize(ProviderDialect::Anthropic);
    assert_eq!(st.out.provider_response_id.as_deref(), Some("msg_123"));
    assert_eq!(st.out.reasoning_blocks.len(), 2);
    assert_eq!(
        st.out.reasoning_blocks[0],
        ReasoningBlock::AnthropicThinking {
            thinking: "plan A".to_owned(),
            signature: "sig_part1_part2".to_owned(),
        }
    );
    assert_eq!(
        st.out.reasoning_blocks[1],
        ReasoningBlock::AnthropicRedactedThinking {
            data: "opaque_redacted_1".to_owned(),
        }
    );
    assert_eq!(st.out.tool_calls.len(), 1);
    assert_eq!(st.out.tool_calls[0].name, "read");
    assert_eq!(st.out.tool_calls[0].call_id, "toolu_01");
}

#[test]
fn captures_openai_encrypted_reasoning_and_function_call() {
    let mut st = StreamState::default();
    let frames = [
        r#"{"type":"response.created","response":{"id":"resp_99"}}"#,
        r#"{"type":"response.output_item.done","item":{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"checked"}],"encrypted_content":"enc_blob_xyz"}}"#,
        r#"{"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_42","name":"grep"}}"#,
        r#"{"type":"response.function_call_arguments.delta","item_id":"fc_1","delta":"{\"pattern\":\"WAL\"}"}"#,
        r#"{"type":"response.completed","response":{"id":"resp_99","output":[]}}"#,
    ];
    for f in frames {
        st.handle_payload(ProviderDialect::OpenAi, f, &mut |_| {}, &mut |_| {});
    }
    st.finalize(ProviderDialect::OpenAi);
    assert_eq!(st.out.provider_response_id.as_deref(), Some("resp_99"));
    assert_eq!(st.out.reasoning_blocks.len(), 1);
    assert!(matches!(
        &st.out.reasoning_blocks[0],
        ReasoningBlock::OpenAiReasoning { id, encrypted_content, .. }
        if id == "rs_1" && encrypted_content == "enc_blob_xyz"
    ));
    assert_eq!(st.out.tool_calls.len(), 1);
    assert_eq!(st.out.tool_calls[0].call_id, "call_42");
    assert_eq!(st.out.tool_calls[0].name, "grep");
}

#[test]
fn captures_gemini_thought_signature_and_function_call() {
    let mut st = StreamState::default();
    let frame = r#"{"candidates":[{"content":{"parts":[{"thought":true,"text":"thinking","thoughtSignature":"gem_sig_77"},{"functionCall":{"id":"fc_g1","name":"glob","args":{"pattern":"*.rs"}},"thoughtSignature":"gem_sig_77"}]},"finishReason":"STOP"}]}"#;
    st.handle_payload(
        ProviderDialect::GoogleGemini,
        frame,
        &mut |_| {},
        &mut |_| {},
    );
    st.finalize(ProviderDialect::GoogleGemini);
    assert_eq!(st.out.full_text, "");
    assert_eq!(st.out.thinking_text, "thinking");
    assert_eq!(st.out.reasoning_blocks.len(), 1);
    assert_eq!(st.out.tool_calls.len(), 1);
    assert_eq!(
        st.out.tool_calls[0].thought_signature.as_deref(),
        Some("gem_sig_77")
    );
}

fn run(dialect: ProviderDialect, frames: &[&str]) -> (StreamState, Vec<String>) {
    let mut st = StreamState::default();
    let mut shown = Vec::new();
    for f in frames {
        st.handle_payload(dialect, f, &mut |_| {}, &mut |t| shown.push(t.to_owned()));
    }
    st.finalize(dialect);
    (st, shown)
}

/// `OpenRouter` streams the same thought twice (plain `reasoning` and `reasoning_details`): the
/// details are kept raw, joined by index, in one opaque block, and the thought is shown once.
#[test]
fn openrouter_reasoning_details_are_kept_raw_and_shown_once() {
    let (st, shown) = run(
        ProviderDialect::CustomOpenAi,
        &[
            r#"{"choices":[{"delta":{"reasoning":"Plan","reasoning_details":[{"type":"reasoning.text","index":0,"format":"anthropic-claude-v1","text":"Plan"}]}}]}"#,
            r#"{"choices":[{"delta":{"reasoning":" more","reasoning_details":[{"type":"reasoning.text","index":0,"text":" more"}]}}]}"#,
            r#"{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.text","index":0,"signature":"sig"}]}}]}"#,
            r#"{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","index":1,"id":"tool_1","format":"google-gemini-v1","data":"ENC"}]}}]}"#,
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"tool_1","type":"function","function":{"name":"read","arguments":"{}"}}]}}]}"#,
            r#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ],
    );
    assert_eq!(st.out.thinking_text, "Plan more");
    assert_eq!(shown.concat(), "Plan more");
    assert_eq!(
        st.out.reasoning_blocks,
        [ReasoningBlock::OpenRouterDetails {
            details: vec![
                serde_json::json!({"type":"reasoning.text","index":0,"format":"anthropic-claude-v1","text":"Plan more","signature":"sig"}),
                serde_json::json!({"type":"reasoning.encrypted","index":1,"id":"tool_1","format":"google-gemini-v1","data":"ENC"}),
            ],
        }]
    );
    assert_eq!(st.out.tool_calls[0].call_id, "tool_1");
}

/// Encrypted reasoning streams a `[REDACTED]` placeholder: it is never shown; a delta with
/// only readable details shows their text.
#[test]
fn the_redacted_placeholder_is_never_shown() {
    let (st, shown) = run(
        ProviderDialect::CustomOpenAi,
        &[
            r#"{"choices":[{"delta":{"reasoning":"[REDACTED]","reasoning_details":[{"type":"reasoning.encrypted","index":0,"data":"X"}]}}]}"#,
            r#"{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.summary","index":1,"summary":"Sum"}]}}]}"#,
        ],
    );
    assert_eq!(shown, ["Sum"]);
    assert_eq!(st.out.thinking_text, "Sum");
}

/// Responses tool calls from a gateway that omits item ids stay separate: they are keyed by
/// `output_index`, which every streaming event carries.
#[test]
fn responses_calls_without_ids_stay_separate_by_output_index() {
    let (st, _) = run(
        ProviderDialect::OpenAi,
        &[
            r#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","name":"read"}}"#,
            r#"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","name":"grep"}}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\"path\":\"a\"}"}"#,
            r#"{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"pattern\":\"b\"}"}"#,
        ],
    );
    let calls: Vec<(&str, &str)> = st
        .out
        .tool_calls
        .iter()
        .map(|c| (c.name.as_str(), c.arguments_json.as_str()))
        .collect();
    assert_eq!(
        calls,
        [("read", r#"{"path":"a"}"#), ("grep", r#"{"pattern":"b"}"#)]
    );
}

/// A gateway that resends the whole function name on every chunk never doubles it; a name
/// split over chunks still joins.
#[test]
fn a_resent_chat_function_name_is_not_doubled() {
    let (st, _) = run(
        ProviderDialect::CustomOpenAi,
        &[
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"grep","arguments":""}}]}}]}"#,
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"grep","arguments":"{}"}}]}}]}"#,
            r#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c2","function":{"name":"re","arguments":""}}]}}]}"#,
            r#"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"ad","arguments":"{}"}}]}}]}"#,
        ],
    );
    let names: Vec<&str> = st.out.tool_calls.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, ["grep", "read"]);
}
