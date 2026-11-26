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

/// Hard upper bound for a single local IPC RPC frame (`8 MiB`), preventing memory exhaustion.
pub const MAX_IPC_FRAME_BYTES: usize = 8 * 1024 * 1024;

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

/// How long one frame may take to arrive (R40: an idle client never holds a daemon slot).
pub const IPC_FRAME_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// How long the app waits for the daemon's reply, which includes the daemon's own work.
pub const IPC_REPLY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// [`read_ipc_frame`] with an explicit time limit for the whole frame. The body buffer grows
/// with the bytes that arrive, never to the declared length up front (R40).
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

/// Executes a single RPC call against a running local `bistre-daemon` instance.
pub async fn send_daemon_rpc(
    endpoint: &str,
    request: DaemonRpcRequest,
) -> BistreResult<DaemonRpcResponse> {
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use tokio::net::windows::named_pipe::ClientOptions;
        let mut client = ClientOptions::new()
            .open(endpoint)
            .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
        // R29: the endpoint name is predictable, so refuse a pipe served by another account
        // before writing anything to it.
        if !bistre_crypto::pipe_identity::pipe_server_is_current_user(client.as_raw_handle())? {
            return Err(BistreError::with_detail(
                DiagnosticKey::DaemonUnavailable,
                "ipc_server_foreign_user",
            ));
        }
        write_ipc_frame(&mut client, &request).await?;
        read_ipc_frame_within(&mut client, IPC_REPLY_TIMEOUT).await
    }

    #[cfg(unix)]
    {
        use tokio::net::UnixStream;
        let mut stream = UnixStream::connect(endpoint)
            .await
            .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
        // R29: talk only to a daemon running as this user.
        let peer = stream.peer_cred().map_err(|_| {
            BistreError::with_detail(DiagnosticKey::DaemonUnavailable, "ipc_peer_cred")
        })?;
        if peer.uid() != bistre_crypto::pipe_identity::current_uid() {
            return Err(BistreError::with_detail(
                DiagnosticKey::DaemonUnavailable,
                "ipc_server_foreign_user",
            ));
        }
        write_ipc_frame(&mut stream, &request).await?;
        read_ipc_frame_within(&mut stream, IPC_REPLY_TIMEOUT).await
    }
}

/// Probes whether a live `bistre-daemon` is reachable on `endpoint`.
pub async fn probe_daemon_alive(endpoint: &str) -> bool {
    let req = DaemonRpcRequest {
        request_id: 1,
        method: "health".to_owned(),
        params_json: "{}".to_owned(),
    };
    send_daemon_rpc(endpoint, req)
        .await
        .is_ok_and(|resp| resp.ok)
}

#[cfg(all(test, windows))]
mod pipe_tests {
    use super::*;

    /// R29: the client checks who serves the pipe; a daemon running as this user is accepted
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
                    ok: true,
                    payload_json: "{}".to_owned(),
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
                params_json: "{}".to_owned(),
            },
        )
        .await?;
        assert!(resp.ok);
        assert_eq!(resp.request_id, 7);
        drop(serve.await);
        Ok(())
    }
}

#[cfg(test)]
mod frame_tests {
    use super::*;

    /// R40: a client that announces a frame and then goes quiet is dropped within the limit,
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
