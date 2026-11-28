//! App settings and their stored defaults.

use super::{MoneyMicros, TrustPreset};
use serde::{Deserialize, Serialize};

pub(crate) fn default_theme() -> String {
    "system".to_owned()
}
/// Messenger bubbles by default; the document/page view stays one tap away.
pub(crate) fn default_layout_mode() -> String {
    "bubbles".to_owned()
}
pub(crate) fn default_locale() -> String {
    "en".to_owned()
}
pub(crate) fn default_accent_preset() -> String {
    "brass".to_owned()
}
pub(crate) fn default_font_size_px() -> u32 {
    15
}
pub(crate) fn default_line_height_bps() -> u32 {
    16_000
}
pub(crate) fn default_reading_width_px() -> u32 {
    760
}
pub(crate) fn default_true() -> bool {
    true
}
pub(crate) fn default_ota_channel() -> String {
    "stable".to_owned()
}
pub(crate) fn default_ota_feed_url() -> String {
    "https://github.com/baros4294/bistre/releases/latest/download/manifest.json".to_owned()
}
pub(crate) fn default_reasoning_effort() -> String {
    "default".to_owned()
}
pub(crate) const fn default_retry_watchdog_max_wait_secs() -> u32 {
    1800
}
pub(crate) const fn default_unattended_policy() -> UnattendedPolicy {
    UnattendedPolicy::PauseAndNotify
}
#[expect(
    clippy::unnecessary_wraps,
    reason = "Serde field default callback for Option<MoneyMicros> must return Option<MoneyMicros>."
)]
pub(crate) const fn default_wallet_ceiling() -> Option<MoneyMicros> {
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
    /// The user's name: shown on their messages, and told to the model in chats that do not
    /// bring their own persona (Write mode does). Empty: not shared.
    #[serde(default)]
    pub user_display_name: String,
    /// How full the context window may get (percent) before a run shortens the chat; core
    /// keeps it within the range `compaction` allows.
    #[serde(default = "default_auto_compact_at_percent")]
    pub auto_compact_at_percent: u8,
}

pub(crate) const fn default_auto_compact_at_percent() -> u8 {
    85
}

pub(crate) fn default_code_wrap_mode() -> String {
    "auto".to_owned()
}

pub(crate) const fn default_trust_preset() -> TrustPreset {
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
            user_display_name: String::new(),
            auto_compact_at_percent: default_auto_compact_at_percent(),
        }
    }
}
