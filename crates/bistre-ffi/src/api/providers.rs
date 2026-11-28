//! Provider and assistant FFI entrypoints: profiles, keys, dialects, endpoints, and model lists.

use super::{
    current_engine, frb, map_assistant, map_provider, AssistantPatch, FfiAssistantRecord,
    FfiProviderModelInfo, FfiProviderProfile, ProviderDialect, ProviderPatch, ThreadMode,
};

/// Lists built-in (Big 3) and user-added custom provider profiles.
#[frb]
pub async fn list_providers() -> Result<Vec<FfiProviderProfile>, String> {
    let engine = current_engine()?;
    let list = engine
        .list_providers()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(list.into_iter().map(map_provider).collect())
}

/// The facts the provider settings show for one API format: one source, in core.
#[derive(Debug, Clone)]
pub struct FfiDialectDescriptor {
    pub id: String,
    pub default_base_url: String,
    pub endpoint_path: String,
    pub requires_api_key: bool,
}

/// Every API format with its default server URL and chat endpoint path.
#[frb(sync)]
pub fn provider_dialect_descriptors() -> Vec<FfiDialectDescriptor> {
    ProviderDialect::ALL
        .into_iter()
        .map(|d| FfiDialectDescriptor {
            id: d.as_str().to_owned(),
            default_base_url: d.default_base_url().to_owned(),
            endpoint_path: d.default_endpoint_path().to_owned(),
            requires_api_key: d.requires_api_key(),
        })
        .collect()
}

/// The chat and model-list URLs a provider with this format and server URL is called at.
#[derive(Debug, Clone)]
pub struct FfiResolvedEndpoint {
    pub chat_url: String,
    pub models_url: String,
}

/// Resolves a provider's URLs exactly as requests build them (empty server URL: the default).
#[frb(sync)]
pub fn resolve_provider_endpoint(dialect: String, base_url: String) -> FfiResolvedEndpoint {
    let r = bistre_core::credentials::resolve_endpoint(ProviderDialect::parse(&dialect), &base_url);
    FfiResolvedEndpoint {
        chat_url: r.chat_url,
        models_url: r.models_url,
    }
}

/// Updates non-secret provider metadata (name, base URL, default model, enabled, cache toggle, icon).
#[frb]
#[expect(
    clippy::too_many_arguments,
    reason = "Flat FRB v2 boundary avoids deeply nested patch structs."
)]
pub async fn update_provider(
    provider_id: String,
    name: Option<String>,
    base_url: Option<String>,
    default_model: Option<String>,
    is_enabled: Option<bool>,
    use_server_state_cache: Option<bool>,
    icon_slug: Option<String>,
    custom_icon_path: Option<String>,
) -> Result<FfiProviderProfile, String> {
    let engine = current_engine()?;
    let updated = engine
        .update_provider(
            provider_id,
            ProviderPatch {
                name,
                base_url,
                default_model,
                key_hint: None,
                is_enabled,
                use_server_state_cache,
                icon_slug,
                custom_icon_path,
            },
        )
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_provider(updated))
}

/// Stores an API key strictly in the node-local OS `SecretVault` (Windows DPAPI / OS vault).
#[frb]
pub async fn set_provider_api_key(
    provider_id: String,
    api_key: String,
) -> Result<FfiProviderProfile, String> {
    let engine = current_engine()?;
    let updated = engine
        .set_provider_api_key(provider_id, api_key)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_provider(updated))
}

/// Removes a stored API key from the node-local `SecretVault`.
#[frb]
pub async fn clear_provider_api_key(provider_id: String) -> Result<FfiProviderProfile, String> {
    let engine = current_engine()?;
    let updated = engine
        .clear_provider_api_key(provider_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_provider(updated))
}

/// Creates a provider of any supported dialect (`openai`, `google_gemini`, `anthropic`, `custom_openai`).
#[frb]
pub async fn create_provider(
    name: String,
    dialect: String,
    base_url: String,
    default_model: String,
    icon_slug: String,
    custom_icon_path: String,
    api_key: Option<String>,
) -> Result<FfiProviderProfile, String> {
    let engine = current_engine()?;
    let created = engine
        .create_provider(
            name,
            ProviderDialect::parse(&dialect),
            base_url,
            default_model,
            icon_slug,
            custom_icon_path,
            api_key,
        )
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_provider(created))
}

/// Adds a user-defined Custom OpenAI-Compatible provider profile.
#[frb]
pub async fn create_custom_provider(
    name: String,
    base_url: String,
    default_model: String,
    api_key: Option<String>,
) -> Result<FfiProviderProfile, String> {
    let engine = current_engine()?;
    let created = engine
        .create_custom_provider(name, base_url, default_model, api_key)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_provider(created))
}

/// Removes any provider profile and deletes its key from `SecretVault`.
#[frb]
pub async fn delete_provider(provider_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_provider(provider_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// Queries live models from the provider's `/models` endpoint (zero hardcoded model list).
#[frb]
pub async fn fetch_provider_models(
    provider_id: String,
) -> Result<Vec<FfiProviderModelInfo>, String> {
    let engine = current_engine()?;
    let list = engine
        .fetch_provider_models(provider_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(list
        .into_iter()
        .map(|m| FfiProviderModelInfo {
            id: m.id,
            display_name: m.display_name,
        })
        .collect())
}

/// Lists built-in and custom assistants.
#[frb]
pub async fn list_assistants() -> Result<Vec<FfiAssistantRecord>, String> {
    let engine = current_engine()?;
    let list = engine
        .list_assistants()
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(list.into_iter().map(map_assistant).collect())
}

/// Creates a custom assistant persisted in local SQLite.
#[frb]
pub async fn create_assistant(
    name: String,
    role_subtitle: String,
    system_prompt: String,
    default_mode: String,
    badge_code: String,
) -> Result<FfiAssistantRecord, String> {
    let engine = current_engine()?;
    let created = engine
        .create_assistant(
            name,
            role_subtitle,
            system_prompt,
            ThreadMode::parse(&default_mode),
            badge_code,
        )
        .await
        .map_err(crate::dto_mapping::ffi_err)?;
    Ok(map_assistant(created))
}

/// Updates an assistant's profile, default provider/model, icon, and generation parameters in local SQLite.
#[frb]
#[expect(
    clippy::too_many_arguments,
    reason = "Flat FRB v2 boundary avoids nested Option<Option<T>> codegen."
)]
pub async fn update_assistant(
    assistant_id: String,
    name: Option<String>,
    role_subtitle: Option<String>,
    system_prompt: Option<String>,
    default_mode: Option<String>,
    badge_code: Option<String>,
    icon_slug: Option<String>,
    default_provider_id: Option<String>,
    default_model_id: Option<String>,
    temperature_milli: Option<u32>,
    clear_temperature: bool,
    max_output_tokens: Option<u32>,
    clear_max_output_tokens: bool,
    top_p_milli: Option<u32>,
    clear_top_p: bool,
) -> Result<FfiAssistantRecord, String> {
    let engine = current_engine()?;
    let updated = engine
        .update_assistant(
            assistant_id,
            AssistantPatch {
                name,
                role_subtitle,
                system_prompt,
                default_mode: default_mode.as_deref().map(ThreadMode::parse),
                badge_code,
                icon_slug,
                default_provider_id,
                default_model_id,
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
    Ok(map_assistant(updated))
}

/// Deletes an assistant (at least one assistant always remains; threads repoint cleanly).
#[frb]
pub async fn delete_assistant(assistant_id: String) -> Result<(), String> {
    let engine = current_engine()?;
    engine
        .delete_assistant(assistant_id)
        .await
        .map_err(crate::dto_mapping::ffi_err)
}

/// The built-in title prompt Settings > Default models shows while the setting is empty.
#[frb(sync)]
pub fn default_title_prompt() -> String {
    bistre_core::utility::DEFAULT_TITLE_PROMPT.to_owned()
}
