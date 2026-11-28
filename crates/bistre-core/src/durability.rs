//! Recovery of runs a restart left unfinished, and per-tool replay safety (Spec 04, ADR-0003,
//! ADR-0013).

use bistre_protocol::{BistreResult, DiagnosticKey, EngineEvent, RunStatus};
use bistre_storage::StorageHandle;
use bistre_storage::harness::AgentRunUpdate;
use tokio::sync::broadcast;

use crate::events::emit_logged;

/// Whether a tool call is safe to re-run automatically if the host crashed mid-call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolReplaySafety {
    /// Pure or read-only observation (`read`, `grep`, `glob`, `diff`, `skill_load`, `calc_eval`,
    /// `dice_roll`, `mcp_schema`, `history_search`, `history_open`): safe to replay without duplicating side effects.
    ReplaySafe,
    /// Side-effecting or external (`edit`, `shell`, `web_fetch`, `web_search`, `computer_use`,
    /// `agent_memory`, `todo_write`, `mcp:*`): never auto-replayed after a crash.
    NonIdempotent,
}

/// Classifies whether `tool_name` may be safely replayed after an unexpected process crash.
#[must_use]
pub fn classify_tool_replay_safety(tool_name: &str) -> ToolReplaySafety {
    match tool_name {
        "read" | "grep" | "glob" | "diff" | "skill_load" | "calc_eval" | "dice_roll"
        | "mcp_schema" | "history_search" | "history_open" => ToolReplaySafety::ReplaySafe,
        _ => ToolReplaySafety::NonIdempotent,
    }
}

/// Summary of a boot-time recovery scan.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RecoveryReport {
    /// Runs a restart left unfinished, now failed with `diag.run.interrupted`.
    pub interrupted_run_ids: Vec<String>,
    /// Non-idempotent tool steps that were in flight, marked `interrupted` so they never re-run.
    pub interrupted_tool_steps: u32,
}

/// Unfinished runs scanned per page (pages repeat until none are left, at most 64 pages).
const RECOVERY_PAGE: u32 = 128;
const MAX_RECOVERY_PAGES: usize = 64;

/// Scans SQLite at engine open for runs a restart (crash, kill, closed daemon) left unfinished.
/// No process runs them any more, and a run never continues on its own, since that would send
/// a paid request without the user. So every in-flight non-idempotent tool step is marked
/// `interrupted` (never replayed) and every unfinished run fails with `diag.run.interrupted`;
/// the chat offers Try again.
pub fn recover_interrupted_runs(
    storage: &StorageHandle,
    events_tx: &broadcast::Sender<EngineEvent>,
) -> BistreResult<RecoveryReport> {
    let mut report = RecoveryReport::default();
    for _ in 0..MAX_RECOVERY_PAGES {
        let unfinished = storage.list_agent_runs(None, true, RECOVERY_PAGE)?;
        let full = unfinished.len() >= RECOVERY_PAGE as usize;
        for run in unfinished {
            for step in storage.list_run_steps(&run.id)? {
                if step.status == "running"
                    && !step.tool_name.is_empty()
                    && classify_tool_replay_safety(&step.tool_name)
                        == ToolReplaySafety::NonIdempotent
                {
                    let detail = serde_json::json!({
                        "interrupted_by_restart": true,
                        "replay_policy": "non_idempotent_not_replayed",
                        "tool": step.tool_name,
                    })
                    .to_string();
                    storage.complete_run_step(step.id, "interrupted".to_owned(), detail, 0)?;
                    report.interrupted_tool_steps = report.interrupted_tool_steps.saturating_add(1);
                }
            }
            let interrupted = storage.update_agent_run(
                run.id.clone(),
                AgentRunUpdate {
                    status: Some(RunStatus::Failed),
                    error_key: Some(Some(DiagnosticKey::RunInterrupted.as_key().to_owned())),
                    ..AgentRunUpdate::default()
                },
            )?;
            emit_logged(
                storage,
                events_tx,
                Some(run.thread_id),
                EngineEvent::RunStateChanged { run: interrupted },
            );
            report.interrupted_run_ids.push(run.id);
        }
        if !full {
            break;
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use bistre_protocol::{NodeRole, ThreadMode, UnattendedPolicy};
    use bistre_storage::harness::CreateAgentRunParams;

    fn make_run(
        storage: &StorageHandle,
        thread_id: String,
        unattended_policy: UnattendedPolicy,
    ) -> BistreResult<bistre_protocol::AgentRunRecord> {
        storage.create_agent_run(CreateAgentRunParams {
            thread_id,
            parent_run_id: None,
            root_node_id: None,
            mode: ThreadMode::Chat,
            max_steps: 24,
            unattended_policy,
            worktree_path: None,
        })
    }

    #[test]
    fn classify_tool_replay_safety_distinguishes_reads_from_side_effects() {
        assert_eq!(
            classify_tool_replay_safety("read"),
            ToolReplaySafety::ReplaySafe
        );
        assert_eq!(
            classify_tool_replay_safety("grep"),
            ToolReplaySafety::ReplaySafe
        );
        assert_eq!(
            classify_tool_replay_safety("calc_eval"),
            ToolReplaySafety::ReplaySafe
        );
        assert_eq!(
            classify_tool_replay_safety("shell"),
            ToolReplaySafety::NonIdempotent
        );
        assert_eq!(
            classify_tool_replay_safety("edit"),
            ToolReplaySafety::NonIdempotent
        );
        assert_eq!(
            classify_tool_replay_safety("computer_use"),
            ToolReplaySafety::NonIdempotent
        );
        assert_eq!(
            classify_tool_replay_safety("mcp__srv__deploy"),
            ToolReplaySafety::NonIdempotent
        );
    }

    /// After a restart nothing is left running: every unfinished run (waiting for approval,
    /// halted, or mid-tool) is failed as interrupted, and a side-effecting tool step that was
    /// in flight is marked interrupted so it never runs again. A second scan finds nothing.
    #[test]
    fn a_restart_leaves_no_run_running_and_never_replays_side_effects()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("durable.sqlite"))?;
        let thread = storage.create_thread(None, "durable", ThreadMode::Chat, None, None)?;
        let mid_tool = make_run(
            &storage,
            thread.id.clone(),
            UnattendedPolicy::PauseAndNotify,
        )?;
        storage.record_run_step(
            mid_tool.id.clone(),
            1,
            bistre_protocol::RunStepKind::ToolCall,
            "shell".to_owned(),
            bistre_protocol::ToolRiskTier::Tier2ExternalSideEffect,
            "idem-shell-1".to_owned(),
            "running".to_owned(),
            r#"{"command":"echo hi"}"#.to_owned(),
            String::new(),
            0,
            None,
        )?;
        let waiting = make_run(
            &storage,
            thread.id.clone(),
            UnattendedPolicy::DenyTier2AndContinue,
        )?;
        storage.update_agent_run(
            waiting.id.clone(),
            AgentRunUpdate {
                status: Some(RunStatus::WaitingApproval),
                ..AgentRunUpdate::default()
            },
        )?;
        let halted = make_run(&storage, thread.id, UnattendedPolicy::PauseAndNotify)?;
        storage.update_agent_run(
            halted.id.clone(),
            AgentRunUpdate {
                status: Some(RunStatus::IndeterminateHalt),
                ..AgentRunUpdate::default()
            },
        )?;
        let (tx, _rx) = broadcast::channel(16);

        let report = recover_interrupted_runs(&storage, &tx)?;
        let mut ids = report.interrupted_run_ids.clone();
        ids.sort();
        let mut expected = vec![mid_tool.id.clone(), waiting.id, halted.id];
        expected.sort();
        assert_eq!(ids, expected);
        assert_eq!(report.interrupted_tool_steps, 1);
        assert_eq!(storage.list_agent_runs(None, true, 10)?.len(), 0);
        let runs = storage.list_agent_runs(None, false, 10)?;
        assert!(runs.iter().all(|r| r.status == RunStatus::Failed
            && r.error_key.as_deref() == Some("diag.run.interrupted")));
        let step = storage.list_run_steps(&mid_tool.id)?;
        assert_eq!(step.first().map(|s| s.status.as_str()), Some("interrupted"));

        assert_eq!(
            recover_interrupted_runs(&storage, &tx)?,
            RecoveryReport::default()
        );
        Ok(())
    }

    #[test]
    fn a_restart_after_compaction_keeps_the_summary_and_interrupts_the_run()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let db_path = dir.path().join("compact_resume.sqlite");
        let thread_id = {
            let storage = StorageHandle::open(db_path.clone())?;
            let thread = storage.create_thread(None, "compact", ThreadMode::Chat, None, None)?;
            let u1 = storage.append_node(
                thread.id.clone(),
                None,
                NodeRole::User,
                "first".to_owned(),
                None,
            )?;
            let a1 = storage.append_node(
                thread.id.clone(),
                Some(u1.id),
                NodeRole::Assistant,
                "reply".to_owned(),
                None,
            )?;
            let _summary = storage.append_node(
                thread.id.clone(),
                Some(a1.id),
                NodeRole::CompactionSummary,
                "Compacted summary of earlier turns.".to_owned(),
                Some(serde_json::json!({ "compacted_count": 2 }).to_string()),
            )?;
            make_run(
                &storage,
                thread.id.clone(),
                UnattendedPolicy::PauseAndNotify,
            )?;
            thread.id
        };

        // Simulate restart: reopen SQLite and run boot recovery.
        let reopened = StorageHandle::open(db_path)?;
        let (tx, _rx) = broadcast::channel(16);
        let report = recover_interrupted_runs(&reopened, &tx)?;
        assert_eq!(report.interrupted_run_ids.len(), 1);
        let nodes = reopened.list_nodes(&thread_id)?;
        assert!(
            nodes
                .iter()
                .any(|n| n.role == NodeRole::CompactionSummary && n.content.contains("Compacted"))
        );
        Ok(())
    }
}
