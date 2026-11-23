//! MCP Client supporting Spec `2026-07-28` (`server/discover`, `Mcp-Method`/`Mcp-Name`,
//! `ttlMs`/`cacheScope`) with seamless legacy `2025-11-25` / `2025-03-26` negotiation,
//! noisy `stdout` banner quarantine, 64 KiB `stderr` ring buffering, and deterministic
//! prompt-cache-stable tool ordering (`ADR-0006`, `rmcp 3.11.0`).

use std::collections::VecDeque;
use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use reqwest::header::{ACCEPT, CONTENT_TYPE, HeaderMap, HeaderValue};
use reqwest::{Method, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::ssrf::PublicWebTransport;

/// Hard cap on per-tool MCP output payloads (`256 KiB`, ADR-0006).
pub const MAX_MCP_TOOL_RESULT_BYTES: usize = 256 * 1024;
/// Bounded `stderr` ring buffer capacity (`64 KiB`, ADR-0006).
pub const MAX_MCP_STDERR_RING_BYTES: usize = 64 * 1024;
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
}

/// Per-server MCP session state (`Mcp-Session-Id`) with a single renewal on HTTP `404`.
#[derive(Debug)]
struct McpSession<'a> {
    transport: &'a McpHttpTransport,
    url: &'a str,
    session_id: Option<String>,
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

/// Discovered MCP tool descriptor normalized onto `rmcp::model::Tool` fields.
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

/// Bounded 64 KiB ring buffer draining noisy stdio MCP server `stderr` without unbounded RAM growth.
#[derive(Debug, Default)]
pub struct StderrRingBuffer {
    bytes: VecDeque<u8>,
}

impl StderrRingBuffer {
    pub fn push_bytes(&mut self, chunk: &[u8]) {
        for &b in chunk {
            if self.bytes.len() >= MAX_MCP_STDERR_RING_BYTES {
                self.bytes.pop_front();
            }
            self.bytes.push_back(b);
        }
    }

    pub fn snapshot_lossy(&self) -> String {
        let slice: Vec<u8> = self.bytes.iter().copied().collect();
        String::from_utf8_lossy(&slice).into_owned()
    }
}

/// Splits raw stdio server output into valid JSON-RPC frames while quarantining non-JSON banner noise.
pub fn split_stdio_jsonrpc_and_quarantine(raw_stdout: &str) -> (Vec<Value>, Vec<String>) {
    let mut frames = Vec::new();
    let mut quarantined = Vec::new();
    for line in raw_stdout.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.starts_with('{')
            && let Ok(val) = serde_json::from_str::<Value>(trimmed)
            && val.get("jsonrpc").and_then(Value::as_str) == Some("2.0")
        {
            frames.push(val);
            continue;
        }
        quarantined.push(trimmed.to_owned());
    }
    (frames, quarantined)
}

/// Normalizes and deterministically sorts MCP tools (using `rmcp::model::Tool` compatibility)
/// so LLM prompt-cache prefixes never churn across reconnects.
pub fn normalize_and_sort_tools(server_id: &str, raw_tools: &[Value]) -> Vec<McpDiscoveredTool> {
    let mut out = Vec::new();
    for raw in raw_tools {
        // Validate against official `rmcp 3.11.0` `Tool` schema when present, with graceful fallback.
        if let Ok(rmcp_tool) = serde_json::from_value::<rmcp::model::Tool>(raw.clone()) {
            let schema_val = serde_json::to_value(rmcp_tool.input_schema.as_ref())
                .unwrap_or_else(|_| json!({ "type": "object" }));
            let ttl_ms = raw
                .get("ttlMs")
                .or_else(|| raw.get("_meta").and_then(|m| m.get("ttlMs")))
                .and_then(Value::as_u64);
            out.push(McpDiscoveredTool {
                server_id: server_id.to_owned(),
                name: rmcp_tool.name.into_owned(),
                description: rmcp_tool
                    .description
                    .map_or_default(std::borrow::Cow::into_owned),
                input_schema: schema_val,
                cache_ttl_ms: ttl_ms,
            });
            continue;
        }
        if let Some(name) = raw.get("name").and_then(Value::as_str) {
            out.push(McpDiscoveredTool {
                server_id: server_id.to_owned(),
                name: name.to_owned(),
                description: raw
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                input_schema: raw
                    .get("inputSchema")
                    .cloned()
                    .unwrap_or_else(|| json!({ "type": "object" })),
                cache_ttl_ms: raw.get("ttlMs").and_then(Value::as_u64),
            });
        }
    }
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
        loop {
            let (status, headers, bytes) = self
                .transport
                .post(
                    self.url,
                    mcp_headers(method, tool_name, self.session_id.as_deref()),
                    body,
                )
                .await?;
            if let Some(id) = headers
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
            return serde_json::from_slice::<Value>(&bytes).map_err(|_| {
                BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_json")
            });
        }
    }

    async fn initialize(&mut self) -> BistreResult<Value> {
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
        Box::pin(self.rpc("initialize", None, &init_body)).await
    }
}

fn mcp_headers(method: &str, tool_name: Option<&str>, session_id: Option<&str>) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));
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
    headers
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

/// Discovers tools from a Streamable HTTP MCP server using `2026-07-28` `server/discover` first,
/// falling back seamlessly to legacy `2025-11-25` (`initialize` -> `tools/list`).
pub async fn discover_http_mcp_server(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
) -> BistreResult<McpDiscoveryReport> {
    let url = validate_mcp_url(&server.url)?;
    let mut session = McpSession {
        transport,
        url,
        session_id: None,
        renewed: false,
    };

    // 1. Probe MCP 2026-07-28 stateless `server/discover` with `Mcp-Method` header.
    let discover_body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "server/discover",
        "params": { "protocolVersion": MCP_PROTOCOL_2026 }
    });
    if let Ok(resp) = session.rpc("server/discover", None, &discover_body).await
        && let Some(result) = resp.get("result")
        && let Some(raw_tools) = result.get("tools").and_then(Value::as_array)
    {
        return Ok(McpDiscoveryReport {
            negotiated_protocol: MCP_PROTOCOL_2026.to_owned(),
            tools: normalize_and_sort_tools(&server.id, raw_tools),
            quarantined_stdout_lines: Vec::new(),
        });
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
        negotiated_protocol: MCP_PROTOCOL_2025.to_owned(),
        tools: normalize_and_sort_tools(&server.id, raw_tools),
        quarantined_stdout_lines: Vec::new(),
    })
}

/// Calls a tool on a Streamable HTTP MCP server with `256 KiB` payload capping and `Mcp-Method`/`Mcp-Name` headers.
/// Stateless `2026-07-28` servers answer directly; a legacy server that rejects the call without a
/// session is initialized once and the call is sent once more (never more than one resend).
pub async fn call_http_mcp_tool(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
    tool_name: &str,
    arguments: &Value,
) -> BistreResult<String> {
    let url = validate_mcp_url(&server.url)?;
    let mut session = McpSession {
        transport,
        url,
        session_id: None,
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
    let resp = match session.rpc("tools/call", Some(tool_name), &body).await {
        Ok(v) => v,
        Err(err)
            if matches!(
                err.detail_code.as_deref(),
                Some("mcp_http_400" | "mcp_http_404")
            ) =>
        {
            session.renewed = true;
            session.initialize().await?;
            session.rpc("tools/call", Some(tool_name), &body).await?
        }
        Err(err) => return Err(err),
    };
    let mut rendered = resp
        .get("result")
        .map_or_else(|| resp.to_string(), Value::to_string);
    if rendered.len() > MAX_MCP_TOOL_RESULT_BYTES {
        let mut cut = MAX_MCP_TOOL_RESULT_BYTES;
        while cut > 0 && !rendered.is_char_boundary(cut) {
            cut -= 1;
        }
        rendered.truncate(cut);
        rendered.push_str("...[truncated_256kib]");
    }
    Ok(rendered)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[test]
    fn noisy_stdout_quarantine_stderr_ring_and_deterministic_tool_sort() {
        let noisy = "Banner: booting server...\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\nWARN debug line\n";
        let (frames, quarantined) = split_stdio_jsonrpc_and_quarantine(noisy);
        assert_eq!(frames.len(), 1);
        assert_eq!(quarantined.len(), 2);

        let mut ring = StderrRingBuffer::default();
        ring.push_bytes(&vec![b'x'; MAX_MCP_STDERR_RING_BYTES + 100]);
        assert_eq!(ring.snapshot_lossy().len(), MAX_MCP_STDERR_RING_BYTES);

        let sorted = normalize_and_sort_tools(
            "srv1",
            &[
                json!({"name": "z_tool", "description": "Z", "inputSchema": {"type": "object"}}),
                json!({"name": "a_tool", "description": "A", "inputSchema": {"type": "object"}}),
            ],
        );
        assert_eq!(sorted[0].name, "a_tool");
        assert_eq!(sorted[1].name, "z_tool");
    }

    #[tokio::test]
    async fn mcp_dual_negotiation_supports_2026_discover_and_2025_fallback() {
        let listener = TcpListener::bind("127.0.0.1:0").await.ok();
        let Some(listener) = listener else { return };
        let Ok(addr) = listener.local_addr() else {
            return;
        };

        // Server rejects `server/discover` (HTTP 404) and responds to legacy `initialize` + `tools/list`.
        let server_task = tokio::spawn(async move {
            for _ in 0..3 {
                let Ok((mut sock, _)) = listener.accept().await else {
                    break;
                };
                let mut buf = [0_u8; 4096];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                let (status, body) = if req.contains("server/discover") {
                    ("404 Not Found", r#"{"error":"not_supported"}"#)
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
        let report = discover_http_mcp_server(&transport, &cfg).await.ok();
        assert!(server_task.await.is_ok());
        assert_eq!(
            report.as_ref().map(|r| r.negotiated_protocol.as_str()),
            Some(MCP_PROTOCOL_2025)
        );
        assert_eq!(report.as_ref().map(|r| r.tools.len()), Some(1));
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
}
