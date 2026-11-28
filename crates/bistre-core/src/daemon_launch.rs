//! Desktop start-up (ADR-0003): use this data folder's `bistre-daemon`, starting it when it is
//! not running, or run the engine in this process when no daemon is installed beside the app.
//! Either way exactly one process writes the database: the daemon and the in-process engine
//! both hold the folder's single-writer lock, and the app never opens a second writer.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};

use crate::engine_rpc::{DaemonRelauncher, LocalIpcEngine};
use crate::ipc_client::{daemon_ipc_endpoint, probe_daemon_alive};
use crate::{CORE_VERSION, EngineClient, InProcessEngine};

/// The data folder's single-writer lock (`daemon.lock`), held for as long as this value lives.
#[derive(Debug)]
pub struct WriterLock {
    _file: std::fs::File,
}

impl WriterLock {
    /// Takes the lock; `Ok(None)` when another process (a daemon, another window) holds it.
    pub fn try_acquire(data_dir: &Path) -> BistreResult<Option<Self>> {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(data_dir.join("daemon.lock"))
            .map_err(|_| {
                BistreError::with_detail(DiagnosticKey::InternalError, "writer_lock_open")
            })?;
        match file.try_lock() {
            Ok(()) => Ok(Some(Self { _file: file })),
            Err(std::fs::TryLockError::WouldBlock) => Ok(None),
            Err(std::fs::TryLockError::Error(_)) => Err(BistreError::with_detail(
                DiagnosticKey::InternalError,
                "writer_lock",
            )),
        }
    }
}

/// The engine the desktop app runs on.
pub enum DesktopEngine {
    /// The daemon owns the data folder; the app talks to it.
    Daemon(Arc<LocalIpcEngine>),
    /// No daemon is installed: the engine runs here, holding the writer lock.
    InProcess(Arc<InProcessEngine>, WriterLock),
}

impl std::fmt::Debug for DesktopEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Daemon(_) => "DesktopEngine::Daemon",
            Self::InProcess(..) => "DesktopEngine::InProcess",
        })
    }
}

impl DesktopEngine {
    /// Splits into the engine and, in-process, the lock that must live as long as it.
    pub fn into_parts(self) -> (Arc<dyn EngineClient>, Option<WriterLock>) {
        match self {
            Self::Daemon(engine) => (engine, None),
            Self::InProcess(engine, lock) => (engine, Some(lock)),
        }
    }
}

/// The daemon binary installed beside the running app, if there is one.
pub fn bundled_daemon_exe() -> Option<PathBuf> {
    let name = if cfg!(windows) {
        "bistre-daemon.exe"
    } else {
        "bistre-daemon"
    };
    let exe = std::env::current_exe().ok()?.with_file_name(name);
    exe.is_file().then_some(exe)
}

/// How long a just-started daemon (or an outdated one finishing up) gets to answer.
const DAEMON_START_WAIT: Duration = Duration::from_secs(10);

/// Opens the desktop engine for `data_dir`: the running daemon, a daemon started from
/// `daemon_exe`, or (with no daemon binary) the in-process engine under the writer lock. A
/// daemon that holds the lock but does not answer is an error, never a second writer.
pub async fn open_desktop_engine(
    data_dir: &Path,
    daemon_exe: Option<PathBuf>,
) -> BistreResult<DesktopEngine> {
    std::fs::create_dir_all(data_dir)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "data_dir_create"))?;
    let endpoint = daemon_ipc_endpoint(data_dir);
    let mut alive = probe_daemon_alive(&endpoint).await;
    if alive {
        alive = settle_daemon_version(&endpoint).await?;
    }
    if let Some(exe) = daemon_exe {
        if !alive {
            if let Err(err) = crate::process_util::spawn_detached_daemon(&exe, data_dir) {
                tracing::warn!(error = %err, "daemon could not be started");
            }
            alive = wait_until(DAEMON_START_WAIT, || probe_daemon_alive(&endpoint), true).await;
        }
        if alive {
            let relaunch = relauncher(exe, data_dir.to_path_buf());
            return Ok(DesktopEngine::Daemon(
                LocalIpcEngine::connect(endpoint, Some(relaunch)).await?,
            ));
        }
        tracing::warn!("daemon did not answer; running the engine in this process");
    } else if alive {
        return Ok(DesktopEngine::Daemon(
            LocalIpcEngine::connect(endpoint, None).await?,
        ));
    }
    let key = crate::vault_key::resolve_vault_key(data_dir).await;
    open_in_process(data_dir, key)
}

/// Opens the engine in this process under the writer lock; refused while another process
/// (a daemon, another window) writes the folder.
pub(crate) fn open_in_process(
    data_dir: &Path,
    key: Option<crate::VaultKey>,
) -> BistreResult<DesktopEngine> {
    let Some(lock) = WriterLock::try_acquire(data_dir)? else {
        return Err(BistreError::with_detail(
            DiagnosticKey::RuntimeAlreadyRunning,
            "data_folder_busy",
        ));
    };
    Ok(DesktopEngine::InProcess(
        InProcessEngine::open(data_dir, key)?,
        lock,
    ))
}

/// A daemon from another app version speaks another protocol. Left unattached it exits once
/// its work is done; wait for that, and refuse while it is still busy. Returns whether the
/// answering daemon is still running (same version) or has exited (outdated).
async fn settle_daemon_version(endpoint: &str) -> BistreResult<bool> {
    let probe = LocalIpcEngine::probe_version(endpoint).await?;
    if probe == CORE_VERSION {
        return Ok(true);
    }
    tracing::info!(daemon = %probe, app = CORE_VERSION, "waiting for an outdated daemon to exit");
    if wait_until(DAEMON_START_WAIT, || probe_daemon_alive(endpoint), false).await {
        return Ok(false);
    }
    Err(BistreError::with_detail(
        DiagnosticKey::DaemonUnavailable,
        "daemon_version_mismatch",
    ))
}

/// Waits (backoff 50 ms doubling to 500 ms) until `check` returns `want`, at most `limit`.
/// Returns whether it did.
async fn wait_until<F, Fut>(limit: Duration, mut check: F, want: bool) -> bool
where
    F: FnMut() -> Fut,
    Fut: Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + limit;
    let mut pause = Duration::from_millis(50);
    loop {
        if check().await == want {
            return true;
        }
        if tokio::time::Instant::now() + pause > deadline {
            return false;
        }
        tokio::time::sleep(pause).await;
        pause = (pause * 2).min(Duration::from_millis(500));
    }
}

fn relauncher(exe: PathBuf, data_dir: PathBuf) -> DaemonRelauncher {
    Arc::new(move || {
        crate::process_util::spawn_detached_daemon(&exe, &data_dir)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::DaemonUnavailable, "spawn"))
    })
}
