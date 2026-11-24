//! FFI DTOs and entrypoints for multi-key vault reveal, catalog metadata lookup, native
//! multimodal/Office attachments, immediate steering, storage file manager, export/import,
//! Live TTS, and Live Voice sessions.

use bistre_protocol::AttachmentInput;
use flutter_rust_bridge::frb;

use super::{current_engine, FfiAppSettings, FfiNodeRecord};
use crate::dto_mapping::{ffi_err, map_node, map_settings};

/// Live catalog metadata returned for a single model (`Fill from catalog`).
#[frb]
#[derive(Debug, Clone)]
pub struct FfiModelCatalogInfo {
    pub context_window: Option<u32>,
    pub max_output_tokens: Option<u32>,
    pub input_per_mtok_micros: Option<i64>,
    pub output_per_mtok_micros: Option<i64>,
    pub cached_input_per_mtok_micros: Option<i64>,
    pub reasoning: Option<bool>,
}

/// User-selected file attachment passed from Flutter composer to Rust core.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiAttachmentInput {
    pub name: String,
    pub mime_type: String,
    pub local_path: String,
}

/// File entry listed inside Bistre's local data directory.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiStorageFileEntry {
    pub rel_path: String,
    pub category: String,
    pub size_bytes: u64,
    pub modified_ms: i64,
    pub deletable: bool,
}

/// Returns decrypted API keys stored in the OS vault for `provider_id` in ring order.
#[frb]
pub async fn get_provider_api_keys(provider_id: String) -> Result<Vec<String>, String> {
    current_engine()?
        .get_provider_api_keys(provider_id)
        .await
        .map_err(ffi_err)
}

/// Looks up live pricing & context limit metadata for `model_id` from the cached registry.
#[frb]
pub async fn lookup_model_catalog_info(
    model_id: String,
) -> Result<Option<FfiModelCatalogInfo>, String> {
    let info = current_engine()?
        .lookup_model_catalog_info(model_id)
        .await
        .map_err(ffi_err)?;
    Ok(info.map(|c| FfiModelCatalogInfo {
        context_window: c.context_window,
        max_output_tokens: c.max_output_tokens,
        input_per_mtok_micros: c.input_per_mtok_micros,
        output_per_mtok_micros: c.output_per_mtok_micros,
        cached_input_per_mtok_micros: c.cached_input_per_mtok_micros,
        reasoning: c.reasoning,
    }))
}

/// Persists a user turn with real multimodal/PDF/Office/text attachments and streams the reply.
#[frb]
pub async fn send_and_stream_reply_with_attachments(
    thread_id: String,
    parent_id: Option<String>,
    user_content: String,
    attachments: Vec<FfiAttachmentInput>,
) -> Result<FfiNodeRecord, String> {
    let mapped = attachments
        .into_iter()
        .map(|a| AttachmentInput {
            name: a.name,
            mime_type: a.mime_type,
            local_path: a.local_path,
        })
        .collect();
    let node = current_engine()?
        .send_and_stream_reply_with_attachments(thread_id, parent_id, user_content, mapped)
        .await
        .map_err(ffi_err)?;
    Ok(map_node(node))
}

/// Interrupts the active run immediately and sends `content` as a live steering turn.
#[frb]
pub async fn steer_active_run_now(
    thread_id: String,
    content: String,
) -> Result<FfiNodeRecord, String> {
    let node = current_engine()?
        .steer_active_run_now(thread_id, content)
        .await
        .map_err(ffi_err)?;
    Ok(map_node(node))
}

/// Exports all chats and message trees as portable JSON.
#[frb]
pub async fn export_all_threads_json() -> Result<String, String> {
    current_engine()?
        .export_all_threads_json()
        .await
        .map_err(ffi_err)
}

/// Imports threads from an exported chat JSON file, returning the number of imported threads.
#[frb]
pub async fn import_threads_json(raw_json: String) -> Result<u32, String> {
    current_engine()?
        .import_threads_json(raw_json)
        .await
        .map_err(ffi_err)
}

/// Exports non-secret user settings as portable JSON.
#[frb]
pub async fn export_settings_json() -> Result<String, String> {
    current_engine()?
        .export_settings_json()
        .await
        .map_err(ffi_err)
}

/// Imports user settings JSON after untrusted-import sanitization.
#[frb]
pub async fn import_settings_json(raw_json: String) -> Result<FfiAppSettings, String> {
    let saved = current_engine()?
        .import_settings_json(raw_json)
        .await
        .map_err(ffi_err)?;
    Ok(map_settings(saved))
}

/// Lists files stored inside Bistre's local data directory.
#[frb]
pub async fn list_storage_files() -> Result<Vec<FfiStorageFileEntry>, String> {
    let files = current_engine()?
        .list_storage_files()
        .await
        .map_err(ffi_err)?;
    Ok(files
        .into_iter()
        .map(|f| FfiStorageFileEntry {
            rel_path: f.rel_path,
            category: f.category,
            size_bytes: f.size_bytes,
            modified_ms: f.modified_ms,
            deletable: f.deletable,
        })
        .collect())
}

/// Deletes a single non-protected file inside Bistre's data directory.
#[frb]
pub async fn delete_storage_file(rel_path: String) -> Result<bool, String> {
    current_engine()?
        .delete_storage_file(rel_path)
        .await
        .map_err(ffi_err)
}

/// Removes unreferenced attachment blobs and stale temporary files, returning bytes freed.
#[frb]
pub async fn clean_unused_storage_files() -> Result<u64, String> {
    current_engine()?
        .clean_unused_storage_files()
        .await
        .map_err(ffi_err)
}

/// Synthesizes playable WAV audio bytes via the provider's native TTS model.
#[frb]
pub async fn synthesize_speech(
    provider_id: String,
    model_id: String,
    text: String,
    voice: Option<String>,
) -> Result<Vec<u8>, String> {
    current_engine()?
        .synthesize_speech(provider_id, model_id, text, voice)
        .await
        .map_err(ffi_err)
}

/// Starts a real-time bidirectional Live Voice WebSocket session (Gemini Live / OpenAI Realtime).
#[frb]
pub async fn start_live_voice_session(
    provider_id: String,
    model_id: String,
    voice: String,
    system_prompt: String,
) -> Result<String, String> {
    current_engine()?
        .start_live_voice_session(provider_id, model_id, voice, system_prompt)
        .await
        .map_err(ffi_err)
}

/// Sends a base64-encoded 16 kHz 16-bit mono PCM mic chunk into an active Live Voice session.
#[frb]
pub async fn send_live_voice_pcm_chunk(
    session_id: String,
    pcm_base64: String,
) -> Result<(), String> {
    current_engine()?
        .send_live_voice_pcm_chunk(session_id, pcm_base64)
        .await
        .map_err(ffi_err)
}

/// Sends a text prompt into an active Live Voice session.
#[frb]
pub async fn send_live_voice_text(session_id: String, text: String) -> Result<(), String> {
    current_engine()?
        .send_live_voice_text(session_id, text)
        .await
        .map_err(ffi_err)
}

/// Closes an active Live Voice session cleanly.
#[frb]
pub async fn stop_live_voice_session(session_id: String) -> Result<(), String> {
    current_engine()?
        .stop_live_voice_session(session_id)
        .await
        .map_err(ffi_err)
}
