//! Live shell output for the tool timeline: while a `shell` call runs, its output so far
//! reaches the app as `ToolExecutionUpdated { status: "running" }`, coalesced to at most one
//! event per [`SHELL_PROGRESS_INTERVAL`] and holding only the last [`SHELL_PROGRESS_TAIL`]
//! bytes. The finished call's own event replaces it.

use std::time::{Duration, Instant};

use bistre_protocol::{EngineEvent, ToolRiskTier};
use tokio::sync::{broadcast, mpsc};

use crate::events::emit;

/// Shortest time between two progress events of one call.
pub(crate) const SHELL_PROGRESS_INTERVAL: Duration = Duration::from_millis(250);
/// Most output a progress event carries (the end of what was printed so far).
pub(crate) const SHELL_PROGRESS_TAIL: usize = 16 * 1024;
/// Pieces of output buffered between the command and the forwarder.
pub(crate) const SHELL_PROGRESS_QUEUE: usize = 32;

/// Which call the progress belongs to.
pub(crate) struct ShellProgressTarget<'a> {
    pub(crate) events_tx: &'a broadcast::Sender<EngineEvent>,
    pub(crate) thread_id: &'a str,
    pub(crate) run_id: &'a str,
    pub(crate) call_id: &'a str,
    pub(crate) risk: ToolRiskTier,
}

/// Forwards output pieces until the command ends (the sender is dropped).
pub(crate) async fn forward_shell_progress(
    mut rx: mpsc::Receiver<Vec<u8>>,
    target: ShellProgressTarget<'_>,
) {
    let started = Instant::now();
    let mut tail: Vec<u8> = Vec::new();
    let mut last_emit: Option<Instant> = None;
    while let Some(piece) = rx.recv().await {
        tail.extend_from_slice(&piece);
        if tail.len() > SHELL_PROGRESS_TAIL {
            let cut = tail.len() - SHELL_PROGRESS_TAIL;
            tail.drain(..cut);
        }
        if last_emit.is_some_and(|t| t.elapsed() < SHELL_PROGRESS_INTERVAL) {
            continue;
        }
        last_emit = Some(Instant::now());
        emit(
            target.events_tx,
            EngineEvent::ToolExecutionUpdated {
                thread_id: target.thread_id.to_owned(),
                run_id: target.run_id.to_owned(),
                call_id: target.call_id.to_owned(),
                tool_name: "shell".to_owned(),
                risk_tier: target.risk,
                status: "running".to_owned(),
                summary: "Running shell".to_owned(),
                output_text: String::from_utf8_lossy(&tail).into_owned(),
                diff_text: None,
                checkpoint_id: None,
                duration_ms: i64::try_from(started.elapsed().as_millis()).unwrap_or(i64::MAX),
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Output reaches the timeline while the command runs, coalesced and bounded.
    #[tokio::test]
    async fn progress_is_coalesced_and_bounded() -> Result<(), Box<dyn std::error::Error>> {
        let (events_tx, mut events_rx) = broadcast::channel(64);
        let (tx, rx) = mpsc::channel(SHELL_PROGRESS_QUEUE);
        let forward = forward_shell_progress(
            rx,
            ShellProgressTarget {
                events_tx: &events_tx,
                thread_id: "t",
                run_id: "r",
                call_id: "c",
                risk: ToolRiskTier::Tier2ExternalSideEffect,
            },
        );
        let producer = async move {
            for _ in 0..5 {
                tx.send(vec![b'x'; 8 * 1024]).await?;
            }
            Ok::<(), mpsc::error::SendError<Vec<u8>>>(())
        };
        let ((), fed) = tokio::join!(forward, producer);
        fed?;
        let mut events = Vec::new();
        while let Ok(ev) = events_rx.try_recv() {
            events.push(ev);
        }
        assert_eq!(events.len(), 1, "five quick pieces make one event");
        if let Some(EngineEvent::ToolExecutionUpdated {
            status,
            output_text,
            ..
        }) = events.first()
        {
            assert_eq!(status, "running");
            assert!(output_text.len() <= SHELL_PROGRESS_TAIL);
        }
        Ok(())
    }
}
