//! Chat action FFI entrypoints: leaving messages out of the context, edited reply versions, side
//! questions, summary-and-resume, the chat goal, and a reply's raw request.

use super::{current_engine, frb, map_node, map_thread, FfiNodeRecord, FfiThreadSummary};

/// A chat's goal.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiThreadGoal {
    pub objective: String,
    pub completed: bool,
    pub summary: String,
}

fn map_goal(goal: Option<bistre_core::goal::ThreadGoal>) -> Option<FfiThreadGoal> {
    goal.map(|g| FfiThreadGoal {
        objective: g.objective,
        completed: g.completed,
        summary: g.summary,
    })
}

/// A recent reply's raw request body and response stream (kept in memory only).
#[frb]
#[derive(Debug, Clone)]
pub struct FfiRawExchange {
    pub url: String,
    pub request_body: String,
    pub response: String,
    pub truncated: bool,
}

/// Leaves a message out of the chat's context, or brings it back; returns the left-out ids.
#[frb]
pub async fn set_node_excluded(
    thread_id: String,
    node_id: String,
    excluded: bool,
) -> Result<Vec<String>, String> {
    current_engine()?
        .set_node_excluded(thread_id, node_id, excluded)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// The ids of the chat's left-out messages.
#[frb]
pub async fn list_excluded_nodes(thread_id: String) -> Result<Vec<String>, String> {
    current_engine()?
        .list_excluded_nodes(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Saves edited text as a new version of a reply.
#[frb]
pub async fn edit_reply(
    thread_id: String,
    node_id: String,
    content: String,
) -> Result<FfiNodeRecord, String> {
    current_engine()?
        .edit_reply(thread_id, node_id, content)
        .await
        .map(map_node)
        .map_err(crate::dto_mapping::ffi_err)
}

/// Answers a question about the chat without adding it to the chat.
#[frb]
pub async fn ask_side_question(thread_id: String, question: String) -> Result<String, String> {
    current_engine()?
        .ask_side_question(thread_id, question)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Opens a new chat that starts from a summary of this one.
#[frb]
pub async fn summarize_into_new_chat(thread_id: String) -> Result<FfiThreadSummary, String> {
    current_engine()?
        .summarize_into_new_chat(thread_id)
        .await
        .map(map_thread)
        .map_err(crate::dto_mapping::ffi_err)
}

/// The chat's goal, if one is set.
#[frb]
pub async fn get_thread_goal(thread_id: String) -> Result<Option<FfiThreadGoal>, String> {
    current_engine()?
        .get_thread_goal(thread_id)
        .await
        .map(map_goal)
        .map_err(crate::dto_mapping::ffi_err)
}

/// Sets a new open goal for the chat; blank text clears it.
#[frb]
pub async fn set_thread_goal(
    thread_id: String,
    objective: String,
) -> Result<Option<FfiThreadGoal>, String> {
    current_engine()?
        .set_thread_goal(thread_id, objective)
        .await
        .map(map_goal)
        .map_err(crate::dto_mapping::ffi_err)
}

/// The raw request and response of a recent reply, by its `request_id` metadata.
#[frb]
pub async fn raw_exchange(request_id: String) -> Result<Option<FfiRawExchange>, String> {
    let raw = current_engine()?
        .raw_exchange(request_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(raw.map(|r| FfiRawExchange {
        url: r.url,
        request_body: r.request_body,
        response: r.response,
        truncated: r.truncated,
    }))
}
