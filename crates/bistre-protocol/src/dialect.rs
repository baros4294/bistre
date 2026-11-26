//! The provider wire dialects and the facts every caller shares about them (Spec 02, P7).

use serde::{Deserialize, Serialize};

/// Strictly Big 3 + Custom OpenAI-Compatible wire dialects (Spec 02).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderDialect {
    OpenAi,
    GoogleGemini,
    Anthropic,
    CustomOpenAi,
}

/// Anthropic `anthropic-version` request header value (the Messages API version).
pub const ANTHROPIC_API_VERSION: &str = "2023-06-01";
/// Anthropic beta flag for the Files API (`anthropic-beta`).
pub const ANTHROPIC_BETA_FILES: &str = "files-api-2025-04-14";
/// Anthropic beta flag for server-side context management (`anthropic-beta`).
pub const ANTHROPIC_BETA_CONTEXT_MANAGEMENT: &str = "context-management-2025-06-27";

impl ProviderDialect {
    /// Every dialect, in the order the app lists them.
    pub const ALL: [Self; 4] = [
        Self::OpenAi,
        Self::GoogleGemini,
        Self::Anthropic,
        Self::CustomOpenAi,
    ];

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

    /// The main chat endpoint, relative to [`Self::api_root`] (P7: one source for every caller).
    pub const fn default_endpoint_path(self) -> &'static str {
        match self {
            Self::OpenAi => "/responses",
            Self::GoogleGemini => "/v1beta/interactions",
            Self::Anthropic => "/messages",
            Self::CustomOpenAi => "/chat/completions",
        }
    }

    /// The model list endpoint, relative to [`Self::api_root`].
    pub const fn models_path(self) -> &'static str {
        match self {
            Self::GoogleGemini => "/v1beta/models",
            Self::OpenAi | Self::Anthropic | Self::CustomOpenAi => "/models",
        }
    }

    /// The base URL that endpoint paths are appended to: trimmed, without a trailing `/`.
    /// Gemini paths carry their own API version, so a base that already ends in `/v1beta` or
    /// `/v1` (as the old preset did) is reduced to the host root (S4: never `/v1beta/v1beta`).
    pub fn api_root(self, base: &str) -> &str {
        let trimmed = base.trim().trim_end_matches('/');
        if self != Self::GoogleGemini {
            return trimmed;
        }
        trimmed
            .strip_suffix("/v1beta")
            .or_else(|| trimmed.strip_suffix("/v1"))
            .unwrap_or(trimmed)
            .trim_end_matches('/')
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
