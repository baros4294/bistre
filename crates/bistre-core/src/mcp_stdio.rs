//! Stdio MCP transport (`AGENTS.md` §7, ADR-0006, Wave 4).
//!
//! - Spawns every child exclusively via `process_util::no_window_command` + `spawn_contained`
//!   (Windows `CREATE_NO_WINDOW` + `KILL_ON_JOB_CLOSE`; Unix process group + `PR_SET_PDEATHSIG`).
//! - Quarantines noisy non-JSON stdout banner lines (bounded at 64 lines).
//! - Drains `stderr` into a bounded 64 KiB ring buffer so children never deadlock on pipe pressure.
//! - Enforces a strict `3 starts / 10 min` restart budget per server and never resends a crashed call.
//! - Parses rich MCP `content[]` (`text`, `image`, `audio`, `resource`, `resource_link`) + `isError`,
//!   persisting binary media into `<data_dir>/attachments/` so multimodal models see tool screenshots.

use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, StoredAttachment, lock_or_recover,
};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use uuid::Uuid;

use crate::mcp::{
    MAX_MCP_TOOL_RESULT_BYTES, MCP_CALL_TIMEOUT, MCP_PROTOCOL_2025, MCP_PROTOCOL_2026,
    McpDiscoveryReport, McpServerConfig, normalize_and_sort_tools,
};
use crate::process_util::{ChildContainment, no_window_command, spawn_contained};

/// Maximum quarantined non-JSON stdout banner lines collected per stdio session.
const MAX_QUARANTINED_STDOUT_LINES: usize = 64;
/// Bounded `stderr` ring buffer size (`64 KiB`, AGENTS.md §7).
pub const STDERR_RING_CAP_BYTES: usize = 64 * 1024;
/// Restart budget: at most 3 starts within a 10-minute sliding window.
pub const MAX_STDIO_STARTS_PER_WINDOW: usize = 3;
pub const STDIO_RESTART_WINDOW: Duration = Duration::from_secs(600);

static RESTART_BUDGET: LazyLock<Mutex<HashMap<String, VecDeque<Instant>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Checks and records one stdio server start against the `3 starts / 10 min` budget.
pub fn check_and_record_stdio_start(server_id: &str, now: Instant) -> BistreResult<()> {
    let mut map = lock_or_recover(&RESTART_BUDGET, "mcp_stdio_restart_budget");
    let window = map.entry(server_id.to_owned()).or_default();
    while let Some(&front) = window.front() {
        if now.saturating_duration_since(front) >= STDIO_RESTART_WINDOW {
            window.pop_front();
        } else {
            break;
        }
    }
    if window.len() >= MAX_STDIO_STARTS_PER_WINDOW {
        return Err(BistreError::with_detail(
            DiagnosticKey::ProviderRequestFailed,
            "mcp_restart_budget_exhausted",
        ));
    }
    window.push_back(now);
    Ok(())
}

/// Clears restart budget state for a server (e.g. after explicit user edit or in unit tests).
pub fn reset_stdio_restart_budget(server_id: &str) {
    lock_or_recover(&RESTART_BUDGET, "mcp_stdio_restart_budget").remove(server_id);
}

/// Bounded `64 KiB` ring buffer for child `stderr`.
#[derive(Debug, Default)]
pub struct StderrRing {
    buf: VecDeque<u8>,
}

impl StderrRing {
    pub fn push(&mut self, bytes: &[u8]) {
        for &b in bytes {
            if self.buf.len() >= STDERR_RING_CAP_BYTES {
                self.buf.pop_front();
            }
            self.buf.push_back(b);
        }
    }

    pub fn text(&self) -> String {
        let bytes: Vec<u8> = self.buf.iter().copied().collect();
        String::from_utf8_lossy(&bytes).into_owned()
    }
}

/// Parsed rich outcome of an MCP `tools/call` invocation (`content[]` + `isError`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpToolCallOutput {
    pub text: String,
    pub is_error: bool,
    pub media_attachments: Vec<StoredAttachment>,
}

/// Parses an MCP `tools/call` JSON-RPC `result` object (`content[]`, `isError`), persisting any
/// base64 `image` / `audio` payloads into `<data_dir>/attachments/` and capping text at `256 KiB`.
pub fn parse_mcp_call_result(result: &Value, data_dir: Option<&Path>) -> McpToolCallOutput {
    let is_error = result
        .get("isError")
        .or_else(|| result.get("is_error"))
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let mut text_parts: Vec<String> = Vec::new();
    let mut media_attachments: Vec<StoredAttachment> = Vec::new();

    if let Some(items) = result.get("content").and_then(Value::as_array) {
        for item in items {
            let kind = item.get("type").and_then(Value::as_str).unwrap_or("");
            match kind {
                "text" => {
                    if let Some(t) = item.get("text").and_then(Value::as_str) {
                        text_parts.push(t.to_owned());
                    }
                }
                "image" | "audio" => {
                    let mime = item
                        .get("mimeType")
                        .or_else(|| item.get("mime_type"))
                        .and_then(Value::as_str)
                        .unwrap_or(if kind == "image" {
                            "image/png"
                        } else {
                            "audio/wav"
                        });
                    if let Some(b64) = item.get("data").and_then(Value::as_str)
                        && let Some(dir) = data_dir
                        && let Some(att) = persist_mcp_media_blob(dir, kind, mime, b64)
                    {
                        text_parts.push(format!("[MCP {kind}: {} ({mime})]", att.name));
                        media_attachments.push(att);
                    } else {
                        text_parts.push(format!("[MCP {kind} content ({mime})]"));
                    }
                }
                "resource" => {
                    if let Some(res) = item.get("resource") {
                        let uri = res.get("uri").and_then(Value::as_str).unwrap_or("resource");
                        if let Some(t) = res.get("text").and_then(Value::as_str) {
                            text_parts.push(format!("[Resource: {uri}]\n{t}"));
                        } else {
                            text_parts.push(format!("[Binary resource: {uri}]"));
                        }
                    }
                }
                "resource_link" => {
                    let uri = item.get("uri").and_then(Value::as_str).unwrap_or("");
                    let name = item.get("name").and_then(Value::as_str).unwrap_or(uri);
                    text_parts.push(format!("[Resource link: {name} ({uri})]"));
                }
                _ => {
                    text_parts.push(item.to_string());
                }
            }
        }
    }

    let mut rendered = if text_parts.is_empty() {
        result.to_string()
    } else {
        text_parts.join("\n")
    };
    if rendered.len() > MAX_MCP_TOOL_RESULT_BYTES {
        let mut cut = MAX_MCP_TOOL_RESULT_BYTES;
        while cut > 0 && !rendered.is_char_boundary(cut) {
            cut -= 1;
        }
        rendered.truncate(cut);
        rendered.push_str("...[truncated_256kib]");
    }
    McpToolCallOutput {
        text: rendered,
        is_error,
        media_attachments,
    }
}

fn persist_mcp_media_blob(
    data_dir: &Path,
    kind: &str,
    mime: &str,
    b64: &str,
) -> Option<StoredAttachment> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64.trim())
        .ok()?;
    if bytes.is_empty() || bytes.len() > 16 * 1024 * 1024 {
        return None;
    }
    let ext = match mime.to_ascii_lowercase().as_str() {
        "image/jpeg" | "image/jpg" => "jpg",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "image/png" => "png",
        "audio/mpeg" | "audio/mp3" => "mp3",
        "audio/ogg" => "ogg",
        "audio/wav" | "audio/x-wav" => "wav",
        _ if kind == "image" => "png",
        _ => "bin",
    };
    let hash = blake3::hash(&bytes).to_hex().to_string();
    let dest_dir = data_dir.join("attachments");
    std::fs::create_dir_all(&dest_dir).ok()?;
    let dest = dest_dir.join(format!("{hash}.{ext}"));
    if !dest.exists() {
        let tmp = dest_dir.join(format!(".tmp-mcp-{}-{hash}.{ext}", Uuid::now_v7().simple()));
        std::fs::write(&tmp, &bytes).ok()?;
        if std::fs::rename(&tmp, &dest).is_err() {
            if let Err(err) = std::fs::remove_file(&tmp) {
                tracing::debug!(error = %err, "cleanup temp mcp media blob failed");
            }
            return None;
        }
    }
    Some(StoredAttachment {
        id: format!("mcp_{}", Uuid::now_v7()),
        name: format!("mcp_{kind}.{ext}"),
        mime_type: mime.to_owned(),
        blob_rel_path: format!("attachments/{hash}.{ext}"),
        size_bytes: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
        blake3_hex: hash,
    })
}

/// RAII stdio MCP child process handle; kills the entire process tree on drop.
struct StdioMcpProcess {
    stdin: tokio::process::ChildStdin,
    stdout: BufReader<tokio::process::ChildStdout>,
    _stderr_ring: Arc<Mutex<StderrRing>>,
    containment: ChildContainment,
    quarantined_stdout: Vec<String>,
    next_id: u64,
}

impl Drop for StdioMcpProcess {
    fn drop(&mut self) {
        self.containment.kill_tree();
    }
}

impl StdioMcpProcess {
    fn spawn(server: &McpServerConfig) -> BistreResult<Self> {
        let cmd_str = server.command.trim();
        if cmd_str.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "mcp_stdio_command_empty",
            ));
        }
        check_and_record_stdio_start(&server.id, Instant::now())?;
        let mut cmd = no_window_command(cmd_str);
        cmd.args(&server.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let (mut child, containment) = spawn_contained(&mut cmd).map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_stdio_spawn")
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            BistreError::with_detail(DiagnosticKey::InternalError, "mcp_stdio_stdin")
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            BistreError::with_detail(DiagnosticKey::InternalError, "mcp_stdio_stdout")
        })?;
        let stderr_ring = Arc::new(Mutex::new(StderrRing::default()));
        if let Some(mut stderr) = child.stderr.take() {
            let ring_clone = Arc::clone(&stderr_ring);
            tokio::spawn(async move {
                let mut chunk = [0_u8; 4096];
                while let Ok(n) = stderr.read(&mut chunk).await {
                    if n == 0 {
                        break;
                    }
                    lock_or_recover(&ring_clone, "mcp_stderr_ring").push(&chunk[..n]);
                }
            });
        }
        Ok(Self {
            stdin,
            stdout: BufReader::new(stdout),
            _stderr_ring: stderr_ring,
            containment,
            quarantined_stdout: Vec::new(),
            next_id: 1,
        })
    }

    async fn send_line(&mut self, msg: &Value) -> BistreResult<()> {
        let mut line = msg.to_string();
        line.push('\n');
        self.stdin.write_all(line.as_bytes()).await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_stdio_write")
        })?;
        self.stdin.flush().await.map_err(|_| {
            BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, "mcp_stdio_flush")
        })?;
        Ok(())
    }

    async fn rpc(&mut self, method: &str, params: Value) -> BistreResult<Value> {
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        let req = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        self.send_line(&req).await?;

        let deadline = Instant::now() + MCP_CALL_TIMEOUT;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ProviderRequestFailed,
                    "mcp_stdio_timeout",
                ));
            }
            let mut line = String::new();
            let read_res = tokio::time::timeout(remaining, self.stdout.read_line(&mut line)).await;
            let n = match read_res {
                Ok(Ok(n)) => n,
                Ok(Err(_)) => {
                    return Err(BistreError::with_detail(
                        DiagnosticKey::ProviderRequestFailed,
                        "mcp_stdio_read",
                    ));
                }
                Err(_) => {
                    return Err(BistreError::with_detail(
                        DiagnosticKey::ProviderRequestFailed,
                        "mcp_stdio_timeout",
                    ));
                }
            };
            if n == 0 {
                return Err(BistreError::with_detail(
                    DiagnosticKey::ProviderRequestFailed,
                    "mcp_stdio_eof",
                ));
            }
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            match serde_json::from_str::<Value>(trimmed) {
                Ok(val) if val.get("id").and_then(Value::as_u64) == Some(id) => {
                    if let Some(err) = val.get("error") {
                        let code = err.get("code").and_then(Value::as_i64).unwrap_or(-32000);
                        return Err(BistreError::with_detail(
                            DiagnosticKey::ProviderRequestFailed,
                            format!("mcp_rpc_error_{code}"),
                        ));
                    }
                    return Ok(val);
                }
                Ok(_) => {
                    // Server notification or unrelated frame; ignore safely.
                }
                Err(_) => {
                    // Noisy stdout banner line: quarantine without crashing the session.
                    if self.quarantined_stdout.len() < MAX_QUARANTINED_STDOUT_LINES {
                        self.quarantined_stdout.push(trimmed.to_owned());
                    }
                }
            }
        }
    }

    async fn handshake(&mut self) -> BistreResult<String> {
        let init_params = json!({
            "protocolVersion": MCP_PROTOCOL_2026,
            "capabilities": {},
            "clientInfo": { "name": "Bistre", "version": crate::CORE_VERSION }
        });
        let resp = if let Ok(v) = self.rpc("initialize", init_params).await {
            v
        } else {
            let fallback = json!({
                "protocolVersion": MCP_PROTOCOL_2025,
                "capabilities": {},
                "clientInfo": { "name": "Bistre", "version": crate::CORE_VERSION }
            });
            self.rpc("initialize", fallback).await?
        };
        let negotiated = resp
            .pointer("/result/protocolVersion")
            .and_then(Value::as_str)
            .unwrap_or(MCP_PROTOCOL_2025)
            .to_owned();
        self.send_line(&json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        }))
        .await?;
        Ok(negotiated)
    }
}

/// Discovers tools from a local `stdio` MCP server, quarantining noisy stdout banners cleanly.
pub async fn discover_stdio_mcp_server(
    server: &McpServerConfig,
) -> BistreResult<McpDiscoveryReport> {
    let mut proc = StdioMcpProcess::spawn(server)?;
    let negotiated = proc.handshake().await?;
    let list_resp = proc.rpc("tools/list", json!({})).await?;
    let raw_tools = list_resp
        .pointer("/result/tools")
        .and_then(Value::as_array)
        .map_or(&[][..], Vec::as_slice);
    Ok(McpDiscoveryReport {
        negotiated_protocol: negotiated,
        tools: normalize_and_sort_tools(&server.id, raw_tools),
        quarantined_stdout_lines: std::mem::take(&mut proc.quarantined_stdout),
    })
}

/// Calls a tool on a local `stdio` MCP server (never resending a crashed call) and parses rich
/// `content[]` results (`text`, `image`, `audio`, `resource`, `isError`).
pub async fn call_stdio_mcp_tool(
    server: &McpServerConfig,
    tool_name: &str,
    arguments: &Value,
    data_dir: Option<&Path>,
) -> BistreResult<McpToolCallOutput> {
    let mut proc = StdioMcpProcess::spawn(server)?;
    let _negotiated = proc.handshake().await?;
    let resp = proc
        .rpc(
            "tools/call",
            json!({
                "name": tool_name,
                "arguments": arguments,
            }),
        )
        .await?;
    let result = resp.get("result").unwrap_or(&resp);
    Ok(parse_mcp_call_result(result, data_dir))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn stdio_restart_budget_caps_at_three_starts_per_ten_minutes() {
        let id = "budget-test-srv";
        reset_stdio_restart_budget(id);
        let t0 = Instant::now();
        assert!(check_and_record_stdio_start(id, t0).is_ok());
        assert!(check_and_record_stdio_start(id, t0 + Duration::from_secs(10)).is_ok());
        assert!(check_and_record_stdio_start(id, t0 + Duration::from_secs(20)).is_ok());
        let fourth = check_and_record_stdio_start(id, t0 + Duration::from_secs(30));
        assert_eq!(
            fourth.err().and_then(|e| e.detail_code),
            Some("mcp_restart_budget_exhausted".to_owned())
        );
        // After 10 minutes pass, budget resets cleanly.
        assert!(check_and_record_stdio_start(id, t0 + Duration::from_secs(605)).is_ok());
        reset_stdio_restart_budget(id);
    }

    #[test]
    fn stderr_ring_bounds_to_64_kib_and_rich_content_persists_image()
    -> Result<(), Box<dyn std::error::Error>> {
        let mut ring = StderrRing::default();
        let big = vec![b'x'; STDERR_RING_CAP_BYTES + 1024];
        ring.push(&big);
        assert_eq!(ring.buf.len(), STDERR_RING_CAP_BYTES);

        let dir = tempdir()?;
        let png_b64 =
            base64::engine::general_purpose::STANDARD.encode([137_u8, 80, 78, 71, 13, 10, 26, 10]);
        let parsed = parse_mcp_call_result(
            &json!({
                "isError": false,
                "content": [
                    { "type": "text", "text": "Captured viewport" },
                    { "type": "image", "mimeType": "image/png", "data": png_b64 }
                ]
            }),
            Some(dir.path()),
        );
        assert!(!parsed.is_error);
        assert!(parsed.text.contains("Captured viewport"));
        assert_eq!(parsed.media_attachments.len(), 1);
        assert_eq!(parsed.media_attachments[0].mime_type, "image/png");
        Ok(())
    }
}
