//! Runtime loaders for persisted provider advanced flags (`provider.adv:<id>`),
//! custom header/body overrides (`provider.overrides:<id>`), default model slots
//! (`settings.default_models`), per-thread spend caps (`thread_spend_limit:<tid>`),
//! and per-thread assistant reply prefill (`thread_reply_prefill:<tid>`).

use bistre_protocol::MoneyMicros;
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
    pub headers: Vec<(String, String)>,
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

/// Loads sanitized custom headers and extra JSON body fields from `provider.overrides:<provider_id>`.
pub fn load_provider_overrides(
    storage: &StorageHandle,
    provider_id: &str,
) -> ProviderRequestOverrides {
    let key = format!("provider.overrides:{provider_id}");
    let Ok(Some(raw)) = storage.get_kv_meta(&key) else {
        return ProviderRequestOverrides::default();
    };
    let Ok(val) = serde_json::from_str::<Value>(&raw) else {
        return ProviderRequestOverrides::default();
    };
    let mut headers = Vec::new();
    if let Some(h_raw) = val.get("headers_json").and_then(Value::as_str)
        && let Ok(Value::Object(map)) = serde_json::from_str::<Value>(h_raw.trim())
    {
        for (k, v) in map {
            if let Some(s) = v.as_str() {
                headers.push((k, s.to_owned()));
            }
        }
    }
    let body_fields = val
        .get("body_json")
        .and_then(Value::as_str)
        .and_then(|b| serde_json::from_str::<Value>(b.trim()).ok())
        .and_then(|v| match v {
            Value::Object(m) if !m.is_empty() => Some(m),
            _ => None,
        });
    ProviderRequestOverrides {
        headers,
        body_fields,
    }
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

/// Loads optional per-thread spend ceiling (`kv_meta["thread_spend_limit:<thread_id>"]`).
pub fn load_thread_spend_limit(storage: &StorageHandle, thread_id: &str) -> Option<MoneyMicros> {
    let key = format!("thread_spend_limit:{thread_id}");
    let raw = match storage.get_kv_meta(&key) {
        Ok(Some(v)) => v,
        Ok(None) => return None,
        Err(err) => {
            tracing::warn!(key = err.key.as_key(), "thread spend limit lookup failed");
            return None;
        }
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let micros: i64 = trimmed.parse().ok()?;
    (micros > 0).then_some(MoneyMicros(micros))
}

/// Computes cumulative recorded spend on `thread_id` from committed node metadata.
pub fn sum_thread_recorded_spend_micros(storage: &StorageHandle, thread_id: &str) -> MoneyMicros {
    let nodes = match storage.list_nodes(thread_id) {
        Ok(v) => v,
        Err(err) => {
            tracing::warn!(key = err.key.as_key(), "thread spend sum node list failed");
            return MoneyMicros::ZERO;
        }
    };
    let mut total = MoneyMicros::ZERO;
    for node in nodes {
        if let Some(meta) = node.provider_meta_json.as_deref()
            && let Ok(val) = serde_json::from_str::<Value>(meta)
            && let Some(c) = val.get("cost_micros").and_then(Value::as_i64)
            && c > 0
        {
            total = total.saturating_add(MoneyMicros(c));
        }
    }
    total
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
        let ov = load_provider_overrides(&storage, "openai");
        assert_eq!(ov.headers, vec![("X-Custom".to_owned(), "yes".to_owned())]);
        assert_eq!(
            ov.body_fields
                .as_ref()
                .and_then(|m| m.get("seed"))
                .and_then(Value::as_i64),
            Some(42)
        );

        storage.set_kv_meta("thread_spend_limit:t1".to_owned(), "500000".to_owned())?;
        assert_eq!(
            load_thread_spend_limit(&storage, "t1"),
            Some(MoneyMicros(500_000))
        );
        Ok(())
    }
}
