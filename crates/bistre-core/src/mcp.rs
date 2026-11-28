//! MCP client: Streamable HTTP (`ADR-0006`, `ADR-0018`: no SDK) speaking `2026-07-28` first
//! (`server/discover`, `_meta` on every request, `Mcp-Method`/`Mcp-Name`) with a `2025-11-25`
//! session fallback ([`crate::mcp_era`]), and deterministic prompt-cache-stable tool ordering.

use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use reqwest::header::{ACCEPT, CONTENT_TYPE, HeaderMap, HeaderValue};
use reqwest::{Method, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::mcp_era::{
    HttpEra, ProbeVerdict, cached_http_era, complete_result, forget_http_era, http_era_key,
    probe_verdict, remember_http_era, with_modern_meta,
};
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
/// Longest MCP server token kept, in bytes.
pub const MAX_MCP_TOKEN_BYTES: usize = 8 * 1024;

/// The vault key of a server's Bearer token.
pub(crate) fn bearer_vault_key(server_id: &str) -> String {
    format!("mcp_bearer:{server_id}")
}
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
        let resp = client
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
        let bytes = crate::http_clients::read_body_capped(
            resp,
            MAX_MCP_HTTP_RESPONSE_BYTES,
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_read"),
            BistreError::with_detail(
                DiagnosticKey::ProviderRequestFailed,
                "mcp_response_too_large",
            ),
        )
        .await?;
        Ok((status, resp_headers, bytes))
    }

    /// Sends `body` and returns the response before its body is read (a listen stream),
    /// open for at most [`crate::mcp_listen::LISTEN_STREAM_MAX`].
    async fn open_stream(
        &self,
        url: &str,
        headers: HeaderMap,
        body: &Value,
    ) -> BistreResult<reqwest::Response> {
        let max_open = crate::mcp_listen::LISTEN_STREAM_MAX;
        if !crate::net::is_loopback_url(url) {
            return self
                .public
                .open_json_stream(url, headers, body, max_open)
                .await;
        }
        let client = self.local.as_ref().map_err(Clone::clone)?;
        client
            .post(url)
            .headers(headers)
            .json(body)
            .timeout(max_open)
            .send()
            .await
            .map_err(|_| {
                BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_connect")
            })
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

/// Per-server MCP protocol state: the era, and for a legacy server its `Mcp-Session-Id`
/// with a single renewal on HTTP `404`.
#[derive(Debug)]
struct McpSession<'a> {
    transport: &'a McpHttpTransport,
    url: &'a str,
    bearer_token: Option<&'a str>,
    session_id: Option<String>,
    protocol_version: String,
    renewed: bool,
    /// `2026-07-28`: `_meta` on every request, no session.
    modern: bool,
}

/// A JSON-RPC request body.
fn request(id: u64, method: &str, params: Value) -> Value {
    let mut body = json!({ "jsonrpc": "2.0", "id": id, "method": method });
    body["params"] = params;
    body
}

/// Whether `err` is the server's JSON-RPC answer (the session is healthy), not a failure.
fn is_rpc_answer(err: &BistreError) -> bool {
    err.detail_code
        .as_deref()
        .is_some_and(|d| d.starts_with("mcp_rpc_error_"))
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
    /// The list's `ttlMs`: how long after listing it stays fresh (none: until listed again).
    pub cache_ttl_ms: Option<u64>,
    /// The list's `cacheScope` was `private`: it holds only for the token it was listed with.
    #[serde(default)]
    pub cache_private: bool,
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
}

/// Normalizes and deterministically sorts MCP tools so LLM prompt-cache prefixes never churn
/// across reconnects. Entries without a string `name` are skipped; each tool carries the
/// list's `cache` fields.
pub fn normalize_and_sort_tools(
    server_id: &str,
    raw_tools: &[Value],
    cache: crate::mcp_era::ListCache,
) -> Vec<McpDiscoveredTool> {
    let mut out: Vec<McpDiscoveredTool> = raw_tools
        .iter()
        .filter_map(|raw| serde_json::from_value::<WireTool>(raw.clone()).ok())
        .map(|tool| McpDiscoveredTool {
            server_id: server_id.to_owned(),
            cache_ttl_ms: cache.ttl_ms,
            cache_private: cache.private,
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

impl<'a> McpSession<'a> {
    const fn new(
        transport: &'a McpHttpTransport,
        url: &'a str,
        bearer_token: Option<&'a str>,
    ) -> Self {
        Self {
            transport,
            url,
            bearer_token,
            session_id: None,
            protocol_version: String::new(),
            renewed: false,
            modern: false,
        }
    }

    /// Probes the server's era with `server/discover` (MCP `2026-07-28` versioning) and, for
    /// a legacy server only, opens a `2025-11-25` session.
    async fn open(&mut self) -> BistreResult<()> {
        MCP_PROTOCOL_2026.clone_into(&mut self.protocol_version);
        let probe = request(1, "server/discover", with_modern_meta(json!({})));
        let answer = self.rpc("server/discover", None, &probe).await;
        if probe_verdict(answer)? == ProbeVerdict::Modern {
            self.modern = true;
        } else {
            self.initialize().await?;
        }
        Ok(())
    }

    /// Continues from a remembered era instead of probing again.
    fn resume(&mut self, era: HttpEra) {
        match era {
            HttpEra::Modern => {
                self.modern = true;
                MCP_PROTOCOL_2026.clone_into(&mut self.protocol_version);
            }
            HttpEra::Legacy {
                session_id,
                protocol_version,
            } => {
                self.session_id = session_id;
                self.protocol_version = protocol_version;
            }
        }
    }

    fn era(&self) -> HttpEra {
        if self.modern {
            HttpEra::Modern
        } else {
            HttpEra::Legacy {
                session_id: self.session_id.clone(),
                protocol_version: self.protocol_version.clone(),
            }
        }
    }

    /// `params` as this era sends them: a modern request carries `_meta`.
    fn params(&self, params: Value) -> Value {
        if self.modern {
            with_modern_meta(params)
        } else {
            params
        }
    }

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
                // A modern server answers a refused request with a JSON-RPC error body (for
                // example `UnsupportedProtocolVersion` in a `400`); keep its code.
                if let Ok(val) = serde_json::from_slice::<Value>(&bytes)
                    && val.get("jsonrpc").is_some()
                    && val.pointer("/error/code").is_some_and(Value::is_i64)
                {
                    return json_rpc_result(val);
                }
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
            // A JSON-RPC `error` is an error on the HTTP path too.
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
        complete_result(&resp)?
            .get("protocolVersion")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
            .ok_or_else(|| {
                BistreError::with_detail(
                    DiagnosticKey::ProviderRequestFailed,
                    "mcp_initialize_no_version",
                )
            })?
            .clone_into(&mut self.protocol_version);
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

/// Closes the legacy session `era` holds for `server` with `DELETE` (best effort, logged); a
/// modern era has no session.
pub async fn close_http_session(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
    bearer_token: Option<&str>,
    era: HttpEra,
) {
    let Ok(url) = validate_mcp_url(&server.url) else {
        return;
    };
    let mut session = McpSession::new(transport, url, bearer_token);
    session.resume(era);
    session.close().await;
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
        // Fail closed: a token that cannot form a header is never dropped silently.
        let val = HeaderValue::from_str(&format!("Bearer {clean}")).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::InvalidInput, "mcp_bearer_not_a_header_value")
        })?;
        headers.insert(reqwest::header::AUTHORIZATION, val);
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

/// Discovers tools from a Streamable HTTP MCP server: the `server/discover` probe, then
/// `tools/list` (with `_meta` on `2026-07-28`, after `initialize` on `2025-11-25`).
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
    let key = http_era_key(server);
    let mut session = McpSession::new(transport, url, bearer_token);
    // Discovery always probes: the user asked to look at the server as it is now.
    session.open().await?;
    let mut raw_tools = Vec::new();
    let mut cache = crate::mcp_era::ListCache::default();
    let mut cursor: Option<String> = None;
    for page in 0..crate::mcp_era::MAX_TOOL_LIST_PAGES {
        let params = crate::mcp_era::tools_list_params(cursor.as_deref());
        let list_body = request(2 + page, "tools/list", session.params(params));
        let listed = session.rpc("tools/list", None, &list_body).await;
        let list_resp = settle(&mut session, &key, listed).await?;
        let result = complete_result(&list_resp)?;
        cursor =
            crate::mcp_era::take_tools_page(result, cursor.as_deref(), &mut raw_tools, &mut cache);
        if cursor.is_none() {
            break;
        }
    }
    if cursor.is_some() {
        tracing::warn!(server = %server.id, "tools/list page limit reached; later tools unlisted");
    }
    Ok(McpDiscoveryReport {
        negotiated_protocol: session.protocol_version,
        tools: normalize_and_sort_tools(&server.id, &raw_tools, cache),
        quarantined_stdout_lines: Vec::new(),
    })
}

/// Opens a `2026-07-28` `subscriptions/listen` stream asking only for `toolsListChanged`.
pub(crate) async fn open_listen_stream(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
    bearer_token: Option<&str>,
) -> BistreResult<reqwest::Response> {
    let url = validate_mcp_url(&server.url)?;
    let headers = mcp_headers(
        url,
        "subscriptions/listen",
        None,
        None,
        MCP_PROTOCOL_2026,
        bearer_token,
    )?;
    let body = request(
        crate::mcp_listen::LISTEN_REQUEST_ID,
        "subscriptions/listen",
        with_modern_meta(json!({ "notifications": { "toolsListChanged": true } })),
    );
    transport.open_stream(url, headers, &body).await
}

/// Keeps the server's era (and legacy session) after a request the server answered; after a
/// failure (a dropped connection, a `5xx`, a renewal that failed) forgets it and closes the
/// session, so the next call probes again.
async fn settle(
    session: &mut McpSession<'_>,
    key: &str,
    answer: BistreResult<Value>,
) -> BistreResult<Value> {
    match &answer {
        Ok(_) => remember_http_era(key, session.era()),
        Err(err) if is_rpc_answer(err) => remember_http_era(key, session.era()),
        Err(_) => {
            forget_http_era(key);
            session.close().await;
        }
    }
    answer
}

/// A JSON-RPC response as a result: an `error` member is an error, carrying the code and
/// the server's own message (bounded and sanitized), never a successful tool result.
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
    let key = http_era_key(server);
    let mut session = McpSession::new(transport, url, bearer_token);
    // The era is settled before `tools/call`, so the call is sent exactly once. A failed call
    // is an error and never resent (it may already have run); only an expired session (HTTP
    // 404) is renewed once, inside `rpc`, as the spec requires.
    match cached_http_era(&key) {
        Some(era) => session.resume(era),
        None => session.open().await?,
    }
    let body = request(
        3,
        "tools/call",
        session.params(json!({ "name": tool_name, "arguments": arguments })),
    );
    let called = session.rpc("tools/call", Some(tool_name), &body).await;
    let resp = settle(&mut session, &key, called).await?;
    Ok(crate::mcp_stdio::parse_mcp_call_result(
        complete_result(&resp)?,
        data_dir,
    ))
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
#[path = "mcp_tests.rs"]
mod tests;
