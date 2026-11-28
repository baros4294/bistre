//! `subscriptions/listen` (MCP `2026-07-28`) on Streamable HTTP: one long-lived stream per
//! enabled server last reached as `2026-07-28`, opened with the first message sent and kept
//! until the app closes or the server list changes. It asks only for `toolsListChanged`, and
//! a change notice relists that server's tools in the background (`mcp_refresh`). A server
//! that does not acknowledge `toolsListChanged`, answers with an error or a `4xx`, or fails
//! [`MAX_LISTEN_FAILURES`] opens in a row is not asked again until its address or token
//! changes. Stdio servers get the same request on their session (`mcp_stdio`).

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, lock_or_recover};
use bistre_storage::StorageHandle;
use serde_json::Value;

use crate::mcp::{McpHttpTransport, McpServerConfig};
use crate::mcp_era::{HttpEra, cached_http_era, http_era_key};

/// Longest one listen stream stays open before it is opened again (its request timeout).
pub(crate) const LISTEN_STREAM_MAX: Duration = Duration::from_hours(1);

/// First wait before a stream is opened again; it doubles per reopen up to
/// [`LISTEN_RETRY_MAX`] and starts over after a stream that stayed open [`LISTEN_STEADY`].
const LISTEN_RETRY_MIN: Duration = Duration::from_secs(5);
const LISTEN_RETRY_MAX: Duration = Duration::from_mins(10);
const LISTEN_STEADY: Duration = Duration::from_mins(10);

/// Failed opens in a row after which a server is not listened to until it changes.
const MAX_LISTEN_FAILURES: u32 = 8;

/// Most servers listened to (and remembered as declined) at once.
const MAX_LISTENERS: usize = 64;

/// Most bytes read from one stream before it is opened again.
const MAX_LISTEN_STREAM_BYTES: usize = 4 * 1024 * 1024;

/// The listen request's JSON-RPC id, which its notices carry as their subscription id.
pub(crate) const LISTEN_REQUEST_ID: u64 = 1;

struct Listener {
    fingerprint: String,
    task: tokio::task::AbortHandle,
}

static LISTENERS: LazyLock<Mutex<HashMap<String, Listener>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Fingerprints of servers that declined or kept failing, not asked again until they change.
static DECLINED: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

/// How a stream ended.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum StreamEnd {
    /// The server closed it (or its time or byte limit passed): open it again.
    Ended,
    /// The server does not send tool list changes on a listen stream: stop.
    Declined,
}

/// What a listener was started from; a change starts a new one.
fn fingerprint(server: &McpServerConfig, bearer: Option<&str>) -> String {
    serde_json::json!([
        server.id,
        server.url,
        crate::mcp_refresh::auth_context(bearer)
    ])
    .to_string()
}

/// Keeps one listener per server in `servers` that is HTTP and was last reached as
/// `2026-07-28`, and stops every other listener.
pub(crate) fn keep_listening(
    storage: &Arc<StorageHandle>,
    transport: &McpHttpTransport,
    servers: Vec<(McpServerConfig, Option<String>)>,
) {
    let mut listeners = lock_or_recover(&LISTENERS, "mcp_listeners");
    let mut wanted = HashSet::new();
    for (server, bearer) in servers {
        let modern = cached_http_era(&http_era_key(&server)) == Some(HttpEra::Modern);
        if server.transport.eq_ignore_ascii_case("stdio") || !modern {
            continue;
        }
        let print = fingerprint(&server, bearer.as_deref());
        wanted.insert(server.id.clone());
        if listeners
            .get(&server.id)
            .is_some_and(|l| l.fingerprint == print)
            || lock_or_recover(&DECLINED, "mcp_listen_declined").contains(&print)
        {
            continue;
        }
        if listeners.len() >= MAX_LISTENERS && !listeners.contains_key(&server.id) {
            tracing::warn!(server = %server.id, "too many mcp listen streams; not listening");
            continue;
        }
        let task = tokio::spawn(listen_loop(
            Arc::clone(storage),
            transport.clone(),
            server.clone(),
            bearer,
            print.clone(),
        ))
        .abort_handle();
        if let Some(old) = listeners.insert(
            server.id,
            Listener {
                fingerprint: print,
                task,
            },
        ) {
            old.task.abort();
        }
    }
    listeners.retain(|id, l| {
        let keep = wanted.contains(id);
        if !keep {
            l.task.abort();
        }
        keep
    });
}

/// Stops every listener and forgets which servers declined: the server list changed, or the
/// engine is shutting down.
pub(crate) fn stop_all() {
    for (_, l) in lock_or_recover(&LISTENERS, "mcp_listeners").drain() {
        l.task.abort();
    }
    lock_or_recover(&DECLINED, "mcp_listen_declined").clear();
}

fn decline(print: String) {
    let mut declined = lock_or_recover(&DECLINED, "mcp_listen_declined");
    if declined.len() < MAX_LISTENERS {
        declined.insert(print);
    }
}

async fn listen_loop(
    storage: Arc<StorageHandle>,
    transport: McpHttpTransport,
    server: McpServerConfig,
    bearer: Option<String>,
    print: String,
) {
    let mut wait = LISTEN_RETRY_MIN;
    let mut failures = 0_u32;
    let on_change = || {
        crate::mcp_refresh::note_list_changed(&server.id);
        crate::mcp_refresh::spawn_refresh(
            Arc::clone(&storage),
            transport.clone(),
            server.clone(),
            bearer.clone(),
        );
    };
    loop {
        let opened = Instant::now();
        match listen_once(&transport, &server, bearer.as_deref(), &on_change).await {
            Ok(StreamEnd::Declined) => {
                tracing::info!(server = %server.id, "mcp server sends no tool list changes");
                decline(print);
                return;
            }
            Ok(StreamEnd::Ended) => {
                failures = 0;
                if opened.elapsed() >= LISTEN_STEADY {
                    wait = LISTEN_RETRY_MIN;
                }
            }
            Err(err) => {
                failures = failures.saturating_add(1);
                tracing::warn!(
                    key = err.key.as_key(),
                    detail = err.detail_code.as_deref().unwrap_or_default(),
                    server = %server.id,
                    failures,
                    "mcp listen stream failed"
                );
                if failures >= MAX_LISTEN_FAILURES {
                    decline(print);
                    return;
                }
            }
        }
        tokio::time::sleep(wait).await;
        wait = wait.saturating_mul(2).min(LISTEN_RETRY_MAX);
    }
}

fn listen_err(detail: &str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, detail)
}

/// What one stream message means: `None` to keep reading.
fn on_message(msg: &Value, acked: &mut bool, on_change: &(dyn Fn() + Sync)) -> Option<StreamEnd> {
    match msg.get("method").and_then(Value::as_str) {
        Some("notifications/subscriptions/acknowledged") => {
            *acked = true;
            let tools = msg.pointer("/params/notifications/toolsListChanged");
            (tools != Some(&Value::Bool(true))).then_some(StreamEnd::Declined)
        }
        Some("notifications/tools/list_changed") => {
            on_change();
            None
        }
        None if msg.get("error").is_some() => Some(StreamEnd::Declined),
        None if msg.get("result").is_some() => Some(StreamEnd::Ended),
        _ => None,
    }
}

/// Opens one listen stream and reads it until it ends, calling `on_change` per tool list
/// change notice.
pub(crate) async fn listen_once(
    transport: &McpHttpTransport,
    server: &McpServerConfig,
    bearer: Option<&str>,
    on_change: &(dyn Fn() + Sync),
) -> BistreResult<StreamEnd> {
    let mut resp = crate::mcp::open_listen_stream(transport, server, bearer).await?;
    let status = resp.status();
    if status.is_client_error() {
        return Ok(StreamEnd::Declined);
    }
    if !status.is_success() {
        return Err(listen_err("mcp_listen_status"));
    }
    let mut framer = crate::sse::SseFramer::new();
    let mut read_bytes = 0_usize;
    let mut acked = false;
    let is_json = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|ct| ct.starts_with("application/json"));
    let mut json_body = Vec::new();
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|_| listen_err("mcp_listen_read"))?
    {
        read_bytes = read_bytes.saturating_add(chunk.len());
        if read_bytes > MAX_LISTEN_STREAM_BYTES {
            return Ok(StreamEnd::Ended);
        }
        if is_json {
            json_body.extend_from_slice(&chunk);
            continue;
        }
        for payload in framer.push_bytes(&chunk)? {
            match serde_json::from_str::<Value>(&payload) {
                Ok(msg) => {
                    if let Some(end) = on_message(&msg, &mut acked, on_change) {
                        return Ok(end);
                    }
                }
                Err(err) => tracing::debug!(%err, "mcp listen event is not json"),
            }
        }
    }
    if is_json {
        let msg: Value =
            serde_json::from_slice(&json_body).map_err(|_| listen_err("mcp_listen_json"))?;
        return Ok(on_message(&msg, &mut acked, on_change).unwrap_or(StreamEnd::Ended));
    }
    if acked {
        Ok(StreamEnd::Ended)
    } else {
        Err(listen_err("mcp_listen_unacknowledged"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{MockServer, Scripted};
    use std::sync::atomic::{AtomicUsize, Ordering};

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    fn server(url: String) -> McpServerConfig {
        McpServerConfig {
            id: "listen".to_owned(),
            name: "listen".to_owned(),
            transport: "http".to_owned(),
            command: String::new(),
            args: Vec::new(),
            url,
            enabled: true,
        }
    }

    fn event(msg: &Value) -> String {
        format!("data: {msg}\n\n")
    }

    /// The stream asks only for tool list changes, and each change notice is counted while
    /// the stream stays open.
    #[tokio::test]
    async fn a_listen_stream_reports_each_tool_list_change() -> TestResult {
        let ack = serde_json::json!({"jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
            "params": {"_meta": {"io.modelcontextprotocol/subscriptionId": 1}, "notifications": {"toolsListChanged": true}}});
        let change = serde_json::json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed",
            "params": {"_meta": {"io.modelcontextprotocol/subscriptionId": 1}}});
        let body = format!("{}{}{}", event(&ack), event(&change), event(&change));
        let mock = MockServer::start(vec![Scripted::sse(body).then_hang()]).await?;
        let srv = server(format!("{}/mcp", mock.base()));
        let changes = AtomicUsize::new(0);
        let count = || {
            changes.fetch_add(1, Ordering::SeqCst);
        };
        let transport = McpHttpTransport::new();
        let read = listen_once(&transport, &srv, None, &count);
        let stalled = tokio::time::timeout(Duration::from_secs(2), read).await;
        assert!(stalled.is_err(), "the stream stays open");
        assert_eq!(changes.load(Ordering::SeqCst), 2);
        let sent = mock.finish().await;
        let req = sent.first().ok_or("no request")?;
        assert_eq!(req.header("mcp-method"), Some("subscriptions/listen"));
        let body = req.body_json()?;
        assert_eq!(body["method"], "subscriptions/listen");
        assert_eq!(
            body["params"]["notifications"],
            serde_json::json!({"toolsListChanged": true})
        );
        assert!(body["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"].is_string());
        Ok(())
    }

    /// A server that leaves `toolsListChanged` out of its acknowledgement, or answers with an
    /// error, declines.
    #[tokio::test]
    async fn a_server_without_tool_list_changes_declines() -> TestResult {
        let ack = serde_json::json!({"jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
            "params": {"notifications": {}}});
        let refusal = serde_json::json!({"jsonrpc": "2.0", "id": 1,
            "error": {"code": -32601, "message": "Method not found"}});
        let mock = MockServer::start(vec![
            Scripted::sse(event(&ack)).then_hang(),
            Scripted::json(200, &refusal),
            Scripted::status(404),
        ])
        .await?;
        let srv = server(format!("{}/mcp", mock.base()));
        let transport = McpHttpTransport::new();
        let never = || {};
        for _ in 0..3 {
            let end = tokio::time::timeout(
                Duration::from_secs(5),
                listen_once(&transport, &srv, None, &never),
            )
            .await??;
            assert_eq!(end, StreamEnd::Declined);
        }
        mock.finish().await;
        Ok(())
    }
}
