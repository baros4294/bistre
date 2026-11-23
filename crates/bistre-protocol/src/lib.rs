//! Shared protocol types, typed diagnostic keys, exact fixed-point money accounting,
//! and engine DTOs shared across pure Rust core, storage, crypto, FFI, daemon, and updater.
//!
//! Invariants:
//! - Zero English UI sentences; all user-facing diagnostics flow as stable `DiagnosticKey` codes.
//! - Zero floating-point monetary arithmetic; all financial amounts use `MoneyMicros(i64)`.

pub mod story;

use core::fmt;
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub use story::*;

/// Exact fixed-point currency amount in micro-USD (`1 USD = 1_000_000` micros).
///
/// Guarantees deterministic, lossless accounting for Wallet Shield budgets and ledgers.
#[must_use]
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize,
)]
#[serde(transparent)]
pub struct MoneyMicros(pub i64);

impl MoneyMicros {
    /// Zero micro-USD.
    pub const ZERO: Self = Self(0);

    /// Number of micros per one whole USD.
    pub const MICROS_PER_USD: i64 = 1_000_000;

    /// Constructs a monetary value from exact micro-USD.
    pub const fn from_micros(micros: i64) -> Self {
        Self(micros)
    }

    /// Constructs a monetary value from whole cents (`1 cent = 10_000` micros), returning `None` on overflow.
    pub const fn from_cents(cents: i64) -> Option<Self> {
        match cents.checked_mul(10_000) {
            Some(v) => Some(Self(v)),
            None => None,
        }
    }

    /// Returns the raw integer micro-USD count.
    pub const fn as_micros(self) -> i64 {
        self.0
    }

    /// Checked addition returning `None` on signed 64-bit overflow.
    pub const fn checked_add(self, rhs: Self) -> Option<Self> {
        match self.0.checked_add(rhs.0) {
            Some(v) => Some(Self(v)),
            None => None,
        }
    }

    /// Checked subtraction returning `None` on signed 64-bit underflow.
    pub const fn checked_sub(self, rhs: Self) -> Option<Self> {
        match self.0.checked_sub(rhs.0) {
            Some(v) => Some(Self(v)),
            None => None,
        }
    }

    /// Saturating addition guaranteed never to wrap or panic.
    pub const fn saturating_add(self, rhs: Self) -> Self {
        Self(self.0.saturating_add(rhs.0))
    }

    /// Saturating subtraction guaranteed never to wrap or panic.
    pub const fn saturating_sub(self, rhs: Self) -> Self {
        Self(self.0.saturating_sub(rhs.0))
    }
}

/// Stable, localization-keyed diagnostic codes emitted by pure Rust crates.
///
/// UI layers resolve each dot-key through the active ICU localization catalog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Error)]
#[non_exhaustive]
pub enum DiagnosticKey {
    #[error("diag.ok")]
    #[serde(rename = "diag.ok")]
    Ok,

    #[error("diag.storage.busy")]
    #[serde(rename = "diag.storage.busy")]
    StorageBusy,

    #[error("diag.storage.disk_full")]
    #[serde(rename = "diag.storage.disk_full")]
    StorageDiskFull,

    #[error("diag.storage.migration_failed")]
    #[serde(rename = "diag.storage.migration_failed")]
    StorageMigrationFailed,

    #[error("diag.storage.not_found")]
    #[serde(rename = "diag.storage.not_found")]
    StorageNotFound,

    #[error("diag.crypto.signature_invalid")]
    #[serde(rename = "diag.crypto.signature_invalid")]
    CryptoSignatureInvalid,

    #[error("diag.crypto.vault_unavailable")]
    #[serde(rename = "diag.crypto.vault_unavailable")]
    CryptoVaultUnavailable,

    #[error("diag.network.captive_portal")]
    #[serde(rename = "diag.network.captive_portal")]
    NetworkCaptivePortal,

    #[error("diag.clock.skew_suspected")]
    #[serde(rename = "diag.clock.skew_suspected")]
    ClockSkewSuspected,

    #[error("diag.tool.edit_hash_mismatch")]
    #[serde(rename = "diag.tool.edit_hash_mismatch")]
    ToolEditHashMismatch,

    #[error("diag.wallet.ceiling_exceeded")]
    #[serde(rename = "diag.wallet.ceiling_exceeded")]
    WalletCeilingExceeded,

    #[error("diag.provider.not_configured")]
    #[serde(rename = "diag.provider.not_configured")]
    ProviderNotConfigured,

    #[error("diag.provider.model_required")]
    #[serde(rename = "diag.provider.model_required")]
    ProviderModelRequired,

    #[error("diag.provider.auth_failed")]
    #[serde(rename = "diag.provider.auth_failed")]
    ProviderAuthFailed,

    #[error("diag.provider.request_failed")]
    #[serde(rename = "diag.provider.request_failed")]
    ProviderRequestFailed,

    #[error("diag.ota.check_failed")]
    #[serde(rename = "diag.ota.check_failed")]
    OtaCheckFailed,

    #[error("diag.ota.active_runs_deferred")]
    #[serde(rename = "diag.ota.active_runs_deferred")]
    OtaActiveRunsDeferred,

    #[error("diag.ota.managed_externally")]
    #[serde(rename = "diag.ota.managed_externally")]
    OtaManagedExternally,

    #[error("diag.export.failed")]
    #[serde(rename = "diag.export.failed")]
    ExportFailed,

    #[error("diag.validation.invalid_input")]
    #[serde(rename = "diag.validation.invalid_input")]
    InvalidInput,

    #[error("diag.runtime.already_running")]
    #[serde(rename = "diag.runtime.already_running")]
    RuntimeAlreadyRunning,

    #[error("diag.runtime.not_initialized")]
    #[serde(rename = "diag.runtime.not_initialized")]
    RuntimeNotInitialized,

    #[error("diag.run.indeterminate_halt")]
    #[serde(rename = "diag.run.indeterminate_halt")]
    RunIndeterminateHalt,

    #[error("diag.run.backoff_waiting")]
    #[serde(rename = "diag.run.backoff_waiting")]
    RunBackoffWaiting,

    #[error("diag.power.guard_degraded")]
    #[serde(rename = "diag.power.guard_degraded")]
    PowerGuardDegraded,

    #[error("diag.daemon.unavailable")]
    #[serde(rename = "diag.daemon.unavailable")]
    DaemonUnavailable,

    #[error("diag.network.destination_blocked")]
    #[serde(rename = "diag.network.destination_blocked")]
    NetworkDestinationBlocked,

    #[error("diag.provider.rate_limited")]
    #[serde(rename = "diag.provider.rate_limited")]
    ProviderRateLimited,

    #[error("diag.provider.quota_exhausted")]
    #[serde(rename = "diag.provider.quota_exhausted")]
    ProviderQuotaExhausted,

    #[error("diag.provider.stream_interrupted")]
    #[serde(rename = "diag.provider.stream_interrupted")]
    ProviderStreamInterrupted,

    #[error("diag.provider.context_overflow")]
    #[serde(rename = "diag.provider.context_overflow")]
    ProviderContextOverflow,

    #[error("diag.provider.request_healed")]
    #[serde(rename = "diag.provider.request_healed")]
    ProviderRequestHealed,

    #[error("diag.tool.stale_read")]
    #[serde(rename = "diag.tool.stale_read")]
    ToolStaleRead,

    #[error("diag.tool.approval_required")]
    #[serde(rename = "diag.tool.approval_required")]
    ToolApprovalRequired,

    #[error("diag.ota.integrity_failed")]
    #[serde(rename = "diag.ota.integrity_failed")]
    OtaIntegrityFailed,

    #[error("diag.ota.signing_key_missing")]
    #[serde(rename = "diag.ota.signing_key_missing")]
    OtaSigningKeyMissing,

    #[error("diag.wallet.check_unavailable")]
    #[serde(rename = "diag.wallet.check_unavailable")]
    WalletCheckUnavailable,

    #[error("diag.tool.tier_blocked")]
    #[serde(rename = "diag.tool.tier_blocked")]
    ToolTierBlocked,

    #[error("diag.internal.error")]
    #[serde(rename = "diag.internal.error")]
    InternalError,
}

impl DiagnosticKey {
    /// Returns the canonical ICU catalog lookup key.
    pub const fn as_key(self) -> &'static str {
        match self {
            Self::Ok => "diag.ok",
            Self::StorageBusy => "diag.storage.busy",
            Self::StorageDiskFull => "diag.storage.disk_full",
            Self::StorageMigrationFailed => "diag.storage.migration_failed",
            Self::StorageNotFound => "diag.storage.not_found",
            Self::CryptoSignatureInvalid => "diag.crypto.signature_invalid",
            Self::CryptoVaultUnavailable => "diag.crypto.vault_unavailable",
            Self::NetworkCaptivePortal => "diag.network.captive_portal",
            Self::ClockSkewSuspected => "diag.clock.skew_suspected",
            Self::ToolEditHashMismatch => "diag.tool.edit_hash_mismatch",
            Self::WalletCeilingExceeded => "diag.wallet.ceiling_exceeded",
            Self::ProviderNotConfigured => "diag.provider.not_configured",
            Self::ProviderModelRequired => "diag.provider.model_required",
            Self::ProviderAuthFailed => "diag.provider.auth_failed",
            Self::ProviderRequestFailed => "diag.provider.request_failed",
            Self::OtaCheckFailed => "diag.ota.check_failed",
            Self::OtaActiveRunsDeferred => "diag.ota.active_runs_deferred",
            Self::OtaManagedExternally => "diag.ota.managed_externally",
            Self::ExportFailed => "diag.export.failed",
            Self::InvalidInput => "diag.validation.invalid_input",
            Self::RuntimeAlreadyRunning => "diag.runtime.already_running",
            Self::RuntimeNotInitialized => "diag.runtime.not_initialized",
            Self::RunIndeterminateHalt => "diag.run.indeterminate_halt",
            Self::RunBackoffWaiting => "diag.run.backoff_waiting",
            Self::PowerGuardDegraded => "diag.power.guard_degraded",
            Self::DaemonUnavailable => "diag.daemon.unavailable",
            Self::NetworkDestinationBlocked => "diag.network.destination_blocked",
            Self::ProviderRateLimited => "diag.provider.rate_limited",
            Self::ProviderQuotaExhausted => "diag.provider.quota_exhausted",
            Self::ProviderStreamInterrupted => "diag.provider.stream_interrupted",
            Self::ProviderContextOverflow => "diag.provider.context_overflow",
            Self::ProviderRequestHealed => "diag.provider.request_healed",
            Self::ToolStaleRead => "diag.tool.stale_read",
            Self::ToolApprovalRequired => "diag.tool.approval_required",
            Self::OtaIntegrityFailed => "diag.ota.integrity_failed",
            Self::OtaSigningKeyMissing => "diag.ota.signing_key_missing",
            Self::WalletCheckUnavailable => "diag.wallet.check_unavailable",
            Self::ToolTierBlocked => "diag.tool.tier_blocked",
            Self::InternalError => "diag.internal.error",
        }
    }
}

/// Structured domain error pairing a typed `DiagnosticKey` with an optional non-localized technical code.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BistreError {
    pub key: DiagnosticKey,
    pub detail_code: Option<String>,
}

impl BistreError {
    pub const fn new(key: DiagnosticKey) -> Self {
        Self {
            key,
            detail_code: None,
        }
    }

    pub fn with_detail(key: DiagnosticKey, detail_code: impl Into<String>) -> Self {
        Self {
            key,
            detail_code: Some(detail_code.into()),
        }
    }
}

impl fmt::Display for BistreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.detail_code {
            Some(code) => write!(f, "{} ({code})", self.key.as_key()),
            None => f.write_str(self.key.as_key()),
        }
    }
}

impl std::error::Error for BistreError {}

impl From<DiagnosticKey> for BistreError {
    fn from(key: DiagnosticKey) -> Self {
        Self::new(key)
    }
}

/// Canonical result alias for Bistre pure-Rust APIs.
pub type BistreResult<T> = Result<T, BistreError>;

/// Conversation interaction mode for a thread.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadMode {
    Chat,
    Plan,
    Code,
    Write,
    Translate,
}

impl ThreadMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Chat => "chat",
            Self::Plan => "plan",
            Self::Code => "code",
            Self::Write => "write",
            Self::Translate => "translate",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw {
            "plan" => Self::Plan,
            "code" | "build" => Self::Code,
            "write" | "roleplay" => Self::Write,
            "translate" => Self::Translate,
            _ => Self::Chat,
        }
    }
}

/// Role of a canonical DAG node in local conversation history.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeRole {
    System,
    User,
    Assistant,
    Tool,
    CompactionSummary,
}

impl NodeRole {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::User => "user",
            Self::Assistant => "assistant",
            Self::Tool => "tool",
            Self::CompactionSummary => "compaction_summary",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw {
            "system" => Self::System,
            "assistant" => Self::Assistant,
            "tool" => Self::Tool,
            "compaction_summary" => Self::CompactionSummary,
            _ => Self::User,
        }
    }
}

/// Live health and telemetry-free diagnostic snapshot of the Rust engine & SQLite WAL store.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppHealthSnapshot {
    pub core_version: String,
    pub schema_version: u32,
    pub wal_mode_active: bool,
    pub thread_count: u64,
    pub node_count: u64,
    pub active_runs: u32,
    pub status_key: DiagnosticKey,
}

/// Summary row for a workspace.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceSummary {
    pub id: String,
    pub name: String,
    pub root_path: Option<String>,
    pub created_at_ms: i64,
}

/// Trust preset governing automatic tool execution tiers (Spec 06).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustPreset {
    Parchment,
    GuidedCraft,
    UnchainedSandbox,
}

impl TrustPreset {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Parchment => "parchment",
            Self::GuidedCraft => "guided_craft",
            Self::UnchainedSandbox => "unchained_sandbox",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw {
            "parchment" => Self::Parchment,
            "unchained_sandbox" => Self::UnchainedSandbox,
            _ => Self::GuidedCraft,
        }
    }
}

fn default_theme() -> String {
    "system".to_owned()
}
/// Messenger bubbles by default (Parchment v2.6.0); the page view stays one tap away.
fn default_layout_mode() -> String {
    "bubbles".to_owned()
}
fn default_locale() -> String {
    "en".to_owned()
}
fn default_accent_preset() -> String {
    "wax".to_owned()
}
fn default_font_size_px() -> u32 {
    15
}
fn default_line_height_bps() -> u32 {
    16_000
}
fn default_reading_width_px() -> u32 {
    760
}
fn default_font_scale_bps() -> u32 {
    10_000
}
fn default_true() -> bool {
    true
}
fn default_ota_channel() -> String {
    "stable".to_owned()
}
fn default_ota_feed_url() -> String {
    "https://github.com/baros4294/bistre/releases/latest/download/manifest.json".to_owned()
}
fn default_reasoning_effort() -> String {
    "default".to_owned()
}
const fn default_retry_watchdog_max_wait_secs() -> u32 {
    1800
}
const fn default_unattended_policy() -> UnattendedPolicy {
    UnattendedPolicy::PauseAndNotify
}
#[expect(
    clippy::unnecessary_wraps,
    reason = "Serde field default callback for Option<MoneyMicros> must return Option<MoneyMicros>."
)]
const fn default_wallet_ceiling() -> Option<MoneyMicros> {
    Some(MoneyMicros::from_micros(5_000_000))
}

/// Policy governing Tier-2 approvals during unattended, overnight, or scheduled agent runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UnattendedPolicy {
    /// Pause the run safely in SQLite WAL and notify the user until approved.
    #[default]
    PauseAndNotify,
    /// Automatically return a structured policy denial for Tier-2 tools so the agent adapts without hanging.
    DenyTier2AndContinue,
    /// Permit Tier-2 operations strictly inside isolated git worktree / sandbox workspaces.
    SandboxWorktreeAuto,
}

impl UnattendedPolicy {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::PauseAndNotify => "pause_and_notify",
            Self::DenyTier2AndContinue => "deny_tier2_and_continue",
            Self::SandboxWorktreeAuto => "sandbox_worktree_auto",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw {
            "deny_tier2_and_continue" => Self::DenyTier2AndContinue,
            "sandbox_worktree_auto" => Self::SandboxWorktreeAuto,
            _ => Self::PauseAndNotify,
        }
    }
}

/// Persisted user preferences, typography, personalization, OTA, sleep guard, and Wallet/Trust Shield config (`kv_meta`).
#[expect(
    clippy::struct_excessive_bools,
    reason = "Flat user preference record with independent boolean toggles serialized to kv_meta."
)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppSettings {
    #[serde(default = "default_theme")]
    pub theme: String,
    #[serde(default = "default_layout_mode")]
    pub layout_mode: String,
    #[serde(default = "default_locale")]
    pub locale: String,
    #[serde(default = "default_trust_preset")]
    pub trust_preset: TrustPreset,
    /// `None` explicitly represents Unlimited spending (no daily cap).
    #[serde(default = "default_wallet_ceiling")]
    pub wallet_daily_ceiling_micros: Option<MoneyMicros>,
    #[serde(default = "default_true")]
    pub wallet_local_first: bool,
    #[serde(default = "default_true")]
    pub provider_stateless_default: bool,
    #[serde(default = "default_font_scale_bps")]
    pub font_scale_bps: u32,
    #[serde(default = "default_font_size_px")]
    pub font_size_px: u32,
    #[serde(default = "default_line_height_bps")]
    pub line_height_bps: u32,
    #[serde(default = "default_reading_width_px")]
    pub reading_width_px: u32,
    #[serde(default)]
    pub prose_font_family: String,
    #[serde(default)]
    pub prose_font_path: String,
    #[serde(default)]
    pub mono_font_family: String,
    #[serde(default)]
    pub mono_font_path: String,
    #[serde(default = "default_accent_preset")]
    pub accent_preset: String,
    #[serde(default)]
    pub custom_accent_hex: String,
    #[serde(default = "default_true")]
    pub sidebar_open: bool,
    #[serde(default = "default_true")]
    pub send_on_enter: bool,
    #[serde(default)]
    pub reduce_motion_override: bool,
    #[serde(default = "default_true")]
    pub show_token_metrics: bool,
    #[serde(default)]
    pub active_provider_id: String,
    #[serde(default)]
    pub active_model_id: String,
    #[serde(default = "default_ota_feed_url")]
    pub ota_feed_url: String,
    #[serde(default = "default_ota_channel")]
    pub ota_channel: String,
    #[serde(default = "default_true")]
    pub ota_auto_check: bool,
    #[serde(default)]
    pub window_bounds_json: String,
    #[serde(default)]
    pub custom_shortcuts_json: String,
    /// Prevent system idle sleep while active agent runs are executing (`PowerRequestSystemRequired`/`logind`/Android FGS).
    #[serde(default = "default_true")]
    pub keep_awake_while_running: bool,
    /// Explicit opt-in toggle for Windows Modern Standby (S0ix) laptops on battery (acquires `PowerRequestDisplayRequired`).
    #[serde(default)]
    pub windows_keep_awake_on_battery: bool,
    /// Desktop `bistre-daemon` stays alive after window close strictly while an agent run or cron job is active.
    #[serde(default = "default_true")]
    pub daemon_keep_alive_when_active: bool,
    /// Policy governing Tier-2 actions during unattended/background runs.
    #[serde(default = "default_unattended_policy")]
    pub unattended_policy: UnattendedPolicy,
    /// Maximum total seconds to wait across 429/529 rate-limit backoffs before pausing a long-horizon run.
    #[serde(default = "default_retry_watchdog_max_wait_secs")]
    pub retry_watchdog_max_wait_secs: u32,
    /// Default reasoning effort (`default` | `off` | `low` | `medium` | `high` | `xhigh` | `max`;
    /// see [`ReasoningEffort`]). `default` lets the model decide.
    #[serde(default = "default_reasoning_effort")]
    pub reasoning_effort: String,
    /// Optional Android Termux `RUN_COMMAND` shell bridge toggle (off by default).
    #[serde(default)]
    pub termux_bridge_enabled: bool,
    /// Code-fence wrapping: `auto` (soft-wrap below 640 px), `on`, or `off`.
    #[serde(default = "default_code_wrap_mode")]
    pub code_wrap_mode: String,
    /// Refresh public model prices automatically (at most once per 24 h). Off: prices update
    /// only when the user asks, and unknown prices count as `$0` toward the daily limit.
    #[serde(default = "default_true")]
    pub pricing_auto_refresh: bool,
}

fn default_code_wrap_mode() -> String {
    "auto".to_owned()
}

const fn default_trust_preset() -> TrustPreset {
    TrustPreset::GuidedCraft
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            theme: default_theme(),
            layout_mode: default_layout_mode(),
            locale: default_locale(),
            trust_preset: default_trust_preset(),
            wallet_daily_ceiling_micros: default_wallet_ceiling(),
            wallet_local_first: true,
            provider_stateless_default: true,
            font_scale_bps: default_font_scale_bps(),
            font_size_px: default_font_size_px(),
            line_height_bps: default_line_height_bps(),
            reading_width_px: default_reading_width_px(),
            prose_font_family: String::new(),
            prose_font_path: String::new(),
            mono_font_family: String::new(),
            mono_font_path: String::new(),
            accent_preset: default_accent_preset(),
            custom_accent_hex: String::new(),
            sidebar_open: true,
            send_on_enter: true,
            reduce_motion_override: false,
            show_token_metrics: true,
            active_provider_id: String::new(),
            active_model_id: String::new(),
            ota_feed_url: default_ota_feed_url(),
            ota_channel: default_ota_channel(),
            ota_auto_check: true,
            window_bounds_json: String::new(),
            custom_shortcuts_json: String::new(),
            keep_awake_while_running: true,
            windows_keep_awake_on_battery: false,
            daemon_keep_alive_when_active: true,
            unattended_policy: default_unattended_policy(),
            retry_watchdog_max_wait_secs: default_retry_watchdog_max_wait_secs(),
            reasoning_effort: default_reasoning_effort(),
            termux_bridge_enabled: false,
            code_wrap_mode: default_code_wrap_mode(),
            pricing_auto_refresh: true,
        }
    }
}

/// Strictly Big 3 + Custom OpenAI-Compatible wire dialects (Spec 02).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderDialect {
    OpenAi,
    GoogleGemini,
    Anthropic,
    CustomOpenAi,
}

impl ProviderDialect {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::OpenAi => "openai",
            Self::GoogleGemini => "google_gemini",
            Self::Anthropic => "anthropic",
            Self::CustomOpenAi => "custom_openai",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw {
            "openai" => Self::OpenAi,
            "google_gemini" | "gemini" => Self::GoogleGemini,
            "anthropic" => Self::Anthropic,
            _ => Self::CustomOpenAi,
        }
    }

    /// Official default API root URL for built-in dialects.
    pub const fn default_base_url(self) -> &'static str {
        match self {
            Self::OpenAi => "https://api.openai.com/v1",
            Self::GoogleGemini => "https://generativelanguage.googleapis.com",
            Self::Anthropic => "https://api.anthropic.com/v1",
            Self::CustomOpenAi => "http://127.0.0.1:11434/v1",
        }
    }

    /// Default opaque local icon identifier (zero external references).
    pub const fn default_icon_slug(self) -> &'static str {
        match self {
            Self::OpenAi => "openai",
            Self::GoogleGemini => "gemini",
            Self::Anthropic => "anthropic",
            Self::CustomOpenAi => "server",
        }
    }

    /// Big 3 cloud providers always require an API key; custom endpoints may run locally without one.
    pub const fn requires_api_key(self) -> bool {
        !matches!(self, Self::CustomOpenAi)
    }
}

/// Exact integer generation parameters forwarded cleanly to any LLM wire dialect (zero floats).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenerationParams {
    /// Fixed-point temperature in thousandths (`0..=2000`, e.g., `700` = `0.7`).
    pub temperature_milli: Option<u32>,
    /// Maximum output tokens (`1..=1_000_000`).
    pub max_output_tokens: Option<u32>,
    /// Fixed-point nucleus sampling top-p in thousandths (`0..=1000`, e.g., `950` = `0.95`).
    pub top_p_milli: Option<u32>,
    /// Thinking effort to request; [`ReasoningEffort::ModelDefault`] sends nothing.
    pub reasoning_effort: ReasoningEffort,
}

/// How hard a reasoning model should think. Parsed once from the stored setting; providers
/// map it to their own wire field (`OpenAI` `reasoning.effort`, Anthropic `output_config.effort`,
/// Gemini `thinking_level`). Only sent to models the registry marks as reasoning-capable.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReasoningEffort {
    /// Send no effort field; the provider decides.
    #[default]
    ModelDefault,
    Off,
    Low,
    Medium,
    High,
    ExtraHigh,
    Max,
}

impl ReasoningEffort {
    /// Stable setting key (also the OpenAI/Anthropic wire value where one exists).
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ModelDefault => "default",
            Self::Off => "off",
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
            Self::ExtraHigh => "xhigh",
            Self::Max => "max",
        }
    }

    /// Lenient parse of a stored value; unknown text means the model default.
    pub fn parse(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "off" | "none" => Self::Off,
            "low" | "minimal" => Self::Low,
            "medium" => Self::Medium,
            "high" => Self::High,
            "xhigh" | "extra" | "extra_high" => Self::ExtraHigh,
            "max" => Self::Max,
            _ => Self::ModelDefault,
        }
    }
}

/// Exact integer token usage and estimated micro-USD spend captured from provider SSE streams.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageMetrics {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cached_input_tokens: u64,
    pub estimated_cost_micros: MoneyMicros,
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

    /// Returns `true` when the run is still unfinished and eligible for sleep/crash recovery or active tracking.
    pub const fn is_active(self) -> bool {
        matches!(
            self,
            Self::Running | Self::WaitingApproval | Self::BackoffWait | Self::SleepPaused
        )
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
    PowerSourceChanged { on_ac: bool },
}

/// Monotonically ordered persisted event envelope enabling lossless IPC / FGS resume (`resume_after_cursor`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CursorEventRecord {
    pub cursor: u64,
    pub thread_id: Option<String>,
    pub event: EngineEvent,
    pub created_at_ms: i64,
}

/// Length-prefixed JSON RPC request frame sent from `LocalIpcEngine` to `bistre-daemon`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonRpcRequest {
    pub request_id: u64,
    pub method: String,
    pub params_json: String,
}

/// Length-prefixed JSON RPC response frame returned by `bistre-daemon`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonRpcResponse {
    pub request_id: u64,
    pub ok: bool,
    pub payload_json: String,
    pub error: Option<BistreError>,
}

/// Batched event union streamed from Rust core to UI / IPC subscribers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum EngineEvent {
    RunStarted {
        thread_id: String,
        node_id: String,
    },
    DeltaBatch {
        thread_id: String,
        chunks: Vec<StreamChunk>,
    },
    ThinkingDelta {
        thread_id: String,
        node_id: String,
        delta: String,
    },
    RunFinished {
        thread_id: String,
        node_id: String,
        cancelled: bool,
    },
    RunStateChanged {
        run: AgentRunRecord,
    },
    RunStepUpdated {
        step: RunStepRecord,
    },
    SteeringQueueChanged {
        thread_id: String,
        pending_count: u32,
    },
    PowerStatusChanged {
        status: PowerGuardStatus,
    },
    NodeCommitted {
        node: NodeRecord,
    },
    DraftSaved {
        thread_id: String,
        updated_at_ms: i64,
    },
    DiagnosticRaised {
        key: DiagnosticKey,
        detail_code: Option<String>,
    },
    LocalePackVerified {
        pack_id: String,
        semver: String,
    },
}

/// Locks `mutex`, recovering the inner value if a previous holder panicked.
///
/// The one sanctioned `Mutex::lock` call site (`clippy.toml` bans the raw method). Bistre's
/// mutexes guard plain data that stays valid after a panic, so recovery is correct; it is logged
/// with `what` so a poisoned lock is never silent, and callers never lose a write (such as a
/// Stop request) because of an old panic.
pub fn lock_or_recover<'a, T>(
    mutex: &'a std::sync::Mutex<T>,
    what: &'static str,
) -> std::sync::MutexGuard<'a, T> {
    #[expect(clippy::disallowed_methods, reason = "the single sanctioned lock site")]
    let result = mutex.lock();
    result.unwrap_or_else(|poisoned| {
        tracing::error!(lock = what, "mutex poisoned; recovering its data");
        poisoned.into_inner()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[test]
    fn money_micros_checked_and_saturating_math() {
        let one_dollar = MoneyMicros::from_cents(100);
        assert_eq!(one_dollar, Some(MoneyMicros(1_000_000)));
        assert_eq!(MoneyMicros(i64::MAX).checked_add(MoneyMicros(1)), None);
        assert_eq!(
            MoneyMicros(i64::MAX).saturating_add(MoneyMicros(1)),
            MoneyMicros(i64::MAX)
        );
        assert_eq!(MoneyMicros(i64::MIN).checked_sub(MoneyMicros(1)), None);
    }

    #[test]
    fn diagnostic_key_serializes_stable_dot_key() -> TestResult {
        let json = serde_json::to_string(&DiagnosticKey::StorageDiskFull);
        assert_eq!(json?, "\"diag.storage.disk_full\"");
        assert_eq!(
            DiagnosticKey::CryptoSignatureInvalid.as_key(),
            "diag.crypto.signature_invalid"
        );
        Ok(())
    }
}
