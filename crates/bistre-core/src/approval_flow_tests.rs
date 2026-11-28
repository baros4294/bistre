//! Regression tests for live tool approvals.
//!
//! Each test runs a real `InProcessEngine` against `test_support::MockServer` providers that
//! answer with scripted `OpenAI` Responses tool calls.

use std::path::{Path, PathBuf};
use std::time::Duration;

use bistre_protocol::{
    CronJobRecord, EngineEvent, ProviderDialect, ThreadMode, ThreadPatch, ToolApprovalDecision,
    UnattendedPolicy,
};
use tokio::sync::broadcast;

use crate::test_support::{MockServer, Scripted};

pub(crate) type TestResult = Result<(), Box<dyn std::error::Error>>;

/// Upper bound for any single wait on engine events.
const EVENT_WAIT: Duration = Duration::from_secs(15);

/// One `OpenAI` Responses turn that asks for a single `edit` call.
fn edit_call(call_id: &str, target: &str, replacement: &str) -> Scripted {
    let args = serde_json::json!({
        "path": "note.txt",
        "target": target,
        "replacement": replacement,
    })
    .to_string();
    let item = serde_json::json!({
        "type": "response.output_item.added",
        "item": {
            "id": format!("fc_{call_id}"),
            "type": "function_call",
            "call_id": call_id,
            "name": "edit",
            "arguments": args,
        }
    });
    Scripted::sse(format!(
        "data: {item}\n\ndata: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"resp_{call_id}\",\"usage\":{{\"input_tokens\":10,\"output_tokens\":5}}}}}}\n\n"
    ))
}

/// One `OpenAI` Responses turn that answers with plain text.
fn text_turn(text: &str) -> Scripted {
    let delta = serde_json::json!({ "type": "response.output_text.delta", "delta": text });
    Scripted::sse(format!(
        "data: {delta}\n\ndata: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"resp_text\",\"usage\":{{\"input_tokens\":10,\"output_tokens\":5}}}}}}\n\n"
    ))
}

struct Workspace {
    _dir: tempfile::TempDir,
    root: PathBuf,
    engine: std::sync::Arc<crate::InProcessEngine>,
}

impl Workspace {
    fn open() -> Result<Self, Box<dyn std::error::Error>> {
        let dir = tempfile::tempdir()?;
        let root = dir.path().join("workspace");
        std::fs::create_dir_all(&root)?;
        let engine = crate::InProcessEngine::open_for_test(
            dir.path(),
            crate::http_clients::provider_client()?,
        )?;
        Ok(Self {
            _dir: dir,
            root,
            engine,
        })
    }

    /// A code-mode thread whose workspace is `<root>/<name>` (holding `note.txt` = `hello`),
    /// pinned to its own provider at `server`.
    async fn thread(
        &self,
        name: &str,
        server: &MockServer,
    ) -> Result<(String, PathBuf), Box<dyn std::error::Error>> {
        let ws = self.root.join(name);
        std::fs::create_dir_all(&ws)?;
        std::fs::write(ws.join("note.txt"), "hello\n")?;
        let provider = self
            .engine
            .create_provider(
                format!("Mock {name}"),
                ProviderDialect::OpenAi,
                server.base().to_owned(),
                "gpt-test".to_owned(),
                "openai".to_owned(),
                String::new(),
                Some("sk-test-key".to_owned()),
            )
            .await?;
        let thread = self
            .engine
            .create_thread(None, name.to_owned(), ThreadMode::Code, None, None)
            .await?;
        self.engine
            .update_thread(
                thread.id.clone(),
                ThreadPatch {
                    provider_id_override: Some(Some(provider.id.clone())),
                    model_id_override: Some(Some("gpt-test".to_owned())),
                    ..ThreadPatch::default()
                },
            )
            .await?;
        Ok((thread.id, ws))
    }

    async fn set_workspace(&self, ws: &Path) -> TestResult {
        self.engine
            .set_kv_meta(
                "agent.workspace_root".to_owned(),
                ws.to_string_lossy().into_owned(),
            )
            .await?;
        Ok(())
    }
}

/// A pending approval as announced by the engine.
struct Request {
    thread: String,
    run: String,
    call: String,
}

/// Waits for the next approval request of `thread_id`; `None` if the run finished first.
async fn next_request(
    rx: &mut broadcast::Receiver<EngineEvent>,
    thread_id: &str,
) -> Result<Option<Request>, Box<dyn std::error::Error>> {
    let deadline = tokio::time::Instant::now() + EVENT_WAIT;
    loop {
        let event = tokio::time::timeout_at(deadline, rx.recv()).await??;
        match event {
            EngineEvent::ToolApprovalRequested {
                thread_id: t,
                run_id,
                call_id,
                ..
            } if t == thread_id => {
                return Ok(Some(Request {
                    thread: t,
                    run: run_id,
                    call: call_id,
                }));
            }
            EngineEvent::RunFinished { thread_id: t, .. } if t == thread_id => return Ok(None),
            _ => {}
        }
    }
}

/// Waits until the run of `thread_id` finishes and returns how many approvals it asked for.
async fn finish(
    rx: &mut broadcast::Receiver<EngineEvent>,
    thread_id: &str,
) -> Result<usize, Box<dyn std::error::Error>> {
    let mut asked = 0;
    while next_request(rx, thread_id).await?.is_some() {
        asked += 1;
    }
    Ok(asked)
}

async fn respond(
    ws: &Workspace,
    req: &Request,
    decision: ToolApprovalDecision,
) -> Result<bool, Box<dyn std::error::Error>> {
    Ok(ws
        .engine
        .respond_tool_approval(
            req.thread.clone(),
            req.run.clone(),
            req.call.clone(),
            decision,
        )
        .await?)
}

/// Two chats paused on the same provider call id. Approving chat A releases only chat A.
#[tokio::test]
async fn approving_one_chat_never_releases_another_chat_with_the_same_call_id() -> TestResult {
    let ws = Workspace::open()?;
    let server_a = MockServer::start(vec![
        edit_call("call_0", "hello", "from-a"),
        text_turn("done a"),
    ])
    .await?;
    let server_b = MockServer::start(vec![
        edit_call("call_0", "hello", "from-b"),
        text_turn("done b"),
    ])
    .await?;
    let (thread_a, dir_a) = ws.thread("a", &server_a).await?;
    let (thread_b, dir_b) = ws.thread("b", &server_b).await?;
    let mut rx = ws.engine.subscribe_events();

    ws.set_workspace(&dir_a).await?;
    ws.engine
        .send_and_stream_reply(thread_a.clone(), None, "edit a".to_owned())
        .await?;
    let req_a = next_request(&mut rx, &thread_a)
        .await?
        .ok_or("a never asked")?;
    ws.set_workspace(&dir_b).await?;
    ws.engine
        .send_and_stream_reply(thread_b.clone(), None, "edit b".to_owned())
        .await?;
    let req_b = next_request(&mut rx, &thread_b)
        .await?
        .ok_or("b never asked")?;
    assert_eq!(req_a.call, req_b.call, "both chats wait on call_0");

    // The broker checks permits against the active workspace, so approve A with A's root.
    ws.set_workspace(&dir_a).await?;
    assert!(respond(&ws, &req_a, ToolApprovalDecision::ApproveOnce).await?);
    assert_eq!(finish(&mut rx, &thread_a).await?, 0);
    assert_eq!(std::fs::read_to_string(dir_a.join("note.txt"))?, "from-a\n");
    assert_eq!(
        std::fs::read_to_string(dir_b.join("note.txt"))?,
        "hello\n",
        "chat B's call must still be waiting, untouched"
    );

    assert!(
        respond(&ws, &req_b, ToolApprovalDecision::Deny).await?,
        "chat B's waiter must still exist"
    );
    assert_eq!(finish(&mut rx, &thread_b).await?, 0);
    assert_eq!(std::fs::read_to_string(dir_b.join("note.txt"))?, "hello\n");
    drop((server_a.finish().await, server_b.finish().await));
    Ok(())
}

/// "Approve for this chat" covers the exact call only; other arguments ask again.
#[tokio::test]
async fn approve_for_chat_covers_the_exact_call_only() -> TestResult {
    let ws = Workspace::open()?;
    let server = MockServer::start(vec![
        edit_call("call_1", "hello", "hi"),
        edit_call("call_2", "hi", "bye"),
        text_turn("done"),
    ])
    .await?;
    let (thread, dir) = ws.thread("chat", &server).await?;
    ws.set_workspace(&dir).await?;
    let mut rx = ws.engine.subscribe_events();
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "edit twice".to_owned())
        .await?;

    let first = next_request(&mut rx, &thread)
        .await?
        .ok_or("first never asked")?;
    assert!(respond(&ws, &first, ToolApprovalDecision::ApproveForThread).await?);
    let second = next_request(&mut rx, &thread)
        .await?
        .ok_or("an edit with different arguments must ask again")?;
    assert!(respond(&ws, &second, ToolApprovalDecision::Deny).await?);
    assert_eq!(finish(&mut rx, &thread).await?, 0);
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hi\n");
    drop(server.finish().await);
    Ok(())
}

/// A denied call is not asked again in the same run.
#[tokio::test]
async fn a_denied_call_is_not_asked_again_in_the_same_run() -> TestResult {
    let ws = Workspace::open()?;
    let server = MockServer::start(vec![
        edit_call("call_1", "hello", "hi"),
        edit_call("call_2", "hello", "hi"),
        text_turn("ok, leaving it"),
    ])
    .await?;
    let (thread, dir) = ws.thread("chat", &server).await?;
    ws.set_workspace(&dir).await?;
    let mut rx = ws.engine.subscribe_events();
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "edit".to_owned())
        .await?;

    let first = next_request(&mut rx, &thread).await?.ok_or("never asked")?;
    assert!(respond(&ws, &first, ToolApprovalDecision::Deny).await?);
    assert_eq!(
        finish(&mut rx, &thread).await?,
        0,
        "the identical retry must be refused without a second prompt"
    );
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hello\n");
    let seen = server.finish().await;
    assert_eq!(seen.len(), 3, "the model still gets its answer and replies");
    let replay = String::from_utf8_lossy(&seen[2].body).into_owned();
    assert!(replay.contains("already denied"), "{replay}");
    Ok(())
}

/// Stop refuses the call and ends the run; nothing more is sent to the provider.
#[tokio::test]
async fn stop_ends_the_run_without_another_request() -> TestResult {
    let ws = Workspace::open()?;
    let server = MockServer::start(vec![
        edit_call("call_1", "hello", "hi"),
        text_turn("should never be requested"),
    ])
    .await?;
    let (thread, dir) = ws.thread("chat", &server).await?;
    ws.set_workspace(&dir).await?;
    let mut rx = ws.engine.subscribe_events();
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "edit".to_owned())
        .await?;

    let req = next_request(&mut rx, &thread).await?.ok_or("never asked")?;
    assert!(respond(&ws, &req, ToolApprovalDecision::Stop).await?);
    assert_eq!(finish(&mut rx, &thread).await?, 0);
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hello\n");
    assert_eq!(
        server.finish().await.len(),
        1,
        "Stop must not start another turn"
    );
    Ok(())
}

/// An approval waits as long as the user needs (a virtual day here), never
/// auto-denies, and costs no polling; cancel still ends it at once.
#[tokio::test(start_paused = true)]
async fn an_approval_waits_without_a_time_limit_and_ends_on_cancel() {
    use std::sync::atomic::{AtomicBool, Ordering};

    use crate::agent_tools::wait_for_decision;

    let cancel = AtomicBool::new(false);
    let wake = tokio::sync::Notify::new();
    let (tx, rx) = tokio::sync::oneshot::channel();
    let wait = wait_for_decision(rx, &cancel, &wake);
    tokio::pin!(wait);
    assert!(
        tokio::time::timeout(Duration::from_hours(24), &mut wait)
            .await
            .is_err(),
        "still waiting after a day"
    );
    assert!(tx.send(ToolApprovalDecision::ApproveOnce).is_ok());
    assert_eq!(wait.await, (ToolApprovalDecision::ApproveOnce, false));

    let (_tx, rx) = tokio::sync::oneshot::channel();
    let wait = wait_for_decision(rx, &cancel, &wake);
    tokio::pin!(wait);
    assert!(
        tokio::time::timeout(Duration::from_secs(60), &mut wait)
            .await
            .is_err()
    );
    cancel.store(true, Ordering::SeqCst);
    wake.notify_one();
    assert_eq!(wait.await, (ToolApprovalDecision::Deny, true));
}

/// While a run waits for the user, its keep-awake lease is given back, then taken again.
#[test]
fn waiting_for_the_user_releases_keep_awake() {
    use std::sync::Arc;

    use crate::power::{NoopPowerGuardBackend, PowerCoordinator};

    let power = PowerCoordinator::new(Arc::new(NoopPowerGuardBackend));
    let lease = power.acquire_run_lease("run");
    assert_eq!(power.status().active_run_count, 1);
    {
        let _paused = power.pause_for_user();
        assert_eq!(power.status().active_run_count, 0);
    }
    assert_eq!(power.status().active_run_count, 1);
    drop(lease);
    assert_eq!(power.status().active_run_count, 0);
}

/// A raw `edit` call whose arguments are exactly `arguments_json`.
fn raw_edit_call(call_id: &str, arguments_json: &str) -> Scripted {
    let item = serde_json::json!({
        "type": "response.output_item.added",
        "item": {
            "id": format!("fc_{call_id}"),
            "type": "function_call",
            "call_id": call_id,
            "name": "edit",
            "arguments": arguments_json,
        }
    });
    Scripted::sse(format!(
        "data: {item}\n\ndata: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"resp_{call_id}\",\"usage\":{{\"input_tokens\":10,\"output_tokens\":5}}}}}}\n\n"
    ))
}

/// An unreadable tool-permission map blocks every tool except Tier-0 reads, without
/// even asking (a user's "Off" must never silently turn back on).
#[tokio::test]
async fn an_unreadable_permission_map_blocks_everything_but_reads() -> TestResult {
    let ws = Workspace::open()?;
    let server = MockServer::start(vec![
        edit_call("call_1", "hello", "hi"),
        text_turn("blocked"),
    ])
    .await?;
    let (thread, dir) = ws.thread("chat", &server).await?;
    ws.set_workspace(&dir).await?;
    ws.engine
        .set_kv_meta("agent.tool_permissions".to_owned(), "{not json".to_owned())
        .await?;
    let mut rx = ws.engine.subscribe_events();
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "edit".to_owned())
        .await?;
    assert_eq!(
        finish(&mut rx, &thread).await?,
        0,
        "no approval is even offered"
    );
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hello\n");
    let seen = server.finish().await;
    let replay = String::from_utf8_lossy(&seen[1].body).into_owned();
    assert!(replay.contains("blocked by security policy"), "{replay}");
    Ok(())
}

/// Tool arguments that are not valid JSON become an error result with no permit,
/// never an empty `{}` call.
#[tokio::test]
async fn malformed_tool_arguments_are_an_error_not_an_empty_call() -> TestResult {
    let ws = Workspace::open()?;
    let server = MockServer::start(vec![
        raw_edit_call("call_1", r#"{"path":"note.txt","target":"hel"#),
        text_turn("sorry"),
    ])
    .await?;
    let (thread, dir) = ws.thread("chat", &server).await?;
    ws.set_workspace(&dir).await?;
    let mut rx = ws.engine.subscribe_events();
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "edit".to_owned())
        .await?;
    assert_eq!(finish(&mut rx, &thread).await?, 0, "nothing to approve");
    let seen = server.finish().await;
    let replay = String::from_utf8_lossy(&seen[1].body).into_owned();
    assert!(replay.contains("not valid JSON"), "{replay}");
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hello\n");
    Ok(())
}

/// Workspace hooks never run until the user approves this exact file, and a pre-tool
/// hook that is unapproved or fails blocks the call.
#[tokio::test]
async fn pre_tool_hooks_need_approval_and_a_failing_one_blocks_the_call() -> TestResult {
    let ws = Workspace::open()?;
    let server = MockServer::start(vec![
        edit_call("call_1", "hello", "one"),
        text_turn("blocked: unapproved"),
        edit_call("call_2", "hello", "two"),
        text_turn("blocked: hook failed"),
    ])
    .await?;
    let (thread, dir) = ws.thread("chat", &server).await?;
    ws.set_workspace(&dir).await?;
    std::fs::create_dir_all(dir.join(".bistre"))?;
    std::fs::write(
        dir.join(".bistre").join("hooks.json"),
        r#"[{"event":"pre_tool_use","tool_filter":"edit","command":"exit 3"}]"#,
    )?;
    let root = dir.to_string_lossy().into_owned();
    let mut rx = ws.engine.subscribe_events();

    ws.engine
        .send_and_stream_reply(thread.clone(), None, "edit".to_owned())
        .await?;
    let req = next_request(&mut rx, &thread).await?.ok_or("never asked")?;
    assert!(respond(&ws, &req, ToolApprovalDecision::ApproveOnce).await?);
    assert_eq!(finish(&mut rx, &thread).await?, 0);
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hello\n");

    let status = ws
        .engine
        .workspace_hooks_status(root.clone())
        .await?
        .ok_or("hooks file present")?;
    assert!(!status.approved);
    ws.engine
        .approve_workspace_hooks(root.clone(), status.digest)
        .await?;
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "edit again".to_owned())
        .await?;
    let req = next_request(&mut rx, &thread).await?.ok_or("never asked")?;
    assert!(respond(&ws, &req, ToolApprovalDecision::ApproveOnce).await?);
    assert_eq!(finish(&mut rx, &thread).await?, 0);
    assert_eq!(
        std::fs::read_to_string(dir.join("note.txt"))?,
        "hello\n",
        "a failing pre-tool hook blocks the call"
    );
    let seen = server.finish().await;
    let first = String::from_utf8_lossy(&seen[1].body).into_owned();
    let second = String::from_utf8_lossy(&seen[3].body).into_owned();
    assert!(first.contains("not approved yet"), "{first}");
    assert!(second.contains("failed (exit 3)"), "{second}");
    Ok(())
}

/// opencode #65442: read-only Plan mode is enforced where tools run, for every tool (shell and
/// MCP included), not only by hiding write tools: a write the model calls anyway is refused
/// without asking.
#[tokio::test]
async fn plan_mode_refuses_every_write_even_when_the_model_calls_one() -> TestResult {
    let ws = Workspace::open()?;
    let server = MockServer::start(vec![
        edit_call("call_1", "hello", "hi"),
        text_turn("refused"),
    ])
    .await?;
    let (thread, dir) = ws.thread("plan", &server).await?;
    ws.set_workspace(&dir).await?;
    ws.engine
        .update_thread(
            thread.clone(),
            ThreadPatch {
                mode: Some(ThreadMode::Plan),
                ..ThreadPatch::default()
            },
        )
        .await?;
    ws.engine
        .set_kv_meta(
            "agent.tool_permissions".to_owned(),
            r#"{"edit":"auto"}"#.to_owned(),
        )
        .await?;
    let mut rx = ws.engine.subscribe_events();
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "edit".to_owned())
        .await?;
    assert_eq!(finish(&mut rx, &thread).await?, 0, "no approval is offered");
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hello\n");
    let seen = server.finish().await;
    let replay = String::from_utf8_lossy(&seen[1].body).into_owned();
    assert!(replay.contains("read-only"), "{replay}");
    Ok(())
}

/// Deleting a file asks every time, even with Edit files set to Allow; editing does not.
#[tokio::test]
async fn deleting_a_file_asks_even_when_edits_are_allowed() -> TestResult {
    let ws = Workspace::open()?;
    let delete = serde_json::json!({
        "type": "response.output_item.added",
        "item": {
            "id": "fc_call_2",
            "type": "function_call",
            "call_id": "call_2",
            "name": "fs_delete",
            "arguments": serde_json::json!({ "path": "note.txt" }).to_string(),
        }
    });
    let server = MockServer::start(vec![
        edit_call("call_1", "hello", "hi"),
        Scripted::sse(format!(
            "data: {delete}\n\ndata: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"resp_call_2\",\"usage\":{{\"input_tokens\":10,\"output_tokens\":5}}}}}}\n\n"
        )),
        text_turn("kept"),
    ])
    .await?;
    let (thread, dir) = ws.thread("delete", &server).await?;
    ws.set_workspace(&dir).await?;
    ws.engine
        .set_kv_meta(
            "agent.tool_permissions".to_owned(),
            r#"{"edit_file":"allow"}"#.to_owned(),
        )
        .await?;
    let mut rx = ws.engine.subscribe_events();
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "tidy up".to_owned())
        .await?;
    let req = next_request(&mut rx, &thread)
        .await?
        .ok_or("the delete was never offered for approval")?;
    assert_eq!(req.call, "call_2", "the edit ran without asking");
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hi\n");
    respond(&ws, &req, ToolApprovalDecision::Deny).await?;
    assert_eq!(finish(&mut rx, &thread).await?, 0);
    assert!(dir.join("note.txt").exists());
    drop(server.finish().await);
    Ok(())
}

/// One `OpenAI` Responses turn that asks for a single call of `name`.
fn tool_turn(call_id: &str, name: &str, args: &serde_json::Value) -> Scripted {
    let item = serde_json::json!({
        "type": "response.output_item.added",
        "item": {
            "id": format!("fc_{call_id}"),
            "type": "function_call",
            "call_id": call_id,
            "name": name,
            "arguments": args.to_string(),
        }
    });
    Scripted::sse(format!(
        "data: {item}\n\ndata: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"resp_{call_id}\",\"usage\":{{\"input_tokens\":10,\"output_tokens\":5}}}}}}\n\n"
    ))
}

/// A helper reads the workspace with read tools only, and the run gets its summary back.
#[tokio::test]
async fn a_helper_reads_with_read_tools_only_and_reports_back() -> TestResult {
    let ws = Workspace::open()?;
    let server = MockServer::start(vec![
        tool_turn(
            "call_1",
            "agent_delegate",
            &serde_json::json!({ "tasks": ["what does note.txt say?"] }),
        ),
        tool_turn("h_1", "read", &serde_json::json!({ "path": "note.txt" })),
        text_turn("note.txt says hello"),
        text_turn("done"),
    ])
    .await?;
    let (thread, dir) = ws.thread("delegate", &server).await?;
    ws.set_workspace(&dir).await?;
    ws.engine
        .set_kv_meta(
            "agent.tool_permissions".to_owned(),
            r#"{"agent_delegate":"allow","edit_file":"allow"}"#.to_owned(),
        )
        .await?;
    let mut rx = ws.engine.subscribe_events();
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "look around".to_owned())
        .await?;
    assert_eq!(finish(&mut rx, &thread).await?, 0);
    let requests = server.finish().await;
    assert_eq!(requests.len(), 4);
    let tool_names = |i: usize| -> Result<Vec<String>, Box<dyn std::error::Error>> {
        let body = requests.get(i).ok_or("missing request")?.body_json()?;
        Ok(body
            .get("tools")
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|t| t.get("name").and_then(serde_json::Value::as_str))
            .map(str::to_owned)
            .collect())
    };
    assert!(tool_names(0)?.contains(&"agent_delegate".to_owned()));
    let mut helper_tools = tool_names(1)?;
    helper_tools.sort();
    assert_eq!(helper_tools, ["fs_list", "glob", "grep", "read"]);
    let helper_answer = requests
        .get(2)
        .ok_or("missing request")?
        .body_json()?
        .to_string();
    assert!(
        helper_answer.contains("hello"),
        "the helper never saw the file"
    );
    let parent_follow_up = requests
        .get(3)
        .ok_or("missing request")?
        .body_json()?
        .to_string();
    assert!(parent_follow_up.contains("note.txt says hello"));
    Ok(())
}

/// `ask_user` ends the run without another request, skips the calls after it, and the user's
/// next message reaches the model as the answer.
#[tokio::test]
async fn asking_the_user_ends_the_run_and_the_next_message_answers() -> TestResult {
    let ws = Workspace::open()?;
    let ask = serde_json::json!({
        "type": "response.output_item.added",
        "item": {
            "id": "fc_ask",
            "type": "function_call",
            "call_id": "ask",
            "name": "ask_user",
            "arguments": serde_json::json!({
                "question": "Which file?",
                "options": ["note.txt", "other.txt"],
            })
            .to_string(),
        }
    });
    let read = serde_json::json!({
        "type": "response.output_item.added",
        "item": {
            "id": "fc_read",
            "type": "function_call",
            "call_id": "read",
            "name": "read",
            "arguments": serde_json::json!({ "path": "note.txt" }).to_string(),
        }
    });
    let server = MockServer::start(vec![
        Scripted::sse(format!(
            "data: {ask}\n\ndata: {read}\n\ndata: {{\"type\":\"response.completed\",\"response\":{{\"id\":\"resp_ask\",\"usage\":{{\"input_tokens\":10,\"output_tokens\":5}}}}}}\n\n"
        )),
        text_turn("thanks"),
    ])
    .await?;
    let (thread, dir) = ws.thread("ask", &server).await?;
    ws.set_workspace(&dir).await?;
    let mut rx = ws.engine.subscribe_events();
    ws.engine
        .send_and_stream_reply(thread.clone(), None, "fix it".to_owned())
        .await?;
    assert_eq!(
        finish(&mut rx, &thread).await?,
        0,
        "asking needs no approval"
    );
    let nodes = ws.engine.list_nodes(thread.clone()).await?;
    let tool_texts: Vec<&str> = nodes
        .iter()
        .filter(|n| n.role == bistre_protocol::NodeRole::Tool)
        .map(|n| n.content.as_str())
        .collect();
    assert_eq!(tool_texts.len(), 2);
    assert_eq!(
        tool_texts.first().copied(),
        Some(crate::utility_tools::ASK_USER_RESULT)
    );
    assert!(tool_texts.get(1).is_some_and(|t| t.starts_with("Not run")));
    let leaf = nodes.last().map(|n| n.id.clone());
    ws.engine
        .send_and_stream_reply(thread.clone(), leaf, "note.txt".to_owned())
        .await?;
    finish(&mut rx, &thread).await?;
    let requests = server.finish().await;
    assert_eq!(
        requests.len(),
        2,
        "the run asked the model again before the answer"
    );
    let answer = requests
        .get(1)
        .ok_or("missing request")?
        .body_json()?
        .to_string();
    assert!(
        answer.contains(crate::utility_tools::ASK_USER_RESULT),
        "{answer}"
    );
    assert!(answer.contains("note.txt"));
    Ok(())
}

/// A job that runs in the code workspace under `policy`, sending one edit request.
fn scheduled_job(policy: UnattendedPolicy, use_worktree: bool) -> CronJobRecord {
    CronJobRecord {
        id: "job".to_owned(),
        name: "Nightly fix".to_owned(),
        workspace_id: "default".to_owned(),
        assistant_id: String::new(),
        schedule_expr: "every 1d".to_owned(),
        prompt: "edit the note".to_owned(),
        mode: ThreadMode::Code,
        unattended_policy: policy,
        use_worktree,
        enabled: true,
        next_run_ms: 0,
        last_run_id: None,
        last_status: "triggered".to_owned(),
    }
}

/// Skip & continue: a scheduled run refuses a call that needs approval, never asks, and the
/// model hears why and answers.
#[tokio::test]
async fn a_scheduled_run_under_skip_refuses_approvals_and_goes_on() -> TestResult {
    let ws = Workspace::open()?;
    let server = MockServer::start(vec![
        edit_call("call_1", "hello", "hi"),
        text_turn("left it"),
    ])
    .await?;
    let (_, dir) = ws.thread("skip", &server).await?;
    ws.set_workspace(&dir).await?;
    let mut rx = ws.engine.subscribe_events();
    let job = scheduled_job(UnattendedPolicy::DenyTier2AndContinue, false);
    let thread = ws.engine.start_scheduled_run(job).await?;
    assert_eq!(
        finish(&mut rx, &thread).await?,
        0,
        "nothing waits for the user"
    );
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hello\n");
    let seen = server.finish().await;
    assert_eq!(seen.len(), 2);
    let replay = String::from_utf8_lossy(&seen[1].body).into_owned();
    assert!(
        replay.contains("skips actions that need approval"),
        "{replay}"
    );
    Ok(())
}

/// Sandbox auto: a scheduled run with its own worktree edits the worktree copy without asking,
/// and the folder the app has open stays as it was.
#[tokio::test]
async fn a_scheduled_sandbox_run_edits_its_worktree_without_asking() -> TestResult {
    let ws = Workspace::open()?;
    let server =
        MockServer::start(vec![edit_call("call_1", "hello", "hi"), text_turn("done")]).await?;
    let (_, dir) = ws.thread("sandbox", &server).await?;
    ws.set_workspace(&dir).await?;
    let mut rx = ws.engine.subscribe_events();
    let job = scheduled_job(UnattendedPolicy::SandboxWorktreeAuto, true);
    let thread = ws.engine.start_scheduled_run(job).await?;
    assert_eq!(
        finish(&mut rx, &thread).await?,
        0,
        "the worktree edit needs no approval"
    );
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hello\n");
    let runs = ws
        .engine
        .list_agent_runs(Some(thread.clone()), false, 10)
        .await?;
    let worktree = runs
        .first()
        .and_then(|r| r.worktree_path.clone())
        .ok_or("the run records its worktree")?;
    assert!(worktree.contains("scheduled_worktrees"), "{worktree}");
    assert_eq!(
        std::fs::read_to_string(Path::new(&worktree).join("note.txt"))?,
        "hi\n"
    );
    drop(server.finish().await);
    Ok(())
}

/// Sandbox auto without a worktree is not a sandbox: the edit waits for the user (fail closed).
#[tokio::test]
async fn sandbox_auto_without_a_worktree_waits_for_the_user() -> TestResult {
    let ws = Workspace::open()?;
    let server =
        MockServer::start(vec![edit_call("call_1", "hello", "hi"), text_turn("ok")]).await?;
    let (_, dir) = ws.thread("no_tree", &server).await?;
    ws.set_workspace(&dir).await?;
    let mut rx = ws.engine.subscribe_events();
    let job = scheduled_job(UnattendedPolicy::SandboxWorktreeAuto, false);
    let thread = ws.engine.start_scheduled_run(job).await?;
    let asked = next_request(&mut rx, &thread).await?.ok_or("never asked")?;
    assert!(respond(&ws, &asked, ToolApprovalDecision::Deny).await?);
    finish(&mut rx, &thread).await?;
    assert_eq!(std::fs::read_to_string(dir.join("note.txt"))?, "hello\n");
    drop(server.finish().await);
    Ok(())
}
