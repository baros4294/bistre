//! Goal mode: a chat's goal, which the model works toward across its steps and closes with
//! `goal_complete`. A reply that ends while the goal is open gets a work check, a user turn
//! that sends the model back to the goal, at most [`MAX_GOAL_CHECKS`] times per message the
//! user wrote.

use bistre_protocol::{
    BistreError, BistreResult, DiagnosticKey, NodeRecord, NodeRole, ThreadMode, ToolRiskTier,
};
use bistre_storage::StorageHandle;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::agent_tools::{ActiveToolCatalog, ToolPermission};
use crate::tools::ToolExecutionOutput;

/// The tool that closes the goal.
pub const GOAL_COMPLETE: &str = "goal_complete";
/// Longest goal, in characters.
pub const MAX_GOAL_CHARS: usize = 2_000;
/// Longest summary `goal_complete` keeps, in characters.
const MAX_GOAL_SUMMARY_CHARS: usize = 4_000;
/// Work checks sent after one message the user wrote, before the run stops.
pub const MAX_GOAL_CHECKS: usize = 3;
/// The node metadata mark of a work check.
pub const GOAL_CHECK_MARK: &str = "goal_check";

/// The user turn a work check sends.
pub(crate) const GOAL_CHECK_PROMPT: &str = "The goal is still open. Compare the work so far with the goal. If any part is unfinished or unchecked, continue it now. If every part is done and checked, call `goal_complete`.";

/// The goal set for one chat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadGoal {
    pub objective: String,
    pub completed: bool,
    /// What `goal_complete` reported was done and how it was checked.
    pub summary: String,
}

/// The `kv_meta` key prefix; the chat id follows.
pub(crate) const KEY_PREFIX: &str = "thread_goal:";

fn key(thread_id: &str) -> String {
    format!("{KEY_PREFIX}{thread_id}")
}

/// The chat's goal; `None` when none is set. A stored value that does not parse is an error.
pub fn load(storage: &StorageHandle, thread_id: &str) -> BistreResult<Option<ThreadGoal>> {
    let Some(raw) = storage.get_kv_meta(&key(thread_id))? else {
        return Ok(None);
    };
    serde_json::from_str(&raw)
        .map(Some)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "goal_decode"))
}

fn save(storage: &StorageHandle, thread_id: &str, goal: &ThreadGoal) -> BistreResult<()> {
    let encoded = serde_json::to_string(goal)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "goal_encode"))?;
    storage.set_kv_meta(key(thread_id), encoded)
}

/// Sets a new open goal for the chat; blank text clears it. Control characters are dropped
/// (newlines kept), so a pasted goal cannot add prompt structure.
pub fn set_objective(
    storage: &StorageHandle,
    thread_id: &str,
    objective: &str,
) -> BistreResult<Option<ThreadGoal>> {
    let clean: String = objective
        .chars()
        .filter(|c| !c.is_control() || *c == '\n')
        .collect();
    let clean = clean.trim();
    if clean.is_empty() {
        storage.delete_kv_meta(key(thread_id))?;
        return Ok(None);
    }
    if clean.chars().count() > MAX_GOAL_CHARS {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "goal_too_long",
        ));
    }
    let goal = ThreadGoal {
        objective: clean.to_owned(),
        completed: false,
        summary: String::new(),
    };
    save(storage, thread_id, &goal)?;
    Ok(Some(goal))
}

/// The open goal that runs work toward: set, not complete, outside Write mode.
fn open_goal(storage: &StorageHandle, thread_id: &str, mode: ThreadMode) -> Option<ThreadGoal> {
    if mode == ThreadMode::Write {
        return None;
    }
    match load(storage, thread_id) {
        Ok(goal) => goal.filter(|g| !g.completed),
        Err(err) => {
            tracing::warn!(
                key = err.key.as_key(),
                "chat goal unreadable; runs go on without it"
            );
            None
        }
    }
}

/// Adds the open goal to the system prompt, after the chat's own instructions.
pub(crate) fn append_prompt(
    storage: &StorageHandle,
    thread_id: &str,
    mode: ThreadMode,
    prompt: &mut String,
) {
    let Some(goal) = open_goal(storage, thread_id, mode) else {
        return;
    };
    if !prompt.trim().is_empty() {
        prompt.push_str("\n\n");
    }
    prompt.push_str("[Goal for this chat]\n");
    prompt.push_str(&goal.objective);
    prompt.push_str(
        "\nWork toward this goal across your steps. Call `goal_complete` once every part is done and checked; never call it while a part is unfinished or unchecked.",
    );
}

fn schema() -> Value {
    json!({
        "name": GOAL_COMPLETE,
        "description": "Mark the chat's goal complete. Call it only when every part is done and checked.",
        "parameters": {
            "type": "object",
            "properties": {
                "summary": { "type": "string", "description": "What was done." },
                "verification": { "type": "string", "description": "How each part was checked." }
            },
            "required": ["summary", "verification"]
        }
    })
}

/// Offers `goal_complete`, in name order, while the chat has an open goal and tools are on.
pub fn offer(
    catalog: &mut ActiveToolCatalog,
    storage: &StorageHandle,
    thread_id: &str,
    mode: ThreadMode,
) {
    if catalog.trust_preset == bistre_protocol::TrustPreset::Off
        || catalog.permissions.get(GOAL_COMPLETE) == Some(&ToolPermission::Off)
        || open_goal(storage, thread_id, mode).is_none()
    {
        return;
    }
    let at = catalog
        .canonical_schemas
        .partition_point(|s| s.get("name").and_then(Value::as_str) < Some(GOAL_COMPLETE));
    catalog.canonical_schemas.insert(at, schema());
}

/// Runs `goal_complete`: closes the open goal with what was done and how it was checked.
pub fn dispatch(
    storage: &StorageHandle,
    thread_id: &str,
    args: &Value,
) -> BistreResult<ToolExecutionOutput> {
    let field = |name: &str| {
        args.get(name)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                BistreError::with_detail(DiagnosticKey::InvalidInput, "goal_complete_args")
            })
    };
    let (summary, verification) = (field("summary")?, field("verification")?);
    let Some(mut goal) = load(storage, thread_id)?.filter(|g| !g.completed) else {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "no_open_goal",
        ));
    };
    goal.completed = true;
    goal.summary = format!("{summary}\n\n{verification}")
        .chars()
        .take(MAX_GOAL_SUMMARY_CHARS)
        .collect();
    save(storage, thread_id, &goal)?;
    Ok(ToolExecutionOutput {
        tool_name: GOAL_COMPLETE.to_owned(),
        risk_tier: ToolRiskTier::Tier0ReadOnly,
        ok: true,
        summary: summary.chars().take(120).collect(),
        output_text: "The goal is marked complete.".to_owned(),
        diff_text: None,
        checkpoint_id: None,
        duration_ms: 0,
        media_attachments: Vec::new(),
    })
}

fn is_check(node: &NodeRecord) -> bool {
    node.provider_meta_json
        .as_deref()
        .and_then(|m| serde_json::from_str::<Value>(m).ok())
        .is_some_and(|v| v.get(GOAL_CHECK_MARK) == Some(&Value::Bool(true)))
}

/// Whether the reply that ends the branch at `leaf_id` gets a work check: the chat has an
/// open goal, tools are on (the model can call `goal_complete`), and fewer than
/// [`MAX_GOAL_CHECKS`] checks followed the user's latest message.
pub(crate) fn check_due(
    storage: &StorageHandle,
    thread_id: &str,
    leaf_id: &str,
) -> BistreResult<bool> {
    let mode = storage
        .get_thread(thread_id)?
        .map_or(ThreadMode::Chat, |t| t.mode);
    let tools_on = storage.load_settings()?.trust_preset != bistre_protocol::TrustPreset::Off;
    if !tools_on || open_goal(storage, thread_id, mode).is_none() {
        return Ok(false);
    }
    let branch = storage.list_branch(thread_id, leaf_id)?;
    let checks = branch
        .iter()
        .rev()
        .filter(|n| n.role == NodeRole::User)
        .take_while(|n| is_check(n))
        .count();
    Ok(checks < MAX_GOAL_CHECKS)
}

/// The metadata a work check's user turn carries.
pub(crate) fn check_meta(run_id: &str) -> String {
    json!({ GOAL_CHECK_MARK: true, "run_id": run_id }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn storage()
    -> Result<(tempfile::TempDir, std::sync::Arc<StorageHandle>), Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let storage = StorageHandle::open(dir.path().join("goal.sqlite"))?;
        Ok((dir, storage))
    }

    /// A goal is set, closed by `goal_complete` with its summary, and cleared by blank text;
    /// closing needs both fields and an open goal.
    #[test]
    fn a_goal_opens_closes_with_its_summary_and_clears() -> Result<(), Box<dyn std::error::Error>> {
        let (_dir, storage) = storage()?;
        let set = set_objective(&storage, "t1", "  Ship the\u{7} parser \n")?;
        assert_eq!(set.map(|g| g.objective), Some("Ship the parser".to_owned()));
        assert!(dispatch(&storage, "t1", &json!({ "summary": "done" })).is_err());
        let out = dispatch(
            &storage,
            "t1",
            &json!({ "summary": "Parser shipped", "verification": "Tests pass" }),
        )?;
        assert!(out.ok);
        let goal = load(&storage, "t1")?.ok_or("goal kept")?;
        assert!(goal.completed);
        assert_eq!(goal.summary, "Parser shipped\n\nTests pass");
        assert!(
            dispatch(
                &storage,
                "t1",
                &json!({ "summary": "a", "verification": "b" })
            )
            .is_err(),
            "a closed goal cannot close again"
        );
        assert_eq!(set_objective(&storage, "t1", " \n ")?, None);
        assert_eq!(load(&storage, "t1")?, None);
        let long = "x".repeat(MAX_GOAL_CHARS + 1);
        assert!(set_objective(&storage, "t1", &long).is_err());
        Ok(())
    }

    /// The open goal reaches the prompt; a closed one, or Write mode, leaves it out.
    #[test]
    fn only_an_open_goal_reaches_the_prompt() -> Result<(), Box<dyn std::error::Error>> {
        let (_dir, storage) = storage()?;
        set_objective(&storage, "t1", "Port the tests")?;
        let mut prompt = "Base".to_owned();
        append_prompt(&storage, "t1", ThreadMode::Chat, &mut prompt);
        assert!(prompt.starts_with("Base\n\n[Goal for this chat]\nPort the tests\n"));
        let mut story = String::new();
        append_prompt(&storage, "t1", ThreadMode::Write, &mut story);
        assert_eq!(story, "");
        dispatch(
            &storage,
            "t1",
            &json!({ "summary": "a", "verification": "b" }),
        )?;
        let mut closed = String::new();
        append_prompt(&storage, "t1", ThreadMode::Chat, &mut closed);
        assert_eq!(closed, "");
        Ok(())
    }

    /// Work checks stop after [`MAX_GOAL_CHECKS`] in a row; the user's next message starts a
    /// new count.
    #[test]
    fn work_checks_are_bounded_per_user_message() -> Result<(), Box<dyn std::error::Error>> {
        let (_dir, storage) = storage()?;
        let thread = storage.create_thread(None, "Goal", ThreadMode::Chat, None, None)?;
        let tid = thread.id.as_str();
        let mut leaf = storage
            .append_node(tid.to_owned(), None, NodeRole::User, "Go".to_owned(), None)?
            .id;
        assert!(!check_due(&storage, tid, &leaf)?, "no goal, no check");
        set_objective(&storage, tid, "Finish")?;
        for _ in 0..MAX_GOAL_CHECKS {
            leaf = storage
                .append_node(
                    tid.to_owned(),
                    Some(leaf),
                    NodeRole::Assistant,
                    "Step".to_owned(),
                    None,
                )?
                .id;
            assert!(check_due(&storage, tid, &leaf)?);
            leaf = storage
                .append_node(
                    tid.to_owned(),
                    Some(leaf),
                    NodeRole::User,
                    GOAL_CHECK_PROMPT.to_owned(),
                    Some(check_meta("r1")),
                )?
                .id;
        }
        leaf = storage
            .append_node(
                tid.to_owned(),
                Some(leaf),
                NodeRole::Assistant,
                "Step".to_owned(),
                None,
            )?
            .id;
        assert!(
            !check_due(&storage, tid, &leaf)?,
            "the check budget is spent"
        );
        leaf = storage
            .append_node(
                tid.to_owned(),
                Some(leaf),
                NodeRole::User,
                "More".to_owned(),
                None,
            )?
            .id;
        leaf = storage
            .append_node(
                tid.to_owned(),
                Some(leaf),
                NodeRole::Assistant,
                "Step".to_owned(),
                None,
            )?
            .id;
        assert!(
            check_due(&storage, tid, &leaf)?,
            "a new message starts a new count"
        );
        Ok(())
    }

    #[test]
    fn the_goal_prompts_follow_the_prompt_rules() {
        assert_eq!(
            crate::test_support::prompt_rule_breaks(GOAL_CHECK_PROMPT),
            Vec::<String>::new()
        );
    }
}
