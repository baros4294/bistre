//! Local IPC framing and client transport connecting desktop UI to persistent `bistre-daemon`.
//!
//! Uses length-prefixed JSON RPC frames over:
//! - Windows Named Pipe (`\\.\pipe\bistre-daemon-<16hex>`)
//! - Linux/Unix Domain Socket (`$XDG_RUNTIME_DIR/bistre-daemon-<16hex>.sock`)
//!
//! Deriving the endpoint hash strictly from the canonical `data_dir` guarantees dev (`.bistre-dev/`)
//! and production (`%LOCALAPPDATA%\Bistre`) daemons never collide.

use std::path::Path;

use bistre_crypto::sha256_hex;
use bistre_protocol::{
    BistreError, BistreResult, DaemonRpcRequest, DaemonRpcResponse, DiagnosticKey,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Hard upper bound for one local IPC frame (`64 MiB`, the same as one provider stream), so an
/// export, import, or read-aloud clip fits while memory stays bounded.
pub const MAX_IPC_FRAME_BYTES: usize = 64 * 1024 * 1024;

/// Computes the deterministic per-`data_dir` local IPC endpoint path (Windows Named Pipe or Unix socket).
pub fn daemon_ipc_endpoint(data_dir: &Path) -> String {
    let canonical = data_dir.to_string_lossy().to_lowercase();
    let digest = sha256_hex(canonical.as_bytes());
    let short_hash = &digest[..16];

    #[cfg(windows)]
    {
        format!(r"\\.\pipe\bistre-daemon-{short_hash}")
    }

    #[cfg(not(windows))]
    {
        if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR")
            && !runtime_dir.trim().is_empty()
        {
            return format!(
                "{}/bistre-daemon-{short_hash}.sock",
                runtime_dir.trim_end_matches('/')
            );
        }
        format!(
            "{}/bistre-daemon-{short_hash}.sock",
            data_dir.to_string_lossy().trim_end_matches('/')
        )
    }
}

/// Writes a single big-endian `u32` length-prefixed JSON frame to an async stream.
pub async fn write_ipc_frame<W, T>(writer: &mut W, value: &T) -> BistreResult<()>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let payload = serde_json::to_vec(value)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "ipc_encode"))?;
    if payload.len() > MAX_IPC_FRAME_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "ipc_frame_too_large",
        ));
    }
    let len = u32::try_from(payload.len())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "ipc_frame_len"))?;
    writer
        .write_all(&len.to_be_bytes())
        .await
        .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
    writer
        .write_all(&payload)
        .await
        .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
    writer
        .flush()
        .await
        .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
    Ok(())
}

/// Reads a single big-endian `u32` length-prefixed JSON frame from an async stream.
pub async fn read_ipc_frame<R, T>(reader: &mut R) -> BistreResult<T>
where
    R: AsyncRead + Unpin,
    T: DeserializeOwned,
{
    read_ipc_frame_within(reader, IPC_FRAME_TIMEOUT).await
}

/// How long one frame may take to arrive (an idle client never holds a daemon slot).
pub const IPC_FRAME_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// How long the app waits for the daemon's reply, which includes the daemon's own work.
pub const IPC_REPLY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// How long the app waits for a reply that is long work in the daemon (a run, a download, a
/// tool call). The work keeps its own tighter limits; this only bounds the wait.
pub const IPC_WORK_REPLY_TIMEOUT: std::time::Duration = std::time::Duration::from_hours(24);

/// [`read_ipc_frame`] with an explicit time limit for the whole frame. The body buffer grows
/// with the bytes that arrive, never to the declared length up front.
pub async fn read_ipc_frame_within<R, T>(
    reader: &mut R,
    limit: std::time::Duration,
) -> BistreResult<T>
where
    R: AsyncRead + Unpin,
    T: DeserializeOwned,
{
    tokio::time::timeout(limit, read_ipc_frame_untimed(reader))
        .await
        .map_err(|_| BistreError::with_detail(DiagnosticKey::DaemonUnavailable, "ipc_timeout"))?
}

async fn read_ipc_frame_untimed<R, T>(reader: &mut R) -> BistreResult<T>
where
    R: AsyncRead + Unpin,
    T: DeserializeOwned,
{
    let len = read_frame_len(reader).await?;
    read_frame_body(reader, len).await
}

/// Reads one frame of a stream that may stay quiet for hours (the event stream): waits for the
/// frame to start for as long as the connection lives, then gives the rest [`IPC_FRAME_TIMEOUT`].
pub async fn read_ipc_frame_when_ready<R, T>(reader: &mut R) -> BistreResult<T>
where
    R: AsyncRead + Unpin,
    T: DeserializeOwned,
{
    let len = read_frame_len(reader).await?;
    tokio::time::timeout(IPC_FRAME_TIMEOUT, read_frame_body(reader, len))
        .await
        .map_err(|_| BistreError::with_detail(DiagnosticKey::DaemonUnavailable, "ipc_timeout"))?
}

async fn read_frame_len<R: AsyncRead + Unpin>(reader: &mut R) -> BistreResult<usize> {
    let mut len_buf = [0_u8; 4];
    reader
        .read_exact(&mut len_buf)
        .await
        .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
    let len = usize::try_from(u32::from_be_bytes(len_buf))
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "ipc_len_cast"))?;
    if len == 0 || len > MAX_IPC_FRAME_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "ipc_invalid_frame_len",
        ));
    }
    Ok(len)
}

async fn read_frame_body<R, T>(reader: &mut R, len: usize) -> BistreResult<T>
where
    R: AsyncRead + Unpin,
    T: DeserializeOwned,
{
    let mut buf = Vec::with_capacity(len.min(64 * 1024));
    let read = (&mut *reader)
        .take(u64::try_from(len).unwrap_or(u64::MAX))
        .read_to_end(&mut buf)
        .await
        .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
    if read != len {
        return Err(BistreError::with_detail(
            DiagnosticKey::DaemonUnavailable,
            "ipc_short_frame",
        ));
    }
    serde_json::from_slice::<T>(&buf)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "ipc_decode"))
}

/// A connection to the daemon: a named pipe on Windows, a Unix socket elsewhere.
#[cfg(windows)]
pub type DaemonStream = tokio::net::windows::named_pipe::NamedPipeClient;
/// A connection to the daemon: a named pipe on Windows, a Unix socket elsewhere.
#[cfg(unix)]
pub type DaemonStream = tokio::net::UnixStream;

/// Opens a connection to the daemon at `endpoint`, refusing one served by another account
/// before anything is written to it (the endpoint name is predictable).
pub async fn open_daemon_stream(endpoint: &str) -> BistreResult<DaemonStream> {
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use tokio::net::windows::named_pipe::ClientOptions;
        // Win32 `ERROR_PIPE_BUSY`: every instance is taken for a moment; the daemon is
        // creating the next one.
        const ERROR_PIPE_BUSY: i32 = 231;
        let mut busy_waits = 0_u32;
        let client = loop {
            match ClientOptions::new().open(endpoint) {
                Ok(client) => break client,
                Err(err) if err.raw_os_error() == Some(ERROR_PIPE_BUSY) && busy_waits < 40 => {
                    busy_waits += 1;
                    tokio::time::sleep(std::time::Duration::from_millis(25)).await;
                }
                Err(_) => return Err(BistreError::new(DiagnosticKey::DaemonUnavailable)),
            }
        };
        if !bistre_crypto::pipe_identity::pipe_server_is_current_user(client.as_raw_handle())? {
            return Err(BistreError::with_detail(
                DiagnosticKey::DaemonUnavailable,
                "ipc_server_foreign_user",
            ));
        }
        Ok(client)
    }

    #[cfg(unix)]
    {
        let stream = tokio::net::UnixStream::connect(endpoint)
            .await
            .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
        let peer = stream.peer_cred().map_err(|_| {
            BistreError::with_detail(DiagnosticKey::DaemonUnavailable, "ipc_peer_cred")
        })?;
        if peer.uid() != bistre_crypto::pipe_identity::current_uid() {
            return Err(BistreError::with_detail(
                DiagnosticKey::DaemonUnavailable,
                "ipc_server_foreign_user",
            ));
        }
        Ok(stream)
    }
}

/// Executes a single RPC call against a running local `bistre-daemon` instance, waiting at
/// most `limit` for the reply.
pub async fn send_daemon_rpc(
    endpoint: &str,
    request: DaemonRpcRequest,
    limit: std::time::Duration,
) -> BistreResult<DaemonRpcResponse> {
    let mut stream = open_daemon_stream(endpoint).await?;
    write_ipc_frame(&mut stream, &request).await?;
    read_ipc_frame_within(&mut stream, limit).await
}

/// Probes whether a live `bistre-daemon` is reachable on `endpoint`.
pub async fn probe_daemon_alive(endpoint: &str) -> bool {
    let req = DaemonRpcRequest {
        request_id: 1,
        method: "health".to_owned(),
        params: serde_json::Value::Null,
    };
    send_daemon_rpc(endpoint, req, IPC_FRAME_TIMEOUT)
        .await
        .is_ok_and(|resp| resp.error.is_none())
}

#[cfg(all(test, windows))]
mod pipe_tests {
    use super::*;

    /// The client checks who serves the pipe; a daemon running as this user is accepted
    /// and answers. (A pipe served by another account is refused before anything is written;
    /// that path needs a second Windows account and is checked live, not here.)
    #[tokio::test]
    async fn a_same_user_daemon_pipe_passes_the_identity_check() -> BistreResult<()> {
        use tokio::net::windows::named_pipe::ServerOptions;
        let endpoint = format!(r"\\.\pipe\bistre-test-{}", uuid::Uuid::now_v7().simple());
        let server = ServerOptions::new()
            .first_pipe_instance(true)
            .create(&endpoint)
            .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
        let serve = tokio::spawn(async move {
            let mut conn = server;
            if conn.connect().await.is_err() {
                return;
            }
            if let Ok(req) = read_ipc_frame::<_, DaemonRpcRequest>(&mut conn).await {
                let resp = DaemonRpcResponse {
                    request_id: req.request_id,
                    payload: serde_json::Value::Null,
                    error: None,
                };
                drop(write_ipc_frame(&mut conn, &resp).await);
            }
        });
        let resp = send_daemon_rpc(
            &endpoint,
            DaemonRpcRequest {
                request_id: 7,
                method: "ping".to_owned(),
                params: serde_json::Value::Null,
            },
            IPC_REPLY_TIMEOUT,
        )
        .await?;
        assert!(resp.error.is_none());
        assert_eq!(resp.request_id, 7);
        drop(serve.await);
        Ok(())
    }
}

#[cfg(test)]
mod frame_tests {
    use super::*;

    /// A client that announces a frame and then goes quiet is dropped within the limit,
    /// so it cannot hold one of the daemon's connection slots.
    #[tokio::test]
    async fn a_stalled_frame_times_out() -> Result<(), Box<dyn std::error::Error>> {
        let (mut client, mut server) = tokio::io::duplex(1024);
        let declared = u32::try_from(MAX_IPC_FRAME_BYTES)?;
        client.write_all(&declared.to_be_bytes()).await?;
        client.write_all(b"{\"partial").await?;
        let started = std::time::Instant::now();
        let res = read_ipc_frame_within::<_, serde_json::Value>(
            &mut server,
            std::time::Duration::from_millis(200),
        )
        .await;
        assert_eq!(
            res.err().and_then(|e| e.detail_code).as_deref(),
            Some("ipc_timeout")
        );
        assert!(started.elapsed() < std::time::Duration::from_secs(5));
        drop(client);
        Ok(())
    }
}
