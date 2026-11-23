//! Resident Desktop Background Daemon for Bistre (ADR-0003, ADR-0013).
//!
//! Features:
//! - Survives Flutter window close while active agent runs or enabled cron jobs remain in flight,
//!   exiting cleanly once idle when launched in active-scoped mode (`--active-scoped`).
//! - Acquires run-scoped OS sleep inhibition (`Win32 PowerCreateRequest` on Windows; `systemd-logind`
//!   on Linux) and delivers OS suspend/resume notifications straight to `bistre-core`.
//! - Serves deterministic per-`data_dir` local IPC over Windows Named Pipe or Linux Unix Domain Socket
//!   with lossless `resume_after_cursor` event replay.

#[cfg(target_os = "linux")]
mod power_linux;
#[cfg(windows)]
mod power_win32;

use std::fs::OpenOptions;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use bistre_core::ipc_client::{daemon_ipc_endpoint, read_ipc_frame, write_ipc_frame};
use bistre_core::power::PowerGuardBackend;
use bistre_core::{EngineClient, InProcessEngine};
use bistre_protocol::{
    BistreError, BistreResult, DaemonRpcRequest, DaemonRpcResponse, DiagnosticKey, NodeRole,
    SystemPowerEvent, ThreadMode,
};
use fs2::FileExt;
use tokio::sync::Notify;

struct DaemonCli {
    data_dir: PathBuf,
    health_check: bool,
    active_scoped: bool,
    /// `--seed-synthetic N`: seed N synthetic chats for `just perf` (temp data dirs only).
    seed_synthetic: u32,
}

/// Hard cap on synthetic chats a perf seed may create.
const MAX_SYNTHETIC_CHATS: u32 = 1000;

fn parse_cli() -> DaemonCli {
    let mut data_dir: Option<PathBuf> = None;
    let mut health_check = false;
    let mut active_scoped = false;
    let mut seed_synthetic = 0_u32;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--health-check" => health_check = true,
            "--active-scoped" => active_scoped = true,
            "--seed-synthetic" => {
                seed_synthetic = args
                    .next()
                    .and_then(|v| v.parse::<u32>().ok())
                    .unwrap_or(0)
                    .min(MAX_SYNTHETIC_CHATS);
            }
            "--data-dir" => {
                if let Some(val) = args.next() {
                    data_dir = Some(PathBuf::from(val));
                }
            }
            _ => {}
        }
    }
    DaemonCli {
        data_dir: data_dir.unwrap_or_else(default_data_dir),
        health_check,
        active_scoped,
        seed_synthetic,
    }
}

/// Seeds `count` synthetic chats (6 alternating turns each) for the repeatable perf harness.
fn seed_synthetic_chats(engine: &InProcessEngine, count: u32) -> BistreResult<()> {
    let storage = engine.storage();
    for i in 0..count {
        let thread = storage.create_thread(
            None,
            &format!("Synthetic chat {i:03}"),
            ThreadMode::Chat,
            None,
            None,
        )?;
        let mut parent: Option<String> = None;
        for turn in 0..6_u32 {
            let (role, body) = if turn % 2 == 0 {
                (
                    NodeRole::User,
                    format!("Question {turn} for chat {i}: how should we keep the WAL small?"),
                )
            } else {
                (
                    NodeRole::Assistant,
                    format!(
                        "Answer {turn} for chat {i}.\n\n```rust\nfn checkpoint() -> u32 {{ {turn} }}\n```\n"
                    ),
                )
            };
            let node = storage.append_node(thread.id.clone(), parent.clone(), role, body, None)?;
            parent = Some(node.id);
        }
    }
    Ok(())
}

/// Longest the daemon sleeps before re-reading cron schedules (the app process may edit them).
const MAX_SCHEDULE_SLEEP: Duration = Duration::from_secs(300);
/// How long an active-scoped daemon waits, with the window closed and no work, before exiting.
const IDLE_EXIT_GRACE: Duration = Duration::from_secs(10);

/// Whether the app window has detached, plus a wake-up for anything waiting on that.
#[derive(Debug, Default)]
struct ClientState {
    detached: AtomicBool,
    changed: Notify,
}

impl ClientState {
    fn set_detached(&self, detached: bool) {
        self.detached.store(detached, Ordering::SeqCst);
        self.changed.notify_one();
    }
}

fn unix_now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// Earliest `next_run_ms` among enabled cron jobs.
fn next_cron_due_ms(engine: &InProcessEngine) -> Option<i64> {
    match engine.storage().list_cron_jobs() {
        Ok(jobs) => jobs
            .iter()
            .filter(|j| j.enabled)
            .map(|j| j.next_run_ms)
            .min(),
        Err(err) => {
            tracing::warn!(key = err.key.as_key(), "reading cron schedules failed");
            None
        }
    }
}

/// Event-driven housekeeping: fires due cron jobs and exits an idle active-scoped daemon.
/// Sleeps until the next cron deadline (at most [`MAX_SCHEDULE_SLEEP`]) and wakes early on
/// engine events or a client attach/detach; it never polls on a short timer.
fn spawn_idle_and_cron_task(
    engine: Arc<InProcessEngine>,
    shutdown: Arc<Notify>,
    client: Arc<ClientState>,
    active_scoped: bool,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut events = engine.subscribe_events();
        loop {
            let now_ms = unix_now_ms();
            match bistre_core::cron::poll_due_cron_jobs(&engine.storage(), now_ms) {
                Ok(due) if !due.is_empty() => {
                    tracing::info!(count = due.len(), "daemon triggered scheduled cron jobs");
                }
                Ok(_) => {}
                Err(err) => tracing::warn!(key = err.key.as_key(), "cron poll failed"),
            }
            let until_cron = next_cron_due_ms(&engine).map_or(MAX_SCHEDULE_SLEEP, |due| {
                Duration::from_millis(u64::try_from(due.saturating_sub(now_ms)).unwrap_or(0))
            });
            let idle = active_scoped
                && client.detached.load(Ordering::SeqCst)
                && engine.active_work_count() == 0;
            let wait = if idle {
                until_cron.min(MAX_SCHEDULE_SLEEP).min(IDLE_EXIT_GRACE)
            } else {
                until_cron.min(MAX_SCHEDULE_SLEEP)
            };
            tokio::select! {
                () = tokio::time::sleep(wait) => {
                    let still_idle = active_scoped
                        && client.detached.load(Ordering::SeqCst)
                        && engine.active_work_count() == 0;
                    if idle && still_idle {
                        tracing::info!(
                            "active-scoped daemon idle after window close; shutting down cleanly"
                        );
                        shutdown.notify_one();
                        break;
                    }
                }
                recv = events.recv() => {
                    if matches!(recv, Err(tokio::sync::broadcast::error::RecvError::Closed)) {
                        break;
                    }
                }
                () = client.changed.notified() => {}
            }
        }
    })
}

async fn run_health_check_and_exit(engine: &InProcessEngine) -> ExitCode {
    match engine.health().await {
        Ok(snap) => {
            if let Ok(json) = serde_json::to_string(&snap) {
                #[expect(
                    clippy::print_stdout,
                    reason = "CLI --health-check outputs machine-readable JSON snapshot to stdout."
                )]
                {
                    println!("{json}");
                }
            }
            ExitCode::SUCCESS
        }
        Err(err) => {
            tracing::error!(diagnostic = %err, "health check failed");
            ExitCode::FAILURE
        }
    }
}

// Two workers: enough for IPC plus one run, and far less idle RSS than one per core.
#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_target(false)
        .init();

    let cli = parse_cli();
    if let Err(err) = std::fs::create_dir_all(&cli.data_dir) {
        tracing::error!(error = %err, "failed to create daemon data directory");
        return ExitCode::FAILURE;
    }

    let lock_path = cli.data_dir.join("daemon.lock");
    let Ok(lock_file) = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)
    else {
        tracing::error!("failed to open single-instance lock file");
        return ExitCode::FAILURE;
    };

    if lock_file.try_lock_exclusive().is_err() {
        tracing::error!("diag.runtime.already_running");
        return ExitCode::from(2);
    }

    let engine = match InProcessEngine::open_with_power_guard(
        &cli.data_dir,
        platform_power_backend(),
        bistre_core::vault_key::resolve_vault_key(&cli.data_dir).await,
    ) {
        Ok(engine) => engine,
        Err(err) => {
            tracing::error!(diagnostic = %err, "engine bootstrap failed");
            return ExitCode::FAILURE;
        }
    };
    engine.power_coordinator().set_daemon_connected(true);

    if cli.seed_synthetic > 0 {
        let seeded = seed_synthetic_chats(&engine, cli.seed_synthetic);
        shutdown_and_unlock(&engine, &lock_file).await;
        return match seeded {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => {
                tracing::error!(diagnostic = %err, "synthetic seed failed");
                ExitCode::FAILURE
            }
        };
    }

    if cli.health_check {
        let outcome = run_health_check_and_exit(&engine).await;
        shutdown_and_unlock(&engine, &lock_file).await;
        return outcome;
    }

    if let Err(err) = engine.notify_power_event(SystemPowerEvent::DidResume).await {
        tracing::warn!(
            key = err.key.as_key(),
            "startup resume reconciliation failed"
        );
    }
    #[cfg(windows)]
    let _win32_watcher = power_win32::Win32SuspendWatcher::register(engine.power_coordinator());

    let power_engine = Arc::clone(&engine);
    let mut power_rx = engine.power_coordinator().subscribe();
    let power_task = tokio::spawn(async move {
        while let Ok(evt) = power_rx.recv().await {
            if let Err(err) = power_engine.notify_power_event(evt).await {
                tracing::warn!(key = err.key.as_key(), "power event handling failed");
            }
        }
    });

    let endpoint = daemon_ipc_endpoint(&cli.data_dir);
    let shutdown_notify = Arc::new(Notify::new());
    let client_state = Arc::new(ClientState::default());
    let idle_task = spawn_idle_and_cron_task(
        Arc::clone(&engine),
        Arc::clone(&shutdown_notify),
        Arc::clone(&client_state),
        cli.active_scoped,
    );

    let ipc_engine = Arc::clone(&engine);
    let ipc_endpoint = endpoint.clone();
    let ipc_detached = Arc::clone(&client_state);
    let ipc_shutdown = Arc::clone(&shutdown_notify);
    let ipc_task = tokio::spawn(async move {
        if let Err(err) =
            serve_local_ipc(ipc_engine, &ipc_endpoint, ipc_detached, ipc_shutdown).await
        {
            tracing::error!(diagnostic = %err, "local IPC server terminated");
        }
    });

    tracing::info!(
        data_dir = %cli.data_dir.display(),
        endpoint = %endpoint,
        active_scoped = cli.active_scoped,
        "bistre-daemon ready"
    );

    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            tracing::info!("shutdown signal received; draining engine and checkpointing WAL");
        }
        () = shutdown_notify.notified() => {
            tracing::info!("graceful daemon shutdown requested");
        }
    }

    ipc_task.abort();
    idle_task.abort();
    power_task.abort();
    #[cfg(unix)]
    remove_stale_socket(std::path::Path::new(&endpoint));
    shutdown_and_unlock(&engine, &lock_file).await;
    ExitCode::SUCCESS
}

/// Checkpoints the engine and releases the single-instance lock, logging (never hiding) failures.
async fn shutdown_and_unlock(engine: &InProcessEngine, lock_file: &std::fs::File) {
    if let Err(err) = engine.shutdown().await {
        tracing::warn!(key = err.key.as_key(), "engine shutdown checkpoint failed");
    }
    if let Err(err) = lock_file.unlock() {
        tracing::warn!(error = %err, "single-instance lock release failed");
    }
}

/// Removes a leftover Unix socket path; a missing file is the normal case.
#[cfg(unix)]
fn remove_stale_socket(path: &std::path::Path) {
    if let Err(err) = std::fs::remove_file(path)
        && err.kind() != std::io::ErrorKind::NotFound
    {
        tracing::warn!(error = %err, "stale IPC socket could not be removed");
    }
}

fn platform_power_backend() -> Arc<dyn PowerGuardBackend> {
    #[cfg(windows)]
    {
        power_win32::Win32PowerGuard::new()
    }
    #[cfg(target_os = "linux")]
    {
        power_linux::LinuxPowerGuard::new()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Arc::new(bistre_core::power::NoopPowerGuardBackend)
    }
}

async fn serve_local_ipc(
    engine: Arc<InProcessEngine>,
    endpoint: &str,
    client_detached: Arc<ClientState>,
    shutdown_notify: Arc<Notify>,
) -> BistreResult<()> {
    #[cfg(windows)]
    {
        use tokio::net::windows::named_pipe::ServerOptions;
        let mut first = true;
        let slots = Arc::new(tokio::sync::Semaphore::new(MAX_IPC_CONNECTIONS));
        let mut backoff = AcceptBackoff::default();
        loop {
            let server = ServerOptions::new()
                .first_pipe_instance(first)
                .create(endpoint)
                .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
            first = false;
            if server.connect().await.is_err() {
                backoff.wait().await;
                continue;
            }
            backoff.reset();
            let Ok(slot) = Arc::clone(&slots).acquire_owned().await else {
                return Err(BistreError::new(DiagnosticKey::DaemonUnavailable));
            };
            let eng = Arc::clone(&engine);
            let det = Arc::clone(&client_detached);
            let sd = Arc::clone(&shutdown_notify);
            tokio::spawn(async move {
                let _slot = slot;
                let mut conn = server;
                if let Ok(req) = read_ipc_frame::<_, DaemonRpcRequest>(&mut conn).await {
                    let resp = dispatch_rpc(&eng, req, &det, &sd).await;
                    if let Err(err) = write_ipc_frame(&mut conn, &resp).await {
                        tracing::debug!(key = err.key.as_key(), "IPC client left before the reply");
                    }
                }
            });
        }
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        use tokio::net::UnixListener;
        remove_stale_socket(std::path::Path::new(endpoint));
        let listener = UnixListener::bind(endpoint)
            .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
        // Fail closed: a socket other local users could open must never serve RPCs.
        std::fs::set_permissions(endpoint, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))?;
        let slots = Arc::new(tokio::sync::Semaphore::new(MAX_IPC_CONNECTIONS));
        let mut backoff = AcceptBackoff::default();
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                backoff.wait().await;
                continue;
            };
            backoff.reset();
            let Ok(slot) = Arc::clone(&slots).acquire_owned().await else {
                return Err(BistreError::new(DiagnosticKey::DaemonUnavailable));
            };
            let eng = Arc::clone(&engine);
            let det = Arc::clone(&client_detached);
            let sd = Arc::clone(&shutdown_notify);
            tokio::spawn(async move {
                let _slot = slot;
                if let Ok(req) = read_ipc_frame::<_, DaemonRpcRequest>(&mut stream).await {
                    let resp = dispatch_rpc(&eng, req, &det, &sd).await;
                    if let Err(err) = write_ipc_frame(&mut stream, &resp).await {
                        tracing::debug!(key = err.key.as_key(), "IPC client left before the reply");
                    }
                }
            });
        }
    }
}

/// Concurrent IPC connections; further clients wait for a slot.
const MAX_IPC_CONNECTIONS: usize = 16;

/// Exponential backoff (50 ms → 2 s) after failed accepts, so a persistent error cannot spin.
#[derive(Debug, Default)]
struct AcceptBackoff {
    failures: u32,
}

impl AcceptBackoff {
    async fn wait(&mut self) {
        self.failures = self.failures.saturating_add(1);
        let ms = 50_u64
            .saturating_mul(1_u64 << self.failures.min(6))
            .min(2_000);
        tracing::warn!(failures = self.failures, "IPC accept failed; backing off");
        tokio::time::sleep(Duration::from_millis(ms)).await;
    }

    fn reset(&mut self) {
        self.failures = 0;
    }
}

/// Parses RPC params; empty means none, malformed JSON is an error (never silently `null`).
fn parse_rpc_params(raw: &str) -> Result<serde_json::Value, BistreError> {
    if raw.trim().is_empty() {
        return Ok(serde_json::Value::Null);
    }
    serde_json::from_str(raw)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "rpc_params_json"))
}

fn rpc_response(
    request_id: u64,
    result: Result<serde_json::Value, BistreError>,
) -> DaemonRpcResponse {
    match result {
        Ok(val) => DaemonRpcResponse {
            request_id,
            ok: true,
            payload_json: val.to_string(),
            error: None,
        },
        Err(err) => DaemonRpcResponse {
            request_id,
            ok: false,
            payload_json: String::new(),
            error: Some(err),
        },
    }
}

async fn dispatch_rpc(
    engine: &Arc<InProcessEngine>,
    req: DaemonRpcRequest,
    client_detached: &Arc<ClientState>,
    shutdown_notify: &Arc<Notify>,
) -> DaemonRpcResponse {
    let request_id = req.request_id;
    let params = match parse_rpc_params(&req.params_json) {
        Ok(v) => v,
        Err(err) => return rpc_response(request_id, Err(err)),
    };

    let result: Result<serde_json::Value, BistreError> =
        match req.method.as_str() {
            "health" => engine.health().await.and_then(|v| {
                serde_json::to_value(v).map_err(|_| DiagnosticKey::InternalError.into())
            }),
            "power_guard_status" => engine.power_guard_status().await.and_then(|v| {
                serde_json::to_value(v).map_err(|_| DiagnosticKey::InternalError.into())
            }),
            "list_agent_runs" => {
                let thread_id = params
                    .get("thread_id")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned);
                let only_active = params
                    .get("only_active")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                let limit = params
                    .get("limit")
                    .and_then(serde_json::Value::as_u64)
                    .and_then(|n| u32::try_from(n).ok())
                    .unwrap_or(50);
                engine
                    .list_agent_runs(thread_id, only_active, limit)
                    .await
                    .and_then(|v| {
                        serde_json::to_value(v).map_err(|_| DiagnosticKey::InternalError.into())
                    })
            }
            "replay_events_after" => {
                let after_cursor = params
                    .get("after_cursor")
                    .and_then(serde_json::Value::as_u64)
                    .unwrap_or(0);
                let limit = params
                    .get("limit")
                    .and_then(serde_json::Value::as_u64)
                    .and_then(|n| u32::try_from(n).ok())
                    .unwrap_or(200);
                engine
                    .replay_events_after(after_cursor, limit)
                    .await
                    .and_then(|v| {
                        serde_json::to_value(v).map_err(|_| DiagnosticKey::InternalError.into())
                    })
            }
            "latest_event_cursor" => engine
                .latest_event_cursor()
                .await
                .map(|c| serde_json::json!({ "cursor": c })),
            "enqueue_steering" => {
                let thread_id = params
                    .get("thread_id")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let content = params
                    .get("content")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                engine
                    .enqueue_steering(thread_id, content)
                    .await
                    .and_then(|v| {
                        serde_json::to_value(v).map_err(|_| DiagnosticKey::InternalError.into())
                    })
            }
            "client_attached" => {
                client_detached.set_detached(false);
                Ok(serde_json::json!({ "active_work": engine.active_work_count() }))
            }
            "client_detached" => {
                client_detached.set_detached(true);
                let remaining = engine.active_work_count();
                Ok(serde_json::json!({ "stay_alive": remaining > 0, "active_work": remaining }))
            }
            "shutdown_if_idle" => {
                let remaining = engine.active_work_count();
                if remaining == 0 {
                    shutdown_notify.notify_one();
                }
                Ok(serde_json::json!({ "shutting_down": remaining == 0, "active_work": remaining }))
            }
            _ => Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "unknown_rpc_method",
            )),
        };

    rpc_response(request_id, result)
}

fn default_data_dir() -> PathBuf {
    #[cfg(windows)]
    {
        if let Ok(local_app_data) = std::env::var("LOCALAPPDATA") {
            return PathBuf::from(local_app_data).join("Bistre").join("data");
        }
    }
    #[cfg(not(windows))]
    {
        if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
            return PathBuf::from(xdg).join("bistre");
        }
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home)
                .join(".local")
                .join("share")
                .join("bistre");
        }
    }
    std::env::temp_dir().join("bistre-daemon")
}
