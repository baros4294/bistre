//! Shared protocol types, typed diagnostic keys, exact fixed-point money accounting,
//! and engine DTOs shared across pure Rust core, storage, crypto, FFI, daemon, and updater.
//!
//! Invariants:
//! - Zero English UI sentences; all user-facing diagnostics flow as stable `DiagnosticKey` codes.
//! - Zero floating-point monetary arithmetic; all financial amounts use `MoneyMicros(i64)`.

pub mod story;

use core::fmt;
use serde::{Deserialize, Serialize};

pub mod dialect;
pub use dialect::ProviderDialect;
mod records;
mod settings;
pub mod spend;
pub use records::{
    AgentRunRecord, AssistantPatch, AssistantRecord, AttachmentInput, AttachmentRecord,
    CronJobRecord, DraftRecord, MemoryEntryRecord, ModelCatalogInfo, NodeRecord, PowerGuardStatus,
    ProviderModelInfo, ProviderPatch, ProviderProfile, RunStatus, RunStepKind, RunStepRecord,
    SearchHit, SignedPackManifest, SteeringMessage, StorageFileEntry, StorageStats,
    StoredAttachment, StreamChunk, SystemPowerEvent, ThreadPatch, ThreadSummary, ToolRiskTier,
    UpdateCheckResult, UsageMetrics, WorkspaceCheckpointRecord,
};
pub use settings::{AppSettings, UnattendedPolicy};
pub use spend::{PurposeUsage, SpendPurpose};
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

    #[error("diag.run.interrupted")]
    #[serde(rename = "diag.run.interrupted")]
    RunInterrupted,

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

    /// The provider reported no usage (stream stopped before its usage frame); the request was
    /// billed from the input estimate plus the output counted locally.
    /// The model's price is unknown, so the request cannot be checked against an active cap.
    #[error("diag.wallet.price_unknown")]
    #[serde(rename = "diag.wallet.price_unknown")]
    WalletPriceUnknown,

    #[error("diag.wallet.usage_estimated")]
    #[serde(rename = "diag.wallet.usage_estimated")]
    WalletUsageEstimated,

    /// A disk read or write failed (for example after the computer woke from sleep). The
    /// database connection is reopened; trying again usually works.
    #[error("diag.storage.io_error")]
    #[serde(rename = "diag.storage.io_error")]
    StorageIoError,

    /// A path outside what a tool or import may touch was refused (this used to reuse
    /// the edit hash-mismatch key).
    #[error("diag.tool.path_denied")]
    #[serde(rename = "diag.tool.path_denied")]
    ToolPathDenied,

    /// The run reached its step limit while the model still wanted to go on.
    #[error("diag.run.step_limit_reached")]
    #[serde(rename = "diag.run.step_limit_reached")]
    RunStepLimitReached,

    /// An attachment could not be sent (missing or too large); the model got a note instead.
    #[error("diag.attachment.not_sent")]
    #[serde(rename = "diag.attachment.not_sent")]
    AttachmentNotSent,

    /// Live voice could not start the microphone, so the session was ended.
    #[error("diag.voice.mic_unavailable")]
    #[serde(rename = "diag.voice.mic_unavailable")]
    VoiceMicUnavailable,

    /// The reply hit the model's output limit and stopped early; Continue asks for more.
    #[error("diag.provider.reply_truncated")]
    #[serde(rename = "diag.provider.reply_truncated")]
    ProviderReplyTruncated,

    /// The provider declined or filtered the reply.
    #[error("diag.provider.reply_refused")]
    #[serde(rename = "diag.provider.reply_refused")]
    ProviderReplyRefused,

    /// The update manifest is in a format this version cannot read (reinstall from the
    /// download page once).
    #[error("diag.ota.manifest_unsupported")]
    #[serde(rename = "diag.ota.manifest_unsupported")]
    OtaManifestUnsupported,

    /// The release has no update file for this kind of device.
    #[error("diag.ota.no_asset_for_platform")]
    #[serde(rename = "diag.ota.no_asset_for_platform")]
    OtaNoAssetForPlatform,

    /// The full-text search index is corrupt; search runs as a slower plain scan until it is
    /// rebuilt. Saving messages is never blocked by it.
    #[error("diag.storage.search_index_corrupt")]
    #[serde(rename = "diag.storage.search_index_corrupt")]
    StorageSearchIndexCorrupt,

    /// A node's parent belongs to another thread (or does not exist).
    #[error("diag.storage.parent_thread_mismatch")]
    #[serde(rename = "diag.storage.parent_thread_mismatch")]
    StorageParentThreadMismatch,

    /// The workspace has hooks in `.bistre/hooks.json` that the user has not approved yet.
    #[error("diag.hooks.approval_required")]
    #[serde(rename = "diag.hooks.approval_required")]
    HooksApprovalRequired,

    /// An imported settings file allows more than the current settings (looser trust preset or
    /// a higher or removed spending limit); importing it needs the user's confirmation.
    #[error("diag.import.loosens_safety")]
    #[serde(rename = "diag.import.loosens_safety")]
    ImportLoosensSafety,

    /// The provider this chat or assistant is pinned to is turned off, missing, or has no key.
    #[error("diag.provider.pinned_unavailable")]
    #[serde(rename = "diag.provider.pinned_unavailable")]
    ProviderPinnedUnavailable,

    /// A custom provider header is not allowed (reserved, credential, or not a valid header).
    #[error("diag.provider.headers_invalid")]
    #[serde(rename = "diag.provider.headers_invalid")]
    ProviderHeadersInvalid,

    /// Saved custom headers were removed because the provider's server address changed.
    #[error("diag.provider.headers_cleared")]
    #[serde(rename = "diag.provider.headers_cleared")]
    ProviderHeadersCleared,

    /// The custom request body is not a JSON object.
    #[error("diag.provider.body_invalid")]
    #[serde(rename = "diag.provider.body_invalid")]
    ProviderBodyInvalid,

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
            Self::RunInterrupted => "diag.run.interrupted",
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
            Self::WalletUsageEstimated => "diag.wallet.usage_estimated",
            Self::WalletPriceUnknown => "diag.wallet.price_unknown",
            Self::ToolPathDenied => "diag.tool.path_denied",
            Self::RunStepLimitReached => "diag.run.step_limit_reached",
            Self::AttachmentNotSent => "diag.attachment.not_sent",
            Self::VoiceMicUnavailable => "diag.voice.mic_unavailable",
            Self::ProviderReplyTruncated => "diag.provider.reply_truncated",
            Self::ProviderReplyRefused => "diag.provider.reply_refused",
            Self::OtaManifestUnsupported => "diag.ota.manifest_unsupported",
            Self::OtaNoAssetForPlatform => "diag.ota.no_asset_for_platform",
            Self::StorageIoError => "diag.storage.io_error",
            Self::StorageSearchIndexCorrupt => "diag.storage.search_index_corrupt",
            Self::StorageParentThreadMismatch => "diag.storage.parent_thread_mismatch",
            Self::HooksApprovalRequired => "diag.hooks.approval_required",
            Self::ImportLoosensSafety => "diag.import.loosens_safety",
            Self::ProviderPinnedUnavailable => "diag.provider.pinned_unavailable",
            Self::ProviderHeadersInvalid => "diag.provider.headers_invalid",
            Self::ProviderBodyInvalid => "diag.provider.body_invalid",
            Self::ProviderHeadersCleared => "diag.provider.headers_cleared",
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

/// A project: a named group of chats with a folder they work in and instructions every
/// reply in them reads (a row of `workspaces`; `ThreadSummary::workspace_id` names it). An
/// empty `folder_path` keeps the app's open folders.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectRecord {
    #[serde(default)]
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub folder_path: String,
    #[serde(default)]
    pub instructions: String,
    #[serde(default)]
    pub created_at_ms: i64,
}

/// Trust preset governing automatic tool execution tiers (Spec 06).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustPreset {
    Off,
    #[serde(alias = "parchment", alias = "parchment_safe")]
    Strict,
    GuidedCraft,
    UnchainedSandbox,
}

impl TrustPreset {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Strict => "strict",
            Self::GuidedCraft => "guided_craft",
            Self::UnchainedSandbox => "unchained_sandbox",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "off" => Self::Off,
            "unchained_sandbox" | "sandbox" => Self::UnchainedSandbox,
            "guided_craft" | "guided" => Self::GuidedCraft,
            // "strict", "parchment", "parchment_safe", and any unknown text: unknown text
            // never loosens trust.
            _ => Self::Strict,
        }
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
    Adaptive,
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
            Self::Adaptive => "adaptive",
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
        let norm = raw.trim().to_ascii_lowercase();
        if let Ok(budget) = norm.parse::<u32>() {
            return match budget {
                0 => Self::Off,
                1..=2_048 => Self::Low,
                2_049..=8_192 => Self::Medium,
                8_193..=24_576 => Self::High,
                _ => Self::ExtraHigh,
            };
        }
        match norm.as_str() {
            "adaptive" => Self::Adaptive,
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

pub mod events;
pub use events::{
    CursorEventRecord, DaemonEventFrame, DaemonRpcRequest, DaemonRpcResponse, EngineEvent,
    ToolApprovalDecision,
};

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
