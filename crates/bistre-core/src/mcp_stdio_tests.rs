//! Stdio MCP sessions against a real child process: this test binary re-runs itself as a small
//! MCP server (`mock_stdio_server_entry`, active only when its marker argument is present), so
//! the tests need no interpreter or extra binary on any platform.

use std::io::{BufRead as _, Write as _};
use std::path::Path;
use std::time::Duration;

use serde_json::{Value, json};

use crate::mcp::McpServerConfig;
use crate::mcp_stdio::{
    call_stdio_mcp_tool, close_stdio_session, discover_stdio_mcp_server, reset_stdio_restart_budget,
};

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
    let modern = args.iter().any(|a| a == "modern");
    // A `2025-03-26` server answers `initialize` with its own version, not the client's.
    let march_2025 = args.iter().any(|a| a == "v2025-03-26");
    let mut task_polls = 0_u32;
    let note = |text: &str| -> std::io::Result<()> {
        if let Some(path) = heartbeat.as_deref() {
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)?;
            writeln!(f, "{text}")?;
        }
        Ok(())
    };
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
            Some("server/discover") if modern => {
                let found = json!({ "resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": { "tools": {} } });
                writeln!(out, "{}", reply(found))?;
            }
            Some("subscriptions/listen") if modern => {
                let [ack, change] = listen_notices(&id);
                writeln!(out, "{ack}\n{change}")?;
            }
            Some("tasks/get") if modern => {
                task_polls += 1;
                writeln!(out, "{}", reply(task_poll(task_polls)))?;
            }
            Some("initialize") if !modern => {
                writeln!(out, "{}", reply(initialize_answer(march_2025, &msg)))?;
            }
            Some("initialize" | "server/discover") => writeln!(
                out,
                "{}",
                json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": "Method not found" } })
            )?,
            Some("tools/list") => writeln!(out, "{}", reply(tools_page(&msg)))?,
            Some("tools/call") => match msg.pointer("/params/name").and_then(Value::as_str) {
                Some(name) if instant_result(name, &msg).is_some() => {
                    let result = instant_result(name, &msg).unwrap_or(Value::Null);
                    writeln!(out, "{}", reply(result))?;
                }
                Some("server_requests") => {
                    // A server request that reuses the client's id, then a ping.
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
                    // An endless line with no newline, then stay alive until killed.
                    let chunk = "a".repeat(64 * 1024);
                    for _ in 0..40 {
                        write!(out, "{chunk}")?;
                    }
                    out.flush()?;
                    for _ in 0..600 {
                        note("beat")?;
                        #[expect(
                            clippy::disallowed_methods,
                            reason = "The mock server is its own synchronous child process; nothing async runs on this thread."
                        )]
                        std::thread::sleep(Duration::from_millis(50));
                    }
                }
                Some("slow") => {
                    // Never answers; records the cancel notice it gets instead.
                    for next in lines.by_ref() {
                        let next: Value = serde_json::from_str(&next?).unwrap_or(Value::Null);
                        if next["method"] == "notifications/cancelled" {
                            note(&format!("cancelled {}", next["params"]["requestId"]))?;
                            break;
                        }
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
    note("eof")
}

/// A `tools/list` page: two pages, the first naming the second with `nextCursor`.
fn tools_page(msg: &Value) -> Value {
    if msg.pointer("/params/cursor").and_then(Value::as_str) == Some("p2") {
        json!({ "tools": [{ "name": "echo", "inputSchema": { "type": "object" } }] })
    } else {
        json!({ "tools": [{ "name": "pid", "inputSchema": { "type": "object" } }], "nextCursor": "p2" })
    }
}

/// The `initialize` answer: the client's version, or a `2025-03-26` server's own.
fn initialize_answer(march_2025: bool, msg: &Value) -> Value {
    let ver = if march_2025 {
        json!("2025-03-26")
    } else {
        msg.pointer("/params/protocolVersion")
            .cloned()
            .unwrap_or(Value::Null)
    };
    json!({ "protocolVersion": ver })
}

/// The task `long` started: working on the first poll, done on the second.
fn task_poll(polls: u32) -> Value {
    if polls < 2 {
        json!({ "resultType": "complete", "taskId": "job-1", "status": "working", "pollIntervalMs": 250 })
    } else {
        json!({ "resultType": "complete", "taskId": "job-1", "status": "completed",
            "result": { "content": [{ "type": "text", "text": "long done" }] } })
    }
}

/// The answer to `subscriptions/listen` with request `id`: the acknowledgement, then at once a
/// tool list change on that subscription.
fn listen_notices(id: &Value) -> [Value; 2] {
    let meta = json!({ "io.modelcontextprotocol/subscriptionId": id });
    [
        json!({ "jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
            "params": { "_meta": meta, "notifications": { "toolsListChanged": true } } }),
        json!({ "jsonrpc": "2.0", "method": "notifications/tools/list_changed", "params": { "_meta": meta } }),
    ]
}

/// The mock tools that answer at once: `pid` (the process id), `meta` (the protocol version in
/// the request's `_meta`, or `none`), and `needs_input` (an interim `input_required` result).
fn instant_result(name: &str, msg: &Value) -> Option<Value> {
    let text = |t: String| json!({ "content": [{ "type": "text", "text": t }] });
    match name {
        "pid" => Some(text(std::process::id().to_string())),
        "meta" => Some(text(
            msg.pointer("/params/_meta/io.modelcontextprotocol~1protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("none")
                .to_owned(),
        )),
        // A long tool answers with a task handle, but only to a client that declared tasks.
        "long" if msg
            .pointer("/params/_meta/io.modelcontextprotocol~1clientCapabilities/extensions/io.modelcontextprotocol~1tasks")
            .is_some() =>
        {
            Some(json!({ "resultType": "task", "taskId": "job-1", "status": "working", "pollIntervalMs": 250 }))
        }
        "needs_input" => Some(
            json!({ "resultType": "input_required", "inputRequests": { "q": { "method": "elicitation/create" } } }),
        ),
        _ => None,
    }
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
    mock_server_era(id, heartbeat, false)
}

fn mock_server_era(
    id: &str,
    heartbeat: Option<&Path>,
    modern: bool,
) -> Result<McpServerConfig, std::io::Error> {
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
    if modern {
        args.push("modern".to_owned());
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

/// Calls share one long-lived process, so the restart budget (3 starts / 10 min) is never
/// spent by ordinary use. The old code spawned one process per call (the 4th call failed).
/// Discovery follows `nextCursor` to the last page, over the one session.
#[tokio::test]
async fn discovery_reads_every_tools_page() -> Result<(), Box<dyn std::error::Error>> {
    let server = mock_server("paged-tools", None)?;
    let _session = SessionGuard(server.id.clone());
    let report = discover_stdio_mcp_server(&server).await?;
    let names: Vec<&str> = report.tools.iter().map(|t| t.name.as_str()).collect();
    assert_eq!(names, ["echo", "pid"]);
    Ok(())
}

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

/// Requests from the server are answered by method (ping -> `{}`, anything not
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

/// The failed-session reconnect: an endless line fails the call
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

/// Waits up to 10 s for `path` to hold a line starting with `prefix`.
async fn wait_for_note(path: &Path, prefix: &str) -> Option<String> {
    for _ in 0..100 {
        if let Ok(text) = std::fs::read_to_string(path)
            && let Some(line) = text.lines().find(|l| l.starts_with(prefix))
        {
            return Some(line.to_owned());
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    None
}

/// A `2026-07-28` server has no `initialize` (this one rejects it): the client probes with
/// `server/discover` and then sends the version in every request's `_meta`.
#[tokio::test]
async fn a_modern_server_gets_meta_on_every_request_and_no_handshake()
-> Result<(), Box<dyn std::error::Error>> {
    let server = mock_server_era("modern-meta", None, true)?;
    let _session = SessionGuard(server.id.clone());
    let out = call_stdio_mcp_tool(&server, "meta", &json!({}), None).await?;
    assert_eq!(out.text, "2026-07-28");
    Ok(())
}

/// A modern session opens `subscriptions/listen`, and a tool list change notice that arrives
/// among the answers marks the server's list for relisting.
#[tokio::test]
async fn a_modern_session_listens_for_tool_list_changes() -> Result<(), Box<dyn std::error::Error>>
{
    let server = mock_server_era("modern-listen", None, true)?;
    let _session = SessionGuard(server.id.clone());
    call_stdio_mcp_tool(&server, "pid", &json!({}), None).await?;
    assert!(crate::mcp_refresh::list_changed("modern-listen"));
    Ok(())
}

/// A legacy server answers the probe with an error and gets `initialize`, then plain requests.
#[tokio::test]
async fn a_legacy_server_falls_back_to_initialize() -> Result<(), Box<dyn std::error::Error>> {
    let server = mock_server("legacy-meta", None)?;
    let _session = SessionGuard(server.id.clone());
    let out = call_stdio_mcp_tool(&server, "meta", &json!({}), None).await?;
    assert_eq!(out.text, "none");
    Ok(())
}

/// A modern server may answer a long call with a task: Bistre declares the tasks extension,
/// polls `tasks/get`, and reads the finished task's result as the tool's answer.
#[tokio::test]
async fn a_task_handle_is_polled_until_the_tool_finishes() -> Result<(), Box<dyn std::error::Error>>
{
    let server = mock_server_era("tasks", None, true)?;
    let _session = SessionGuard(server.id.clone());
    let out = call_stdio_mcp_tool(&server, "long", &json!({}), None).await?;
    assert_eq!(out.text, "long done");
    Ok(())
}

/// A `2025-03-26` server negotiates its own older version and still serves tools.
#[tokio::test]
async fn a_2025_03_26_server_is_used_at_its_own_version() -> Result<(), Box<dyn std::error::Error>>
{
    let mut server = mock_server("march-2025", None)?;
    server.args.push("v2025-03-26".to_owned());
    let _session = SessionGuard(server.id.clone());
    let report = discover_stdio_mcp_server(&server).await?;
    assert_eq!(report.negotiated_protocol, "2025-03-26");
    let out = call_stdio_mcp_tool(&server, "meta", &json!({}), None).await?;
    assert_eq!(out.text, "none", "no modern _meta on an older session");
    Ok(())
}

/// An interim `input_required` result fails closed: it is never read as the tool's answer.
#[tokio::test]
async fn an_input_required_result_fails_closed() -> Result<(), Box<dyn std::error::Error>> {
    let server = mock_server_era("needs-input", None, true)?;
    let _session = SessionGuard(server.id.clone());
    let err = call_stdio_mcp_tool(&server, "needs_input", &json!({}), None)
        .await
        .err()
        .ok_or("an interim result is not a tool result")?;
    assert_eq!(err.detail_code.as_deref(), Some("mcp_input_required"));
    Ok(())
}

/// A caller that stops waiting (a cancelled run drops the call) tells the server with
/// `notifications/cancelled`, so a tool call nobody will read stops running.
#[tokio::test]
async fn a_dropped_call_sends_cancelled_to_the_server() -> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let notes = dir.path().join("notes.txt");
    let server = mock_server("cancel-on-drop", Some(&notes))?;
    let _session = SessionGuard(server.id.clone());
    let args = json!({});
    let pending = call_stdio_mcp_tool(&server, "slow", &args, None);
    let waited = tokio::time::timeout(Duration::from_millis(1500), pending).await;
    assert!(waited.is_err(), "the slow tool never answers");
    let line = wait_for_note(&notes, "cancelled ").await;
    assert!(line.is_some(), "the server got no cancel notice");
    Ok(())
}

/// Closing a session closes the server's stdin and lets it exit on its own before any kill.
#[tokio::test]
async fn closing_a_session_lets_the_server_exit_on_its_own()
-> Result<(), Box<dyn std::error::Error>> {
    let dir = tempfile::tempdir()?;
    let notes = dir.path().join("notes.txt");
    let server = mock_server("graceful-close", Some(&notes))?;
    pid_of(&server).await?;
    close_stdio_session(&server.id);
    assert!(
        wait_for_note(&notes, "eof").await.is_some(),
        "the server was killed first"
    );
    Ok(())
}
