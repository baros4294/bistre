//! Shared test support: a scripted local HTTP provider and recorded SSE fixtures.
//!
//! `MockServer` answers each accepted connection with the next scripted response and
//! records every request (method, path, headers, body), so wire tests assert on what was
//! actually sent. Fixtures live in `crates/bistre-core/fixtures/sse/<dialect>/<name>.sse`.

use std::path::PathBuf;
use std::time::Duration;

use bistre_protocol::{NodeRecord, NodeRole, ProviderDialect, ProviderProfile};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::credentials::KeyRing;

/// Upper bound for one recorded request (headers + body).
const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
/// How long `finish` waits for scripted responses that were not requested yet.
const FINISH_GRACE: Duration = Duration::from_secs(5);

/// One request as received by the mock provider.
#[derive(Debug, Clone)]
pub(crate) struct RecordedRequest {
    pub(crate) method: String,
    pub(crate) path: String,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) body: Vec<u8>,
}

impl RecordedRequest {
    /// Case-insensitive header lookup.
    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// The body parsed as JSON.
    pub(crate) fn body_json(&self) -> Result<serde_json::Value, serde_json::Error> {
        serde_json::from_slice(&self.body)
    }
}

/// How the scripted body is delivered.
#[derive(Debug, Clone)]
pub(crate) enum ScriptedBody {
    /// The whole body, then the connection closes.
    Full(Vec<u8>),
    /// `sent` bytes while `Content-Length` promises `declared`, then the connection drops.
    Truncated { sent: Vec<u8>, declared: usize },
    /// Headers are never sent; the connection stays open until the server is finished.
    Hang,
    /// The headers and these bytes are sent, then the connection stays open (a stalled stream).
    PartialThenHang(Vec<u8>),
}

/// One scripted HTTP response.
#[derive(Debug, Clone)]
pub(crate) struct Scripted {
    pub(crate) status: u16,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) body: ScriptedBody,
}

impl Scripted {
    /// `200` with an SSE body.
    pub(crate) fn sse(body: impl Into<String>) -> Self {
        Self {
            status: 200,
            headers: vec![("Content-Type".to_owned(), "text/event-stream".to_owned())],
            body: ScriptedBody::Full(body.into().into_bytes()),
        }
    }

    /// Any status with a JSON body.
    pub(crate) fn json(status: u16, body: &serde_json::Value) -> Self {
        Self {
            status,
            headers: vec![("Content-Type".to_owned(), "application/json".to_owned())],
            body: ScriptedBody::Full(body.to_string().into_bytes()),
        }
    }

    /// Any status with an empty body.
    pub(crate) fn status(status: u16) -> Self {
        Self {
            status,
            headers: Vec::new(),
            body: ScriptedBody::Full(Vec::new()),
        }
    }

    /// A response that never sends its headers.
    pub(crate) fn hang() -> Self {
        Self {
            status: 200,
            headers: Vec::new(),
            body: ScriptedBody::Hang,
        }
    }

    /// Adds one response header.
    pub(crate) fn with_header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_owned(), value.to_owned()));
        self
    }

    /// Sends the headers and the body so far, then stalls with the connection open.
    pub(crate) fn then_hang(mut self) -> Self {
        if let ScriptedBody::Full(sent) = self.body {
            self.body = ScriptedBody::PartialThenHang(sent);
        }
        self
    }

    /// Sends the body, then drops the connection although `Content-Length` promised more.
    pub(crate) fn truncated(mut self, declared: usize) -> Self {
        if let ScriptedBody::Full(sent) = self.body {
            self.body = ScriptedBody::Truncated { sent, declared };
        }
        self
    }
}

/// A loopback HTTP/1.1 server that serves scripted responses in order.
pub(crate) struct MockServer {
    base: String,
    records: mpsc::Receiver<RecordedRequest>,
    task: JoinHandle<()>,
    expected: usize,
}

impl MockServer {
    /// Binds `127.0.0.1:0` and serves `responses`, one per connection.
    pub(crate) async fn start(responses: Vec<Scripted>) -> std::io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let addr = listener.local_addr()?;
        let expected = responses.len();
        let (tx, records) = mpsc::channel(expected.max(1));
        let task = tokio::spawn(async move {
            // Connections are answered concurrently (a stalled stream must not block the next
            // request); the scripts are still handed out in accept order. Dropping the set when
            // the server is finished aborts any connection still open.
            let mut open = tokio::task::JoinSet::new();
            for scripted in responses {
                let Ok((sock, _)) = listener.accept().await else {
                    break;
                };
                let tx = tx.clone();
                open.spawn(async move {
                    if let Err(err) = serve_one(sock, scripted, &tx).await {
                        tracing::debug!(%err, "mock connection ended");
                    }
                });
            }
            while open.join_next().await.is_some() {}
        });
        Ok(Self {
            base: format!("http://{addr}"),
            records,
            task,
            expected,
        })
    }

    /// `http://127.0.0.1:<port>` with no trailing slash.
    pub(crate) fn base(&self) -> &str {
        &self.base
    }

    /// Stops the server and returns every recorded request, in arrival order.
    pub(crate) async fn finish(mut self) -> Vec<RecordedRequest> {
        let mut out = Vec::new();
        while out.len() < self.expected {
            match tokio::time::timeout(FINISH_GRACE, self.records.recv()).await {
                Ok(Some(req)) => out.push(req),
                Ok(None) | Err(_) => break,
            }
        }
        self.task.abort();
        out
    }
}

async fn serve_one(
    mut sock: TcpStream,
    scripted: Scripted,
    tx: &mpsc::Sender<RecordedRequest>,
) -> std::io::Result<()> {
    let request = read_request(&mut sock).await?;
    if tx.send(request).await.is_err() {
        return Ok(());
    }
    let mut head = format!("HTTP/1.1 {} Scripted\r\n", scripted.status);
    for (k, v) in &scripted.headers {
        for part in [k.as_str(), ": ", v.as_str(), "\r\n"] {
            head.push_str(part);
        }
    }
    match scripted.body {
        ScriptedBody::Full(body) => {
            head.push_str("Content-Length: ");
            head.push_str(&body.len().to_string());
            head.push_str("\r\nConnection: close\r\n\r\n");
            sock.write_all(head.as_bytes()).await?;
            sock.write_all(&body).await?;
        }
        ScriptedBody::Truncated { sent, declared } => {
            head.push_str("Content-Length: ");
            head.push_str(&declared.to_string());
            head.push_str("\r\nConnection: close\r\n\r\n");
            sock.write_all(head.as_bytes()).await?;
            sock.write_all(&sent).await?;
        }
        ScriptedBody::Hang => {
            std::future::pending::<()>().await;
        }
        ScriptedBody::PartialThenHang(sent) => {
            head.push_str("Connection: close\r\n\r\n");
            sock.write_all(head.as_bytes()).await?;
            sock.write_all(&sent).await?;
            sock.flush().await?;
            std::future::pending::<()>().await;
        }
    }
    sock.flush().await?;
    sock.shutdown().await
}

async fn read_request(sock: &mut TcpStream) -> std::io::Result<RecordedRequest> {
    let mut buf = Vec::with_capacity(8 * 1024);
    let mut chunk = [0_u8; 8 * 1024];
    let header_end = loop {
        if let Some(pos) = find_subslice(&buf, b"\r\n\r\n") {
            break pos;
        }
        let n = sock.read(&mut chunk).await?;
        if n == 0 || buf.len() + n > MAX_REQUEST_BYTES {
            return Err(std::io::Error::other(
                "request head incomplete or too large",
            ));
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).into_owned();
    let mut lines = head.split("\r\n");
    let mut start = lines.next().unwrap_or_default().split(' ');
    let method = start.next().unwrap_or_default().to_owned();
    let path = start.next().unwrap_or_default().to_owned();
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned()))
        .collect();
    let declared = headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .map(|(_, v)| v.parse::<usize>())
        .transpose()
        .map_err(std::io::Error::other)?
        .unwrap_or(0);
    // Record at most `MAX_REQUEST_BYTES`, but read the whole declared body: closing with unread
    // bytes resets the connection, and the client would see a failed upload.
    let mut body = buf[header_end + 4..].to_vec();
    let mut read_total = body.len();
    while read_total < declared {
        let n = sock.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        read_total += n;
        if body.len() < MAX_REQUEST_BYTES {
            body.extend_from_slice(&chunk[..n]);
        }
    }
    body.truncate(declared.min(MAX_REQUEST_BYTES));
    Ok(RecordedRequest {
        method,
        path,
        headers,
        body,
    })
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// Loads `fixtures/sse/<dialect>/<name>.sse`, normalising line endings to `\n`.
pub(crate) fn sse_fixture(dialect: ProviderDialect, name: &str) -> std::io::Result<String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("fixtures")
        .join("sse")
        .join(dialect.as_str())
        .join(format!("{name}.sse"));
    Ok(std::fs::read_to_string(path)?.replace("\r\n", "\n"))
}

/// A custom provider profile pointing at `base_url`.
pub(crate) fn provider(dialect: ProviderDialect, base_url: &str) -> ProviderProfile {
    ProviderProfile {
        id: "p".to_owned(),
        name: "Fixture".to_owned(),
        dialect,
        base_url: base_url.to_owned(),
        default_model: "fixture-model".to_owned(),
        key_hint: String::new(),
        has_api_key: true,
        is_enabled: true,
        is_builtin: false,
        use_server_state_cache: false,
        icon_slug: String::new(),
        custom_icon_path: String::new(),
        created_at_ms: 0,
        updated_at_ms: 0,
    }
}

/// A key ring holding `keys` in order.
pub(crate) fn keys(keys: &[&str]) -> KeyRing {
    KeyRing::new(
        keys.iter()
            .map(|k| zeroize::Zeroizing::new((*k).to_owned()))
            .collect(),
    )
}

/// A one-node history: a single user turn in thread `t`.
pub(crate) fn user_turn(text: &str) -> Vec<NodeRecord> {
    vec![NodeRecord {
        id: "u".to_owned(),
        thread_id: "t".to_owned(),
        parent_id: None,
        role: NodeRole::User,
        content: text.to_owned(),
        provider_meta_json: None,
        created_at_ms: 0,
    }]
}

#[cfg(test)]
mod fixture_tests {
    use std::sync::atomic::AtomicBool;

    use bistre_protocol::{GenerationParams, ProviderDialect};

    use super::{MockServer, Scripted, keys, provider, sse_fixture, user_turn};
    use crate::providers::{build_http_client, stream_completion};

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    async fn run_fixture(
        dialect: ProviderDialect,
        script: Vec<Scripted>,
        base_suffix: &str,
    ) -> Result<
        (crate::providers::StreamOutcome, Vec<super::RecordedRequest>),
        Box<dyn std::error::Error>,
    > {
        let server = MockServer::start(script).await?;
        let profile = provider(dialect, &format!("{}{base_suffix}", server.base()));
        let http = build_http_client()?;
        let cancel = AtomicBool::new(false);
        let outcome = stream_completion(
            &http,
            &profile,
            &keys(&["fixture-key"]),
            "fixture-model",
            "",
            &user_turn("hello"),
            GenerationParams::default(),
            true,
            &cancel,
            |_| {},
        )
        .await?;
        Ok((outcome, server.finish().await))
    }

    #[tokio::test]
    async fn every_dialect_text_fixture_streams_hello_world() -> TestResult {
        let cases = [
            (ProviderDialect::OpenAi, "text", "/v1", "/v1/responses"),
            (ProviderDialect::Anthropic, "text", "/v1", "/v1/messages"),
            (
                ProviderDialect::GoogleGemini,
                "text_interactions",
                "",
                "/v1beta/interactions",
            ),
            (
                ProviderDialect::CustomOpenAi,
                "text",
                "/v1",
                "/v1/chat/completions",
            ),
        ];
        for (dialect, name, suffix, path) in cases {
            let body = sse_fixture(dialect, name)?;
            let (outcome, seen) = run_fixture(dialect, vec![Scripted::sse(body)], suffix).await?;
            assert_eq!(outcome.full_text, "Hello world", "{dialect:?}");
            assert!(!outcome.interrupted, "{dialect:?}");
            assert_eq!(outcome.usage.input_tokens, 12, "{dialect:?}");
            assert_eq!(outcome.usage.output_tokens, 2, "{dialect:?}");
            assert_eq!(seen.len(), 1, "{dialect:?}");
            assert_eq!(seen[0].method, "POST", "{dialect:?}");
            assert_eq!(seen[0].path, path, "{dialect:?}");
            assert!(seen[0].body_json().is_ok(), "{dialect:?} body is JSON");
        }
        Ok(())
    }

    #[tokio::test]
    async fn gemini_generate_content_fixture_streams_after_interactions_404() -> TestResult {
        let body = sse_fixture(ProviderDialect::GoogleGemini, "text_generate_content")?;
        let (outcome, seen) = run_fixture(
            ProviderDialect::GoogleGemini,
            vec![Scripted::status(404), Scripted::sse(body)],
            "",
        )
        .await?;
        assert_eq!(outcome.full_text, "Hello world");
        assert_eq!(seen.len(), 2);
        assert!(seen[1].path.contains(":streamGenerateContent"));
        Ok(())
    }
}
