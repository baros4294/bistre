use super::*;
use tempfile::tempdir;

#[test]
fn mcp_schema_deferral_activates_past_six_tools() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempdir()?;
    let storage = StorageHandle::open(dir.path().join("t.sqlite"))?;
    let srv = McpServerConfig {
        id: "srv1".to_owned(),
        name: "Demo".to_owned(),
        transport: "http".to_owned(),
        command: String::new(),
        args: Vec::new(),
        url: "http://127.0.0.1:9999".to_owned(),
        enabled: true,
    };
    storage.set_kv_meta(
        "agent.mcp_servers".to_owned(),
        serde_json::to_string(&vec![srv])?,
    )?;
    let defs: Vec<McpDiscoveredTool> = (0..9)
        .map(|i| McpDiscoveredTool {
            server_id: "srv1".to_owned(),
            name: format!("tool_{i:02}"),
            description: format!("Desc {i}"),
            input_schema: json!({"type": "object", "properties": {}}),
            cache_ttl_ms: None,
        })
        .collect();
    storage.set_kv_meta(
        "mcp.tools_cache:srv1".to_owned(),
        serde_json::to_string(&defs)?,
    )?;

    let catalog = resolve_active_tool_catalog(&storage, ThreadMode::Chat)?;
    assert_eq!(catalog.deferred_mcp_schemas.len(), 3);
    assert!(
        catalog
            .canonical_schemas
            .iter()
            .any(|s| s.get("name").and_then(Value::as_str) == Some("mcp_schema"))
    );
    // 6 direct MCP tools + 1 `mcp_schema` loader = 7 schemas.
    assert_eq!(catalog.canonical_schemas.len(), 7);
    Ok(())
}

#[test]
fn wire_tool_formatting_matches_all_four_dialects() {
    let cat = ActiveToolCatalog {
        canonical_schemas: vec![json!({
            "name": "read",
            "description": "Read a file",
            "parameters": { "type": "object", "properties": { "path": { "type": "string" } } }
        })],
        ..ActiveToolCatalog::default()
    };
    let oai = cat.wire_tools_for_dialect(ProviderDialect::OpenAi);
    assert_eq!(oai[0]["type"], "function");
    assert_eq!(oai[0]["name"], "read");

    let anth = cat.wire_tools_for_dialect(ProviderDialect::Anthropic);
    assert!(anth[0].get("input_schema").is_some());

    let gem = cat.wire_tools_for_dialect(ProviderDialect::GoogleGemini);
    assert_eq!(gem[0]["type"], "function");

    let custom = cat.wire_tools_for_dialect(ProviderDialect::CustomOpenAi);
    assert_eq!(custom[0]["function"]["name"], "read");
}

#[expect(
    clippy::too_many_lines,
    reason = "Full 3-turn mock-HTTP integration test covering Tier-0 auto-read, Tier-1 pause, and Deny."
)]
#[tokio::test]
async fn end_to_end_agentic_tool_loop_reads_file_and_handles_approval_deny()
-> Result<(), Box<dyn std::error::Error>> {
    use crate::EngineClient;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrd};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    let dir = tempdir()?;
    let ws = dir.path().join("workspace");
    std::fs::create_dir_all(&ws)?;
    std::fs::write(ws.join("note.txt"), "hello wave2 tool loop\n")?;

    let turn_counter = Arc::new(AtomicUsize::new(0));
    let counter_clone = Arc::clone(&turn_counter);
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;

    let server = tokio::spawn(async move {
        for _ in 0..4 {
            let Ok((mut sock, _)) = listener.accept().await else {
                break;
            };
            let mut req_buf = vec![0_u8; 32_768];
            let n = sock.read(&mut req_buf).await.unwrap_or(0);
            let req_text = String::from_utf8_lossy(&req_buf[..n]).into_owned();
            let step = counter_clone.fetch_add(1, AtomicOrd::SeqCst);
            let body = match step {
                0 => concat!(
                    "data: {\"type\":\"response.output_item.added\",\"item\":{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_read_1\",\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"note.txt\\\"}\"}}\n\n",
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}\n\n",
                )
                .to_owned(),
                1 => {
                    assert!(
                        req_text.contains("hello wave2 tool loop"),
                        "Turn 2 wire payload must include paired tool_result output: {req_text}"
                    );
                    concat!(
                        "data: {\"type\":\"response.output_item.added\",\"item\":{\"id\":\"fc_2\",\"type\":\"function_call\",\"call_id\":\"call_edit_2\",\"name\":\"edit\",\"arguments\":\"{\\\"path\\\":\\\"note.txt\\\",\\\"target\\\":\\\"hello\\\",\\\"replacement\\\":\\\"hi\\\"}\"}}\n\n",
                        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"usage\":{\"input_tokens\":20,\"output_tokens\":6}}}\n\n",
                    )
                    .to_owned()
                }
                _ => {
                    assert!(
                        req_text.contains("denied by user"),
                        "Turn 3 wire payload must include synthetic denied tool_result: {req_text}"
                    );
                    concat!(
                        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Understood, I did not edit note.txt.\"}\n\n",
                        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_3\",\"usage\":{\"input_tokens\":30,\"output_tokens\":10}}}\n\n",
                    )
                    .to_owned()
                }
            };
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            if sock.write_all(resp.as_bytes()).await.is_err() {
                break;
            }
        }
    });

    let engine =
        crate::InProcessEngine::open(dir.path(), Some(bistre_crypto::VaultKey::generate()?))?;
    engine
        .set_kv_meta(
            "agent.workspace_root".to_owned(),
            ws.to_string_lossy().into_owned(),
        )
        .await?;
    let provider = engine
        .create_provider(
            "Mock OpenAI".to_owned(),
            ProviderDialect::OpenAi,
            format!("http://{addr}"),
            "gpt-test".to_owned(),
            "openai".to_owned(),
            String::new(),
            Some("sk-test-key".to_owned()),
        )
        .await?;
    let thread = engine
        .create_thread(None, "Tool Loop".to_owned(), ThreadMode::Code, None, None)
        .await?;
    engine
        .update_thread(
            thread.id.clone(),
            bistre_protocol::ThreadPatch {
                provider_id_override: Some(Some(provider.id.clone())),
                model_id_override: Some(Some("gpt-test".to_owned())),
                ..bistre_protocol::ThreadPatch::default()
            },
        )
        .await?;

    let mut rx = engine.subscribe_events();
    let _user_node = engine
        .send_and_stream_reply(
            thread.id.clone(),
            None,
            "Read note.txt then edit it".to_owned(),
        )
        .await?;

    let mut saw_approval_req = false;
    let mut saw_final_reply = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(200), rx.recv()).await {
            Ok(Ok(EngineEvent::ToolApprovalRequested {
                thread_id,
                call_id,
                tool_name,
                ..
            })) => {
                assert_eq!(tool_name, "edit");
                saw_approval_req = true;
                let delivered = engine
                    .respond_tool_approval(thread_id, call_id, ToolApprovalDecision::Deny)
                    .await?;
                assert!(delivered);
            }
            Ok(Ok(EngineEvent::NodeCommitted { node })) => {
                if node.role == NodeRole::Assistant
                    && node
                        .content
                        .contains("Understood, I did not edit note.txt.")
                {
                    saw_final_reply = true;
                }
            }
            Ok(Ok(EngineEvent::RunFinished { .. })) => break,
            _ => {}
        }
    }
    assert!(saw_approval_req, "Tier-1 edit must pause for approval");
    assert!(saw_final_reply, "Loop must complete cleanly after denial");
    assert_eq!(
        std::fs::read_to_string(ws.join("note.txt"))?,
        "hello wave2 tool loop\n"
    );
    server.abort();
    Ok(())
}
