//! The daemon's side of one IPC connection: answer one call from the RPC table, or stream
//! events to an attached app (ADR-0003).

use std::sync::atomic::{AtomicUsize, Ordering};

use bistre_protocol::{
    BistreError, BistreResult, DaemonEventFrame, DaemonRpcRequest, DaemonRpcResponse, EngineEvent,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite};
use tokio::sync::{Notify, broadcast};

use crate::EngineClient;
use crate::engine_rpc::{SUBSCRIBE_EVENTS, dispatch_engine_rpc};
use crate::ipc_client::{IPC_FRAME_TIMEOUT, read_ipc_frame, write_ipc_frame};

/// How many apps hold an event subscription. An app is attached exactly while its stream is
/// open, so a closed window (or a crashed app) detaches without having to say so.
#[derive(Debug, Default)]
pub struct AttachedApps {
    count: AtomicUsize,
    changed: Notify,
}

impl AttachedApps {
    /// Whether any app is attached.
    pub fn any(&self) -> bool {
        self.count.load(Ordering::SeqCst) > 0
    }

    /// Wakes when an app attaches or detaches.
    pub fn changed(&self) -> &Notify {
        &self.changed
    }

    fn attach(&self) -> AttachGuard<'_> {
        self.count.fetch_add(1, Ordering::SeqCst);
        self.changed.notify_one();
        AttachGuard(self)
    }
}

struct AttachGuard<'a>(&'a AttachedApps);

impl Drop for AttachGuard<'_> {
    fn drop(&mut self) {
        self.0.count.fetch_sub(1, Ordering::SeqCst);
        self.0.changed.notify_one();
    }
}

/// Serves one connection: reads one request, then answers it once or, for
/// [`SUBSCRIBE_EVENTS`], streams events until the app leaves.
pub async fn serve_ipc_connection<S>(engine: &dyn EngineClient, mut stream: S, apps: &AttachedApps)
where
    S: AsyncRead + AsyncWrite + Unpin + Send,
{
    let request = match read_ipc_frame::<_, DaemonRpcRequest>(&mut stream).await {
        Ok(request) => request,
        Err(err) => {
            tracing::debug!(key = err.key.as_key(), "IPC request unreadable");
            return;
        }
    };
    if request.method == SUBSCRIBE_EVENTS {
        let ended = match serde_json::from_value::<(Option<u64>,)>(request.params) {
            Ok((after,)) => stream_events(engine, stream, after, apps).await,
            Err(_) => Err(BistreError::with_detail(
                bistre_protocol::DiagnosticKey::InvalidInput,
                "rpc_params",
            )),
        };
        if let Err(err) = ended {
            tracing::debug!(key = err.key.as_key(), "event stream ended");
        }
        return;
    }
    let request_id = request.request_id;
    let response = match dispatch_engine_rpc(engine, &request.method, request.params).await {
        Ok(payload) => DaemonRpcResponse {
            request_id,
            payload,
            error: None,
        },
        Err(err) => error_response(request_id, err),
    };
    if let Err(err) = write_ipc_frame(&mut stream, &response).await {
        // A reply too large for one frame still gets an answer, so the app never waits it out.
        let answered = if err.detail_code.as_deref() == Some("ipc_frame_too_large") {
            write_ipc_frame(&mut stream, &error_response(request_id, err)).await
        } else {
            Err(err)
        };
        if let Err(err) = answered {
            tracing::debug!(key = err.key.as_key(), "IPC client left before the reply");
        }
    }
}

fn error_response(request_id: u64, err: BistreError) -> DaemonRpcResponse {
    DaemonRpcResponse {
        request_id,
        payload: serde_json::Value::Null,
        error: Some(err),
    }
}

/// Logged events replayed per request to the engine.
const REPLAY_PAGE: u32 = 200;
/// Most logged events one replay sends; older ones are skipped, since the newest say where
/// runs stand now (the app reloads its chats from storage anyway).
pub(crate) const MAX_REPLAY_EVENTS: u64 = 2_000;

/// Events whose stream is the content itself and that are never logged: they never move the
/// cursor, so they cost no storage read.
const fn is_streamed_only(event: &EngineEvent) -> bool {
    matches!(
        event,
        EngineEvent::DeltaBatch { .. }
            | EngineEvent::ThinkingDelta { .. }
            | EngineEvent::ToolExecutionUpdated { .. }
            | EngineEvent::LiveVoiceAudio { .. }
            | EngineEvent::LiveVoiceTranscript { .. }
    )
}

/// Streams events to one app: replays what was logged after `after`, says where the live
/// stream starts, then forwards every live event until the app closes the connection.
///
/// Each frame carries the log cursor the app has seen through. It advances only when no
/// event is queued, so a reconnect replays from there; an event logged in the instant between
/// its log write and its broadcast, exactly when the connection drops, can be missed (the app
/// reloads chats and runs from storage, so nothing is lost from history).
async fn stream_events<S>(
    engine: &dyn EngineClient,
    stream: S,
    after: Option<u64>,
    apps: &AttachedApps,
) -> BistreResult<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send,
{
    // Subscribe before reading the log, so nothing logged after the read is missed.
    let mut rx = engine.subscribe_events();
    let _attached = apps.attach();
    let (mut reader, mut writer) = tokio::io::split(stream);
    let mut cursor = match after {
        Some(after) => replay(engine, after, &mut writer).await?,
        None => engine.latest_event_cursor().await?,
    };
    send(&mut writer, cursor, None).await?;
    let mut probe = [0_u8; 1];
    loop {
        tokio::select! {
            recv = rx.recv() => match recv {
                Ok(event) => {
                    if !is_streamed_only(&event) && rx.is_empty() {
                        cursor = cursor.max(engine.latest_event_cursor().await?);
                    }
                    send(&mut writer, cursor, Some(event)).await?;
                }
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    tracing::warn!(skipped, "event stream fell behind; replaying the log");
                    cursor = replay(engine, cursor, &mut writer).await?;
                }
                Err(broadcast::error::RecvError::Closed) => return Ok(()),
            },
            // The app never writes after its request: any read result means it left.
            _ = reader.read(&mut probe) => return Ok(()),
        }
    }
}

/// Sends the newest [`MAX_REPLAY_EVENTS`] events logged after `after` and returns the cursor
/// reached. Cursors are `AUTOINCREMENT` row ids, so starting at `latest - MAX_REPLAY_EVENTS`
/// skips only the oldest backlog.
async fn replay<W>(engine: &dyn EngineClient, after: u64, writer: &mut W) -> BistreResult<u64>
where
    W: AsyncWrite + Unpin + Send,
{
    let latest = engine.latest_event_cursor().await?;
    let mut cursor = after.max(latest.saturating_sub(MAX_REPLAY_EVENTS));
    if cursor > after {
        tracing::warn!(
            skipped = cursor - after,
            "replay backlog over the cap; skipping the oldest logged events"
        );
    }
    let mut sent = 0_u64;
    loop {
        let page = engine.replay_events_after(cursor, REPLAY_PAGE).await?;
        let full = page.len() >= REPLAY_PAGE as usize;
        for record in page {
            cursor = record.cursor;
            send(writer, cursor, Some(record.event)).await?;
            sent = sent.saturating_add(1);
        }
        if !full {
            return Ok(cursor);
        }
        // Events logged while the replay runs can keep pages full; stop at the cap and let the
        // live stream carry on from the latest cursor.
        if sent >= MAX_REPLAY_EVENTS {
            tracing::warn!(sent, "replay cap reached while events kept arriving");
            return engine.latest_event_cursor().await;
        }
    }
}

/// Writes one frame, giving up after [`IPC_FRAME_TIMEOUT`] so an app that stopped reading
/// cannot hold the stream.
async fn send<W>(writer: &mut W, cursor: u64, event: Option<EngineEvent>) -> BistreResult<()>
where
    W: AsyncWrite + Unpin + Send,
{
    let frame = DaemonEventFrame { cursor, event };
    tokio::time::timeout(IPC_FRAME_TIMEOUT, write_ipc_frame(writer, &frame))
        .await
        .map_err(|_| {
            BistreError::with_detail(
                bistre_protocol::DiagnosticKey::DaemonUnavailable,
                "ipc_timeout",
            )
        })?
}
