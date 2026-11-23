//! Provider and assistant catalog repository (`impl StorageHandle`).

use super::{
    AssistantPatch, AssistantRecord, BistreError, BistreResult, DEFAULT_TOPIC, DiagnosticKey,
    OptionalExtension, ProviderDialect, ProviderPatch, ProviderProfile, StorageHandle, ThreadMode,
    Uuid, map_sqlite_err, now_unix_ms, opt_i64_to_u32, params,
};

impl StorageHandle {
    /// Lists all configured provider profiles (fully user-manageable & deletable).
    pub fn list_providers(&self) -> BistreResult<Vec<ProviderProfile>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, name, dialect, base_url, default_model, key_hint, is_enabled, is_builtin,
                        use_server_state_cache, icon_slug, custom_icon_path, created_at_ms, updated_at_ms
                 FROM providers ORDER BY created_at_ms ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([], map_provider_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Fetches a single provider profile by ID.
    pub fn get_provider(&self, provider_id: &str) -> BistreResult<Option<ProviderProfile>> {
        let conn = self.open_reader()?;
        conn.query_row(
            "SELECT id, name, dialect, base_url, default_model, key_hint, is_enabled, is_builtin,
                    use_server_state_cache, icon_slug, custom_icon_path, created_at_ms, updated_at_ms
             FROM providers WHERE id = ?1",
            [provider_id],
            map_provider_row,
        )
        .optional()
        .map_err(map_sqlite_err)
    }

    /// Creates a provider profile of any supported dialect (`OpenAi`, `GoogleGemini`, `Anthropic`, `CustomOpenAi`).
    pub fn create_provider(
        &self,
        name: &str,
        dialect: ProviderDialect,
        base_url: &str,
        default_model: &str,
        icon_slug: &str,
        custom_icon_path: &str,
    ) -> BistreResult<ProviderProfile> {
        let clean_name = name.trim().to_owned();
        let clean_url = normalize_base_url(base_url)?;
        if clean_name.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "empty_provider_name",
            ));
        }
        let clean_model = default_model.trim().to_owned();
        let resolved_slug = if icon_slug.trim().is_empty() {
            dialect.default_icon_slug().to_owned()
        } else {
            icon_slug.trim().to_lowercase()
        };
        let clean_custom_icon = custom_icon_path.trim().to_owned();
        let id = format!("{}_{}", dialect.as_str(), Uuid::now_v7());
        let now = now_unix_ms();

        self.write(move |conn| {
            conn.execute(
                "INSERT INTO providers (id, name, dialect, base_url, default_model, key_hint, is_enabled,
                                        is_builtin, use_server_state_cache, icon_slug, custom_icon_path,
                                        created_at_ms, updated_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, '', 1, 0, 0, ?6, ?7, ?8, ?8)",
                params![
                    id,
                    clean_name,
                    dialect.as_str(),
                    clean_url,
                    clean_model,
                    resolved_slug,
                    clean_custom_icon,
                    now
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(ProviderProfile {
                id,
                name: clean_name,
                dialect,
                base_url: clean_url,
                default_model: clean_model,
                key_hint: String::new(),
                has_api_key: false,
                is_enabled: true,
                is_builtin: false,
                use_server_state_cache: false,
                icon_slug: resolved_slug,
                custom_icon_path: clean_custom_icon,
                created_at_ms: now,
                updated_at_ms: now,
            })
        })
    }

    /// Creates a new custom OpenAI-compatible provider profile (Spec 02).
    pub fn create_custom_provider(
        &self,
        name: &str,
        base_url: &str,
        default_model: &str,
    ) -> BistreResult<ProviderProfile> {
        self.create_provider(
            name,
            ProviderDialect::CustomOpenAi,
            base_url,
            default_model,
            "",
            "",
        )
    }

    /// Atomically updates mutable fields of a provider profile.
    pub fn update_provider(
        &self,
        provider_id: String,
        patch: ProviderPatch,
    ) -> BistreResult<ProviderProfile> {
        let now = now_unix_ms();
        self.write(move |conn| {
            let existing = conn
                .query_row(
                    "SELECT id, name, dialect, base_url, default_model, key_hint, is_enabled, is_builtin,
                            use_server_state_cache, icon_slug, custom_icon_path, created_at_ms, updated_at_ms
                     FROM providers WHERE id = ?1",
                    [&provider_id],
                    map_provider_row,
                )
                .optional()
                .map_err(map_sqlite_err)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;

            let next_name = match patch.name {
                Some(raw) => {
                    let t = raw.trim().to_owned();
                    if t.is_empty() {
                        return Err(BistreError::with_detail(
                            DiagnosticKey::InvalidInput,
                            "empty_provider_name",
                        ));
                    }
                    t
                }
                None => existing.name,
            };
            let next_url = match patch.base_url {
                Some(raw) => normalize_base_url(&raw)?,
                None => existing.base_url,
            };
            let next_model = patch
                .default_model
                .map_or(existing.default_model, |m| m.trim().to_owned());
            let next_hint = patch.key_hint.unwrap_or(existing.key_hint);
            let next_enabled = patch.is_enabled.unwrap_or(existing.is_enabled);
            let next_cache = patch
                .use_server_state_cache
                .unwrap_or(existing.use_server_state_cache);
            let next_icon_slug = patch
                .icon_slug
                .map_or(existing.icon_slug, |s| s.trim().to_lowercase());
            let next_custom_icon = patch
                .custom_icon_path
                .map_or(existing.custom_icon_path, |s| s.trim().to_owned());

            conn.execute(
                "UPDATE providers
                 SET name = ?1, base_url = ?2, default_model = ?3, key_hint = ?4, is_enabled = ?5,
                     use_server_state_cache = ?6, icon_slug = ?7, custom_icon_path = ?8, updated_at_ms = ?9
                 WHERE id = ?10",
                params![
                    next_name,
                    next_url,
                    next_model,
                    next_hint,
                    i64::from(next_enabled),
                    i64::from(next_cache),
                    next_icon_slug,
                    next_custom_icon,
                    now,
                    provider_id
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(ProviderProfile {
                id: existing.id,
                name: next_name,
                dialect: existing.dialect,
                base_url: next_url,
                default_model: next_model,
                key_hint: next_hint,
                has_api_key: existing.has_api_key,
                is_enabled: next_enabled,
                is_builtin: existing.is_builtin,
                use_server_state_cache: next_cache,
                icon_slug: next_icon_slug,
                custom_icon_path: next_custom_icon,
                created_at_ms: existing.created_at_ms,
                updated_at_ms: now,
            })
        })
    }

    /// Deletes ANY provider profile cleanly (nothing is forcibly locked against user deletion).
    pub fn delete_provider(&self, provider_id: String) -> BistreResult<()> {
        self.write(move |conn| {
            let deleted = conn
                .execute("DELETE FROM providers WHERE id = ?1", [&provider_id])
                .map_err(map_sqlite_err)?;
            if deleted == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            Ok(())
        })
    }

    /// Lists all assistants ordered built-in default first then creation time.
    pub fn list_assistants(&self) -> BistreResult<Vec<AssistantRecord>> {
        let conn = self.open_reader()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, name, role_subtitle, system_prompt, default_mode, badge_code,
                        icon_slug, default_provider_id, default_model_id,
                        temperature_milli, max_output_tokens, top_p_milli,
                        is_builtin, created_at_ms
                 FROM assistants ORDER BY is_builtin DESC, created_at_ms ASC",
            )
            .map_err(map_sqlite_err)?;
        let rows = stmt
            .query_map([], map_assistant_row)
            .map_err(map_sqlite_err)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(map_sqlite_err)
    }

    /// Creates a new user-owned assistant persona persisted in SQLite.
    pub fn create_assistant(
        &self,
        name: &str,
        role_subtitle: &str,
        system_prompt: &str,
        default_mode: ThreadMode,
        badge_code: &str,
    ) -> BistreResult<AssistantRecord> {
        let clean_name = name.trim().to_owned();
        if clean_name.is_empty() {
            return Err(BistreError::with_detail(
                DiagnosticKey::InvalidInput,
                "empty_assistant_name",
            ));
        }
        let clean_subtitle = role_subtitle.trim().to_owned();
        let clean_prompt = system_prompt.trim().to_owned();
        let clean_badge = normalize_badge(badge_code, &clean_name);
        let id = format!("custom_{}", Uuid::now_v7());
        let now = now_unix_ms();

        self.write(move |conn| {
            conn.execute(
                "INSERT INTO assistants (id, name, role_subtitle, system_prompt, default_mode, badge_code,
                                         icon_slug, default_provider_id, default_model_id,
                                         temperature_milli, max_output_tokens, top_p_milli,
                                         is_builtin, created_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, '', '', '', NULL, NULL, NULL, 0, ?7)",
                params![
                    id,
                    clean_name,
                    clean_subtitle,
                    clean_prompt,
                    default_mode.as_str(),
                    clean_badge,
                    now
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(AssistantRecord {
                id,
                name: clean_name,
                role_subtitle: clean_subtitle,
                system_prompt: clean_prompt,
                default_mode,
                badge_code: clean_badge,
                icon_slug: String::new(),
                default_provider_id: String::new(),
                default_model_id: String::new(),
                temperature_milli: None,
                max_output_tokens: None,
                top_p_milli: None,
                is_builtin: false,
                created_at_ms: now,
            })
        })
    }

    /// Updates mutable fields of an assistant persisted in SQLite.
    pub fn update_assistant(
        &self,
        assistant_id: String,
        patch: AssistantPatch,
    ) -> BistreResult<AssistantRecord> {
        self.write(move |conn| {
            let existing = conn
                .query_row(
                    "SELECT id, name, role_subtitle, system_prompt, default_mode, badge_code,
                            icon_slug, default_provider_id, default_model_id,
                            temperature_milli, max_output_tokens, top_p_milli,
                            is_builtin, created_at_ms
                     FROM assistants WHERE id = ?1",
                    [&assistant_id],
                    map_assistant_row,
                )
                .optional()
                .map_err(map_sqlite_err)?
                .ok_or_else(|| BistreError::new(DiagnosticKey::StorageNotFound))?;

            let next_name = match patch.name {
                Some(raw) => {
                    let t = raw.trim().to_owned();
                    if t.is_empty() {
                        return Err(BistreError::with_detail(
                            DiagnosticKey::InvalidInput,
                            "empty_assistant_name",
                        ));
                    }
                    t
                }
                None => existing.name,
            };
            let next_subtitle = patch
                .role_subtitle
                .map_or(existing.role_subtitle, |s| s.trim().to_owned());
            let next_prompt = patch
                .system_prompt
                .map_or(existing.system_prompt, |p| p.trim().to_owned());
            let next_mode = patch.default_mode.unwrap_or(existing.default_mode);
            let next_badge = match patch.badge_code {
                Some(raw) => normalize_badge(&raw, &next_name),
                None => existing.badge_code,
            };
            let next_icon = patch
                .icon_slug
                .map_or(existing.icon_slug, |s| s.trim().to_lowercase());
            let next_provider = patch
                .default_provider_id
                .map_or(existing.default_provider_id, |s| s.trim().to_owned());
            let next_model = patch
                .default_model_id
                .map_or(existing.default_model_id, |s| s.trim().to_owned());
            let next_temp = patch
                .temperature_milli
                .unwrap_or(existing.temperature_milli)
                .map(|v| v.clamp(0, 2000));
            let next_max_tokens = patch
                .max_output_tokens
                .unwrap_or(existing.max_output_tokens)
                .map(|v| v.clamp(1, 1_000_000));
            let next_top_p = patch
                .top_p_milli
                .unwrap_or(existing.top_p_milli)
                .map(|v| v.clamp(0, 1000));

            conn.execute(
                "UPDATE assistants
                 SET name = ?1, role_subtitle = ?2, system_prompt = ?3, default_mode = ?4, badge_code = ?5,
                     icon_slug = ?6, default_provider_id = ?7, default_model_id = ?8,
                     temperature_milli = ?9, max_output_tokens = ?10, top_p_milli = ?11
                 WHERE id = ?12",
                params![
                    next_name,
                    next_subtitle,
                    next_prompt,
                    next_mode.as_str(),
                    next_badge,
                    next_icon,
                    next_provider,
                    next_model,
                    next_temp.map(i64::from),
                    next_max_tokens.map(i64::from),
                    next_top_p.map(i64::from),
                    assistant_id
                ],
            )
            .map_err(map_sqlite_err)?;

            Ok(AssistantRecord {
                id: assistant_id,
                name: next_name,
                role_subtitle: next_subtitle,
                system_prompt: next_prompt,
                default_mode: next_mode,
                badge_code: next_badge,
                icon_slug: next_icon,
                default_provider_id: next_provider,
                default_model_id: next_model,
                temperature_milli: next_temp,
                max_output_tokens: next_max_tokens,
                top_p_milli: next_top_p,
                is_builtin: existing.is_builtin,
                created_at_ms: existing.created_at_ms,
            })
        })
    }

    /// Deletes an assistant while keeping at least one remaining assistant and repointing any threads.
    pub fn delete_assistant(&self, assistant_id: String) -> BistreResult<()> {
        self.write(move |conn| {
            let total: i64 = conn
                .query_row("SELECT COUNT(*) FROM assistants", [], |r| r.get(0))
                .map_err(map_sqlite_err)?;
            if total <= 1 {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "cannot_delete_last_assistant",
                ));
            }

            let fallback_id: Option<String> = conn
                .query_row(
                    "SELECT id FROM assistants WHERE id != ?1 ORDER BY is_builtin DESC, created_at_ms ASC LIMIT 1",
                    [&assistant_id],
                    |r| r.get(0),
                )
                .optional()
                .map_err(map_sqlite_err)?;
            let Some(fallback_id) = fallback_id else {
                return Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "cannot_delete_last_assistant",
                ));
            };

            let tx = conn
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(map_sqlite_err)?;
            tx.execute(
                "UPDATE threads SET assistant_id = ?1 WHERE assistant_id = ?2",
                params![fallback_id, assistant_id],
            )
            .map_err(map_sqlite_err)?;
            let deleted = tx
                .execute("DELETE FROM assistants WHERE id = ?1", [&assistant_id])
                .map_err(map_sqlite_err)?;
            if deleted == 0 {
                return Err(BistreError::new(DiagnosticKey::StorageNotFound));
            }
            tx.commit().map_err(map_sqlite_err)
        })
    }
}

pub(crate) fn map_provider_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<ProviderProfile> {
    let dialect_raw: String = row.get(2)?;
    let dialect = ProviderDialect::parse(&dialect_raw);
    let key_hint: String = row.get(5)?;
    let enabled_int: i64 = row.get(6)?;
    let builtin_int: i64 = row.get(7)?;
    let cache_int: i64 = row.get(8)?;
    let icon_slug_raw: String = row.get(9)?;
    let icon_slug = if icon_slug_raw.trim().is_empty() {
        dialect.default_icon_slug().to_owned()
    } else {
        icon_slug_raw
    };
    Ok(ProviderProfile {
        id: row.get(0)?,
        name: row.get(1)?,
        dialect,
        base_url: row.get(3)?,
        default_model: row.get(4)?,
        has_api_key: !key_hint.is_empty(),
        key_hint,
        is_enabled: enabled_int != 0,
        is_builtin: builtin_int != 0,
        use_server_state_cache: cache_int != 0,
        icon_slug,
        custom_icon_path: row.get(10)?,
        created_at_ms: row.get(11)?,
        updated_at_ms: row.get(12)?,
    })
}

pub(crate) fn normalize_base_url(raw: &str) -> BistreResult<String> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() || (!trimmed.starts_with("https://") && !trimmed.starts_with("http://")) {
        return Err(BistreError::with_detail(
            DiagnosticKey::InvalidInput,
            "invalid_provider_url",
        ));
    }
    Ok(trimmed.to_owned())
}

pub(crate) fn map_assistant_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssistantRecord> {
    let mode_raw: String = row.get(4)?;
    let temp: Option<i64> = row.get(9)?;
    let max_tok: Option<i64> = row.get(10)?;
    let top_p: Option<i64> = row.get(11)?;
    let builtin_int: i64 = row.get(12)?;
    Ok(AssistantRecord {
        id: row.get(0)?,
        name: row.get(1)?,
        role_subtitle: row.get(2)?,
        system_prompt: row.get(3)?,
        default_mode: ThreadMode::parse(&mode_raw),
        badge_code: row.get(5)?,
        icon_slug: row.get(6)?,
        default_provider_id: row.get(7)?,
        default_model_id: row.get(8)?,
        temperature_milli: opt_i64_to_u32(temp),
        max_output_tokens: opt_i64_to_u32(max_tok),
        top_p_milli: opt_i64_to_u32(top_p),
        is_builtin: builtin_int != 0,
        created_at_ms: row.get(13)?,
    })
}

pub(crate) fn normalize_topic(raw: Option<&str>) -> String {
    match raw.map(str::trim) {
        Some(t) if !t.is_empty() => t.to_lowercase(),
        _ => DEFAULT_TOPIC.to_owned(),
    }
}

pub(crate) fn normalize_badge(badge_code: &str, name: &str) -> String {
    let trimmed = badge_code.trim();
    if !trimmed.is_empty() {
        return trimmed.chars().take(3).collect::<String>().to_uppercase();
    }
    name.chars().take(2).collect::<String>().to_uppercase()
}
