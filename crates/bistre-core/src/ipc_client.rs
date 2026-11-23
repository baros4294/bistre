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
    let mut buf = vec![0_u8; len];
    reader
        .read_exact(&mut buf)
        .await
        .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
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
        use tokio::net::windows::named_pipe::ClientOptions;
        let mut client = ClientOptions::new()
            .open(endpoint)
            .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
        write_ipc_frame(&mut client, &request).await?;
        read_ipc_frame(&mut client).await
    }

    #[cfg(unix)]
    {
        use tokio::net::UnixStream;
        let mut stream = UnixStream::connect(endpoint)
            .await
            .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
        write_ipc_frame(&mut stream, &request).await?;
        read_ipc_frame(&mut stream).await
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
