//! Stored records the crates share: providers, assistants, threads, nodes, runs, memory, schedules, and power state.

use super::{MoneyMicros, NodeRole, ProviderDialect, ThreadMode, UnattendedPolicy};
use serde::{Deserialize, Serialize};

/// Exact integer token usage and estimated micro-USD spend captured from provider SSE streams.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageMetrics {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cached_input_tokens: u64,
    #[serde(default)]
    pub cache_creation_input_tokens: u64,
    /// The part of `cache_creation_input_tokens` written with the 1-hour TTL (Anthropic
    /// `usage.cache_creation.ephemeral_1h_input_tokens`); the rest used the default TTL.
    #[serde(default)]
    pub cache_creation_1h_input_tokens: u64,
    #[serde(default)]
    pub reasoning_tokens: u64,
    #[serde(default)]
    pub first_token_ms: u64,
    pub estimated_cost_micros: MoneyMicros,
    /// Provider web searches billed per search (Anthropic `server_tool_use.web_search_requests`,
    /// `OpenAI` Responses `web_search_call` items).
    #[serde(default)]
    pub web_searches: u64,
    /// Provider code sessions billed per session (`OpenAI` Responses `code_interpreter_call`
    /// containers).
    #[serde(default)]
    pub code_sessions: u64,
    /// The part of `output_tokens` that is a picture (Gemini `IMAGE` modality, `OpenAI`
    /// `image_tokens`), billed at its own rate when the catalog has one.
    #[serde(default)]
    pub output_image_tokens: u64,
    /// The part of `output_tokens` that is sound (`audio_tokens`, Gemini `AUDIO`).
    #[serde(default)]
    pub output_audio_tokens: u64,
}

/// Non-secret provider configuration persisted in SQLite (`providers` table).
/// Raw API keys are NEVER stored in this struct or in SQLite; they live exclusively in `SecretVault`.
#[expect(
    clippy::struct_excessive_bools,
    reason = "Flat provider DTO mirroring independent SQLite boolean columns and vault key presence."
)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderProfile {
    pub id: String,
    pub name: String,
    pub dialect: ProviderDialect,
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
}

impl ProviderProfile {
    /// Whether requests need a key: always for the Big 3, and for an `OpenAI`-compatible
    /// provider pointed at `OpenRouter`, which answers every keyless request with `401`.
    pub fn requires_api_key(&self) -> bool {
        self.dialect.requires_api_key() || crate::dialect::is_openrouter_base(&self.base_url)
    }
}

/// Optional fields for atomically updating a provider profile.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderPatch {
    pub name: Option<String>,
    pub base_url: Option<String>,
    pub default_model: Option<String>,
    pub key_hint: Option<String>,
    pub is_enabled: Option<bool>,
    pub use_server_state_cache: Option<bool>,
    pub icon_slug: Option<String>,
    pub custom_icon_path: Option<String>,
}

/// Live model metadata discovered from a provider's `/models` endpoint (zero hardcoded models).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderModelInfo {
    pub id: String,
    pub display_name: String,
}

/// Catalog metadata for a single model returned from the live pricing/model registry.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelCatalogInfo {
    pub context_window: Option<u32>,
    pub max_output_tokens: Option<u32>,
    pub input_per_mtok_micros: Option<i64>,
    pub output_per_mtok_micros: Option<i64>,
    pub cached_input_per_mtok_micros: Option<i64>,
    pub cache_write_per_mtok_micros: Option<i64>,
    pub cache_write_1h_per_mtok_micros: Option<i64>,
    pub reasoning: Option<bool>,
    /// False for a model that only draws, films, or speaks (it has no thinking setting).
    pub writes_text: bool,
    /// Picture shapes the model offers (`16:9`); empty leaves the shape to the provider.
    pub aspect_ratios: Vec<String>,
    /// Output sizes the model offers (`2K`, `720p`).
    pub resolutions: Vec<String>,
    /// Video lengths the model offers, in seconds.
    pub durations_s: Vec<u32>,
}

/// Attachment selected by the user to be ingested into Bistre's content-addressed blob store.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentInput {
    pub name: String,
    pub mime_type: String,
    pub local_path: String,
}

/// Canonical attachment stored inside `<data_dir>/attachments/` and linked from a user node.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredAttachment {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    pub blob_rel_path: String,
    pub size_bytes: u64,
    pub blake3_hex: String,
}

/// File entry reported by the Storage & File Manager inside Bistre's data directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StorageFileEntry {
    pub rel_path: String,
    pub category: String,
    pub size_bytes: u64,
    pub modified_ms: i64,
    pub deletable: bool,
}

/// Assistant persona persisted in SQLite (`default_assistant` created on fresh install if empty).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssistantRecord {
    pub id: String,
    pub name: String,
    pub role_subtitle: String,
    pub system_prompt: String,
    pub default_mode: ThreadMode,
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

/// Optional fields for updating an assistant atomically.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssistantPatch {
    pub name: Option<String>,
    pub role_subtitle: Option<String>,
    pub system_prompt: Option<String>,
    pub default_mode: Option<ThreadMode>,
    pub badge_code: Option<String>,
    pub icon_slug: Option<String>,
    pub default_provider_id: Option<String>,
    pub default_model_id: Option<String>,
    /// `Some(Some(v))` sets temperature; `Some(None)` clears back to provider default.
    pub temperature_milli: Option<Option<u32>>,
    pub max_output_tokens: Option<Option<u32>>,
    pub top_p_milli: Option<Option<u32>>,
}

/// Summary row for a conversation thread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadSummary {
    pub id: String,
    pub workspace_id: String,
    pub title: String,
    pub mode: ThreadMode,
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

/// Optional fields for updating thread metadata atomically.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadPatch {
    pub title: Option<String>,
    pub is_pinned: Option<bool>,
    pub topic: Option<String>,
    pub mode: Option<ThreadMode>,
    pub assistant_id: Option<String>,
    pub provider_id_override: Option<Option<String>>,
    pub model_id_override: Option<Option<String>>,
    pub system_prompt_override: Option<Option<String>>,
    pub temperature_milli: Option<Option<u32>>,
    pub max_output_tokens: Option<Option<u32>>,
    pub top_p_milli: Option<Option<u32>>,
}

/// Detailed local storage and runtime diagnostics exposed to Storage & Updates UI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StorageStats {
    pub data_dir: String,
    pub db_size_bytes: u64,
    pub core_version: String,
    pub schema_version: u32,
    pub wal_mode_active: bool,
    pub thread_count: u64,
    pub node_count: u64,
    pub active_runs: u32,
}

/// Zero-telemetry Track-A / Track-B OTA update check snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateCheckResult {
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

/// Canonical DAG node stored in local SQLite history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NodeRecord {
    pub id: String,
    pub thread_id: String,
    pub parent_id: Option<String>,
    pub role: NodeRole,
    pub content: String,
    pub provider_meta_json: Option<String>,
    pub created_at_ms: i64,
}

/// Persistent unsent composer draft stored per thread.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DraftRecord {
    pub thread_id: String,
    pub text: String,
    pub updated_at_ms: i64,
}

/// Full-text search hit across canonical history nodes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SearchHit {
    pub node_id: String,
    pub thread_id: String,
    pub role: NodeRole,
    pub snippet: String,
    pub created_at_ms: i64,
}

/// Signed Track-A data pack or Track-B binary release manifest (verified via `minisign-verify`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedPackManifest {
    pub format_version: u32,
    pub pack_id: String,
    pub semver: String,
    pub min_app_semver: String,
    pub sha256_hex: String,
    pub published_at_unix: i64,
}

/// Incremental streaming chunk coalesced across the FFI / IPC boundary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StreamChunk {
    pub node_id: String,
    pub text_delta: String,
}

/// Lifecycle status of a durable SQLite-journaled long-horizon agent run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Running,
    WaitingApproval,
    BackoffWait,
    SleepPaused,
    IndeterminateHalt,
    Completed,
    Failed,
    Cancelled,
}

impl RunStatus {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::WaitingApproval => "waiting_approval",
            Self::BackoffWait => "backoff_wait",
            Self::SleepPaused => "sleep_paused",
            Self::IndeterminateHalt => "indeterminate_halt",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw {
            "running" => Self::Running,
            "waiting_approval" => Self::WaitingApproval,
            "backoff_wait" => Self::BackoffWait,
            "sleep_paused" => Self::SleepPaused,
            "indeterminate_halt" => Self::IndeterminateHalt,
            "completed" => Self::Completed,
            "cancelled" => Self::Cancelled,
            _ => Self::Failed,
        }
    }
}

/// Static + dynamic tool risk tier (Spec 06).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolRiskTier {
    Tier0ReadOnly,
    Tier1ReversibleEdit,
    Tier2ExternalSideEffect,
    Tier3Blocked,
}

impl ToolRiskTier {
    pub const fn as_u8(self) -> u8 {
        match self {
            Self::Tier0ReadOnly => 0,
            Self::Tier1ReversibleEdit => 1,
            Self::Tier2ExternalSideEffect => 2,
            Self::Tier3Blocked => 3,
        }
    }

    pub const fn from_u8(raw: u8) -> Self {
        match raw {
            0 => Self::Tier0ReadOnly,
            1 => Self::Tier1ReversibleEdit,
            2 => Self::Tier2ExternalSideEffect,
            _ => Self::Tier3Blocked,
        }
    }
}

/// Kind of journaled step inside an `agent_runs` execution trace.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStepKind {
    LlmCall,
    ToolCall,
    ToolResult,
    Compaction,
    SteeringInjected,
    Checkpoint,
}

impl RunStepKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::LlmCall => "llm_call",
            Self::ToolCall => "tool_call",
            Self::ToolResult => "tool_result",
            Self::Compaction => "compaction",
            Self::SteeringInjected => "steering_injected",
            Self::Checkpoint => "checkpoint",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw {
            "tool_call" => Self::ToolCall,
            "tool_result" => Self::ToolResult,
            "compaction" => Self::Compaction,
            "steering_injected" => Self::SteeringInjected,
            "checkpoint" => Self::Checkpoint,
            _ => Self::LlmCall,
        }
    }
}

/// Durable long-horizon agent run record persisted in SQLite WAL (`agent_runs`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentRunRecord {
    pub id: String,
    pub thread_id: String,
    pub parent_run_id: Option<String>,
    pub root_node_id: Option<String>,
    pub mode: ThreadMode,
    pub status: RunStatus,
    pub step_index: u32,
    pub max_steps: u32,
    pub unattended_policy: UnattendedPolicy,
    pub worktree_path: Option<String>,
    pub retry_after_ms: Option<i64>,
    pub last_heartbeat_ms: i64,
    pub partial_text_buffer: String,
    pub partial_thinking_buffer: String,
    pub cost_micros: MoneyMicros,
    pub error_key: Option<String>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

/// Individual step journaled inside `run_steps` with deterministic idempotency metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunStepRecord {
    pub id: String,
    pub run_id: String,
    pub step_index: u32,
    pub kind: RunStepKind,
    pub tool_name: String,
    pub risk_tier: ToolRiskTier,
    pub idempotency_key: String,
    pub status: String,
    pub input_json: String,
    pub output_json: String,
    pub duration_ms: i64,
    pub created_at_ms: i64,
    pub completed_at_ms: Option<i64>,
}

/// Queued mid-stream user steering message injected cleanly at the next step boundary without cancelling the run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SteeringMessage {
    pub id: String,
    pub thread_id: String,
    pub run_id: Option<String>,
    pub content: String,
    pub attachments_json: String,
    pub status: String,
    pub created_at_ms: i64,
}

/// Pre-edit workspace file snapshot enabling instant 1-click Rewind.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceCheckpointRecord {
    pub id: String,
    pub thread_id: String,
    pub run_id: Option<String>,
    pub node_id: Option<String>,
    pub file_path: String,
    pub before_blake3: String,
    pub after_blake3: String,
    pub pre_image_blob: Vec<u8>,
    pub created_at_ms: i64,
}

/// Multimodal attachment metadata linked to a thread/node (`attachments` table).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentRecord {
    pub id: String,
    pub thread_id: String,
    pub node_id: Option<String>,
    pub kind: String,
    pub filename: String,
    pub mime_type: String,
    pub byte_len: u64,
    pub sha256: String,
    pub storage_rel_path: String,
    pub extracted_text: String,
    pub created_at_ms: i64,
}

/// Persistent cross-chat / workspace / assistant memory item (`memory_entries` table).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemoryEntryRecord {
    pub id: String,
    pub scope: String,
    pub scope_id: String,
    pub key: String,
    pub content: String,
    pub source_thread_id: Option<String>,
    pub pinned: bool,
    pub updated_at_ms: i64,
}

/// Scheduled recurring cron or one-shot automation record (`cron_jobs` table).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CronJobRecord {
    pub id: String,
    pub name: String,
    pub workspace_id: String,
    pub assistant_id: String,
    pub schedule_expr: String,
    pub prompt: String,
    pub mode: ThreadMode,
    pub unattended_policy: UnattendedPolicy,
    pub use_worktree: bool,
    pub enabled: bool,
    pub next_run_ms: i64,
    pub last_run_id: Option<String>,
    pub last_status: String,
}

/// Live OS power/sleep inhibition & background daemon health surfaced to the Runs Dock & Settings.
#[expect(
    clippy::struct_excessive_bools,
    reason = "Cross-platform OS sleep/daemon status snapshot with independent runtime flags."
)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PowerGuardStatus {
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

impl Default for PowerGuardStatus {
    fn default() -> Self {
        Self {
            platform: std::env::consts::OS.to_owned(),
            keep_awake_active: false,
            battery_override_active: false,
            daemon_connected: false,
            on_ac_power: true,
            sleep_prevented_reason: String::new(),
            android_fgs_active: false,
            android_battery_unrestricted: false,
            active_run_count: 0,
        }
    }
}

/// OS lifecycle and connectivity transition delivered from platform guards into `bistre-core`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum SystemPowerEvent {
    WillSuspend,
    DidResume,
    NetworkLost,
    NetworkRestored,
    OsTimeoutImminent,
    PowerSourceChanged {
        on_ac: bool,
    },
    /// The app came back to the foreground: stalled streams end; runs are not touched.
    AppResumed,
}
