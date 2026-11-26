//! Runtime loaders for persisted provider advanced flags (`provider.adv:<id>`),
//! custom header/body overrides (`provider.overrides:<id>`), default model slots
//! (`settings.default_models`), per-thread spend caps (`thread_spend_limit:<tid>`),
//! and per-thread assistant reply prefill (`thread_reply_prefill:<tid>`).

use bistre_protocol::{BistreError, BistreResult, DiagnosticKey, MoneyMicros};
use bistre_storage::StorageHandle;
use serde_json::{Map, Value};

/// Parsed `provider.adv:<id>` preferences.
#[expect(
    clippy::struct_excessive_bools,
    reason = "Independent per-provider wire-feature flags persisted in kv_meta JSON."
)]
#[derive(Debug, Clone)]
pub struct ProviderAdvancedPrefs {
    pub store_server_side: bool,
    pub use_stateful_chaining: bool,
    pub use_background_polling: bool,
    pub use_legacy_fallback: bool,
    pub anthropic_cache_1h: bool,
    pub enable_server_compaction: bool,
}

impl Default for ProviderAdvancedPrefs {
    fn default() -> Self {
        Self {
            store_server_side: false,
            use_stateful_chaining: false,
            use_background_polling: false,
            use_legacy_fallback: true,
            anthropic_cache_1h: false,
            enable_server_compaction: true,
        }
    }
}

/// Parsed `provider.overrides:<id>` custom headers & body fields.
#[derive(Debug, Default, Clone)]
pub struct ProviderRequestOverrides {
    pub headers: Vec<crate::custom_headers::CustomHeader>,
    pub body_fields: Option<Map<String, Value>>,
}

/// Parsed `settings.default_models` slot routing configuration.
#[derive(Debug, Default, Clone)]
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
}

/// Loads `provider.adv:<provider_id>` from SQLite `kv_meta`, falling back to safe defaults.
pub fn load_provider_advanced(storage: &StorageHandle, provider_id: &str) -> ProviderAdvancedPrefs {
    let key = format!("provider.adv:{provider_id}");
    let Ok(Some(raw)) = storage.get_kv_meta(&key) else {
        return ProviderAdvancedPrefs::default();
    };
    let Ok(val) = serde_json::from_str::<Value>(&raw) else {
        return ProviderAdvancedPrefs::default();
    };
    ProviderAdvancedPrefs {
        store_server_side: val
            .get("storeServerSide")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        use_stateful_chaining: val
            .get("useStatefulChaining")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        use_background_polling: val
            .get("useBackgroundPolling")
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
    }
}

/// Loads the validated custom headers and extra JSON body fields of `provider.overrides:<id>`.
///
/// Fails closed (A-S8): an unreadable entry or any invalid header or body is an error that
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
    }
}

/// Loads the optional per-chat spend cap (`kv_meta["thread_spend_limit:<thread_id>"]`).
///
/// Fails closed (A-S1): a storage error or a value that is not a whole, non-negative number of
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

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn loads_provider_advanced_overrides_and_thread_spend_limit()
    -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempdir()?;
        let storage = StorageHandle::open(dir.path().join("prefs.sqlite"))?;

        storage.set_kv_meta(
            "provider.adv:openai".to_owned(),
            r#"{"storeServerSide":true,"useStatefulChaining":true,"anthropicCache1h":true}"#
                .to_owned(),
        )?;
        let adv = load_provider_advanced(&storage, "openai");
        assert!(adv.store_server_side);
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
        // A-S1: a malformed or negative cap denies instead of silently meaning "no cap".
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
}
