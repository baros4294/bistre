//! Public FFI entrypoints exposed to Dart via `flutter_rust_bridge 2.13`.

use std::sync::{Arc, LazyLock, RwLock};
use std::time::Duration;

use bistre_core::{EngineClient, InProcessEngine, VaultKey};
use bistre_protocol::{
    AppSettings, AssistantPatch, DiagnosticKey, EngineEvent, MoneyMicros, NodeRole,
    ProviderDialect, ProviderPatch, SystemPowerEvent, ThreadMode, ThreadPatch, TrustPreset,
    UnattendedPolicy, UpdateCheckResult,
};
use flutter_rust_bridge::frb;

use crate::dto_mapping::{
    buffer_delta_chunks, flush_pending_delta, map_agent_run, map_assistant, map_draft, map_event,
    map_health, map_hit, map_node, map_power_status, map_provider, map_settings, map_steering,
    map_storage_stats, map_thread, map_update_check,
};
use crate::frb_generated::StreamSink;

pub mod chat;
pub mod harness;
pub mod library;
pub mod media;
pub mod projects;
pub mod providers;
pub mod runs;
pub mod story;

static ENGINE: LazyLock<RwLock<Option<Arc<dyn EngineClient>>>> =
    LazyLock::new(|| RwLock::new(None));

/// The data folder's writer lock while the engine runs in this process on desktop; dropped
/// only after that engine has shut down.
static WRITER_LOCK: LazyLock<std::sync::Mutex<Option<bistre_core::daemon_launch::WriterLock>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));

/// Shuts down the current engine, then releases its writer lock.
async fn retire_engine() -> Result<(), String> {
    let previous = ENGINE
        .write()
        .map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())?
        .take();
    if let Some(old) = previous {
        old.shutdown().await.map_err(crate::dto_mapping::ffi_err)?;
    }
    drop(bistre_protocol::lock_or_recover(&WRITER_LOCK, "writer_lock").take());
    Ok(())
}

pub(crate) fn current_engine() -> Result<Arc<dyn EngineClient>, String> {
    let guard = ENGINE
        .read()
        .map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())?;
    guard
        .clone()
        .ok_or_else(|| DiagnosticKey::RuntimeNotInitialized.as_key().to_owned())
}

/// Thin FFI DTO mirror of `AppHealthSnapshot`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiHealthSnapshot {
    pub core_version: String,
    pub schema_version: u32,
    pub wal_mode_active: bool,
    pub thread_count: u64,
    pub node_count: u64,
    pub active_runs: u32,
    pub status_key: String,
}

/// Thin FFI DTO mirror of `AssistantRecord`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiAssistantRecord {
    pub id: String,
    pub name: String,
    pub role_subtitle: String,
    pub system_prompt: String,
    pub default_mode: String,
    pub badge_code: String,
    pub icon_slug: String,
    pub default_provider_id: String,
    pub default_model_id: String,
    pub temperature_milli: Option<u32>,
    pub max_output_tokens: Option<u32>,
    pub top_p_milli: Option<u32>,
    pub is_builtin: bool,
    pub created_at_ms: i64,
}

/// Thin FFI DTO mirror of `ProviderProfile` (never contains raw API keys).
#[frb]
#[derive(Debug, Clone)]
pub struct FfiProviderProfile {
    pub id: String,
    pub name: String,
    pub dialect: String,
    pub base_url: String,
    pub default_model: String,
    pub key_hint: String,
    pub has_api_key: bool,
    pub is_enabled: bool,
    pub is_builtin: bool,
    pub use_server_state_cache: bool,
    pub icon_slug: String,
    pub custom_icon_path: String,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    /// Core's parsed-host loopback decision: the model runs on this device.
    pub is_local: bool,
}

/// Thin FFI DTO mirror of `ProviderModelInfo`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiProviderModelInfo {
    pub id: String,
    pub display_name: String,
}

/// Thin FFI DTO mirror of `AppSettings`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiAppSettings {
    pub theme: String,
    pub layout_mode: String,
    pub locale: String,
    pub trust_preset: String,
    /// `None` explicitly represents Unlimited spending (no daily cap).
    pub wallet_daily_ceiling_micros: Option<i64>,
    pub wallet_local_first: bool,
    pub provider_stateless_default: bool,
    pub font_size_px: u32,
    pub line_height_bps: u32,
    pub reading_width_px: u32,
    pub prose_font_family: String,
    pub prose_font_path: String,
    pub mono_font_family: String,
    pub mono_font_path: String,
    pub accent_preset: String,
    pub custom_accent_hex: String,
    pub sidebar_open: bool,
    pub send_on_enter: bool,
    pub reduce_motion_override: bool,
    pub show_token_metrics: bool,
    pub active_provider_id: String,
    pub active_model_id: String,
    pub ota_feed_url: String,
    pub ota_channel: String,
    pub ota_auto_check: bool,
    pub window_bounds_json: String,
    pub custom_shortcuts_json: String,
    pub keep_awake_while_running: bool,
    pub windows_keep_awake_on_battery: bool,
    pub daemon_keep_alive_when_active: bool,
    pub unattended_policy: String,
    pub retry_watchdog_max_wait_secs: u32,
    pub reasoning_effort: String,
    pub termux_bridge_enabled: bool,
    pub code_wrap_mode: String,
    pub pricing_auto_refresh: bool,
    pub user_display_name: String,
    pub auto_compact_at_percent: u8,
}

/// Thin FFI DTO mirror of `ThreadSummary`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiThreadSummary {
    pub id: String,
    pub workspace_id: String,
    pub title: String,
    pub mode: String,
    pub topic: String,
    pub assistant_id: String,
    pub is_pinned: bool,
    pub active_head_node_id: Option<String>,
    pub provider_id_override: Option<String>,
    pub model_id_override: Option<String>,
    pub system_prompt_override: Option<String>,
    pub temperature_milli: Option<u32>,
    pub max_output_tokens: Option<u32>,
    pub top_p_milli: Option<u32>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

/// Thin FFI DTO mirror of `NodeRecord`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiNodeRecord {
    pub id: String,
    pub thread_id: String,
    pub parent_id: Option<String>,
    pub role: String,
    pub content: String,
    pub provider_meta_json: Option<String>,
    pub created_at_ms: i64,
    /// Files sent with this message, parsed once in core from its metadata.
    pub attachments: Vec<FfiNodeAttachment>,
}

/// One file sent with a message. `blob_rel_path` is relative to the data directory.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiNodeAttachment {
    pub name: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub blob_rel_path: String,
}

/// Thin FFI DTO mirror of `StorageStats`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiStorageStats {
    pub data_dir: String,
    pub db_size_bytes: u64,
    pub core_version: String,
    pub schema_version: u32,
    pub wal_mode_active: bool,
    pub thread_count: u64,
    pub node_count: u64,
    pub active_runs: u32,
}

/// Thin FFI DTO mirror of `UpdateCheckResult`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiUpdateCheckResult {
    pub current_version: String,
    pub latest_version: String,
    pub update_available: bool,
    pub track: String,
    pub ownership_mode: String,
    pub signature_verified: bool,
    pub active_runs_blocking: bool,
    pub release_notes: String,
    pub download_url: String,
    pub sha256_hex: String,
    pub download_size_bytes: u64,
    pub checked_at_ms: i64,
}

/// Thin FFI DTO mirror of `DraftRecord`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiDraftRecord {
    pub thread_id: String,
    pub text: String,
    pub updated_at_ms: i64,
}

/// Thin FFI DTO mirror of `SearchHit`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiSearchHit {
    pub node_id: String,
    pub thread_id: String,
    pub role: String,
    pub snippet: String,
    pub created_at_ms: i64,
}

/// Thin FFI DTO mirror of `AgentRunRecord`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiAgentRunRecord {
    pub id: String,
    pub thread_id: String,
    pub parent_run_id: Option<String>,
    pub root_node_id: Option<String>,
    pub mode: String,
    pub status: String,
    pub step_index: u32,
    pub max_steps: u32,
    pub unattended_policy: String,
    pub worktree_path: Option<String>,
    pub retry_after_ms: Option<i64>,
    pub last_heartbeat_ms: i64,
    pub cost_micros: i64,
    pub error_key: Option<String>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

/// Thin FFI DTO mirror of `SteeringMessage`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiSteeringMessage {
    pub id: String,
    pub thread_id: String,
    pub run_id: Option<String>,
    pub content: String,
    pub status: String,
    pub created_at_ms: i64,
}

/// Thin FFI DTO mirror of `PowerGuardStatus`.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiPowerGuardStatus {
    pub platform: String,
    pub keep_awake_active: bool,
    pub battery_override_active: bool,
    pub daemon_connected: bool,
    pub on_ac_power: bool,
    pub sleep_prevented_reason: String,
    pub android_fgs_active: bool,
    pub android_battery_unrestricted: bool,
    pub active_run_count: u32,
}

/// Thin flat FFI DTO mirror of coalesced streaming event batches (zero `freezed` codegen bloat;
/// decoded into a Dart 3 `sealed class` in `apps/bistre_app/lib/bridge/`).
#[frb]
#[derive(Debug, Clone)]
pub struct FfiEngineEvent {
    pub kind: String,
    pub thread_id: Option<String>,
    pub node_id: Option<String>,
    pub text_delta: Option<String>,
    pub cancelled: Option<bool>,
    pub node: Option<FfiNodeRecord>,
    pub updated_at_ms: Option<i64>,
    pub diagnostic_key: Option<String>,
    pub detail_code: Option<String>,
    pub pack_id: Option<String>,
    pub semver: Option<String>,
    pub payload_json: Option<String>,
}

impl FfiEngineEvent {
    pub(crate) fn blank(kind: &str) -> Self {
        Self {
            kind: kind.to_owned(),
            thread_id: None,
            node_id: None,
            text_delta: None,
            cancelled: None,
            node: None,
            updated_at_ms: None,
            diagnostic_key: None,
            detail_code: None,
            pack_id: None,
            semver: None,
            payload_json: None,
        }
    }

    pub(crate) fn delta(thread_id: String, node_id: String, text_delta: String) -> Self {
        let mut evt = Self::blank("delta_batch");
        evt.thread_id = Some(thread_id);
        evt.node_id = Some(node_id);
        evt.text_delta = Some(text_delta);
        evt
    }

    pub(crate) fn diagnostic(key: String, detail_code: Option<String>) -> Self {
        let mut evt = Self::blank("diagnostic_raised");
        evt.diagnostic_key = Some(key);
        evt.detail_code = detail_code;
        evt
    }
}

/// Initializes the Rust core engine for `data_dir`. On Windows and Linux that is the data
/// folder's `bistre-daemon` (started when it is not running), or the engine in this process
/// when no daemon is installed. `vault_key` is the 32-byte Android Keystore-unwrapped vault
/// data key (Android only); pass `None` elsewhere.
#[frb]
pub async fn init_runtime(
    data_dir: String,
    vault_key: Option<Vec<u8>>,
) -> Result<FfiHealthSnapshot, String> {
    // Re-initialising (hot restart, data-dir switch) must never leave two engines, and so two
    // SQLite writers, alive: shut down the previous engine before opening the next.
    retire_engine().await?;
    let engine = open_engine(&data_dir, vault_key).await?;
    {
        let mut guard = ENGINE
            .write()
            .map_err(|_| DiagnosticKey::InternalError.as_key().to_owned())?;
        *guard = Some(engine.clone());
    }
    let snap = engine.health().await.map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_health(snap))
}

/// Android hands over its Keystore-unwrapped data key and runs the engine in this process.
async fn open_engine(
    data_dir: &str,
    vault_key: Option<Vec<u8>>,
) -> Result<Arc<dyn EngineClient>, String> {
    if let Some(bytes) = vault_key.map(zeroize::Zeroizing::new) {
        let key = VaultKey::from_slice(&bytes).map_err(crate::dto_mapping::ffi_err)?;
        let engine: Arc<dyn EngineClient> =
            InProcessEngine::open(data_dir, Some(key)).map_err(crate::dto_mapping::ffi_err)?;
        return Ok(engine);
    }
    #[cfg(any(windows, target_os = "linux"))]
    {
        let desktop = bistre_core::daemon_launch::open_desktop_engine(
            std::path::Path::new(data_dir),
            bistre_core::daemon_launch::bundled_daemon_exe(),
        )
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
        let (engine, lock) = desktop.into_parts();
        *bistre_protocol::lock_or_recover(&WRITER_LOCK, "writer_lock") = lock;
        Ok(engine)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let key = bistre_core::vault_key::resolve_vault_key(std::path::Path::new(data_dir)).await;
        let engine: Arc<dyn EngineClient> =
            InProcessEngine::open(data_dir, key).map_err(crate::dto_mapping::ffi_err)?;
        Ok(engine)
    }
}

/// Returns a live engine & SQLite WAL health snapshot.
#[frb]
pub async fn get_health() -> Result<FfiHealthSnapshot, String> {
    let engine = current_engine()?;
    let snap = engine.health().await.map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_health(snap))
}

/// Creates a new conversation thread, in `project_id` when given, with optional topic and
/// assistant binding.
#[frb]
pub async fn create_thread(
    project_id: Option<String>,
    title: String,
    mode: String,
    topic: Option<String>,
    assistant_id: Option<String>,
) -> Result<FfiThreadSummary, String> {
    let engine = current_engine()?;
    let thread = engine
        .create_thread(
            project_id,
            title,
            ThreadMode::parse(&mode),
            topic,
            assistant_id,
        )
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_thread(thread))
}

/// Updates thread metadata and per-thread provider/model/parameter overrides atomically.
#[frb]
#[expect(
    clippy::too_many_arguments,
    reason = "Flat FRB v2 boundary avoids nested Option<Option<T>> codegen."
)]
pub async fn update_thread(
    thread_id: String,
    title: Option<String>,
    is_pinned: Option<bool>,
    topic: Option<String>,
    mode: Option<String>,
    assistant_id: Option<String>,
    provider_id_override: Option<String>,
    clear_provider_override: bool,
    model_id_override: Option<String>,
    clear_model_override: bool,
    system_prompt_override: Option<String>,
    clear_system_prompt_override: bool,
    temperature_milli: Option<u32>,
    clear_temperature: bool,
    max_output_tokens: Option<u32>,
    clear_max_output_tokens: bool,
    top_p_milli: Option<u32>,
    clear_top_p: bool,
) -> Result<FfiThreadSummary, String> {
    let engine = current_engine()?;
    let updated = engine
        .update_thread(
            thread_id,
            ThreadPatch {
                title,
                is_pinned,
                topic,
                mode: mode.as_deref().map(ThreadMode::parse),
                assistant_id,
                provider_id_override: if clear_provider_override {
                    Some(None)
                } else {
                    provider_id_override.map(Some)
                },
                model_id_override: if clear_model_override {
                    Some(None)
                } else {
                    model_id_override.map(Some)
                },
                system_prompt_override: if clear_system_prompt_override {
                    Some(None)
                } else {
                    system_prompt_override.map(Some)
                },
                temperature_milli: if clear_temperature {
                    Some(None)
                } else {
                    temperature_milli.map(Some)
                },
                max_output_tokens: if clear_max_output_tokens {
                    Some(None)
                } else {
                    max_output_tokens.map(Some)
                },
                top_p_milli: if clear_top_p {
                    Some(None)
                } else {
                    top_p_milli.map(Some)
                },
            },
        )
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_thread(updated))
}

/// Deletes a conversation thread and cascades its nodes and drafts.
#[frb]
pub async fn delete_thread(thread_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_thread(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Lists all persisted conversation threads ordered pinned first then newest-updated.
#[frb]
pub async fn list_threads() -> Result<Vec<FfiThreadSummary>, String> {
    let engine = current_engine()?;
    let list = engine
        .list_threads(None)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(list.into_iter().map(map_thread).collect())
}

/// Appends a canonical DAG node to `thread_id`.
#[frb]
pub async fn append_node(
    thread_id: String,
    parent_id: Option<String>,
    role: String,
    content: String,
) -> Result<FfiNodeRecord, String> {
    let engine = current_engine()?;
    let node = engine
        .append_node(thread_id, parent_id, NodeRole::parse(&role), content, None)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_node(node))
}

/// Persists a user message and streams an assistant reply over `subscribe_events`.
#[frb]
pub async fn send_and_stream_reply(
    thread_id: String,
    parent_id: Option<String>,
    user_content: String,
) -> Result<FfiNodeRecord, String> {
    let engine = current_engine()?;
    let user_node = engine
        .send_and_stream_reply(thread_id, parent_id, user_content)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_node(user_node))
}

/// Generates a new sibling assistant reply branch off `user_node_id`.
#[frb]
pub async fn regenerate_reply(thread_id: String, user_node_id: String) -> Result<String, String> {
    let engine = current_engine()?;
    engine
        .regenerate_reply(thread_id, user_node_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Edits a user message by creating a clean sibling DAG branch and streaming a fresh assistant reply.
#[frb]
pub async fn edit_user_node_and_stream(
    thread_id: String,
    node_id: String,
    new_content: String,
) -> Result<FfiNodeRecord, String> {
    let engine = current_engine()?;
    let node = engine
        .edit_user_node_and_stream(thread_id, node_id, new_content)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_node(node))
}

/// Deletes a single message node cleanly while preserving DAG integrity.
#[frb]
pub async fn delete_node(thread_id: String, node_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_node(thread_id, node_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Copies the branch ending at `node_id` into a new chat and returns it.
#[frb]
pub async fn fork_thread(thread_id: String, node_id: String) -> Result<FfiThreadSummary, String> {
    let engine = current_engine()?;
    let thread = engine
        .fork_thread(thread_id, node_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_thread(thread))
}

/// Removes a message and every message after it.
#[frb]
pub async fn delete_from_node(thread_id: String, node_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_from_node(thread_id, node_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Removes every message of a chat and keeps the chat.
#[frb]
pub async fn clear_thread_messages(thread_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .clear_thread_messages(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Exports a thread cleanly as Markdown (`"markdown"`) or JSON (`"json"`).
#[frb]
pub async fn export_thread(thread_id: String, format: String) -> Result<String, String> {
    let engine = current_engine()?;
    engine
        .export_thread(thread_id, format)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Writes an atomic WAL-consistent SQLite backup snapshot to `dest_path`.
#[frb]
pub async fn backup_database(dest_path: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .backup_database(dest_path)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Returns active storage path, on-disk DB size, schema version, and WAL metrics.
#[frb]
pub async fn get_storage_stats() -> Result<FfiStorageStats, String> {
    let engine = current_engine()?;
    let stats = engine
        .storage_stats()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_storage_stats(stats))
}

/// Performs a zero-telemetry Track-A / Track-B OTA update check against the configured feed URL.
#[frb]
pub async fn check_for_updates(
    feed_url_override: Option<String>,
) -> Result<FfiUpdateCheckResult, String> {
    let engine = current_engine()?;
    let res = engine
        .check_for_updates(feed_url_override)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_update_check(res))
}

/// Downloads, verifies SHA-256 offline, and stages an OTA payload without interrupting active runs.
#[frb]
pub async fn stage_update(check: FfiUpdateCheckResult) -> Result<String, String> {
    let engine = current_engine()?;
    engine
        .stage_update(map_ffi_update_check(check))
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Re-downloads, verifies SHA-256 offline, and stages the currently running version for reinstall.
#[frb]
pub async fn reinstall_update(check: FfiUpdateCheckResult) -> Result<String, String> {
    let engine = current_engine()?;
    engine
        .reinstall_update(map_ffi_update_check(check))
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// The staged update a restart would install, if any.
#[frb]
pub async fn pending_update_version() -> Result<Option<String>, String> {
    current_engine()?
        .pending_update_version()
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// What the app does after core handed an update over.
#[frb]
#[derive(Debug, Clone)]
pub struct FfiStagedInstall {
    pub version: String,
    /// Android: the verified APK for the system installer; empty on desktop, where core
    /// already started the installer and the app quits.
    pub android_apk_path: String,
}

/// Checks the staged update's SHA-256 again and hands it to the platform installer.
#[frb]
pub async fn install_staged_update() -> Result<FfiStagedInstall, String> {
    let done = current_engine()?
        .install_staged_update()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(FfiStagedInstall {
        version: done.version,
        android_apk_path: done.android_apk_path,
    })
}

fn map_ffi_update_check(check: FfiUpdateCheckResult) -> UpdateCheckResult {
    UpdateCheckResult {
        current_version: check.current_version,
        latest_version: check.latest_version,
        update_available: check.update_available,
        track: check.track,
        ownership_mode: check.ownership_mode,
        signature_verified: check.signature_verified,
        active_runs_blocking: check.active_runs_blocking,
        release_notes: check.release_notes,
        download_url: check.download_url,
        sha256_hex: check.sha256_hex,
        download_size_bytes: check.download_size_bytes,
        checked_at_ms: check.checked_at_ms,
    }
}

/// Cancels any active streaming reply for `thread_id`.
#[frb]
pub async fn cancel_active_run(thread_id: String) -> Result<bool, String> {
    let engine = current_engine()?;
    engine
        .cancel_active_run(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Ends a run's backoff wait immediately (`Retry now`); `false` when nothing is waiting.
#[frb]
pub async fn retry_run_now(thread_id: String) -> Result<bool, String> {
    let engine = current_engine()?;
    engine
        .retry_run_now(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Lists chronological DAG nodes for `thread_id`.
#[frb]
pub async fn list_nodes(thread_id: String) -> Result<Vec<FfiNodeRecord>, String> {
    let engine = current_engine()?;
    let nodes = engine
        .list_nodes(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(nodes.into_iter().map(map_node).collect())
}

/// Persists an unsent composer draft for `thread_id`.
#[frb]
pub async fn save_draft(thread_id: String, text: String) -> Result<FfiDraftRecord, String> {
    let engine = current_engine()?;
    let draft = engine
        .save_draft(thread_id, text)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_draft(draft))
}

/// Loads the persisted unsent composer draft for `thread_id`.
#[frb]
pub async fn load_draft(thread_id: String) -> Result<Option<FfiDraftRecord>, String> {
    let engine = current_engine()?;
    let draft = engine
        .load_draft(thread_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(draft.map(map_draft))
}

/// Loads persisted user settings from SQLite `kv_meta`.
#[frb]
pub async fn load_settings() -> Result<FfiAppSettings, String> {
    let engine = current_engine()?;
    let settings = engine
        .load_settings()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_settings(settings))
}

/// Persists validated user settings in SQLite `kv_meta`.
#[frb]
pub async fn save_settings(settings: FfiAppSettings) -> Result<FfiAppSettings, String> {
    let engine = current_engine()?;
    let saved = engine
        .save_settings(AppSettings {
            theme: settings.theme,
            layout_mode: settings.layout_mode,
            locale: settings.locale,
            trust_preset: TrustPreset::parse(&settings.trust_preset),
            wallet_daily_ceiling_micros: settings
                .wallet_daily_ceiling_micros
                .map(MoneyMicros::from_micros),
            wallet_local_first: settings.wallet_local_first,
            provider_stateless_default: settings.provider_stateless_default,
            font_size_px: settings.font_size_px,
            line_height_bps: settings.line_height_bps,
            reading_width_px: settings.reading_width_px,
            prose_font_family: settings.prose_font_family,
            prose_font_path: settings.prose_font_path,
            mono_font_family: settings.mono_font_family,
            mono_font_path: settings.mono_font_path,
            accent_preset: settings.accent_preset,
            custom_accent_hex: settings.custom_accent_hex,
            sidebar_open: settings.sidebar_open,
            send_on_enter: settings.send_on_enter,
            reduce_motion_override: settings.reduce_motion_override,
            show_token_metrics: settings.show_token_metrics,
            active_provider_id: settings.active_provider_id,
            active_model_id: settings.active_model_id,
            ota_feed_url: settings.ota_feed_url,
            ota_channel: settings.ota_channel,
            ota_auto_check: settings.ota_auto_check,
            window_bounds_json: settings.window_bounds_json,
            custom_shortcuts_json: settings.custom_shortcuts_json,
            keep_awake_while_running: settings.keep_awake_while_running,
            windows_keep_awake_on_battery: settings.windows_keep_awake_on_battery,
            daemon_keep_alive_when_active: settings.daemon_keep_alive_when_active,
            unattended_policy: UnattendedPolicy::parse(&settings.unattended_policy),
            retry_watchdog_max_wait_secs: settings.retry_watchdog_max_wait_secs,
            reasoning_effort: settings.reasoning_effort,
            termux_bridge_enabled: settings.termux_bridge_enabled,
            code_wrap_mode: settings.code_wrap_mode,
            pricing_auto_refresh: settings.pricing_auto_refresh,
            user_display_name: settings.user_display_name,
            auto_compact_at_percent: settings.auto_compact_at_percent,
        })
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_settings(saved))
}

/// Returns total recorded spend across all time in exact micro-USD (`1 USD = 1_000_000`).
#[frb]
pub async fn get_wallet_spend_micros() -> Result<i64, String> {
    let engine = current_engine()?;
    let spent = engine
        .wallet_spend_micros()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(spent.as_micros())
}

/// Returns today's recorded spend (since UTC day start) in exact micro-USD (`1 USD = 1_000_000`).
#[frb]
pub async fn get_wallet_daily_spend_micros() -> Result<i64, String> {
    let engine = current_engine()?;
    let spent = engine
        .wallet_daily_spend_micros()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(spent.as_micros())
}

/// Searches local canonical conversation history via SQLite FTS5.
#[frb]
pub async fn search_nodes(
    query: String,
    thread_id: Option<String>,
    limit: u32,
) -> Result<Vec<FfiSearchHit>, String> {
    let engine = current_engine()?;
    let hits = engine
        .search_nodes(query, thread_id, limit)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(hits.into_iter().map(map_hit).collect())
}

/// Verifies a Track-A signed locale or catalog pack offline via `minisign-verify`.
#[frb]
pub async fn verify_data_pack(
    public_key_b64: String,
    manifest_bytes: Vec<u8>,
    manifest_sig_text: String,
    pack_payload: Vec<u8>,
) -> Result<String, String> {
    let engine = current_engine()?;
    let manifest = engine
        .verify_data_pack(
            public_key_b64,
            manifest_bytes,
            manifest_sig_text,
            pack_payload,
        )
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(manifest.semver)
}

/// Streams engine events to Dart, coalescing contiguous `DeltaBatch` chunks on a 16ms cadence
/// so streaming tokens never saturate the Flutter UI event loop.
#[frb]
pub async fn subscribe_events(sink: StreamSink<FfiEngineEvent>) -> Result<(), String> {
    let engine = current_engine()?;
    let mut rx = engine.subscribe_events();
    let mut pending_delta: Option<(String, String, String)> = None;
    let mut tick = tokio::time::interval(Duration::from_millis(16));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = tick.tick(), if pending_delta.is_some() => {
                if !flush_pending_delta(&mut pending_delta, &sink) {
                    break;
                }
            }
            recv = rx.recv() => {
                match recv {
                    Ok(EngineEvent::DeltaBatch { thread_id, chunks }) => {
                        if !buffer_delta_chunks(&mut pending_delta, &thread_id, chunks, &sink) {
                            break;
                        }
                    }
                    Ok(other) => {
                        if !flush_pending_delta(&mut pending_delta, &sink) {
                            break;
                        }
                        if sink.add(map_event(other)).is_err() {
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                        // Events were dropped: drop the partial frame and tell the UI to reload
                        // state from storage (not an error the user must act on).
                        pending_delta = None;
                        if sink.add(FfiEngineEvent::blank("events_lagged")).is_err() {
                            break;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }
    Ok(())
}

/// Starts a public price-list refresh now.
#[frb]
pub async fn refresh_prices() -> Result<(), String> {
    current_engine()?
        .refresh_prices()
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Cleanly shuts down the active engine (in-process: checkpoints SQLite WAL; daemon: leaves
/// it, so it keeps live work running and exits on its own once idle).
#[frb]
pub async fn shutdown_runtime() -> Result<(), String> {
    retire_engine().await
}
