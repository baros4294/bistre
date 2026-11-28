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

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use bistre_core::InProcessEngine;
use bistre_core::daemon_launch::WriterLock;
use bistre_core::daemon_serve::{AttachedApps, serve_ipc_connection};
use bistre_core::ipc_client::daemon_ipc_endpoint;
use bistre_core::power::PowerGuardBackend;
use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, EngineEvent, NodeRole, SystemPowerEvent, ThreadMode,
};
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

fn unix_now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// Shortest housekeeping sleep: a due job that could not be advanced never makes the loop spin.
const MIN_SCHEDULE_SLEEP: Duration = Duration::from_secs(1);

/// Why the housekeeping loop woke up.
enum Wake {
    Deadline,
    Event,
    Closed,
}

/// How long the housekeeping sleeps: until the next cron deadline, within
/// [`MIN_SCHEDULE_SLEEP`]..=[`MAX_SCHEDULE_SLEEP`] (and [`IDLE_EXIT_GRACE`] when idle).
fn housekeeping_wait(until_cron: Duration, idle: bool) -> Duration {
    let cap = if idle {
        MAX_SCHEDULE_SLEEP.min(IDLE_EXIT_GRACE)
    } else {
        MAX_SCHEDULE_SLEEP
    };
    until_cron.clamp(MIN_SCHEDULE_SLEEP, cap)
}

/// Events that change whether work is running (and so the idle exit); deltas do not.
const fn wakes_housekeeping(event: &EngineEvent) -> bool {
    matches!(
        event,
        EngineEvent::RunStarted { .. }
            | EngineEvent::RunFinished { .. }
            | EngineEvent::RunStateChanged { .. }
    )
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

/// Whether an active-scoped daemon has nothing to stay for: no app is attached and either no
/// work is live or the user turned off "keep running while a run is active". Unreadable
/// settings keep it running (the default), so a broken file never ends a run.
fn is_idle(engine: &InProcessEngine, apps: &AttachedApps, active_scoped: bool) -> bool {
    if !active_scoped || apps.any() {
        return false;
    }
    if engine.active_work_count() == 0 {
        return true;
    }
    match engine.storage().load_settings() {
        Ok(settings) => !settings.daemon_keep_alive_when_active,
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "settings unreadable; keeping work alive"
            );
            false
        }
    }
}

/// Event-driven housekeeping: fires due cron jobs and exits an idle active-scoped daemon.
/// Sleeps until the next cron deadline (at most [`MAX_SCHEDULE_SLEEP`]) and wakes early on
/// engine events or an app attaching or leaving; it never polls on a short timer.
fn spawn_idle_and_cron_task(
    engine: Arc<InProcessEngine>,
    shutdown: Arc<Notify>,
    apps: Arc<AttachedApps>,
    active_scoped: bool,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut events = engine.subscribe_events();
        loop {
            let now_ms = unix_now_ms();
            match bistre_core::cron::poll_due_cron_jobs(&engine.storage(), now_ms) {
                Ok(due) if !due.is_empty() => {
                    tracing::info!(count = due.len(), "daemon triggered scheduled cron jobs");
                    // Each due job starts its real run (it was only marked "triggered").
                    for mut job in due {
                        match engine.start_scheduled_run(job.clone()).await {
                            Ok(thread_id) => {
                                job.last_run_id = Some(thread_id);
                                "started".clone_into(&mut job.last_status);
                            }
                            Err(err) => {
                                tracing::warn!(
                                    key = err.key.as_key(),
                                    "scheduled run did not start"
                                );
                                err.key.as_key().clone_into(&mut job.last_status);
                            }
                        }
                        if let Err(err) = engine.storage().upsert_cron_job(job) {
                            tracing::warn!(
                                key = err.key.as_key(),
                                "saving the job's last run failed"
                            );
                        }
                    }
                }
                Ok(_) => {}
                Err(err) => tracing::warn!(key = err.key.as_key(), "cron poll failed"),
            }
            let until_cron = next_cron_due_ms(&engine).map_or(MAX_SCHEDULE_SLEEP, |due| {
                Duration::from_millis(u64::try_from(due.saturating_sub(now_ms)).unwrap_or(0))
            });
            let idle = is_idle(&engine, &apps, active_scoped);
            let deadline = tokio::time::Instant::now() + housekeeping_wait(until_cron, idle);
            // Only events that change whether work is running wake the housekeeping;
            // the stream of deltas during a run does not (each wake re-reads the schedule).
            let woke = loop {
                tokio::select! {
                    () = tokio::time::sleep_until(deadline) => break Wake::Deadline,
                    recv = events.recv() => match recv {
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            break Wake::Closed;
                        }
                        Ok(ev) if !wakes_housekeeping(&ev) => {}
                        _ => break Wake::Event,
                    },
                    () = apps.changed().notified() => break Wake::Event,
                }
            };
            match woke {
                Wake::Closed => break,
                Wake::Deadline => {
                    if idle && is_idle(&engine, &apps, active_scoped) {
                        tracing::info!(
                            "active-scoped daemon idle after window close; shutting down cleanly"
                        );
                        shutdown.notify_one();
                        break;
                    }
                }
                Wake::Event => {}
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

    let lock = match WriterLock::try_acquire(&cli.data_dir) {
        Ok(Some(lock)) => lock,
        Ok(None) => {
            tracing::error!("diag.runtime.already_running");
            return ExitCode::from(2);
        }
        Err(err) => {
            tracing::error!(diagnostic = %err, "single-instance lock unavailable");
            return ExitCode::FAILURE;
        }
    };

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
        shutdown_and_unlock(&engine, lock).await;
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
        shutdown_and_unlock(&engine, lock).await;
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
    let apps = Arc::new(AttachedApps::default());
    let idle_task = spawn_idle_and_cron_task(
        Arc::clone(&engine),
        Arc::clone(&shutdown_notify),
        Arc::clone(&apps),
        cli.active_scoped,
    );

    let ipc_engine = Arc::clone(&engine);
    let ipc_endpoint = endpoint.clone();
    let ipc_task = tokio::spawn(async move {
        if let Err(err) = serve_local_ipc(ipc_engine, &ipc_endpoint, apps).await {
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
    shutdown_and_unlock(&engine, lock).await;
    ExitCode::SUCCESS
}

/// Checkpoints the engine, then releases the single-instance lock, logging (never hiding) a
/// failed checkpoint.
async fn shutdown_and_unlock(engine: &InProcessEngine, lock: WriterLock) {
    if let Err(err) = engine.shutdown().await {
        tracing::warn!(key = err.key.as_key(), "engine shutdown checkpoint failed");
    }
    drop(lock);
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
    apps: Arc<AttachedApps>,
) -> BistreResult<()> {
    #[cfg(windows)]
    {
        use tokio::net::windows::named_pipe::ServerOptions;
        let slots = Arc::new(tokio::sync::Semaphore::new(MAX_IPC_CONNECTIONS));
        let mut backoff = AcceptBackoff::default();
        // Every pipe instance is granted only to this user and SYSTEM, and remote
        // (network) clients are refused.
        let mut security = bistre_crypto::pipe_identity::OwnerOnlyPipeSecurity::new()?;
        let mut options = ServerOptions::new();
        options
            .first_pipe_instance(true)
            .reject_remote_clients(true);
        let mut server = create_owner_only_pipe(&options, endpoint, &mut security)?;
        options.first_pipe_instance(false);
        loop {
            if server.connect().await.is_err() {
                backoff.wait().await;
                server = create_owner_only_pipe(&options, endpoint, &mut security)?;
                continue;
            }
            backoff.reset();
            // The next instance exists before this client is served, so the pipe never
            // disappears while every slot is busy (a client would take that for no daemon).
            let next = create_owner_only_pipe(&options, endpoint, &mut security)?;
            let connected = std::mem::replace(&mut server, next);
            let Ok(slot) = Arc::clone(&slots).acquire_owned().await else {
                return Err(BistreError::new(DiagnosticKey::DaemonUnavailable));
            };
            let eng = Arc::clone(&engine);
            let apps = Arc::clone(&apps);
            tokio::spawn(async move {
                let _slot = slot;
                serve_ipc_connection(eng.as_ref(), connected, &apps).await;
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
            let Ok((stream, _)) = listener.accept().await else {
                backoff.wait().await;
                continue;
            };
            backoff.reset();
            let Ok(slot) = Arc::clone(&slots).acquire_owned().await else {
                return Err(BistreError::new(DiagnosticKey::DaemonUnavailable));
            };
            let eng = Arc::clone(&engine);
            let apps = Arc::clone(&apps);
            tokio::spawn(async move {
                let _slot = slot;
                serve_ipc_connection(eng.as_ref(), stream, &apps).await;
            });
        }
    }
}

/// Concurrent IPC connections; further clients wait for a slot. A run's reply holds its
/// connection for the whole run, and each app holds one for its event stream.
const MAX_IPC_CONNECTIONS: usize = 64;

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

/// Creates one named-pipe instance with the owner-only security descriptor.
#[cfg(windows)]
#[expect(
    unsafe_code,
    reason = "Audited: tokio's raw security-attributes constructor (R29, ADR-0003)."
)]
fn create_owner_only_pipe(
    options: &tokio::net::windows::named_pipe::ServerOptions,
    endpoint: &str,
    security: &mut bistre_crypto::pipe_identity::OwnerOnlyPipeSecurity,
) -> BistreResult<tokio::net::windows::named_pipe::NamedPipeServer> {
    // SAFETY: `as_raw_attributes` returns a valid SECURITY_ATTRIBUTES pointer whose descriptor
    // lives as long as `security`, which outlives this call; the kernel copies it.
    unsafe { options.create_with_security_attributes_raw(endpoint, security.as_raw_attributes()) }
        .map_err(|_| BistreError::new(DiagnosticKey::DaemonUnavailable))
}

#[cfg(test)]
mod housekeeping_tests {
    use super::*;

    /// The housekeeping never spins (a due job that cannot advance still waits a
    /// second) and sleeps at most until the next deadline cap.
    #[test]
    fn housekeeping_waits_within_its_bounds() {
        assert_eq!(housekeeping_wait(Duration::ZERO, false), MIN_SCHEDULE_SLEEP);
        assert_eq!(
            housekeeping_wait(Duration::from_secs(3600), false),
            MAX_SCHEDULE_SLEEP
        );
        assert_eq!(
            housekeeping_wait(Duration::from_secs(3600), true),
            MAX_SCHEDULE_SLEEP.min(IDLE_EXIT_GRACE)
        );
    }

    /// With the window closed, live work keeps the daemon running only while "keep running
    /// while a run is active" is on; a daemon that is not active-scoped never idles out.
    #[test]
    fn keep_alive_off_lets_a_closed_window_end_live_work() -> Result<(), Box<dyn std::error::Error>>
    {
        let dir = tempfile::tempdir()?;
        let engine = InProcessEngine::open(dir.path(), Some(bistre_core::VaultKey::generate()?))?;
        let storage = engine.storage();
        storage.upsert_cron_job(bistre_protocol::CronJobRecord {
            id: String::new(),
            name: "Nightly".to_owned(),
            workspace_id: "default".to_owned(),
            assistant_id: "default_assistant".to_owned(),
            schedule_expr: "0 3 * * *".to_owned(),
            prompt: "x".to_owned(),
            mode: ThreadMode::Chat,
            unattended_policy: bistre_protocol::UnattendedPolicy::PauseAndNotify,
            use_worktree: false,
            enabled: true,
            next_run_ms: unix_now_ms() + 3_600_000,
            last_run_id: None,
            last_status: "idle".to_owned(),
        })?;
        let apps = AttachedApps::default();
        assert!(!is_idle(&engine, &apps, true));
        let mut settings = storage.load_settings()?;
        settings.daemon_keep_alive_when_active = false;
        storage.save_settings(settings)?;
        assert!(is_idle(&engine, &apps, true));
        assert!(!is_idle(&engine, &apps, false));
        Ok(())
    }

    /// Streaming deltas do not wake the housekeeping; run start and end do.
    #[test]
    fn only_run_state_events_wake_the_housekeeping() {
        let delta = EngineEvent::DeltaBatch {
            thread_id: "t".to_owned(),
            chunks: Vec::new(),
        };
        assert!(!wakes_housekeeping(&delta));
        let finished = EngineEvent::RunFinished {
            thread_id: "t".to_owned(),
            node_id: "n".to_owned(),
            cancelled: false,
        };
        assert!(wakes_housekeeping(&finished));
    }
}
