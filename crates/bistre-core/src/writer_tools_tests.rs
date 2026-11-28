//! The Writing Studio tools against a recording mock provider: what each sends, what comes
//! back, and that nothing is written to the chat.

use bistre_protocol::{
    StoryChapterRecord, StorySceneRecord, StoryThreadStateRecord, ThreadMode, ThreadPatch,
    UserPersonaRecord,
};

use crate::egress_tests::{chat_reply, local_chat};
use crate::test_support::MockServer;

type TestResult = Result<(), Box<dyn std::error::Error>>;

/// The system prompt and the last user message of a recorded chat request.
fn system_and_user(body: &serde_json::Value) -> (String, String) {
    let messages = body["messages"].as_array().cloned().unwrap_or_default();
    let text_of = |role: &str| {
        messages
            .iter()
            .rev()
            .find(|m| m["role"] == role)
            .and_then(|m| m["content"].as_str())
            .map_or_else(String::new, str::to_owned)
    };
    (text_of("system"), text_of("user"))
}

/// Shorten sends its instruction as the system prompt, the scene and excerpt as the message,
/// and returns the trimmed replacement; the chat gains no message.
#[tokio::test]
async fn a_rewrite_returns_the_replacement_and_saves_nothing() -> TestResult {
    let server = MockServer::start(vec![chat_reply("  She left.  ")]).await?;
    let chat = local_chat(&server).await?;
    let out = chat
        .engine
        .rewrite_passage(
            chat.thread_id.clone(),
            "shorten".to_owned(),
            "She opened the door slowly and walked out.".to_owned(),
            "The hallway was dark.".to_owned(),
        )
        .await?;
    assert_eq!(out, "She left.");
    assert_eq!(
        chat.engine.list_nodes(chat.thread_id.clone()).await?.len(),
        0,
        "a rewrite saves nothing to the chat"
    );
    let seen = server.finish().await;
    let (system, user) = system_and_user(&seen.first().ok_or("no request")?.body_json()?);
    assert!(
        system.starts_with("Shorten the highlighted excerpt."),
        "{system}"
    );
    assert!(user.contains("The hallway was dark."), "{user}");
    assert!(
        user.ends_with("She opened the door slowly and walked out."),
        "{user}"
    );
    Ok(())
}

/// The scene brief reads the chat's story memory beside the beats.
#[tokio::test]
async fn a_scene_brief_reads_the_beats_and_the_story_memory() -> TestResult {
    let server = MockServer::start(vec![chat_reply("1. Arc")]).await?;
    let chat = local_chat(&server).await?;
    chat.engine
        .save_story_thread_state(StoryThreadStateRecord {
            thread_id: chat.thread_id.clone(),
            story_memory: "Lyra is afraid of water.".to_owned(),
            ..StoryThreadStateRecord::default()
        })
        .await?;
    let brief = chat
        .engine
        .plan_scene(
            chat.thread_id.clone(),
            "The river".to_owned(),
            "Lyra must cross.".to_owned(),
        )
        .await?;
    assert_eq!(brief, "1. Arc");
    let seen = server.finish().await;
    let (system, user) = system_and_user(&seen.first().ok_or("no request")?.body_json()?);
    assert!(system.contains("writing brief"), "{system}");
    assert!(user.contains("Lyra is afraid of water."), "{user}");
    assert!(user.contains("Lyra must cross."), "{user}");
    Ok(())
}

/// The chapter summary reads the chapter's scenes in order and the earlier chapters' era
/// summaries, and splits off the contradictions.
#[tokio::test]
async fn a_chapter_summary_checks_earlier_chapters_and_lists_contradictions() -> TestResult {
    let server = MockServer::start(vec![chat_reply(
        "- Lyra crosses the river.\nContradictions:\n- Chapter 1 says she cannot swim.",
    )])
    .await?;
    let chat = local_chat(&server).await?;
    let first = chat
        .engine
        .upsert_story_chapter(StoryChapterRecord {
            thread_id: chat.thread_id.clone(),
            order_index: 1,
            title: "Shore".to_owned(),
            era_summary: "Lyra cannot swim.".to_owned(),
            ..StoryChapterRecord::default()
        })
        .await?;
    let second = chat
        .engine
        .upsert_story_chapter(StoryChapterRecord {
            thread_id: chat.thread_id.clone(),
            order_index: 2,
            title: "River".to_owned(),
            ..StoryChapterRecord::default()
        })
        .await?;
    for (order, prose) in [(2, "She reached the far bank."), (1, "Lyra swam.")] {
        chat.engine
            .upsert_story_scene(StorySceneRecord {
                chapter_id: second.id.clone(),
                order_index: order,
                title: format!("Scene {order}"),
                prose_text: prose.to_owned(),
                ..StorySceneRecord::default()
            })
            .await?;
    }
    let summary = chat
        .engine
        .summarize_chapter(chat.thread_id.clone(), second.id.clone())
        .await?;
    assert_eq!(summary.era_summary, "- Lyra crosses the river.");
    assert_eq!(
        summary.contradictions,
        vec!["Chapter 1 says she cannot swim.".to_owned()]
    );
    let seen = server.finish().await;
    let (_, user) = system_and_user(&seen.first().ok_or("no request")?.body_json()?);
    assert!(user.contains("Shore: Lyra cannot swim."), "{user}");
    let swam = user.find("Lyra swam.").ok_or("first scene missing")?;
    let bank = user
        .find("She reached the far bank.")
        .ok_or("second scene missing")?;
    assert!(swam < bank, "scenes are read in order: {user}");
    assert!(
        chat.engine
            .summarize_chapter(chat.thread_id.clone(), first.id)
            .await
            .is_err(),
        "a chapter with no prose has nothing to summarize"
    );
    Ok(())
}

/// Draft my reply in a story chat writes as the chat's persona.
#[tokio::test]
async fn a_drafted_reply_in_a_story_chat_writes_as_the_persona() -> TestResult {
    let server = MockServer::start(vec![chat_reply("I step forward.")]).await?;
    let chat = local_chat(&server).await?;
    chat.engine
        .update_thread(
            chat.thread_id.clone(),
            ThreadPatch {
                mode: Some(ThreadMode::Write),
                ..ThreadPatch::default()
            },
        )
        .await?;
    let persona = chat
        .engine
        .upsert_user_persona(UserPersonaRecord {
            name: "Kael".to_owned(),
            description: "a quiet ranger".to_owned(),
            ..UserPersonaRecord::default()
        })
        .await?;
    chat.engine
        .save_story_thread_state(StoryThreadStateRecord {
            thread_id: chat.thread_id.clone(),
            user_persona_id: Some(persona.id),
            ..StoryThreadStateRecord::default()
        })
        .await?;
    let draft = chat
        .engine
        .draft_next_message(chat.thread_id.clone(), String::new())
        .await?;
    assert_eq!(draft, "I step forward.");
    let seen = server.finish().await;
    let (_, user) = system_and_user(&seen.first().ok_or("no request")?.body_json()?);
    assert!(user.contains("Kael: a quiet ranger"), "{user}");
    Ok(())
}
