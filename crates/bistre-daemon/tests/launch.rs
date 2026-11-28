//! The app's desktop start-up against the real `bistre-daemon` binary: it starts the daemon
//! detached, talks to it, reuses it while it runs, and the daemon exits by itself once the
//! app has left and no work is live.

use std::path::PathBuf;
use std::time::Duration;

use bistre_core::daemon_launch::{DesktopEngine, open_desktop_engine};
use bistre_core::ipc_client::{daemon_ipc_endpoint, probe_daemon_alive};
use bistre_protocol::ThreadMode;

type TestResult = Result<(), Box<dyn std::error::Error>>;

async fn wait_for(alive: bool, endpoint: &str) -> bool {
    for _ in 0..80 {
        if probe_daemon_alive(endpoint).await == alive {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    false
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_app_starts_the_daemon_uses_it_and_the_daemon_leaves_when_idle() -> TestResult {
    let dir = tempfile::tempdir()?;
    let exe = PathBuf::from(env!("CARGO_BIN_EXE_bistre-daemon"));
    let endpoint = daemon_ipc_endpoint(dir.path());
    assert!(!probe_daemon_alive(&endpoint).await);

    let first = open_desktop_engine(dir.path(), Some(exe.clone())).await?;
    assert!(matches!(first, DesktopEngine::Daemon(_)));
    let (app, lock) = first.into_parts();
    assert!(lock.is_none(), "the app holds no writer lock with a daemon");
    let thread = app
        .create_thread(
            None,
            "Via the daemon".to_owned(),
            ThreadMode::Chat,
            None,
            None,
        )
        .await?;

    // A second window finds the same daemon and sees the same data.
    let second = open_desktop_engine(dir.path(), Some(exe)).await?;
    let (other, _) = second.into_parts();
    let listed = other.list_threads(None).await?;
    assert!(listed.iter().any(|t| t.id == thread.id));

    other.shutdown().await?;
    app.shutdown().await?;
    drop((app, other));
    assert!(
        wait_for(false, &endpoint).await,
        "the daemon exits once no app is attached and nothing runs"
    );
    Ok(())
}
