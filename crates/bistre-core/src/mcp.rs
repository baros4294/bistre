//! MCP Client supporting Spec `2026-07-28` (`server/discover`, `Mcp-Method`/`Mcp-Name`,
//! `ttlMs`/`cacheScope`) with seamless legacy `2025-11-25` / `2025-03-26` negotiation,
//! noisy `stdout` banner quarantine, 64 KiB `stderr` ring buffering, and deterministic
//! prompt-cache-stable tool ordering (`ADR-0006`, `ADR-0018`: Streamable HTTP, no SDK).

use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use reqwest::header::{ACCEPT, CONTENT_TYPE, HeaderMap, HeaderValue};
use reqwest::{Method, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ssrf::PublicWebTransport;

/// Hard cap on per-tool MCP output payloads (`256 KiB`, ADR-0006).
pub const MAX_MCP_TOOL_RESULT_BYTES: usize = 256 * 1024;
/// Primary MCP 2026 stateless protocol revision.
pub const MCP_PROTOCOL_2026: &str = "2026-07-28";
/// Fallback legacy MCP protocol revision.
pub const MCP_PROTOCOL_2025: &str = "2025-11-25";
/// Network read cap for one MCP HTTP response (`4 x` the rendered tool-result cap).
pub const MAX_MCP_HTTP_RESPONSE_BYTES: usize = 4 * MAX_MCP_TOOL_RESULT_BYTES;
/// Hard per-call timeout for MCP HTTP requests.
pub const MCP_CALL_TIMEOUT: Duration = Duration::from_secs(60);
const MCP_SESSION_HEADER: &str = "Mcp-Session-Id";

/// HTTP transport for user-configured MCP servers.
///
/// Loopback servers (`127.0.0.0/8`, `::1`, `localhost`) use a dedicated no-proxy, no-redirect
/// client; every other host goes through `PublicWebTransport` (public IPs only, redirects refused).
#[derive(Debug, Clone)]
pub struct McpHttpTransport {
    local: Result<reqwest::Client, BistreError>,
    public: PublicWebTransport,
}

impl Default for McpHttpTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl McpHttpTransport {
    pub fn new() -> Self {
        let local = crate::http_clients::loopback_client(Duration::from_secs(5), MCP_CALL_TIMEOUT)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "mcp_client_init"));
        Self {
            local,
            public: PublicWebTransport::new(),
        }
    }

    async fn post(
        &self,
        url: &str,
        headers: HeaderMap,
        body: &Value,
    ) -> BistreResult<(StatusCode, HeaderMap, Vec<u8>)> {
        if !crate::net::is_loopback_url(url) {
            return self
                .public
                .send_json(
                    Method::POST,
                    url,
                    headers,
                    body,
                    MAX_MCP_HTTP_RESPONSE_BYTES,
                )
                .await;
        }
        let client = self.local.as_ref().map_err(Clone::clone)?;
        let mut resp = client
            .post(url)
            .headers(headers)
            .json(body)
            .send()
            .await
            .map_err(|_| {
                BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_connect")
            })?;
        let status = resp.status();
        let resp_headers = resp.headers().clone();
        let mut bytes = Vec::new();
        while let Some(chunk) = resp.chunk().await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_read")
        })? {
            if bytes.len() + chunk.len() > MAX_MCP_HTTP_RESPONSE_BYTES {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ProviderRequestFailed,
                    "mcp_response_too_large",
                ));
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok((status, resp_headers, bytes))
    }

    /// Sends a bodiless `DELETE` (session close); only the status matters.
    async fn delete(&self, url: &str, headers: HeaderMap) -> BistreResult<StatusCode> {
        if !crate::net::is_loopback_url(url) {
            return self
                .public
                .send_json(
                    Method::DELETE,
                    url,
                    headers,
                    &Value::Null,
                    MAX_MCP_HTTP_RESPONSE_BYTES,
                )
                .await
                .map(|(status, _, _)| status);
        }
        let client = self.local.as_ref().map_err(Clone::clone)?;
        client
            .delete(url)
            .headers(headers)
            .send()
            .await
            .map(|resp| resp.status())
            .map_err(|_| {
                BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_connect")
            })
    }
}

/// Per-server MCP session state (`Mcp-Session-Id`) with a single renewal on HTTP `404`.
#[derive(Debug)]
struct McpSession<'a> {
    transport: &'a McpHttpTransport,
    url: &'a str,
    bearer_token: Option<&'a str>,
    session_id: Option<String>,
    protocol_version: String,
    renewed: bool,
}

/// Persisted MCP server profile (`stdio` or Streamable `http`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct McpServerConfig {
    pub id: String,
    pub name: String,
    pub transport: String,
    pub command: String,
    pub args: Vec<String>,
    pub url: String,
    pub enabled: bool,
}

/// Discovered MCP tool descriptor (the MCP `Tool` fields Bistre uses).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct McpDiscoveredTool {
    pub server_id: String,
    pub name: String,
    pub description: String,
    pub input_schema: Value,
    pub cache_ttl_ms: Option<u64>,
}

/// Discovery report including negotiated MCP revision and any quarantined noisy stdout lines.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct McpDiscoveryReport {
    pub negotiated_protocol: String,
    pub tools: Vec<McpDiscoveredTool>,
    pub quarantined_stdout_lines: Vec<String>,
}

/// The subset of an MCP `Tool` object Bistre reads (spec field names).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireTool {
    name: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    input_schema: Option<Value>,
    #[serde(default)]
    ttl_ms: Option<u64>,
    #[serde(default, rename = "_meta")]
    meta: Option<Value>,
}

/// Normalizes and deterministically sorts MCP tools so LLM prompt-cache prefixes never churn
/// across reconnects. Entries without a string `name` are skipped.
pub fn normalize_and_sort_tools(server_id: &str, raw_tools: &[Value]) -> Vec<McpDiscoveredTool> {
    let mut out: Vec<McpDiscoveredTool> = raw_tools
        .iter()
        .filter_map(|raw| serde_json::from_value::<WireTool>(raw.clone()).ok())
        .map(|tool| McpDiscoveredTool {
            server_id: server_id.to_owned(),
            cache_ttl_ms: tool.ttl_ms.or_else(|| {
                tool.meta
                    .as_ref()
                    .and_then(|m| m.get("ttlMs"))
                    .and_then(Value::as_u64)
            }),
            name: tool.name,
            description: tool.description.unwrap_or_default(),
            input_schema: tool
                .input_schema
                .unwrap_or_else(|| json!({ "type": "object" })),
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out.dedup_by(|a, b| a.name == b.name);
    out
}

impl McpSession<'_> {
    async fn rpc(
        &mut self,
        method: &str,
        tool_name: Option<&str>,
        body: &Value,
    ) -> BistreResult<Value> {
        let req_id = body.get("id").and_then(Value::as_u64);
        loop {
            let headers = mcp_headers(
                self.url,
                method,
                tool_name,
                self.session_id.as_deref(),
                &self.protocol_version,
                self.bearer_token,
            )?;
            let (status, resp_headers, bytes) =
                self.transport.post(self.url, headers, body).await?;
            if let Some(id) = resp_headers
                .get(MCP_SESSION_HEADER)
                .and_then(|v| v.to_str().ok())
                .filter(|v| !v.is_empty() && v.len() <= 256)
            {
                self.session_id = Some(id.to_owned());
            }
            // An expired session answers 404: re-initialize exactly once, then retry the call.
            if status == StatusCode::NOT_FOUND
                && self.session_id.is_some()
                && !self.renewed
                && method != "initialize"
            {
                self.renewed = true;
                self.session_id = None;
                self.initialize().await?;
                continue;
            }
            if !status.is_success() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ProviderRequestFailed,
                    format!("mcp_http_{}", status.as_u16()),
                ));
            }
            let content_type = resp_headers
                .get(CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_ascii_lowercase();
            let val = if content_type.contains("text/event-stream") {
                decode_mcp_sse_response(&bytes, req_id)?
            } else {
                serde_json::from_slice::<Value>(&bytes).map_err(|_| {
                    BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_json")
                })?
            };
            // R17: a JSON-RPC `error` is an error on the HTTP path too.
            return json_rpc_result(val);
        }
    }

    async fn initialize(&mut self) -> BistreResult<Value> {
        MCP_PROTOCOL_2025.clone_into(&mut self.protocol_version);
        let init_body = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": MCP_PROTOCOL_2025,
                "capabilities": {},
                "clientInfo": { "name": "Bistre", "version": crate::CORE_VERSION }
            }
        });
        let resp = Box::pin(self.rpc("initialize", None, &init_body)).await?;
        if let Some(ver) = resp
            .pointer("/result/protocolVersion")
            .and_then(Value::as_str)
        {
            ver.clone_into(&mut self.protocol_version);
        }
        // Best-effort `notifications/initialized` per Streamable HTTP spec (202 Accepted or 200 OK).
        let notif = json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        });
        if let Ok(headers) = mcp_headers(
            self.url,
            "notifications/initialized",
            None,
            self.session_id.as_deref(),
            &self.protocol_version,
            self.bearer_token,
        ) && let Err(err) = self.transport.post(self.url, headers, &notif).await
        {
            tracing::debug!(
                key = err.key.as_key(),
                "mcp notifications/initialized ignored"
            );
        }
        Ok(resp)
    }

    /// Ends a 2025-11-25 session with `DELETE` (spec: clients should close sessions they no
    /// longer need). Best effort: a failure is logged, and the server expires it anyway.
    async fn close(&mut self) {
        let Some(id) = self.session_id.take() else {
            return;
        };
        let headers = match mcp_headers(
            self.url,
            "session/close",
            None,
            Some(&id),
            &self.protocol_version,
            self.bearer_token,
        ) {
            Ok(h) => h,
            Err(err) => {
                tracing::warn!(key = err.key.as_key(), "mcp session close skipped");
                return;
            }
        };
        if let Err(err) = self.transport.delete(self.url, headers).await {
            tracing::debug!(key = err.key.as_key(), "mcp session close failed");
        }
    }
}

/// Decodes a Streamable HTTP `text/event-stream` MCP response using `SseFramer`, returning the
/// JSON-RPC payload matching `expected_id` (or the final JSON-RPC object in the stream).
fn decode_mcp_sse_response(bytes: &[u8], expected_id: Option<u64>) -> BistreResult<Value> {
    let mut sse = crate::sse::SseFramer::new();
    let mut events = sse.push_bytes(bytes)?;
    events.extend(sse.finish());
    let mut fallback: Option<Value> = None;
    for payload in events {
        if let Ok(val) = serde_json::from_str::<Value>(&payload) {
            if let Some(eid) = expected_id
                && val.get("id").and_then(Value::as_u64) == Some(eid)
            {
                return Ok(val);
            }
            if val.get("result").is_some() || val.get("error").is_some() {
                fallback = Some(val);
            }
        }
    }
    fallback.ok_or_else(|| {
        BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_sse_empty")
    })
}

fn mcp_headers(
    url: &str,
    method: &str,
    tool_name: Option<&str>,
    session_id: Option<&str>,
    protocol_version: &str,
    bearer_token: Option<&str>,
) -> BistreResult<HeaderMap> {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(
        ACCEPT,
        HeaderValue::from_static("application/json, text/event-stream"),
    );
    if let Ok(pv) = HeaderValue::from_str(protocol_version) {
        headers.insert("MCP-Protocol-Version", pv);
    }
    if let Ok(m) = HeaderValue::from_str(method) {
        headers.insert("Mcp-Method", m);
    }
    if let Some(tn) = tool_name
        && let Ok(v) = HeaderValue::from_str(tn)
    {
        headers.insert("Mcp-Name", v);
    }
    if let Some(id) = session_id
        && let Ok(v) = HeaderValue::from_str(id)
    {
        headers.insert(MCP_SESSION_HEADER, v);
    }
    if let Some(tok) = bearer_token.map(str::trim).filter(|t| !t.is_empty()) {
        // Fail closed: bearer tokens are ONLY sent over HTTPS or parsed loopback hosts (AGENTS.md §7).
        let safe_scheme = url.starts_with("https://") || crate::net::is_loopback_url(url);
        if !safe_scheme {
            return Err(BistreError::with_detail(
                DiagnosticKey::NetworkDestinationBlocked,
                "mcp_bearer_requires_https_or_loopback",
            ));
        }
        let clean: String = tok.chars().filter(|c| !c.is_control()).collect();
        if let Ok(val) = HeaderValue::from_str(&format!("Bearer {clean}")) {
            headers.insert(reqwest::header::AUTHORIZATION, val);
        }
    }
    Ok(headers)
}

fn validate_mcp_url(url: &str) -> BistreResult<&str> {
    let url = url.trim();
    if url.starts_with("https://") || url.starts_with("http://") {
        Ok(url)
    } else {
        Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_mcp_url",
        ))
    }
}

/// Unified MCP discovery entrypoint dispatching `stdio` vs Streamable `http`.
pub async fn discover_mcp_server(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
    bearer_token: Option<&str>,
) -> BistreResult<McpDiscoveryReport> {
    if server.transport.eq_ignore_ascii_case("stdio") {
        return crate::mcp_stdio::discover_stdio_mcp_server(server).await;
    }
    discover_http_mcp_server_with_auth(transport, server, bearer_token).await
}

/// Discovers tools from a Streamable HTTP MCP server using `2026-07-28` `server/discover` first,
/// falling back seamlessly to legacy `2025-11-25` (`initialize` -> `tools/list`).
pub async fn discover_http_mcp_server(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
) -> BistreResult<McpDiscoveryReport> {
    discover_http_mcp_server_with_auth(transport, server, None).await
}

/// Streamable HTTP MCP discovery with optional fail-closed Vault Bearer auth.
pub async fn discover_http_mcp_server_with_auth(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
    bearer_token: Option<&str>,
) -> BistreResult<McpDiscoveryReport> {
    let url = validate_mcp_url(&server.url)?;
    let mut session = McpSession {
        transport,
        url,
        bearer_token,
        session_id: None,
        protocol_version: MCP_PROTOCOL_2026.to_owned(),
        renewed: false,
    };

    // 1. Probe MCP 2026-07-28 stateless `server/discover` with `Mcp-Method` header.
    let discover_body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "server/discover",
        "params": { "protocolVersion": MCP_PROTOCOL_2026 }
    });
    match session.rpc("server/discover", None, &discover_body).await {
        Ok(resp) => {
            if let Some(result) = resp.get("result")
                && let Some(raw_tools) = result.get("tools").and_then(Value::as_array)
            {
                return Ok(McpDiscoveryReport {
                    negotiated_protocol: MCP_PROTOCOL_2026.to_owned(),
                    tools: normalize_and_sort_tools(&server.id, raw_tools),
                    quarantined_stdout_lines: Vec::new(),
                });
            }
        }
        Err(err) if err.key == DiagnosticKey::NetworkDestinationBlocked => return Err(err),
        Err(_) => {}
    }

    // 2. Fallback seamlessly to MCP 2025-11-25 `initialize` + `tools/list` (session-aware).
    session.initialize().await?;
    let list_body = json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
        "params": {}
    });
    let list_resp = session.rpc("tools/list", None, &list_body).await?;
    let raw_tools = list_resp
        .get("result")
        .and_then(|r| r.get("tools"))
        .and_then(Value::as_array)
        .map_or(&[][..], Vec::as_slice);

    Ok(McpDiscoveryReport {
        negotiated_protocol: session.protocol_version,
        tools: normalize_and_sort_tools(&server.id, raw_tools),
        quarantined_stdout_lines: Vec::new(),
    })
}

/// A JSON-RPC response as a result: an `error` member is an error (R17), carrying the code and
/// the server's own message (bounded and sanitized, P4), never a successful tool result.
pub fn json_rpc_result(val: Value) -> BistreResult<Value> {
    let Some(err) = val.get("error") else {
        return Ok(val);
    };
    let code = err.get("code").and_then(Value::as_i64).unwrap_or(-32000);
    let mut detail = format!("mcp_rpc_error_{code}");
    if let Some(msg) = err
        .get("message")
        .and_then(Value::as_str)
        .map(crate::finish::sanitize_reason)
        .filter(|m| !m.is_empty())
    {
        detail.push_str(";reason=");
        detail.push_str(&msg);
    }
    Err(BistreError::with_detail(
        DiagnosticKey::ProviderRequestFailed,
        detail,
    ))
}

/// Unified MCP tool-call entrypoint dispatching `stdio` vs Streamable `http` and returning rich
/// parsed output (`text`, `is_error`, and persisted `media_attachments`).
pub async fn call_mcp_tool_rich(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
    bearer_token: Option<&str>,
    tool_name: &str,
    arguments: &Value,
    data_dir: Option<&std::path::Path>,
) -> BistreResult<crate::mcp_stdio::McpToolCallOutput> {
    if server.transport.eq_ignore_ascii_case("stdio") {
        return crate::mcp_stdio::call_stdio_mcp_tool(server, tool_name, arguments, data_dir).await;
    }
    let url = validate_mcp_url(&server.url)?;
    let mut session = McpSession {
        transport,
        url,
        bearer_token,
        session_id: None,
        protocol_version: MCP_PROTOCOL_2026.to_owned(),
        renewed: false,
    };
    let body = json!({
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": arguments
        }
    });
    // A-S9: negotiate first so `tools/call` is sent exactly once. MCP 2026-07-28 answers the
    // stateless, side-effect-free `server/discover`; otherwise open a 2025-11-25 session. A
    // failed call is an error and never resent (it may already have run); only an expired
    // session (HTTP 404) is renewed once, inside `rpc`, as the spec requires.
    let discover_body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "server/discover",
        "params": { "protocolVersion": MCP_PROTOCOL_2026 }
    });
    match session.rpc("server/discover", None, &discover_body).await {
        Ok(resp) if resp.get("result").is_some() => {}
        Err(err) if err.key == DiagnosticKey::NetworkDestinationBlocked => return Err(err),
        Ok(_) | Err(_) => {
            session.initialize().await?;
        }
    }
    let called = session.rpc("tools/call", Some(tool_name), &body).await;
    session.close().await;
    let resp = called?;
    let result = resp.get("result").unwrap_or(&resp);
    Ok(crate::mcp_stdio::parse_mcp_call_result(result, data_dir))
}

/// Calls a tool on a Streamable HTTP MCP server with `256 KiB` payload capping and `Mcp-Method`/`Mcp-Name` headers.
pub async fn call_http_mcp_tool(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
    tool_name: &str,
    arguments: &Value,
) -> BistreResult<String> {
    call_mcp_tool_rich(transport, server, None, tool_name, arguments, None)
        .await
        .map(|o| o.text)
}

#[cfg(test)]
mod tests {
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
                json!({"name": "m_tool", "_meta": {"ttlMs": 5000}}),
            ],
        );
        let names: Vec<&str> = sorted.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["a_tool", "m_tool", "z_tool"]);
        assert_eq!(sorted[1].cache_ttl_ms, Some(5000));
        assert_eq!(sorted[1].input_schema, json!({ "type": "object" }));
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
    async fn streamable_http_sse_response_decodes_and_bearer_fails_closed_on_remote_http()
    -> TestResult {
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
            Scripted::json(200, &json!({"jsonrpc":"2.0","id":1,"result":{"tools":[]}})),
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
        Ok(())
    }

    /// A-S9: `tools/call` is sent exactly once: the protocol is negotiated first, a 400 is an
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

    /// R17: a JSON-RPC `error` over HTTP is an error, not a successful tool result.
    #[tokio::test]
    async fn an_http_json_rpc_error_is_an_error_not_a_result() -> TestResult {
        use crate::test_support::{MockServer, Scripted};
        let server = MockServer::start(vec![
            Scripted::json(
                200,
                &json!({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2026-07-28"}}),
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
}
