//! The daemon connection end to end: the RPC table, `LocalIpcEngine` over a real pipe or
//! socket, the event stream with replay after a reconnect, and the single writer.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use bistre_protocol::{DiagnosticKey, EngineEvent, ThreadMode};

use crate::daemon_launch::{DesktopEngine, open_in_process};
use crate::daemon_serve::{AttachedApps, serve_ipc_connection};
use crate::engine_rpc::{
    ENGINE_RPC_METHODS, LocalIpcEngine, SUBSCRIBE_EVENTS, dispatch_engine_rpc,
};
use crate::{EngineClient, InProcessEngine, VaultKey};

pub(crate) type TestResult = Result<(), Box<dyn std::error::Error>>;

fn test_engine(dir: &Path) -> Result<Arc<InProcessEngine>, Box<dyn std::error::Error>> {
    Ok(InProcessEngine::open_for_test(
        dir,
        crate::http_clients::provider_client()?,
    )?)
}

#[cfg(windows)]
fn test_endpoint(_dir: &Path) -> String {
    format!(r"\\.\pipe\bistre-test-{}", uuid::Uuid::now_v7().simple())
}

#[cfg(unix)]
fn test_endpoint(dir: &Path) -> String {
    dir.join("d.sock").to_string_lossy().into_owned()
}

/// Serves `engine` at `endpoint` the way the daemon does. Listening starts before this
/// returns, so a client may connect at once; aborting the task closes every connection it
/// accepted.
fn serve(
    engine: Arc<InProcessEngine>,
    endpoint: &str,
    apps: Arc<AttachedApps>,
) -> std::io::Result<tokio::task::JoinHandle<std::io::Result<()>>> {
    #[cfg(windows)]
    let mut server = tokio::net::windows::named_pipe::ServerOptions::new().create(endpoint)?;
    #[cfg(windows)]
    let endpoint = endpoint.to_owned();
    #[cfg(unix)]
    let listener = tokio::net::UnixListener::bind(endpoint)?;
    Ok(tokio::spawn(async move {
        let mut conns = tokio::task::JoinSet::new();
        loop {
            #[cfg(windows)]
            let stream = {
                server.connect().await?;
                let next =
                    tokio::net::windows::named_pipe::ServerOptions::new().create(&endpoint)?;
                std::mem::replace(&mut server, next)
            };
            #[cfg(unix)]
            let (stream, _) = listener.accept().await?;
            let (engine, apps) = (Arc::clone(&engine), Arc::clone(&apps));
            conns.spawn(async move {
                serve_ipc_connection(engine.as_ref(), stream, &apps).await;
            });
        }
    }))
}

/// Waits up to 10 s for `check` to hold.
async fn eventually(mut check: impl FnMut() -> bool) -> bool {
    for _ in 0..200 {
        if check() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    check()
}

/// Waits up to 10 s for a diagnostic event with `detail`.
async fn receive_detail(
    rx: &mut tokio::sync::broadcast::Receiver<EngineEvent>,
    detail: &str,
) -> bool {
    let wait = async {
        loop {
            match rx.recv().await {
                Ok(EngineEvent::DiagnosticRaised { detail_code, .. })
                    if detail_code.as_deref() == Some(detail) =>
                {
                    return true;
                }
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return false,
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(10), wait)
        .await
        .is_ok_and(|received| received)
}

fn log_diagnostic(engine: &InProcessEngine, detail: &str) {
    crate::events::emit_logged(
        &engine.storage,
        &engine.events_tx,
        None,
        EngineEvent::DiagnosticRaised {
            key: DiagnosticKey::ProviderStreamInterrupted,
            detail_code: Some(detail.to_owned()),
        },
    );
}

async fn verify_garbage_pack(engine: &dyn EngineClient) -> Option<bistre_protocol::BistreError> {
    engine
        .verify_data_pack(
            "key".to_owned(),
            vec![0, 159, 255],
            "sig".to_owned(),
            vec![1, 2, 3],
        )
        .await
        .err()
}

/// Every method in the table is answered: a call with arguments that do not fit is refused
/// as bad arguments, never as an unknown method. Names are unique and the stream is not one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_engine_method_has_a_daemon_route() -> TestResult {
    let dir = tempfile::tempdir()?;
    let engine = test_engine(dir.path())?;
    let unique: std::collections::HashSet<_> = ENGINE_RPC_METHODS.iter().collect();
    assert_eq!(unique.len(), ENGINE_RPC_METHODS.len());
    assert!(!ENGINE_RPC_METHODS.contains(&SUBSCRIBE_EVENTS));
    for method in ENGINE_RPC_METHODS {
        let err = dispatch_engine_rpc(
            engine.as_ref(),
            method,
            serde_json::Value::String("not arguments".to_owned()),
        )
        .await
        .err();
        assert_eq!(
            err.and_then(|e| e.detail_code).as_deref(),
            Some("rpc_params"),
            "{method}"
        );
    }
    let unknown = dispatch_engine_rpc(engine.as_ref(), "no_such_method", serde_json::Value::Null)
        .await
        .err();
    assert_eq!(
        unknown.and_then(|e| e.detail_code).as_deref(),
        Some("unknown_rpc_method")
    );
    Ok(())
}

/// Calls through the pipe return the engine's values and its exact errors, and payloads
/// larger than the old 8 MiB frame cross both ways.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn calls_cross_the_connection_with_their_values_and_errors() -> TestResult {
    let dir = tempfile::tempdir()?;
    let engine = test_engine(dir.path())?;
    let endpoint = test_endpoint(dir.path());
    let server = serve(
        Arc::clone(&engine),
        &endpoint,
        Arc::new(AttachedApps::default()),
    )?;
    let ipc = LocalIpcEngine::connect(endpoint, None).await?;

    let thread = ipc
        .create_thread(
            None,
            "Over the pipe".to_owned(),
            ThreadMode::Chat,
            None,
            None,
        )
        .await?;
    let node = ipc
        .append_node(
            thread.id.clone(),
            None,
            bistre_protocol::NodeRole::User,
            "hello".to_owned(),
            None,
        )
        .await?;
    let window = ipc.list_nodes_window(thread.id.clone(), None, 10).await?;
    assert_eq!(window, engine.list_nodes(thread.id.clone()).await?);
    assert_eq!(window.first().map(|n| n.id.clone()), Some(node.id));

    // Errors keep their key and detail.
    let via_pipe = ipc
        .list_nodes_window(thread.id.clone(), Some("not-a-node".to_owned()), 10)
        .await
        .err();
    let direct = engine
        .list_nodes_window(thread.id, Some("not-a-node".to_owned()), 10)
        .await
        .err();
    assert!(via_pipe.is_some());
    assert_eq!(via_pipe, direct);

    // Bytes travel as base64 and come back to the same verdict.
    let via_pipe = verify_garbage_pack(ipc.as_ref()).await;
    assert!(via_pipe.is_some());
    assert_eq!(via_pipe, verify_garbage_pack(engine.as_ref()).await);

    let big = "x".repeat(9 * 1024 * 1024);
    ipc.set_kv_meta("big".to_owned(), big.clone()).await?;
    assert_eq!(ipc.get_kv_meta("big".to_owned()).await?, Some(big));

    ipc.shutdown().await?;
    server.abort();
    Ok(())
}

/// The app is attached exactly while its event stream is open.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_app_is_attached_while_its_stream_is_open() -> TestResult {
    let dir = tempfile::tempdir()?;
    let engine = test_engine(dir.path())?;
    let endpoint = test_endpoint(dir.path());
    let apps = Arc::new(AttachedApps::default());
    let server = serve(engine, &endpoint, Arc::clone(&apps))?;
    let ipc = LocalIpcEngine::connect(endpoint, None).await?;
    assert!(eventually(|| apps.any()).await);
    ipc.shutdown().await?;
    assert!(eventually(|| !apps.any()).await);
    server.abort();
    Ok(())
}

/// Live events arrive, and an event logged while the connection was down is replayed when
/// the app reconnects.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn events_arrive_live_and_replay_after_a_reconnect() -> TestResult {
    let dir = tempfile::tempdir()?;
    let engine = test_engine(dir.path())?;
    let endpoint = test_endpoint(dir.path());
    let apps = Arc::new(AttachedApps::default());
    let server = serve(Arc::clone(&engine), &endpoint, Arc::clone(&apps))?;
    let ipc = LocalIpcEngine::connect(endpoint.clone(), None).await?;
    let mut rx = ipc.subscribe_events();
    assert!(eventually(|| apps.any()).await);

    log_diagnostic(&engine, "live");
    assert!(receive_detail(&mut rx, "live").await);

    // The daemon goes away; something is logged while no app is attached.
    server.abort();
    assert!(eventually(|| !apps.any()).await);
    log_diagnostic(&engine, "while_away");
    #[cfg(unix)]
    std::fs::remove_file(&endpoint)?;
    let server = serve(Arc::clone(&engine), &endpoint, Arc::clone(&apps))?;
    assert!(receive_detail(&mut rx, "while_away").await);

    ipc.shutdown().await?;
    server.abort();
    Ok(())
}

/// A backlog past the replay cap skips its oldest events: the newest one logged while the
/// app was away still arrives.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_replay_past_the_cap_keeps_the_newest_events() -> TestResult {
    let dir = tempfile::tempdir()?;
    let engine = test_engine(dir.path())?;
    let endpoint = test_endpoint(dir.path());
    let apps = Arc::new(AttachedApps::default());
    let server = serve(Arc::clone(&engine), &endpoint, Arc::clone(&apps))?;
    let ipc = LocalIpcEngine::connect(endpoint.clone(), None).await?;
    let mut rx = ipc.subscribe_events();
    assert!(eventually(|| apps.any()).await);

    server.abort();
    assert!(eventually(|| !apps.any()).await);
    let event = |detail: &str| EngineEvent::DiagnosticRaised {
        key: DiagnosticKey::ProviderStreamInterrupted,
        detail_code: Some(detail.to_owned()),
    };
    for _ in 0..crate::daemon_serve::MAX_REPLAY_EVENTS + 10 {
        engine
            .storage
            .append_engine_event_log(None, &event("backlog"))?;
    }
    engine
        .storage
        .append_engine_event_log(None, &event("newest"))?;
    #[cfg(unix)]
    std::fs::remove_file(&endpoint)?;
    let server = serve(Arc::clone(&engine), &endpoint, Arc::clone(&apps))?;
    assert!(receive_detail(&mut rx, "newest").await);

    ipc.shutdown().await?;
    server.abort();
    Ok(())
}

/// Only one process writes a data folder: a second in-process open is refused while the
/// first holds the folder, and allowed once it is gone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_second_writer_is_refused() -> TestResult {
    let dir = tempfile::tempdir()?;
    let first = open_in_process(dir.path(), Some(VaultKey::generate()?))?;
    assert!(matches!(first, DesktopEngine::InProcess(..)));
    let second = open_in_process(dir.path(), Some(VaultKey::generate()?)).err();
    assert_eq!(
        second.and_then(|e| e.detail_code).as_deref(),
        Some("data_folder_busy")
    );
    let (engine, lock) = first.into_parts();
    engine.shutdown().await?;
    drop((engine, lock));
    let third = open_in_process(dir.path(), Some(VaultKey::generate()?))?;
    let (engine, _lock) = third.into_parts();
    engine.shutdown().await?;
    Ok(())
}

/// A daemon already answering for the folder is used; the app never opens the database.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_running_daemon_is_used_instead_of_the_database() -> TestResult {
    let dir = tempfile::tempdir()?;
    let engine = test_engine(dir.path())?;
    let endpoint = crate::ipc_client::daemon_ipc_endpoint(dir.path());
    let server = serve(
        Arc::clone(&engine),
        &endpoint,
        Arc::new(AttachedApps::default()),
    )?;
    let desktop = crate::daemon_launch::open_desktop_engine(dir.path(), None).await?;
    assert!(matches!(desktop, DesktopEngine::Daemon(_)));
    let (app, lock) = desktop.into_parts();
    assert!(lock.is_none());
    assert_eq!(app.health().await?.core_version, crate::CORE_VERSION);
    app.shutdown().await?;
    server.abort();
    Ok(())
}
