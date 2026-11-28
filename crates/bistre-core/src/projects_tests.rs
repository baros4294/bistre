//! Projects: chats move out of a deleted project, and a chat in a project works in its folder
//! and sends its instructions.

use bistre_protocol::{ProjectRecord, ThreadMode};

use crate::egress_tests::{chat_reply, local_chat};
use crate::test_support::MockServer;

type TestResult = Result<(), Box<dyn std::error::Error>>;

/// Deleting a project keeps its chats (outside any project); the default workspace and a
/// blank name are refused.
#[tokio::test]
async fn deleting_a_project_keeps_its_chats() -> TestResult {
    let server = MockServer::start(Vec::new()).await?;
    let chat = local_chat(&server).await?;
    let project = chat
        .engine
        .save_project(ProjectRecord {
            name: "  Novel  ".to_owned(),
            ..ProjectRecord::default()
        })
        .await?;
    assert_eq!(project.name, "Novel");
    chat.engine
        .move_thread_to_project(chat.thread_id.clone(), Some(project.id.clone()))
        .await?;
    let moved = chat.engine.storage.get_thread(&chat.thread_id)?;
    assert_eq!(moved.map(|t| t.workspace_id), Some(project.id.clone()));
    chat.engine.delete_project(project.id.clone()).await?;
    assert_eq!(
        chat.engine.list_projects().await?,
        Vec::<ProjectRecord>::new()
    );
    let kept = chat
        .engine
        .storage
        .get_thread(&chat.thread_id)?
        .ok_or("the chat is gone")?;
    assert_eq!(kept.workspace_id, bistre_storage::DEFAULT_WORKSPACE_ID);
    assert!(
        chat.engine
            .delete_project(bistre_storage::DEFAULT_WORKSPACE_ID.to_owned())
            .await
            .is_err()
    );
    assert!(
        chat.engine
            .save_project(ProjectRecord {
                name: " ".to_owned(),
                ..ProjectRecord::default()
            })
            .await
            .is_err()
    );
    Ok(())
}

/// A chat in a project sends the project's instructions and its tools work in the project's
/// folder, not the app's open folder.
#[tokio::test]
async fn a_chat_in_a_project_sends_its_instructions_and_uses_its_folder() -> TestResult {
    let server = MockServer::start(vec![chat_reply("ok")]).await?;
    let chat = local_chat(&server).await?;
    let open = tempfile::tempdir()?;
    let folder = tempfile::tempdir()?;
    chat.engine
        .set_kv_meta(
            "agent.workspace_root".to_owned(),
            open.path().display().to_string(),
        )
        .await?;
    let project = chat
        .engine
        .save_project(ProjectRecord {
            name: "Docs".to_owned(),
            folder_path: folder.path().display().to_string(),
            instructions: "Answer in British English.".to_owned(),
            ..ProjectRecord::default()
        })
        .await?;
    chat.engine
        .move_thread_to_project(chat.thread_id.clone(), Some(project.id))
        .await?;
    let catalog = crate::agent_tools::resolve_active_tool_catalog(
        &chat.engine.storage,
        Some(&chat.thread_id),
        ThreadMode::Code,
    )?;
    assert_eq!(catalog.workspace_root.as_deref(), Some(folder.path()));
    let outside = crate::agent_tools::resolve_active_tool_catalog(
        &chat.engine.storage,
        None,
        ThreadMode::Code,
    )?;
    assert_eq!(outside.workspace_root.as_deref(), Some(open.path()));

    let mut rx = chat.engine.subscribe_events();
    chat.engine
        .send_and_stream_reply(chat.thread_id.clone(), None, "hi".to_owned())
        .await?;
    crate::egress_tests::diagnostics_until_finished(&mut rx, &chat.thread_id).await?;
    let seen = server.finish().await;
    // The body is JSON, so the line break reads as `\n` there.
    let body = String::from_utf8_lossy(&seen.first().ok_or("no request")?.body).into_owned();
    assert!(
        body.contains(r"[Project instructions]\nAnswer in British English."),
        "{body}"
    );

    // The context gauge counts the same block on its own row.
    let leaf = chat
        .engine
        .list_nodes(chat.thread_id.clone())
        .await?
        .last()
        .map(|n| n.id.clone())
        .ok_or("no reply")?;
    let breakdown = crate::context_breakdown::branch_context_breakdown(
        &chat.engine.storage,
        None,
        &chat.thread_id,
        &leaf,
        "",
        &|_| None,
    )?;
    assert_eq!(
        breakdown.tokens_of(crate::context_breakdown::ContextCategoryKind::ProjectInstructions),
        crate::compaction::estimate_tokens_for_model(
            "[Project instructions]\nAnswer in British English.",
            None
        )
    );
    Ok(())
}
