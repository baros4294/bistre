//! MCP tasks extension (`io.modelcontextprotocol/tasks`, checked against the extension's
//! `2026-07-28` schema). A modern server may answer `tools/call` with a task handle
//! (`resultType: "task"`, flat `taskId`, `status`, `pollIntervalMs`) instead of the result;
//! Bistre then polls `tasks/get` until the task ends and reads its `result` as the tool's
//! answer. Bistre answers no server requests, so a task that needs input fails closed like an
//! `input_required` result, and is cancelled.

use std::time::Duration;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey};
use serde_json::{Value, json};

use crate::mcp_era::complete_result;

/// The extension every modern request declares in `clientCapabilities.extensions`.
pub const TASKS_EXTENSION: &str = "io.modelcontextprotocol/tasks";
/// Longest Bistre follows one task before cancelling it.
pub const MAX_TASK_WAIT: Duration = Duration::from_mins(30);
/// Poll interval when the server suggests none.
const DEFAULT_POLL: Duration = Duration::from_secs(1);
/// Bounds on a server's `pollIntervalMs`, so a task is neither hammered nor forgotten.
const MIN_POLL: Duration = Duration::from_millis(250);
const MAX_POLL: Duration = Duration::from_secs(10);
/// Longest task id accepted from a server.
const MAX_TASK_ID_CHARS: usize = 256;

fn task_error(detail: &'static str) -> BistreError {
    BistreError::with_detail(DiagnosticKey::ProviderRequestFailed, detail)
}

/// How a `tools/call` was answered.
#[derive(Debug, PartialEq)]
pub enum CallAnswer<'a> {
    /// The tool's result.
    Result(&'a Value),
    /// A task to poll, first after `poll`.
    Task { task_id: String, poll: Duration },
}

/// Reads a `tools/call` response: the complete result, or a task handle.
pub fn read_call_answer(resp: &Value) -> BistreResult<CallAnswer<'_>> {
    let result = resp.get("result");
    if result
        .and_then(|r| r.get("resultType"))
        .and_then(Value::as_str)
        != Some("task")
    {
        return complete_result(resp).map(CallAnswer::Result);
    }
    let task = result.ok_or_else(|| task_error("mcp_no_result"))?;
    let task_id = task
        .get("taskId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.chars().count() <= MAX_TASK_ID_CHARS)
        .ok_or_else(|| task_error("mcp_task_id_invalid"))?;
    Ok(CallAnswer::Task {
        task_id: task_id.to_owned(),
        poll: poll_interval(task),
    })
}

fn poll_interval(task: &Value) -> Duration {
    task.get("pollIntervalMs")
        .and_then(Value::as_u64)
        .map_or(DEFAULT_POLL, |ms| {
            Duration::from_millis(ms).clamp(MIN_POLL, MAX_POLL)
        })
}

/// One `tasks/get` answer.
#[derive(Debug, PartialEq)]
enum TaskState {
    /// Finished: what `tools/call` would have returned.
    Done(Value),
    /// Still working: ask again after this long.
    Wait(Duration),
}

fn read_task_state(resp: &Value) -> BistreResult<TaskState> {
    let task = complete_result(resp)?;
    match task.get("status").and_then(Value::as_str) {
        Some("working") => Ok(TaskState::Wait(poll_interval(task))),
        Some("completed") => task
            .get("result")
            .filter(|r| r.is_object())
            .cloned()
            .map(TaskState::Done)
            .ok_or_else(|| task_error("mcp_task_no_result")),
        Some("failed") => match task.get("error") {
            Some(error) => crate::mcp::json_rpc_result(json!({ "error": error }))
                .and(Err(task_error("mcp_task_failed"))),
            None => Err(task_error("mcp_task_failed")),
        },
        Some("cancelled") => Err(task_error("mcp_task_cancelled")),
        Some("input_required") => Err(task_error("mcp_input_required")),
        _ => Err(task_error("mcp_task_status_unknown")),
    }
}

/// One request to the server that runs the task (`tasks/get`, `tasks/cancel`), on the
/// transport and session the call used.
pub trait TaskRpc {
    fn call(
        &mut self,
        method: &'static str,
        params: Value,
    ) -> impl Future<Output = BistreResult<Value>> + Send;
}

/// Follows `task_id` until it ends and returns its result. It polls at the server's interval
/// (clamped to 250 ms to 10 s) for at most `max_wait`; a task that needs input or outlives
/// `max_wait` is cancelled (best effort) and fails. A dropped future (a stopped run) stops
/// polling; the server's task then expires by its own TTL.
pub async fn await_task(
    rpc: &mut impl TaskRpc,
    task_id: &str,
    first_poll: Duration,
    max_wait: Duration,
) -> BistreResult<Value> {
    let deadline = tokio::time::Instant::now() + max_wait;
    let mut wait = first_poll;
    loop {
        if tokio::time::Instant::now() + wait > deadline {
            cancel(rpc, task_id).await;
            return Err(task_error("mcp_task_timeout"));
        }
        tokio::time::sleep(wait).await;
        let resp = rpc.call("tasks/get", json!({ "taskId": task_id })).await?;
        match read_task_state(&resp) {
            Ok(TaskState::Done(result)) => return Ok(result),
            Ok(TaskState::Wait(next)) => wait = next,
            Err(err) => {
                if err.detail_code.as_deref() == Some("mcp_input_required") {
                    cancel(rpc, task_id).await;
                }
                return Err(err);
            }
        }
    }
}

async fn cancel(rpc: &mut impl TaskRpc, task_id: &str) {
    if let Err(err) = rpc.call("tasks/cancel", json!({ "taskId": task_id })).await {
        tracing::debug!(key = err.key.as_key(), "mcp tasks/cancel not acknowledged");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    /// Answers each request with the next scripted `tasks/get` state, recording methods.
    struct Script {
        states: std::collections::VecDeque<Value>,
        methods: Vec<&'static str>,
    }

    impl TaskRpc for Script {
        fn call(
            &mut self,
            method: &'static str,
            _params: Value,
        ) -> impl Future<Output = BistreResult<Value>> + Send {
            self.methods.push(method);
            let answer = if method == "tasks/cancel" {
                Ok(json!({ "result": { "resultType": "complete" } }))
            } else {
                self.states
                    .pop_front()
                    .map(|state| json!({ "result": state }))
                    .ok_or_else(|| task_error("script_done"))
            };
            std::future::ready(answer)
        }
    }

    fn script(states: &[Value]) -> Script {
        Script {
            states: states.iter().cloned().collect(),
            methods: Vec::new(),
        }
    }

    fn state(status: &str) -> Value {
        json!({ "resultType": "complete", "taskId": "t1", "status": status, "pollIntervalMs": 1 })
    }

    #[test]
    fn a_task_handle_is_told_apart_from_a_result() -> TestResult {
        let plain = json!({ "result": { "content": [] } });
        assert!(matches!(read_call_answer(&plain)?, CallAnswer::Result(_)));
        let task = json!({ "result": { "resultType": "task", "taskId": "t1", "status": "working", "pollIntervalMs": 60000 } });
        assert_eq!(
            read_call_answer(&task)?,
            CallAnswer::Task {
                task_id: "t1".to_owned(),
                poll: MAX_POLL
            }
        );
        let no_id = json!({ "result": { "resultType": "task", "status": "working" } });
        assert_eq!(
            read_call_answer(&no_id)
                .err()
                .and_then(|e| e.detail_code)
                .as_deref(),
            Some("mcp_task_id_invalid")
        );
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn a_task_is_polled_until_it_completes() -> TestResult {
        let mut done = state("completed");
        done["result"] = json!({ "content": [{ "type": "text", "text": "built" }] });
        let mut rpc = script(&[state("working"), state("working"), done]);
        let result = await_task(&mut rpc, "t1", MIN_POLL, MAX_TASK_WAIT).await?;
        assert_eq!(result["content"][0]["text"], "built");
        assert_eq!(rpc.methods, ["tasks/get"; 3]);
        Ok(())
    }

    #[tokio::test(start_paused = true)]
    async fn a_task_that_fails_needs_input_or_runs_too_long_is_an_error() -> TestResult {
        let mut failed = state("failed");
        failed["error"] = json!({ "code": -32603, "message": "build broke" });
        let mut rpc = script(&[failed]);
        let err = await_task(&mut rpc, "t1", MIN_POLL, MAX_TASK_WAIT)
            .await
            .err();
        assert_eq!(
            err.and_then(|e| e.detail_code).as_deref(),
            Some("mcp_rpc_error_-32603;reason=build broke")
        );

        let mut rpc = script(&[state("input_required")]);
        let err = await_task(&mut rpc, "t1", MIN_POLL, MAX_TASK_WAIT)
            .await
            .err();
        assert_eq!(
            err.and_then(|e| e.detail_code).as_deref(),
            Some("mcp_input_required")
        );
        assert_eq!(
            rpc.methods,
            ["tasks/get", "tasks/cancel"],
            "input is never answered"
        );

        let mut rpc = script(&[state("working"), state("working")]);
        let err = await_task(&mut rpc, "t1", MIN_POLL, Duration::from_millis(600))
            .await
            .err();
        assert_eq!(
            err.and_then(|e| e.detail_code).as_deref(),
            Some("mcp_task_timeout")
        );
        assert_eq!(rpc.methods, ["tasks/get", "tasks/get", "tasks/cancel"]);
        Ok(())
    }
}
