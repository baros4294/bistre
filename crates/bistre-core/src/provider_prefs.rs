//! Runtime loaders for persisted provider advanced flags (`provider.adv:<id>`),
//! custom header/body overrides (`provider.overrides:<id>`), default model slots
//! (`settings.default_models`), per-thread spend caps (`thread_spend_limit:<tid>`),
//! and per-thread assistant reply prefill (`thread_reply_prefill:<tid>`).

use std::collections::HashMap;

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, MoneyMicros, ReasoningEffort};
use bistre_storage::StorageHandle;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::providers::AuthMode;
use crate::registry::{ModelRates, parse_decimal_scaled};

/// Per-model limits and USD/1M price overrides saved under `provider.adv:<id>`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ModelOverride {
    pub context_tokens: Option<u32>,
    pub max_output_tokens: Option<u32>,
    pub input_per_mtok: Option<i64>,
    pub output_per_mtok: Option<i64>,
    pub cached_input_per_mtok: Option<i64>,
    pub cache_write_per_mtok: Option<i64>,
    pub cache_write_1h_per_mtok: Option<i64>,
    pub reasoning_per_mtok: Option<i64>,
}

impl ModelOverride {
    fn from_json(val: &Value) -> Self {
        let pos_u32 = |name: &str| {
            val.get(name)
                .and_then(Value::as_u64)
                .filter(|&n| n > 0)
                .and_then(|n| u32::try_from(n).ok())
        };
        let price = |name: &str| {
            val.get(name)
                .and_then(Value::as_str)
                .and_then(|s| parse_decimal_scaled(s, 6))
        };
        Self {
            context_tokens: pos_u32("contextLimit"),
            max_output_tokens: pos_u32("maxOutputTokens"),
            input_per_mtok: price("inputPerMillion"),
            output_per_mtok: price("outputPerMillion"),
            cached_input_per_mtok: price("cacheReadPerMillion"),
            cache_write_per_mtok: price("cacheWritePerMillion"),
            cache_write_1h_per_mtok: price("cacheWriteLongPerMillion"),
            reasoning_per_mtok: price("reasoningPerMillion"),
        }
    }

    /// Applies this override over registry `base` rates. When `base` is absent, rates are
    /// synthesized only if the user gave both input and output prices (fail closed: setting
    /// only context or reply limits never turns an unpriced model into `$0`).
    #[must_use]
    pub fn apply_to_rates(&self, base: Option<ModelRates>) -> Option<ModelRates> {
        let mut rates = match base {
            Some(r) => r,
            None => ModelRates {
                input_per_mtok: self.input_per_mtok?,
                output_per_mtok: self.output_per_mtok?,
                ..ModelRates::default()
            },
        };
        if let Some(v) = self.input_per_mtok {
            rates.input_per_mtok = v;
        }
        if let Some(v) = self.output_per_mtok {
            rates.output_per_mtok = v;
        }
        if let Some(v) = self.cached_input_per_mtok {
            rates.cached_input_per_mtok = Some(v);
        }
        if let Some(v) = self.cache_write_per_mtok {
            rates.cache_write_per_mtok = Some(v);
        }
        if let Some(v) = self.cache_write_1h_per_mtok {
            rates.cache_write_1h_per_mtok = Some(v);
        }
        if let Some(v) = self.reasoning_per_mtok {
            rates.reasoning_per_mtok = Some(v);
        }
        if let Some(v) = self.context_tokens {
            rates.context_tokens = Some(v);
        }
        if let Some(v) = self.max_output_tokens {
            rates.max_output_tokens = Some(v);
        }
        Some(rates)
    }
}

/// Parsed `provider.adv:<id>` preferences.
#[expect(
    clippy::struct_excessive_bools,
    reason = "Independent per-provider wire-feature flags persisted in kv_meta JSON."
)]
#[derive(Debug, Clone)]
pub struct ProviderAdvancedPrefs {
    /// The wire format a Custom provider speaks (Advanced > API format); `None` keeps
    /// OpenAI-compatible Chat Completions.
    pub custom_dialect: Option<bistre_protocol::ProviderDialect>,
    /// A replacement request path after the base URL (Advanced > Endpoint path).
    pub endpoint_path: Option<String>,
    /// How the API key is sent (Advanced > Authentication).
    pub auth_mode: AuthMode,
    /// Per-provider default thinking effort used when the global effort is `ModelDefault`.
    pub default_thinking_effort: ReasoningEffort,
    pub use_stateful_chaining: bool,
    pub use_legacy_fallback: bool,
    pub anthropic_cache_1h: bool,
    pub enable_server_compaction: bool,
    /// Advanced > the provider's own tools (Gemini `url_context` and `code_execution`,
    /// Anthropic `web_fetch` and `code_execution`), sent beside Bistre's tools.
    pub provider_tools: bool,
    /// Advanced > the provider's tools billed per call (Anthropic and `OpenAI` web search,
    /// `OpenAI` code interpreter); their fee is counted after the reply.
    pub paid_provider_tools: bool,
    pub model_overrides: HashMap<String, ModelOverride>,
}

impl Default for ProviderAdvancedPrefs {
    fn default() -> Self {
        Self {
            custom_dialect: None,
            endpoint_path: None,
            auth_mode: AuthMode::Native,
            default_thinking_effort: ReasoningEffort::ModelDefault,
            use_stateful_chaining: false,
            use_legacy_fallback: true,
            anthropic_cache_1h: false,
            enable_server_compaction: true,
            provider_tools: false,
            paid_provider_tools: false,
            model_overrides: HashMap::new(),
        }
    }
}

/// `raw` as a request path, or `None` when empty or not a plain path: it must start with
/// `/` and hold no scheme, host, query, fragment, `..`, or spaces (at most 256 bytes).
fn endpoint_path(raw: &str) -> Option<String> {
    let plain = raw.starts_with('/')
        && raw.len() <= 256
        && !raw.contains("//")
        && !raw.contains("..")
        && !raw
            .chars()
            .any(|c| c.is_whitespace() || matches!(c, '?' | '#' | '@' | '\\'));
    plain.then(|| raw.to_owned())
}

impl ProviderAdvancedPrefs {
    /// `provider` as it is called: a Custom provider speaks its chosen API format.
    pub fn speaking(
        &self,
        provider: &bistre_protocol::ProviderProfile,
    ) -> bistre_protocol::ProviderProfile {
        let mut wired = provider.clone();
        if provider.dialect == bistre_protocol::ProviderDialect::CustomOpenAi
            && let Some(dialect) = self.custom_dialect
        {
            wired.dialect = dialect;
        }
        wired
    }

    /// Registry rates for `model` overlaid with any per-model override saved for this provider.
    #[must_use]
    pub fn resolve_rates(&self, model: &str, base: Option<ModelRates>) -> Option<ModelRates> {
        match self.model_overrides.get(model) {
            Some(ov) => ov.apply_to_rates(base),
            None => base,
        }
    }

    /// Effective conversation limit for `model`: per-model override wins over the registry.
    #[must_use]
    pub fn context_tokens(&self, model: &str, base: Option<ModelRates>) -> Option<u32> {
        self.model_overrides
            .get(model)
            .and_then(|ov| ov.context_tokens)
            .or_else(|| base.and_then(|r| r.context_tokens))
    }

    /// Effective reply-token override for `model`, when set in Per-Model Settings.
    #[must_use]
    pub fn max_output_tokens(&self, model: &str) -> Option<u32> {
        self.model_overrides
            .get(model)
            .and_then(|ov| ov.max_output_tokens)
    }
}

/// Whether a chat request asks the provider to keep it on its server (`store`, Gemini
/// interactions): the one decision the request, chaining, and the saved reply share.
/// Private requests (Safety & Budget, on by default) never store; otherwise the provider's
/// Allow server-side storage switch (its Advanced settings) decides.
pub fn stores_on_server(private_requests: bool, server_storage: bool) -> bool {
    !private_requests && server_storage
}

/// Parsed `provider.overrides:<id>` custom headers & body fields.
#[derive(Debug, Default, Clone)]
pub struct ProviderRequestOverrides {
    pub headers: Vec<crate::custom_headers::CustomHeader>,
    pub body_fields: Option<Map<String, Value>>,
}

/// Parsed `settings.default_models` slot routing configuration.
#[derive(Debug, Clone)]
pub struct DefaultModelsPrefs {
    pub global_provider_id: String,
    pub global_model_id: String,
    pub title_follow_global: bool,
    pub title_provider_id: String,
    pub title_model_id: String,
    pub title_prompt_template: String,
    pub summary_follow_global: bool,
    pub summary_provider_id: String,
    pub summary_model_id: String,
    pub translation_follow_global: bool,
    pub translation_provider_id: String,
    pub translation_model_id: String,
    pub translation_target_language: String,
}

impl Default for DefaultModelsPrefs {
    fn default() -> Self {
        Self {
            global_provider_id: String::new(),
            global_model_id: String::new(),
            title_follow_global: true,
            title_provider_id: String::new(),
            title_model_id: String::new(),
            title_prompt_template: String::new(),
            summary_follow_global: true,
            summary_provider_id: String::new(),
            summary_model_id: String::new(),
            translation_follow_global: true,
            translation_provider_id: String::new(),
            translation_model_id: String::new(),
            translation_target_language: "English".to_owned(),
        }
    }
}

/// The API formats a Custom provider can speak, as saved under `customDialect` (any other value,
/// including the default `openai_chat`, means Chat Completions).
const CUSTOM_DIALECTS: [(&str, bistre_protocol::ProviderDialect); 3] = [
    ("openai_responses", bistre_protocol::ProviderDialect::OpenAi),
    (
        "anthropic_messages",
        bistre_protocol::ProviderDialect::Anthropic,
    ),
    (
        "gemini_interactions",
        bistre_protocol::ProviderDialect::GoogleGemini,
    ),
];

/// Loads `provider.adv:<provider_id>` from SQLite `kv_meta`, falling back to safe defaults.
pub fn load_provider_advanced(storage: &StorageHandle, provider_id: &str) -> ProviderAdvancedPrefs {
    let key = format!("provider.adv:{provider_id}");
    let Ok(Some(raw)) = storage.get_kv_meta(&key) else {
        return ProviderAdvancedPrefs::default();
    };
    let Ok(val) = serde_json::from_str::<Value>(&raw) else {
        return ProviderAdvancedPrefs::default();
    };
    let text = |name: &str| val.get(name).and_then(Value::as_str).unwrap_or("").trim();
    let model_overrides = val
        .get("modelOverrides")
        .and_then(Value::as_object)
        .map_or_default(|obj| {
            obj.iter()
                .filter_map(|(k, v)| {
                    let clean = k.trim();
                    (!clean.is_empty() && v.is_object())
                        .then(|| (clean.to_owned(), ModelOverride::from_json(v)))
                })
                .collect()
        });
    ProviderAdvancedPrefs {
        custom_dialect: CUSTOM_DIALECTS
            .iter()
            .find(|(id, _)| *id == text("customDialect"))
            .map(|(_, d)| *d),
        endpoint_path: endpoint_path(text("endpointPathOverride")),
        auth_mode: match text("authHeaderMode") {
            "bearer_only" => AuthMode::Bearer,
            "query_param" => AuthMode::Query,
            _ => AuthMode::Native,
        },
        default_thinking_effort: ReasoningEffort::parse(text("defaultThinkingEffort")),
        use_stateful_chaining: val
            .get("useStatefulChaining")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        use_legacy_fallback: val
            .get("useLegacyFallback")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        anthropic_cache_1h: val
            .get("anthropicCache1h")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        enable_server_compaction: val
            .get("enableServerCompaction")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        provider_tools: val
            .get("providerTools")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        paid_provider_tools: val
            .get("paidProviderTools")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        model_overrides,
    }
}

/// Loads the validated custom headers and extra JSON body fields of `provider.overrides:<id>`.
///
/// Fails closed: an unreadable entry or any invalid header or body is an error that
/// stops the request, never a silently dropped header.
pub fn load_provider_overrides(
    storage: &StorageHandle,
    provider_id: &str,
) -> BistreResult<ProviderRequestOverrides> {
    let key = format!("provider.overrides:{provider_id}");
    let Some(raw) = storage.get_kv_meta(&key)? else {
        return Ok(ProviderRequestOverrides::default());
    };
    if raw.trim().is_empty() {
        return Ok(ProviderRequestOverrides::default());
    }
    let val: Value = serde_json::from_str(&raw).map_err(|_| {
        BistreError::with_detail(
            DiagnosticKey::ProviderHeadersInvalid,
            "overrides_unreadable",
        )
    })?;
    let text = |field: &str| val.get(field).and_then(Value::as_str).unwrap_or_default();
    Ok(ProviderRequestOverrides {
        headers: crate::custom_headers::parse_custom_headers(text("headers_json"))?,
        body_fields: crate::custom_headers::parse_custom_body(text("body_json"))?,
    })
}

/// Validates and stores custom headers and body fields for `provider_id`, bound to the
/// provider's current origin. An invalid header or body is refused before anything is saved.
pub fn save_provider_overrides(
    storage: &StorageHandle,
    provider_id: &str,
    base_url: &str,
    headers_json: &str,
    body_json: &str,
) -> BistreResult<()> {
    crate::custom_headers::parse_custom_headers(headers_json)?;
    crate::custom_headers::parse_custom_body(body_json)?;
    let stored = serde_json::json!({
        "headers_json": headers_json.trim(),
        "body_json": body_json.trim(),
        "origin": crate::custom_headers::origin_of(base_url),
    });
    storage.set_kv_meta(
        format!("provider.overrides:{provider_id}"),
        stored.to_string(),
    )
}

/// Clears saved custom headers (body fields stay) when a provider's origin changes, so
/// headers meant for one server are never sent to another.
pub fn drop_headers_if_origin_changed(
    storage: &StorageHandle,
    provider_id: &str,
    new_base_url: &str,
) -> BistreResult<bool> {
    let key = format!("provider.overrides:{provider_id}");
    let Some(raw) = storage.get_kv_meta(&key)? else {
        return Ok(false);
    };
    let Ok(Value::Object(mut map)) = serde_json::from_str::<Value>(&raw) else {
        return Ok(false);
    };
    let saved_origin = map.get("origin").and_then(Value::as_str).map(str::to_owned);
    let has_headers = map
        .get("headers_json")
        .and_then(Value::as_str)
        .is_some_and(|h| !h.trim().is_empty());
    let new_origin = crate::custom_headers::origin_of(new_base_url);
    if !has_headers || saved_origin.is_some_and(|o| Some(o) == new_origin) {
        return Ok(false);
    }
    map.insert("headers_json".to_owned(), Value::String(String::new()));
    map.insert(
        "origin".to_owned(),
        new_origin.map_or(Value::Null, Value::String),
    );
    storage.set_kv_meta(key, Value::Object(map).to_string())?;
    Ok(true)
}
/// Loads `settings.default_models` from SQLite `kv_meta`.
pub fn load_default_models(storage: &StorageHandle) -> DefaultModelsPrefs {
    let Ok(Some(raw)) = storage.get_kv_meta("settings.default_models") else {
        return DefaultModelsPrefs::default();
    };
    let Ok(val) = serde_json::from_str::<Value>(&raw) else {
        return DefaultModelsPrefs::default();
    };
    let get_s = |k: &str| {
        val.get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_owned()
    };
    let target_lang = get_s("translationTargetLanguage");
    DefaultModelsPrefs {
        global_provider_id: get_s("globalProviderId"),
        global_model_id: get_s("globalModelId"),
        title_follow_global: val
            .get("titleFollowGlobal")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        title_provider_id: get_s("titleProviderId"),
        title_model_id: get_s("titleModelId"),
        title_prompt_template: get_s("titlePromptTemplate"),
        summary_follow_global: val
            .get("summaryFollowGlobal")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        summary_provider_id: get_s("summaryProviderId"),
        summary_model_id: get_s("summaryModelId"),
        translation_follow_global: val
            .get("translationFollowGlobal")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        translation_provider_id: get_s("translationProviderId"),
        translation_model_id: get_s("translationModelId"),
        translation_target_language: if target_lang.is_empty() {
            "English".to_owned()
        } else {
            target_lang
        },
    }
}

/// Loads the optional per-chat spend cap (`kv_meta["thread_spend_limit:<thread_id>"]`).
///
/// Fails closed: a storage error or a value that is not a whole, non-negative number of
/// micro-USD is an error that denies the paid request, never "no cap". An empty value means no
/// cap; `0` is a cap of zero.
pub fn load_thread_spend_limit(
    storage: &StorageHandle,
    thread_id: &str,
) -> BistreResult<Option<MoneyMicros>> {
    let key = format!("thread_spend_limit:{thread_id}");
    let raw = storage.get_kv_meta(&key).map_err(|err| {
        BistreError::with_detail(DiagnosticKey::WalletCheckUnavailable, err.key.as_key())
    })?;
    let Some(raw) = raw else { return Ok(None) };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    match trimmed.parse::<i64>() {
        Ok(micros) if micros >= 0 => Ok(Some(MoneyMicros(micros))),
        _ => Err(BistreError::with_detail(
            DiagnosticKey::WalletCheckUnavailable,
            "thread_spend_limit_malformed",
        )),
    }
}
/// Loads optional per-thread assistant reply prefill (`kv_meta["thread_reply_prefill:<thread_id>"]`).
pub fn load_thread_reply_prefill(storage: &StorageHandle, thread_id: &str) -> Option<String> {
    let key = format!("thread_reply_prefill:{thread_id}");
    match storage.get_kv_meta(&key) {
        Ok(v) => v.filter(|s| !s.trim().is_empty()),
        Err(err) => {
            tracing::warn!(key = err.key.as_key(), "thread reply prefill lookup failed");
            None
        }
    }
}

/// Prefix for portable provider share codes (`ai-provider:v1:<base64url JSON>`).
pub const PROVIDER_SHARE_PREFIX: &str = "ai-provider:v1:";
const MAX_PROVIDER_SHARE_BYTES: usize = 16 * 1024;

/// Portable provider configuration payload for `ai-provider:v1:` import/export.
/// API keys are excluded by default (`api_key: None`) unless explicitly opted in by the user.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSharePayload {
    pub name: String,
    pub dialect: String,
    pub base_url: String,
    #[serde(default)]
    pub default_model: String,
    #[serde(default)]
    pub custom_dialect: String,
    #[serde(default)]
    pub endpoint_path: String,
    #[serde(default)]
    pub auth_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
}

/// Encodes a provider profile and its advanced settings as an `ai-provider:v1:` share code.
/// Pass `include_api_key = None` (default) to exclude credentials.
pub fn export_provider_share_code(
    profile: &bistre_protocol::ProviderProfile,
    adv: &ProviderAdvancedPrefs,
    include_api_key: Option<&str>,
) -> BistreResult<String> {
    use base64::Engine as _;
    let payload = ProviderSharePayload {
        name: profile.name.clone(),
        dialect: profile.dialect.as_str().to_owned(),
        base_url: profile.base_url.clone(),
        default_model: profile.default_model.clone(),
        custom_dialect: CUSTOM_DIALECTS
            .iter()
            .find(|(_, d)| Some(*d) == adv.custom_dialect)
            .map_or_else(String::new, |(id, _)| (*id).to_owned()),
        endpoint_path: adv.endpoint_path.clone().unwrap_or_default(),
        auth_mode: match adv.auth_mode {
            AuthMode::Native => "native",
            AuthMode::Bearer => "bearer",
            AuthMode::Query => "query",
        }
        .to_owned(),
        api_key: include_api_key
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned),
    };
    let json_bytes = serde_json::to_vec(&payload)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "share_encode"))?;
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json_bytes);
    Ok(format!("{PROVIDER_SHARE_PREFIX}{b64}"))
}

/// Decodes and validates an `ai-provider:v1:` share code (fail closed on bad prefix, oversized
/// payload, or non-HTTP(S) base URL).
pub fn import_provider_share_code(raw: &str) -> BistreResult<ProviderSharePayload> {
    use base64::Engine as _;
    let clean = raw.trim();
    if clean.len() > MAX_PROVIDER_SHARE_BYTES {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "share_code_too_large",
        ));
    }
    let body = clean.strip_prefix(PROVIDER_SHARE_PREFIX).ok_or_else(|| {
        BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_share_prefix")
    })?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(body)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_share_b64"))?;
    let payload: ProviderSharePayload = serde_json::from_slice(&bytes)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_share_json"))?;
    let parsed_url = reqwest::Url::parse(payload.base_url.trim())
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "invalid_share_url"))?;
    if !matches!(parsed_url.scheme(), "http" | "https") {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_share_url",
        ));
    }
    if payload.name.trim().is_empty() {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_share_name",
        ));
    }
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    /// A Custom provider speaks the API format chosen in Advanced; a built-in provider keeps
    /// its own. Only a plain path is taken as the endpoint path.
    #[test]
    fn a_custom_provider_speaks_its_chosen_format() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("prefs.sqlite"))?;
        storage.set_kv_meta(
            "provider.adv:custom".to_owned(),
            r#"{"customDialect":"anthropic_messages","endpointPathOverride":"/gw/v1/messages","authHeaderMode":"bearer_only"}"#.to_owned(),
        )?;
        let adv = load_provider_advanced(&storage, "custom");
        let mut custom = crate::test_support::provider(
            bistre_protocol::ProviderDialect::CustomOpenAi,
            "https://gw.example/v1",
        );
        custom.id = "custom".to_owned();
        assert_eq!(
            adv.speaking(&custom).dialect,
            bistre_protocol::ProviderDialect::Anthropic
        );
        let builtin = crate::test_support::provider(
            bistre_protocol::ProviderDialect::OpenAi,
            "https://api.example/v1",
        );
        assert_eq!(adv.speaking(&builtin).dialect, builtin.dialect);
        assert_eq!(adv.endpoint_path.as_deref(), Some("/gw/v1/messages"));
        assert_eq!(adv.auth_mode, AuthMode::Bearer);
        for bad in [
            "https://evil.example/x",
            "/a?b=1",
            "/../x",
            "x/y",
            "/a b",
            "//host/x",
        ] {
            assert_eq!(endpoint_path(bad), None, "{bad}");
        }
        Ok(())
    }

    /// One decision: Private requests never store, whatever the provider allows.
    #[test]
    fn private_requests_never_store_and_the_provider_switch_does() {
        assert!(!stores_on_server(true, true));
        assert!(!stores_on_server(false, false));
        assert!(stores_on_server(false, true));
    }

    #[test]
    fn loads_provider_advanced_overrides_and_thread_spend_limit()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("prefs.sqlite"))?;

        storage.set_kv_meta(
            "provider.adv:openai".to_owned(),
            r#"{"useStatefulChaining":true,"anthropicCache1h":true}"#.to_owned(),
        )?;
        let adv = load_provider_advanced(&storage, "openai");
        assert!(adv.use_stateful_chaining);
        assert!(adv.anthropic_cache_1h);

        storage.set_kv_meta(
            "provider.overrides:openai".to_owned(),
            r#"{"headers_json":"{\"X-Custom\":\"yes\"}","body_json":"{\"seed\":42}"}"#.to_owned(),
        )?;
        let ov = load_provider_overrides(&storage, "openai")?;
        assert_eq!(
            ov.headers
                .iter()
                .map(|h| h.name().as_str())
                .collect::<Vec<_>>(),
            ["x-custom"]
        );
        assert_eq!(
            ov.body_fields
                .as_ref()
                .and_then(|m| m.get("seed"))
                .and_then(Value::as_i64),
            Some(42)
        );

        storage.set_kv_meta("thread_spend_limit:t1".to_owned(), "500000".to_owned())?;
        assert_eq!(
            load_thread_spend_limit(&storage, "t1")?,
            Some(MoneyMicros(500_000))
        );
        // A malformed or negative cap denies instead of silently meaning "no cap".
        for bad in ["5 dollars", "-1", "1.5"] {
            storage.set_kv_meta("thread_spend_limit:t1".to_owned(), bad.to_owned())?;
            assert_eq!(
                load_thread_spend_limit(&storage, "t1")
                    .err()
                    .and_then(|e| e.detail_code),
                Some("thread_spend_limit_malformed".to_owned()),
                "{bad}"
            );
        }
        storage.set_kv_meta("thread_spend_limit:t1".to_owned(), String::new())?;
        assert_eq!(load_thread_spend_limit(&storage, "t1")?, None);
        Ok(())
    }

    /// Per-model overrides replace registry limits and prices (including reasoning and cache
    /// tiers) using exact integer micro-USD math, and keep an unpriced model fail-closed when
    /// only limits were overridden.
    #[test]
    fn model_overrides_feed_limits_and_wallet_rates_fail_closed()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("prefs.sqlite"))?;
        storage.set_kv_meta(
            "provider.adv:p1".to_owned(),
            serde_json::json!({
                "defaultThinkingEffort": "xhigh",
                "modelOverrides": {
                    "limits-only": {
                        "contextLimit": 32_000,
                        "maxOutputTokens": 2048
                    },
                    "custom-priced": {
                        "contextLimit": 64_000,
                        "maxOutputTokens": 4096,
                        "inputPerMillion": "2.50",
                        "outputPerMillion": "10.00",
                        "cacheReadPerMillion": "0.50",
                        "cacheWritePerMillion": "3.00",
                        "cacheWriteLongPerMillion": "5.00",
                        "reasoningPerMillion": "20.00"
                    }
                }
            })
            .to_string(),
        )?;
        let adv = load_provider_advanced(&storage, "p1");
        assert_eq!(adv.default_thinking_effort, ReasoningEffort::ExtraHigh);
        assert_eq!(adv.context_tokens("limits-only", None), Some(32_000));
        assert_eq!(adv.max_output_tokens("limits-only"), Some(2048));
        // Fail closed: limits-only override on an unknown model never turns it into $0.
        assert_eq!(adv.resolve_rates("limits-only", None), None);

        let rates = adv
            .resolve_rates("custom-priced", None)
            .ok_or("priced override must produce ModelRates")?;
        assert_eq!(rates.input_per_mtok, 2_500_000);
        assert_eq!(rates.output_per_mtok, 10_000_000);
        assert_eq!(rates.cached_input_per_mtok, Some(500_000));
        assert_eq!(rates.cache_write_per_mtok, Some(3_000_000));
        assert_eq!(rates.cache_write_1h_per_mtok, Some(5_000_000));
        assert_eq!(rates.reasoning_per_mtok, Some(20_000_000));
        // Gemini: 1M input ($2.50) + 1M output ($10) + 500k reasoning ($10) = $22.50.
        let usage = bistre_protocol::UsageMetrics {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            reasoning_tokens: 500_000,
            ..bistre_protocol::UsageMetrics::default()
        };
        assert_eq!(
            rates
                .cost_for_dialect(bistre_protocol::ProviderDialect::GoogleGemini, &usage)
                .map(MoneyMicros::as_micros),
            Some(22_500_000)
        );
        Ok(())
    }

    #[test]
    fn provider_share_code_excludes_api_key_by_default_and_validates_url()
    -> Result<(), Box<dyn std::error::Error>> {
        let profile = bistre_protocol::ProviderProfile {
            id: "custom-1".to_owned(),
            name: "Local Ollama".to_owned(),
            dialect: bistre_protocol::ProviderDialect::CustomOpenAi,
            base_url: "http://127.0.0.1:11434/v1".to_owned(),
            default_model: "local-model".to_owned(),
            key_hint: String::new(),
            has_api_key: true,
            is_enabled: true,
            is_builtin: false,
            use_server_state_cache: false,
            icon_slug: String::new(),
            custom_icon_path: String::new(),
            created_at_ms: 0,
            updated_at_ms: 0,
        };
        let adv = ProviderAdvancedPrefs {
            auth_mode: AuthMode::Bearer,
            endpoint_path: Some("/v1/chat/completions".to_owned()),
            ..ProviderAdvancedPrefs::default()
        };
        let code = export_provider_share_code(&profile, &adv, None)?;
        assert!(code.starts_with(PROVIDER_SHARE_PREFIX));
        let imported = import_provider_share_code(&code)?;
        assert_eq!(imported.name, "Local Ollama");
        assert_eq!(imported.api_key, None);
        assert_eq!(imported.auth_mode, "bearer");

        let mut bad = profile;
        bad.base_url = "file:///etc/passwd".to_owned();
        let bad_code = export_provider_share_code(&bad, &adv, None)?;
        assert!(import_provider_share_code(&bad_code).is_err());
        Ok(())
    }
}
