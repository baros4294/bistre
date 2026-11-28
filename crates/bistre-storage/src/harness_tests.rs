//! Unit tests for `harness.rs`.

use super::*;

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn oversized_step_output_spills_to_overflow_blob_and_hydrates_lazily() {
    let small = "{\"ok\":true}".to_owned();
    assert_eq!(spill_step_output(small.clone()), (small, None));
    let big = format!(
        "{{\"text\":\"{}\"}}",
        "x".repeat(MAX_INLINE_STEP_OUTPUT_BYTES + 10)
    );
    let (inline, blob) = spill_step_output(big.clone());
    assert!(inline.len() < 8 * 1024);
    assert!(inline.contains("\"overflow\":true"));
    assert_eq!(blob.map(String::from_utf8), Some(Ok(big)));
}

#[test]
fn spilled_step_output_round_trips_through_v8_schema() -> TestResult {
    let dir = tempfile::tempdir()?;
    let storage = StorageHandle::open(dir.path().join("v8.sqlite"))?;
    let thread = storage.create_thread(None, "Spill", ThreadMode::Code, None, None)?;
    let run = storage.create_agent_run(CreateAgentRunParams {
        thread_id: thread.id,
        parent_run_id: None,
        root_node_id: None,
        mode: ThreadMode::Code,
        max_steps: 4,
        unattended_policy: UnattendedPolicy::PauseAndNotify,
        worktree_path: None,
    })?;
    let step = storage.record_run_step(
        run.id.clone(),
        0,
        RunStepKind::ToolCall,
        "shell".to_owned(),
        ToolRiskTier::Tier2ExternalSideEffect,
        "k0".to_owned(),
        "running".to_owned(),
        "{}".to_owned(),
        "{}".to_owned(),
        0,
        None,
    )?;
    let big = format!(
        "{{\"stdout\":\"{}\"}}",
        "y".repeat(MAX_INLINE_STEP_OUTPUT_BYTES * 2)
    );
    assert!(
        storage
            .complete_run_step(step.id.clone(), "completed".to_owned(), big.clone(), 5)
            .is_ok()
    );
    let listed = storage.list_run_steps(&run.id);
    assert!(listed.is_ok_and(|steps| {
        steps
            .first()
            .is_some_and(|s| s.output_json.len() < 8 * 1024)
    }));
    assert_eq!(storage.load_run_step_output(&step.id)?, Some(big));
    Ok(())
}
