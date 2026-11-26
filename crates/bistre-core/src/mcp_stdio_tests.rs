//! Stdio MCP sessions against a real child process: this test binary re-runs itself as a small
//! MCP server (`mock_stdio_server_entry`, active only when its marker argument is present), so
//! the tests need no interpreter or extra binary on any platform.

use std::io::{BufRead as _, Write as _};
use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};

use crate::mcp::McpServerConfig;
use crate::mcp_stdio::{call_stdio_mcp_tool, close_stdio_session, reset_stdio_restart_budget};

const MARKER: &str = "bistre-mcp-mock-server";

/// The mock server. libtest prints its own banner to stdout first, which also exercises the
/// non-JSON stdout quarantine.
#[test]
fn mock_stdio_server_entry() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if !args.iter().any(|a| a == MARKER) {
        return Ok(());
    }
    let heartbeat = args
        .iter()
        .find_map(|a| a.strip_prefix("heartbeat="))
        .map(std::path::PathBuf::from);
    let stdin = std::io::stdin();
    let mut lines = stdin.lock().lines();
    let mut out = std::io::stdout().lock();
    while let Some(line) = lines.next() {
        let Ok(msg) = serde_json::from_str::<Value>(&line?) else {
            continue;
        };
        let id = msg.get("id").cloned().unwrap_or(Value::Null);
        let reply = |result: Value| json!({ "jsonrpc": "2.0", "id": id, "result": result });
        match msg.get("method").and_then(Value::as_str) {
            Some("initialize") => {
                let ver = msg.pointer("/params/protocolVersion").cloned();
                writeln!(out, "{}", reply(json!({ "protocolVersion": ver })))?;
            }
            Some("tools/list") => {
                let tools =
                    json!({ "tools": [{ "name": "pid", "inputSchema": { "type": "object" } }] });
                writeln!(out, "{}", reply(tools))?;
            }
            Some("tools/call") => match msg.pointer("/params/name").and_then(Value::as_str) {
                Some("pid") => {
                    let text = std::process::id().to_string();
                    writeln!(
                        out,
                        "{}",
                        reply(json!({ "content": [{ "type": "text", "text": text }] }))
                    )?;
                }
                Some("server_requests") => {
                    // R43: a server request that reuses the client's id, then a ping.
                    writeln!(
                        out,
                        "{}",
                        json!({ "jsonrpc": "2.0", "id": id, "method": "roots/list" })
                    )?;
                    writeln!(
                        out,
                        "{}",
                        json!({ "jsonrpc": "2.0", "id": "p1", "method": "ping" })
                    )?;
                    out.flush()?;
                    let mut answers = Vec::new();
                    for _ in 0..2 {
                        if let Some(answer) = lines.next() {
                            answers.push(answer?);
                        }
                    }
                    let text = answers.join("\n");
                    writeln!(
                        out,
                        "{}",
                        reply(json!({ "content": [{ "type": "text", "text": text }] }))
                    )?;
                }
                Some("huge") => {
                    // R16: an endless line with no newline, then stay alive until killed.
                    let chunk = "a".repeat(64 * 1024);
                    for _ in 0..40 {
                        write!(out, "{chunk}")?;
                    }
                    out.flush()?;
                    for _ in 0..600 {
                        if let Some(path) = heartbeat.as_deref() {
                            let mut f = std::fs::OpenOptions::new()
                                .create(true)
                                .append(true)
                                .open(path)?;
                            writeln!(f, "beat")?;
                        }
                        #[expect(
                            clippy::disallowed_methods,
                            reason = "The mock server is its own synchronous child process; nothing async runs on this thread."
                        )]
                        std::thread::sleep(Duration::from_millis(50));
                    }
                }
                Some("die") => return Ok(()),
                _ => writeln!(
                    out,
                    "{}",
                    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32602, "message": "Unknown tool" } })
                )?,
            },
            _ => {}
        }
        out.flush()?;
    }
    Ok(())
}

/// Closes the test's session when the test ends (pass or fail), so its child pipes let the
/// test runtime shut down.
struct SessionGuard(String);

impl Drop for SessionGuard {
    fn drop(&mut self) {
        close_stdio_session(&self.0);
    }
}

fn mock_server(id: &str, heartbeat: Option<&Path>) -> Result<McpServerConfig, std::io::Error> {
    let exe = std::env::current_exe()?;
    let mut args = vec![
        "mcp_stdio::mcp_stdio_tests::mock_stdio_server_entry".to_owned(),
        "--exact".to_owned(),
        "--nocapture".to_owned(),
        MARKER.to_owned(),
    ];
    if let Some(path) = heartbeat {
        args.push(format!("heartbeat={}", path.display()));
    }
    reset_stdio_restart_budget(id);
    Ok(McpServerConfig {
        id: id.to_owned(),
        name: id.to_owned(),
        transport: "stdio".to_owned(),
        command: exe.display().to_string(),
        args,
        url: String::new(),
        enabled: true,
    })
}

async fn pid_of(server: &McpServerConfig) -> Result<String, Box<dyn std::error::Error>> {
    Ok(call_stdio_mcp_tool(server, "pid", &json!({}), None)
        .await?
        .text)
}

/// R15: calls share one long-lived process, so the restart budget (3 starts / 10 min) is never
/// spent by ordinary use. The old code spawned one process per call (the 4th call failed).
#[tokio::test]
async fn calls_share_one_session_per_server() -> Result<(), Box<dyn std::error::Error>> {
    let server = mock_server("r15-session", None)?;
    let _session = SessionGuard(server.id.clone());
    let first = pid_of(&server).await?;
    for _ in 0..5 {
        assert_eq!(pid_of(&server).await?, first);
    }
    Ok(())
}

/// R43: requests from the server are answered by method (ping -> `{}`, anything not
/// negotiated -> -32601), and one reusing our id is never taken as our response.
#[tokio::test]
async fn server_requests_are_answered_not_taken_as_responses()
-> Result<(), Box<dyn std::error::Error>> {
    let server = mock_server("r43-requests", None)?;
    let _session = SessionGuard(server.id.clone());
    let out = call_stdio_mcp_tool(&server, "server_requests", &json!({}), None).await?;
    let answers: Vec<Value> = out
        .text
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    assert_eq!(answers.len(), 2, "{}", out.text);
    assert_eq!(
        answers[0]["error"]["code"], -32601,
        "roots/list was not negotiated"
    );
    assert_eq!(answers[1]["id"], "p1");
    assert_eq!(answers[1]["result"], json!({}));
    Ok(())
}

/// R16 + the failed-session reconnect (cherry-studio #18144): an endless line fails the call
/// quickly instead of growing memory, the broken child is killed (its heartbeat stops), and
/// the next call starts a fresh process.
#[tokio::test]
async fn a_broken_session_is_killed_and_replaced() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let beat = dir.path().join("beat.txt");
    let server = mock_server("r16-reconnect", Some(&beat))?;
    let _session = SessionGuard(server.id.clone());
    let before = pid_of(&server).await?;
    let started = std::time::Instant::now();
    let err = call_stdio_mcp_tool(&server, "huge", &json!({}), None)
        .await
        .err()
        .ok_or("an endless line must fail")?;
    assert_eq!(err.detail_code.as_deref(), Some("mcp_stdio_line_too_long"));
    assert!(started.elapsed() < Duration::from_secs(20));
    tokio::time::sleep(Duration::from_millis(600)).await;
    let len_a = std::fs::metadata(&beat).map_or(0, |m| m.len());
    tokio::time::sleep(Duration::from_millis(600)).await;
    let len_b = std::fs::metadata(&beat).map_or(0, |m| m.len());
    assert_eq!(len_a, len_b, "the broken child is gone");
    let after = pid_of(&server).await?;
    assert_ne!(before, after, "a new process replaced the broken one");
    Ok(())
}

/// A server that exits mid-call fails that call (never resent) and the next call reconnects.
#[tokio::test]
async fn a_crashed_server_is_restarted_for_the_next_call() -> Result<(), Box<dyn std::error::Error>>
{
    let server = mock_server("crash-restart", None)?;
    let _session = SessionGuard(server.id.clone());
    let before = pid_of(&server).await?;
    let err = call_stdio_mcp_tool(&server, "die", &json!({}), None)
        .await
        .err()
        .ok_or("a crashed call fails")?;
    assert_eq!(err.detail_code.as_deref(), Some("mcp_stdio_eof"));
    assert_ne!(pid_of(&server).await?, before);
    Ok(())
}
