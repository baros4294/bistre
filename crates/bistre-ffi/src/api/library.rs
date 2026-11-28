//! FFI entrypoints for a chat's files, Bistre's own skills, a drafted message, a guided
//! Regenerate, the chats zip, a PNG character card, and erasing the data folder.

use super::{current_engine, frb};
use crate::dto_mapping::ffi_err;

/// One file of a chat and the message it came with.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiChatFile {
    pub node_id: String,
    pub from_user: bool,
    pub name: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub blob_rel_path: String,
    pub created_at_ms: i64,
}

/// A skill: its name and description from `SKILL.md` and that file's path.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiSkill {
    pub name: String,
    pub description: String,
    pub path: String,
}

fn map_skill(s: bistre_core::skills::SkillIndexEntry) -> FfiSkill {
    FfiSkill {
        name: s.name,
        description: s.description,
        path: s.path,
    }
}

/// Every file of the chat, newest first.
#[frb]
pub async fn list_chat_files(thread_id: String) -> Result<Vec<FfiChatFile>, String> {
    let files = current_engine()?
        .list_chat_files(thread_id)
        .await
        .map_err(ffi_err)?;
    Ok(files
        .into_iter()
        .map(|f| FfiChatFile {
            node_id: f.node_id,
            from_user: f.from_user,
            name: f.name,
            mime_type: f.mime_type,
            size_bytes: f.size_bytes,
            blob_rel_path: f.blob_rel_path,
            created_at_ms: f.created_at_ms,
        })
        .collect())
}

/// Bistre's own skills.
#[frb]
pub async fn list_app_skills() -> Result<Vec<FfiSkill>, String> {
    let skills = current_engine()?.list_app_skills().await.map_err(ffi_err)?;
    Ok(skills.into_iter().map(map_skill).collect())
}

/// Installs a skill from a GitHub link or a folder, `SKILL.md`, or zip path.
#[frb]
pub async fn install_skill(source: String) -> Result<FfiSkill, String> {
    current_engine()?
        .install_skill(source)
        .await
        .map(map_skill)
        .map_err(ffi_err)
}

/// Saves a reply as a new skill named by its chat.
#[frb]
pub async fn save_reply_as_skill(thread_id: String, node_id: String) -> Result<FfiSkill, String> {
    current_engine()?
        .save_reply_as_skill(thread_id, node_id)
        .await
        .map(map_skill)
        .map_err(ffi_err)
}

#[frb]
pub async fn remove_app_skill(skill_path: String) -> Result<(), String> {
    current_engine()?
        .remove_app_skill(skill_path)
        .await
        .map_err(ffi_err)
}

/// Drafts the user's next message, following `note` when given; nothing is saved.
#[frb]
pub async fn draft_next_message(thread_id: String, note: String) -> Result<String, String> {
    current_engine()?
        .draft_next_message(thread_id, note)
        .await
        .map_err(ffi_err)
}

/// Regenerate whose reply follows `guidance`.
#[frb]
pub async fn regenerate_reply_guided(
    thread_id: String,
    user_node_id: String,
    guidance: String,
) -> Result<String, String> {
    current_engine()?
        .regenerate_reply_guided(thread_id, user_node_id, guidance)
        .await
        .map_err(ffi_err)
}

/// Writes every chat with its files to a zip; returns the files written.
#[frb]
pub async fn export_chats_zip(dest_path: String) -> Result<u32, String> {
    current_engine()?
        .export_chats_zip(dest_path)
        .await
        .map_err(ffi_err)
}

/// Imports the chats and files of a chats zip; returns the chats imported.
#[frb]
pub async fn import_chats_zip(src_path: String) -> Result<u32, String> {
    current_engine()?
        .import_chats_zip(src_path)
        .await
        .map_err(ffi_err)
}

/// Saves a character card with its lore as a PNG card on its picture.
#[frb]
pub async fn export_character_card_png(card_id: String, dest_path: String) -> Result<(), String> {
    current_engine()?
        .export_character_card_png(card_id, dest_path)
        .await
        .map_err(ffi_err)
}

/// Saves an MCP server's token in the vault; a blank token removes it.
#[frb]
pub async fn set_mcp_token(server_id: String, token: String) -> Result<(), String> {
    current_engine()?
        .set_mcp_token(server_id, token)
        .await
        .map_err(ffi_err)
}

/// Whether an MCP server has a token saved.
#[frb]
pub async fn has_mcp_token(server_id: String) -> Result<bool, String> {
    current_engine()?
        .has_mcp_token(server_id)
        .await
        .map_err(ffi_err)
}

/// Asks the next start to erase everything Bistre keeps on this device.
#[frb]
pub async fn request_data_wipe() -> Result<(), String> {
    current_engine()?.request_data_wipe().await.map_err(ffi_err)
}

/// Withdraws a pending erase; returns whether one was pending.
#[frb]
pub async fn cancel_data_wipe() -> Result<bool, String> {
    current_engine()?.cancel_data_wipe().await.map_err(ffi_err)
}

#[frb]
pub async fn data_wipe_pending() -> Result<bool, String> {
    current_engine()?.data_wipe_pending().await.map_err(ffi_err)
}
