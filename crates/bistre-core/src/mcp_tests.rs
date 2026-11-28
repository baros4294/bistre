//! Streamable HTTP MCP client tests against a scripted local server.

use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn tools_sort_deterministically_and_skip_nameless_entries() {
    let sorted = normalize_and_sort_tools(
        "srv1",
        &[
            json!({"name": "z_tool", "description": "Z", "inputSchema": {"type": "object"}}),
            json!({"name": "a_tool", "description": "A", "inputSchema": {"type": "object"}}),
            json!({"description": "no name"}),
            json!({"name": "m_tool"}),
        ],
        crate::mcp_era::ListCache::default(),
    );
    let names: Vec<&str> = sorted.iter().map(|t| t.name.as_str()).collect();
    assert_eq!(names, ["a_tool", "m_tool", "z_tool"]);
    assert_eq!(sorted[1].input_schema, json!({ "type": "object" }));
}

/// `ttlMs` and `cacheScope` sit on each `tools/list` result: the shortest `ttlMs` over the
/// pages holds, and one private page makes the list private.
#[test]
fn the_list_cache_fields_come_from_every_page() {
    let mut cache = crate::mcp_era::ListCache::default();
    let mut tools = Vec::new();
    let next = crate::mcp_era::take_tools_page(
        &json!({"tools": [{"name": "a"}], "nextCursor": "p2", "ttlMs": 60000, "cacheScope": "public"}),
        None,
        &mut tools,
        &mut cache,
    );
    assert_eq!(next.as_deref(), Some("p2"));
    crate::mcp_era::take_tools_page(
        &json!({"tools": [{"name": "b", "ttlMs": 1}], "ttlMs": 5000, "cacheScope": "private"}),
        next.as_deref(),
        &mut tools,
        &mut cache,
    );
    let listed = normalize_and_sort_tools("srv1", &tools, cache);
    assert_eq!(listed.len(), 2);
    assert!(
        listed
            .iter()
            .all(|t| t.cache_ttl_ms == Some(5000) && t.cache_private)
    );
}

#[tokio::test]
async fn mcp_dual_negotiation_supports_2026_discover_and_2025_fallback() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let Ok(addr) = listener.local_addr() else {
        return Ok(());
    };

    // Server rejects `server/discover` (HTTP 404) and responds to legacy `initialize` + `tools/list`.
    let server_task = tokio::spawn(async move {
        for _ in 0..4 {
            let Ok((mut sock, _)) = listener.accept().await else {
                break;
            };
            let mut buf = [0_u8; 4096];
            let n = sock.read(&mut buf).await.unwrap_or(0);
            let req = String::from_utf8_lossy(&buf[..n]);
            let (status, body) = if req.contains("server/discover") {
                ("404 Not Found", r#"{"error":"not_supported"}"#)
            } else if req.contains("notifications/initialized") {
                ("202 Accepted", "")
            } else if req.contains("initialize") {
                (
                    "200 OK\r\nMcp-Session-Id: sess-1",
                    r#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}"#,
                )
            } else if !req.to_ascii_lowercase().contains("mcp-session-id: sess-1") {
                ("400 Bad Request", r#"{"error":"missing_session"}"#)
            } else {
                (
                    "200 OK",
                    r#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"docs_search","description":"Search docs","inputSchema":{"type":"object"}}]}}"#,
                )
            };
            let resp = format!(
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            assert!(sock.write_all(resp.as_bytes()).await.is_ok());
        }
    });

    let transport = McpHttpTransport::new();
    let cfg = McpServerConfig {
        id: "legacy".to_owned(),
        name: "Legacy MCP".to_owned(),
        transport: "http".to_owned(),
        command: String::new(),
        args: Vec::new(),
        url: format!("http://{addr}/mcp"),
        enabled: true,
    };
    let report = Some(discover_http_mcp_server(&transport, &cfg).await?);
    assert!(server_task.await.is_ok());
    assert_eq!(
        report.as_ref().map(|r| r.negotiated_protocol.as_str()),
        Some(MCP_PROTOCOL_2025)
    );
    assert_eq!(report.as_ref().map(|r| r.tools.len()), Some(1));
    Ok(())
}

#[test]
fn loopback_detection_and_public_routing() {
    assert!(crate::net::is_loopback_url("http://127.0.0.1:3000/mcp"));
    assert!(crate::net::is_loopback_url("http://localhost:8931/mcp"));
    assert!(crate::net::is_loopback_url("http://[::1]:9000/"));
    assert!(!crate::net::is_loopback_url("http://192.168.1.10/mcp"));
    assert!(!crate::net::is_loopback_url("https://mcp.example.com/mcp"));
}

#[tokio::test]
async fn private_lan_mcp_hosts_are_refused() {
    let transport = McpHttpTransport::new();
    let cfg = McpServerConfig {
        id: "lan".to_owned(),
        name: "LAN".to_owned(),
        transport: "http".to_owned(),
        command: String::new(),
        args: Vec::new(),
        url: "http://10.0.0.5:3000/mcp".to_owned(),
        enabled: true,
    };
    let err = call_http_mcp_tool(&transport, &cfg, "x", &json!({}))
        .await
        .err();
    assert_eq!(
        err.map(|e| e.key),
        Some(DiagnosticKey::NetworkDestinationBlocked)
    );
}

#[tokio::test]
async fn streamable_http_sse_response_decodes_and_bearer_fails_closed_on_remote_http() -> TestResult
{
    use crate::test_support::{MockServer, Scripted};
    // 1. Bearer token on non-loopback plain HTTP MUST fail closed before any socket opens.
    let transport = McpHttpTransport::new();
    let remote_http = McpServerConfig {
        id: "remote".to_owned(),
        name: "Remote".to_owned(),
        transport: "http".to_owned(),
        command: String::new(),
        args: Vec::new(),
        url: "http://mcp.example.com/mcp".to_owned(),
        enabled: true,
    };
    let err = discover_mcp_server(&transport, &remote_http, Some("secret-tok"))
        .await
        .err();
    assert_eq!(
        err.as_ref().map(|e| e.key),
        Some(DiagnosticKey::NetworkDestinationBlocked)
    );
    assert_eq!(
        err.and_then(|e| e.detail_code),
        Some("mcp_bearer_requires_https_or_loopback".to_owned())
    );

    // 2. Streamable HTTP `text/event-stream` response decodes via SseFramer. The call
    //    negotiates first: this server speaks 2026-07-28 (`server/discover` succeeds).
    let sse = concat!(
        "event: message\n",
        "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n",
        "event: message\n",
        "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"sse ok\"}]}}\n\n",
    );
    let server = MockServer::start(vec![
        Scripted::json(200, &json!({"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}})),
        Scripted::sse(sse),
    ])
    .await?;
    let local_cfg = McpServerConfig {
        id: "local-sse".to_owned(),
        name: "Local SSE".to_owned(),
        transport: "http".to_owned(),
        command: String::new(),
        args: Vec::new(),
        url: format!("{}/mcp", server.base()),
        enabled: true,
    };
    let out = call_mcp_tool_rich(
        &transport,
        &local_cfg,
        Some("local-tok"),
        "ping",
        &json!({}),
        None,
    )
    .await?;
    assert!(!out.is_error);
    assert_eq!(out.text, "sse ok");
    let seen = server.finish().await;
    assert_eq!(seen.len(), 2, "stateless 2026 server: no session to close");
    let call = &seen[1];
    assert_eq!(call.header("mcp-method"), Some("tools/call"));
    assert!(
        call.header("accept")
            .is_some_and(|a| a.contains("text/event-stream"))
    );
    assert_eq!(call.header("authorization"), Some("Bearer local-tok"));
    let body = call.body_json()?;
    assert_eq!(
        body["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"], MCP_PROTOCOL_2026,
        "a modern request carries its version: {body}"
    );
    Ok(())
}

/// `tools/call` is sent exactly once: the protocol is negotiated first, a 400 is an
/// error (never a resend that could run the tool twice), and the session is closed.
#[tokio::test]
async fn a_failed_tool_call_is_never_resent_and_the_session_is_closed() -> TestResult {
    use crate::test_support::{MockServer, Scripted};
    let server = MockServer::start(vec![
        Scripted::status(404),
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}),
        )
        .with_header("Mcp-Session-Id", "sess-1"),
        Scripted::status(202),
        Scripted::json(400, &json!({"error":"bad"})),
        Scripted::status(200),
    ])
    .await?;
    let cfg = McpServerConfig {
        id: "s".to_owned(),
        name: "S".to_owned(),
        transport: "http".to_owned(),
        command: String::new(),
        args: Vec::new(),
        url: format!("{}/mcp", server.base()),
        enabled: true,
    };
    let transport = McpHttpTransport::new();
    let res = call_mcp_tool_rich(&transport, &cfg, None, "deploy", &json!({}), None).await;
    assert!(res.is_err());
    let seen = server.finish().await;
    let methods: Vec<_> = seen
        .iter()
        .map(|r| {
            (
                r.method.clone(),
                r.header("mcp-method").unwrap_or("").to_owned(),
            )
        })
        .collect();
    assert_eq!(
        methods.iter().filter(|(_, m)| m == "tools/call").count(),
        1,
        "{methods:?}"
    );
    assert_eq!(
        methods.last().map(|(verb, _)| verb.as_str()),
        Some("DELETE"),
        "the session is closed: {methods:?}"
    );
    Ok(())
}

/// A server dropped from the list gets its legacy session closed with `DELETE`, carrying the
/// session id; a modern era has no session to close.
#[tokio::test]
async fn a_dropped_servers_legacy_session_is_closed_with_delete() -> TestResult {
    use crate::mcp_era::{HttpEra, forget_http_eras_except, http_era_key, remember_http_era};
    use crate::test_support::{MockServer, Scripted};
    let server = MockServer::start(vec![Scripted::json(200, &json!({}))]).await?;
    let gone = http_server("dropped-http", server.base());
    let stays = http_server("kept-http", server.base());
    let legacy = HttpEra::Legacy {
        session_id: Some("s-41".to_owned()),
        protocol_version: "2025-11-25".to_owned(),
    };
    remember_http_era(&http_era_key(&gone), legacy);
    remember_http_era(&http_era_key(&stays), HttpEra::Modern);
    let kept: std::collections::HashSet<String> = std::iter::once(http_era_key(&stays)).collect();
    let dropped: Vec<(String, HttpEra)> = forget_http_eras_except(Some(&kept))
        .into_iter()
        .filter(|(k, _)| *k == http_era_key(&gone) || *k == http_era_key(&stays))
        .collect();
    assert_eq!(
        dropped.len(),
        1,
        "only the dropped server's era is forgotten"
    );
    assert_eq!(
        cached_http_era(&http_era_key(&stays)),
        Some(HttpEra::Modern)
    );
    let transport = McpHttpTransport::new();
    for (_, era) in dropped {
        close_http_session(&transport, &gone, None, era).await;
    }
    close_http_session(&transport, &stays, None, HttpEra::Modern).await;
    let seen = server.finish().await;
    assert_eq!(seen.len(), 1, "a modern era sends nothing");
    assert_eq!(seen[0].method, "DELETE");
    assert_eq!(seen[0].header("mcp-session-id"), Some("s-41"));
    Ok(())
}

/// A JSON-RPC `error` over HTTP is an error, not a successful tool result.
#[tokio::test]
async fn an_http_json_rpc_error_is_an_error_not_a_result() -> TestResult {
    use crate::test_support::{MockServer, Scripted};
    let server = MockServer::start(vec![
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}),
        ),
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Unknown tool: deploy"}}),
        ),
    ])
    .await?;
    let cfg = McpServerConfig {
        id: "s".to_owned(),
        name: "S".to_owned(),
        transport: "http".to_owned(),
        command: String::new(),
        args: Vec::new(),
        url: format!("{}/mcp", server.base()),
        enabled: true,
    };
    let transport = McpHttpTransport::new();
    let res = call_mcp_tool_rich(&transport, &cfg, None, "deploy", &json!({}), None).await;
    let detail = res.err().and_then(|e| e.detail_code).unwrap_or_default();
    assert!(detail.starts_with("mcp_rpc_error_-32602"), "{detail}");
    assert!(detail.contains("reason=Unknown tool: deploy"), "{detail}");
    drop(server.finish().await);
    Ok(())
}

fn http_server(id: &str, base: &str) -> McpServerConfig {
    McpServerConfig {
        id: id.to_owned(),
        name: id.to_owned(),
        transport: "http".to_owned(),
        command: String::new(),
        args: Vec::new(),
        url: format!("{base}/mcp"),
        enabled: true,
    }
}

/// A `2026-07-28` server's `server/discover` result lists no tools: discovery then sends
/// `tools/list` with `_meta`, and never `initialize`.
#[tokio::test]
async fn a_modern_http_server_is_discovered_without_initialize() -> TestResult {
    use crate::test_support::{MockServer, Scripted};
    let server = MockServer::start(vec![
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}),
        ),
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","tools":[{"name":"search","inputSchema":{"type":"object"}}]}}),
        ),
    ])
    .await?;
    let cfg = http_server("modern-http", server.base());
    let report = discover_http_mcp_server(&McpHttpTransport::new(), &cfg).await?;
    assert_eq!(report.negotiated_protocol, MCP_PROTOCOL_2026);
    assert_eq!(report.tools.len(), 1);
    let seen = server.finish().await;
    let methods: Vec<&str> = seen.iter().filter_map(|r| r.header("mcp-method")).collect();
    assert_eq!(methods, ["server/discover", "tools/list"]);
    let list = seen[1].body_json()?;
    assert_eq!(
        list["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"],
        MCP_PROTOCOL_2026
    );
    Ok(())
}

/// `tools/list` pages are read until `nextCursor` ends, each request carrying the cursor
/// the page before it gave; a cursor the server repeats ends the walk.
#[tokio::test]
async fn http_discovery_follows_next_cursor_and_stops_on_a_repeat() -> TestResult {
    use crate::test_support::{MockServer, Scripted};
    let page = |id: u64, name: &str, next: &str| {
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":id,"result":{"resultType":"complete","tools":[{"name":name,"inputSchema":{"type":"object"}}],"nextCursor":next}}),
        )
    };
    let server = MockServer::start(vec![
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}),
        ),
        page(2, "alpha", "c2"),
        page(3, "beta", "c3"),
        page(4, "gamma", "c3"),
    ])
    .await?;
    let cfg = http_server("paged-http", server.base());
    let report = discover_http_mcp_server(&McpHttpTransport::new(), &cfg).await?;
    let names: Vec<&str> = report.tools.iter().map(|t| t.name.as_str()).collect();
    assert_eq!(names, ["alpha", "beta", "gamma"]);
    let seen = server.finish().await;
    let cursors: Vec<Value> = seen[1..]
        .iter()
        .map(|r| r.body_json().map(|b| b["params"]["cursor"].clone()))
        .collect::<Result<_, _>>()?;
    assert_eq!(cursors, [Value::Null, json!("c2"), json!("c3")]);
    Ok(())
}

/// A recognized modern error (`UnsupportedProtocolVersion` in a `400` body) is surfaced:
/// the client never falls back to `initialize` on a modern server.
#[tokio::test]
async fn a_modern_protocol_error_never_falls_back_to_initialize() -> TestResult {
    use crate::test_support::{MockServer, Scripted};
    let server = MockServer::start(vec![Scripted::json(
        400,
        &json!({"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2027-01-01"]}}}),
    )])
    .await?;
    let cfg = http_server("modern-error", server.base());
    let err = discover_http_mcp_server(&McpHttpTransport::new(), &cfg)
        .await
        .err()
        .and_then(|e| e.detail_code)
        .unwrap_or_default();
    assert!(err.starts_with("mcp_rpc_error_-32022"), "{err}");
    assert_eq!(
        server.finish().await.len(),
        1,
        "no initialize after a modern error"
    );
    Ok(())
}

/// A `2025-11-25` session is kept for the next call, so a stateful server keeps its state
/// between the tool calls of a run (one `initialize`, the same session id on both calls).
#[tokio::test]
async fn a_legacy_session_is_reused_across_calls() -> TestResult {
    use crate::test_support::{MockServer, Scripted};
    let result = json!({"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"ok"}]}});
    let server = MockServer::start(vec![
        Scripted::status(404),
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}),
        )
        .with_header("Mcp-Session-Id", "sess-7"),
        Scripted::status(202),
        Scripted::json(200, &result),
        Scripted::json(200, &result),
    ])
    .await?;
    let cfg = http_server("legacy-reuse", server.base());
    let transport = McpHttpTransport::new();
    for _ in 0..2 {
        let out = call_mcp_tool_rich(&transport, &cfg, None, "browse", &json!({}), None).await?;
        assert_eq!(out.text, "ok");
    }
    let seen = server.finish().await;
    let calls: Vec<Option<&str>> = seen
        .iter()
        .filter(|r| r.header("mcp-method") == Some("tools/call"))
        .map(|r| r.header("mcp-session-id"))
        .collect();
    assert_eq!(calls, [Some("sess-7"), Some("sess-7")]);
    assert_eq!(
        seen.iter()
            .filter(|r| r.header("mcp-method") == Some("initialize"))
            .count(),
        1
    );
    Ok(())
}

/// An interim `input_required` result over HTTP fails closed, like on stdio.
#[tokio::test]
async fn an_http_input_required_result_fails_closed() -> TestResult {
    use crate::test_support::{MockServer, Scripted};
    let server = MockServer::start(vec![
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{}}}),
        ),
        Scripted::json(
            200,
            &json!({"jsonrpc":"2.0","id":3,"result":{"resultType":"input_required","inputRequests":{}}}),
        ),
    ])
    .await?;
    let cfg = http_server("http-input", server.base());
    let res = call_mcp_tool_rich(&McpHttpTransport::new(), &cfg, None, "t", &json!({}), None).await;
    assert_eq!(
        res.err().and_then(|e| e.detail_code).as_deref(),
        Some("mcp_input_required")
    );
    drop(server.finish().await);
    Ok(())
}
