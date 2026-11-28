//! Pure Rust domain engine for Bistre (ADR-0003).
//!
//! Invariants:
//! - Zero dependency on Flutter, `flutter_rust_bridge`, GUI toolkits, or OS tray crates.
//! - Unifies Embedded (Android), Local Daemon (Desktop IPC), and Remote Bridge behind `EngineClient`.
//! - Stores API keys strictly in node-local `SecretVault` (Windows DPAPI / OS vault), never plaintext SQLite.
//! - Streams real responses over pure `rustls` + `reqwest 0.13` across Big 3 + Custom dialects (Spec 02).

pub mod agent;
pub mod agent_approvals;
pub mod agent_context;
pub mod agent_tools;
pub mod approval;
pub mod attachment_upload;
pub mod attachments;
mod chat_extras;
pub mod chat_files;
pub mod compaction;
pub mod computer_use;
pub mod context_breakdown;
pub mod context_exclusion;
pub mod credentials;
pub mod cron;
pub mod custom_headers;
pub mod daemon_launch;
pub mod daemon_serve;
mod data_wipe;
pub mod delegate;
pub mod desktop_helpers;
pub mod durability;
pub mod effort_levels;
mod engine_grounding;
pub mod error_policy;
mod events;
pub mod finish;
pub mod fs_tools;
pub mod goal;
pub mod grounding;
pub mod history_limit;
pub mod history_recall;
pub mod hooks;
pub mod http_clients;
pub mod import_policy;
pub mod ipc_client;
pub mod live_voice;
pub mod mcp;
pub mod mcp_era;
mod mcp_listen;
mod mcp_refresh;
pub mod mcp_registry;
pub mod mcp_stdio;
mod media_gen;
mod media_jobs;
pub(crate) mod media_wire;
pub mod mime_sniff;
pub mod net;
mod off_worker;
pub mod office_text;
pub mod ota;
pub mod ota_manifest;
mod paid_tools;
pub mod power;
pub mod process_util;
pub mod projects;
pub mod provider_backoff;
pub mod provider_prefs;
pub mod providers;
pub mod raw_exchange;
pub(crate) mod reasoning_details;
pub mod registry;
mod registry_parse;
pub mod replay_policy;
pub mod request_body;
mod shell_progress;
pub mod skill_install;
pub mod skills;
pub mod sse;
pub mod ssrf;
pub mod storage_files;
pub mod story;
pub mod subagents;
pub mod tokenizer;
pub mod tool_batch;
pub mod tool_call_ids;
mod tool_spill;
pub mod tools;
pub mod utility;
mod utility_chat;
pub mod utility_tools;
pub mod vault_key;
pub mod voice;
pub mod wallet;
pub mod web_tools;
pub mod wire_history;
mod wire_history_gemini;
pub mod wire_parse;
pub mod wire_stream;

#[cfg(test)]
mod daemon_ipc_tests;
#[cfg(test)]
mod egress_tests;
mod engine_client;
mod engine_extras;
mod engine_impl;
mod engine_impl_agent;
pub mod engine_rpc;
mod engine_runs;
mod engine_story;
#[cfg(test)]
mod gemini_signature_tests;
#[cfg(test)]
mod slot_and_agent_tests;
#[cfg(test)]
pub(crate) mod test_support;
#[cfg(test)]
mod tests;
mod turn_context;
#[cfg(test)]
mod wallet_flow_tests;

pub use bistre_crypto::VaultKey;
use bistre_protocol::lock_or_recover;
pub use context_breakdown::ContextBreakdown;
pub use engine_client::EngineClient;
pub use engine_grounding::NodeGrounding;
use engine_runs::{StreamServices, execute_durable_stream_loop, utc_day_start_unix_ms};

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::events::{emit, emit_logged};
use bistre_crypto::{LocalSecretVault, SecretVault, verify_signed_pack};
use bistre_protocol::{
    AgentRunRecord, AppHealthSnapshot, AppSettings, AssistantPatch, AssistantRecord,
    AttachmentInput, BistreError, BistreResult, CharacterCardRecord, CronJobRecord,
    CursorEventRecord, DiagnosticKey, DraftRecord, EngineEvent, GenerationParams,
    MemoryEntryRecord, ModelCatalogInfo, MoneyMicros, NodeRecord, NodeRole, PowerGuardStatus,
    ProjectRecord, ProviderDialect, ProviderModelInfo, ProviderPatch, ProviderProfile,
    ReasoningEffort, RegexRuleRecord, RunStatus, RunStepKind, RunStepRecord, SearchHit,
    SignedPackManifest, SteeringMessage, StorageFileEntry, StorageStats, StoryChapterRecord,
    StoryEntryRecord, StoryProgressionRecord, StorySceneRecord, StorySnapshotRecord,
    StoryThreadStateRecord, StreamChunk, SystemPowerEvent, ThreadMode, ThreadPatch, ThreadSummary,
    ToolRiskTier, UpdateCheckResult, UserPersonaRecord, WorkspaceCheckpointRecord,
};
use bistre_storage::{AgentRunUpdate, CreateAgentRunParams, StorageHandle};
use credentials::KeyRing;
use power::{NoopPowerGuardBackend, PowerCoordinator, PowerGuardBackend, PowerLeasePolicy};
use tokio::sync::{Notify, broadcast};
use uuid::Uuid;
use zeroize::Zeroizing;

/// Crate semver exposed in health diagnostics.
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Longest a new run waits for the previous run in the same chat to stop.
pub(crate) const PREVIOUS_RUN_STOP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

const EVENT_BUS_CAPACITY: usize = 256;

/// Boxed future type for object-safe async `EngineClient` implementations.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// In-process pure-Rust engine backed by `StorageHandle`, `LocalSecretVault`, `PowerCoordinator`, and pure `rustls` HTTP.
pub struct InProcessEngine {
    data_dir: PathBuf,
    storage: Arc<StorageHandle>,
    vault: Arc<dyn SecretVault>,
    http: reqwest::Client,
    /// Update feeds and artifacts (`http_clients::ota_client`); never carries credentials.
    ota_http: reqwest::Client,
    /// Hardened transport for every model-directed fetch (never the provider client).
    web: ssrf::PublicWebTransport,
    /// Loopback-or-public MCP HTTP transport (redirects refused, per-call timeout).
    mcp_http: mcp::McpHttpTransport,
    /// Live single-flight pricing registry (no hardcoded model rates).
    pricing: Arc<registry::PricingRegistry>,
    /// Per-`(provider_id, model_id)` runtime set of models that rejected reasoning fields with 400.
    reasoning_unsupported: Arc<Mutex<std::collections::HashSet<(String, String)>>>,
    /// Per-thread backoff wakers (`Retry now` and cancel wake a waiting run instantly).
    wakers: Arc<Mutex<HashMap<String, Arc<Notify>>>>,
    /// One backoff per provider shared by every run.
    provider_backoff: Arc<provider_backoff::ProviderBackoff>,
    /// Run-scoped stale-read guard for workspace edits.
    read_ledger: Arc<tools::ReadLedger>,
    /// Single tool dispatch gate (one-use permits, synchronous revocation).
    broker: Arc<approval::ToolApprovalBroker>,
    /// Live tool-approval waiters keyed by `call_id`.
    pending_approvals: agent_tools::PendingApprovalMap,
    /// Thread-scoped auto-approved tool names granted via `ApproveForThread`.
    thread_auto_approvals: agent_tools::ThreadAutoApprovals,
    unpriced_allowed: engine_runs::UnpricedAllowances,
    power: Arc<PowerCoordinator>,
    events_tx: broadcast::Sender<EngineEvent>,
    active_runs: Arc<AtomicU32>,
    cancellations: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
    /// Per-chat completion signal of the latest run; a new run waits on it.
    run_done: Arc<Mutex<HashMap<String, tokio::sync::watch::Receiver<bool>>>>,
    /// The last signature-verified OTA manifest; `stage_update` acts only on this, never on
    /// fields round-tripped through the UI.
    verified_update: Arc<Mutex<Option<ota::VerifiedManifest>>>,
    /// Every spawned run; shutdown cancels and drains them before closing storage.
    run_tasks: Arc<Mutex<tokio::task::JoinSet<()>>>,
    /// Release key override (tests only); unset uses `ota::OFFICIAL_RELEASE_PUBKEY_B64`.
    ota_release_key: std::sync::OnceLock<String>,
    /// Active bidirectional Live Voice WebSocket sessions.
    live_voice: Arc<voice::LiveVoiceManager>,
    /// Native host-bridge coordinator and ephemeral screenshot buffer (`computer_use`).
    host_actions: Arc<computer_use::HostActionBroker>,
}

impl std::fmt::Debug for InProcessEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InProcessEngine")
            .field("active_runs", &self.active_runs.load(Ordering::Relaxed))
            .finish_non_exhaustive()
    }
}

impl InProcessEngine {
    /// Opens the local SQLite WAL store and OS-backed `SecretVault` inside `data_dir`.
    /// `vault_key` seals the vault on Linux/Android (see [`vault_key::resolve_vault_key`]); Windows
    /// passes `None` and uses DPAPI.
    pub fn open(
        data_dir: impl AsRef<Path>,
        vault_key: Option<VaultKey>,
    ) -> BistreResult<Arc<Self>> {
        Self::open_with_power_guard(data_dir, Arc::new(NoopPowerGuardBackend), vault_key)
    }

    /// Opens the engine with an explicit platform `PowerGuardBackend` (Win32 / Linux logind / Android FGS).
    pub fn open_with_power_guard(
        data_dir: impl AsRef<Path>,
        power_backend: Arc<dyn PowerGuardBackend>,
        vault_key: Option<VaultKey>,
    ) -> BistreResult<Arc<Self>> {
        Self::open_with_http(
            data_dir,
            power_backend,
            vault_key,
            providers::build_http_client()?,
        )
    }

    /// Opens the engine over a test provider client (`http_clients::provider_client_resolving`).
    #[cfg(test)]
    pub(crate) fn open_for_test(
        data_dir: impl AsRef<Path>,
        http: reqwest::Client,
    ) -> BistreResult<Arc<Self>> {
        let engine = Self::open_with_http(
            data_dir,
            Arc::new(NoopPowerGuardBackend),
            Some(VaultKey::generate()?),
            http,
        )?;
        // Tests are hermetic: never fetch live price lists from the internet.
        let mut settings = engine.storage.load_settings()?;
        settings.pricing_auto_refresh = false;
        engine.storage.save_settings(settings)?;
        Ok(engine)
    }

    fn open_with_http(
        data_dir: impl AsRef<Path>,
        power_backend: Arc<dyn PowerGuardBackend>,
        vault_key: Option<VaultKey>,
        http: reqwest::Client,
    ) -> BistreResult<Arc<Self>> {
        let dir = data_dir.as_ref().to_path_buf();
        data_wipe::run_pending(&dir)?;
        let db_path = dir.join("bistre.sqlite");
        let storage = StorageHandle::open(db_path)?;
        // No run exists yet, so any outstanding reservation is from a crash; release it.
        storage.release_all_wallet_reservations()?;
        // A video job a crash cut off is still billed: book its cost.
        if let Err(err) = media_jobs::book_cut_off(&storage, turn_context::utc_now_unix_ms()) {
            tracing::warn!(key = err.key.as_key(), "cut-off video jobs not booked");
        }
        let vault: Arc<dyn SecretVault> = Arc::new(LocalSecretVault::open(&dir, vault_key)?);
        let power = PowerCoordinator::new(power_backend);
        // Unreadable settings must not block opening (the user can fix them in Settings); keep
        // the default power policy and skip the automatic price refresh.
        let settings = match storage.load_settings() {
            Ok(settings) => Some(settings),
            Err(err) => {
                tracing::warn!(
                    key = err.key.as_key(),
                    "settings unreadable at engine start"
                );
                None
            }
        };
        if let Some(settings) = &settings {
            power.update_policy(PowerLeasePolicy {
                keep_awake_while_running: settings.keep_awake_while_running,
                windows_keep_awake_on_battery: settings.windows_keep_awake_on_battery,
            });
        }
        let web = ssrf::PublicWebTransport::new();
        let pricing = Arc::new(registry::PricingRegistry::with_cache(
            dir.join("pricing_cache.json"),
        ));
        // Only trigger automatic pricing network sync at startup when at least one provider
        // actually has a key configured; unconfigured cold starts stay 0-network / low-RAM.
        let has_configured_provider = storage
            .list_providers()
            .is_ok_and(|list| list.iter().any(|p| p.has_api_key));
        if has_configured_provider && settings.as_ref().is_some_and(|s| s.pricing_auto_refresh) {
            pricing.ensure_fresh(&web);
        }
        let (events_tx, _) = broadcast::channel(EVENT_BUS_CAPACITY);
        if let Err(err) = durability::recover_interrupted_runs(&storage, &events_tx) {
            tracing::warn!(
                key = err.key.as_key(),
                "boot recovery of interrupted agent runs failed"
            );
        }
        Ok(Arc::new(Self {
            data_dir: dir,
            storage,
            vault,
            http,
            ota_http: http_clients::ota_client()?,
            web,
            mcp_http: mcp::McpHttpTransport::new(),
            pricing,
            reasoning_unsupported: Arc::new(Mutex::new(std::collections::HashSet::new())),
            wakers: Arc::new(Mutex::new(HashMap::new())),
            provider_backoff: Arc::new(provider_backoff::ProviderBackoff::default()),
            read_ledger: Arc::new(tools::ReadLedger::default()),
            broker: Arc::new(approval::ToolApprovalBroker::new()),
            pending_approvals: Arc::new(Mutex::new(HashMap::new())),
            thread_auto_approvals: Arc::new(Mutex::new(agent_tools::ApprovalMemory::default())),
            unpriced_allowed: Arc::new(Mutex::new(std::collections::HashSet::new())),
            power,
            events_tx,
            active_runs: Arc::new(AtomicU32::new(0)),
            cancellations: Arc::new(Mutex::new(HashMap::new())),
            run_done: Arc::new(Mutex::new(HashMap::new())),
            verified_update: Arc::new(Mutex::new(None)),
            run_tasks: Arc::new(Mutex::new(tokio::task::JoinSet::new())),
            ota_release_key: std::sync::OnceLock::new(),
            live_voice: Arc::new(voice::LiveVoiceManager::new()),
            host_actions: Arc::new(computer_use::HostActionBroker::new()),
        }))
    }

    /// Returns the shared `PowerCoordinator` so desktop daemons or Android shims can report power transitions.
    pub fn power_coordinator(&self) -> Arc<PowerCoordinator> {
        Arc::clone(&self.power)
    }

    /// Returns the number of active runs plus enabled scheduled jobs (active-scoped daemon lifecycle check).
    pub fn active_work_count(&self) -> u32 {
        let running = self.active_runs.load(Ordering::SeqCst);
        let enabled_crons = self.storage.count_enabled_cron_jobs().unwrap_or(0);
        running.saturating_add(enabled_crons)
    }

    /// Returns direct access to the canonical `StorageHandle` for daemon/service hooks.
    pub fn storage(&self) -> Arc<StorageHandle> {
        Arc::clone(&self.storage)
    }

    /// Wakes a run waiting in backoff for `thread_id`.
    fn wake_run(&self, thread_id: &str) -> bool {
        lock_or_recover(&self.wakers, "wakers")
            .get(thread_id)
            .cloned()
            .is_some_and(|wake| {
                wake.notify_one();
                true
            })
    }

    fn vault_key(provider_id: &str) -> String {
        format!("provider_api_key:{provider_id}")
    }

    fn load_mcp_bearer(&self, server_id: &str) -> Option<String> {
        let raw = match self.vault.get(&mcp::bearer_vault_key(server_id)) {
            Ok(v) => v,
            Err(err) => {
                tracing::warn!(
                    key = err.key.as_key(),
                    server_id,
                    "mcp bearer lookup failed"
                );
                return None;
            }
        };
        raw.and_then(|b| String::from_utf8(b.to_vec()).ok())
            .filter(|s| !s.trim().is_empty())
    }

    /// Loads every stored key for a provider (one vault entry, newline separated).
    fn load_key_ring(&self, provider_id: &str) -> BistreResult<KeyRing> {
        let raw = self.vault.get(&Self::vault_key(provider_id))?;
        match raw {
            Some(bytes) => {
                let s = Zeroizing::new(
                    String::from_utf8(bytes.to_vec())
                        .map_err(|_| BistreError::new(DiagnosticKey::CryptoVaultUnavailable))?,
                );
                Ok(KeyRing::from_vault_text(&s))
            }
            None => Ok(KeyRing::default()),
        }
    }

    fn hydrate_provider(&self, mut profile: ProviderProfile) -> ProviderProfile {
        let has_key = self
            .vault
            .contains(&Self::vault_key(&profile.id))
            .unwrap_or(false);
        profile.has_api_key = has_key;
        if !has_key {
            profile.key_hint.clear();
        }
        profile
    }

    fn enforce_wallet_shield(
        &self,
        settings: &AppSettings,
        provider: &ProviderProfile,
    ) -> BistreResult<()> {
        if net::is_loopback_url(&provider.base_url) {
            return Ok(());
        }
        let Some(ceiling) = settings.wallet_daily_ceiling_micros else {
            // Explicit Unlimited mode (`None`) imposes no daily cap.
            return Ok(());
        };
        let spent_today = self
            .storage
            .sum_wallet_spend_since_micros(utc_day_start_unix_ms())?;
        if spent_today >= ceiling {
            return Err(BistreError::new(DiagnosticKey::WalletCeilingExceeded));
        }
        Ok(())
    }

    fn resolve_execution_target(
        &self,
        settings: &AppSettings,
        thread: &ThreadSummary,
        assistant: Option<&AssistantRecord>,
    ) -> BistreResult<(ProviderProfile, KeyRing, String, GenerationParams)> {
        let profiles: Vec<ProviderProfile> = self
            .storage
            .list_providers()?
            .into_iter()
            .map(|p| self.hydrate_provider(p))
            .collect();

        let default_models = provider_prefs::load_default_models(&self.storage);
        // A provider pinned by the chat or its assistant is used or the request fails:
        // falling back could send the chat to another, possibly paid, vendor.
        let pinned_provider_id = thread
            .provider_id_override
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .or_else(|| {
                assistant
                    .map(|a| a.default_provider_id.trim())
                    .filter(|s| !s.is_empty())
            });
        if let Some(pid) = pinned_provider_id {
            let usable = profiles
                .iter()
                .find(|p| p.id == pid && p.is_enabled && (!p.requires_api_key() || p.has_api_key));
            if usable.is_none() {
                return Err(BistreError::new(DiagnosticKey::ProviderPinnedUnavailable));
            }
        }
        // Settings > Default models is the default for a chat that
        // names no provider or model itself; the picker's last pick only fills in when it is
        // unset (the picker sets the open chat's own model).
        let requested_provider_id = pinned_provider_id
            .or_else(|| {
                let id = default_models.global_provider_id.trim();
                if id.is_empty() { None } else { Some(id) }
            })
            .or_else(|| {
                let id = settings.active_provider_id.trim();
                if id.is_empty() { None } else { Some(id) }
            });

        let preferred = requested_provider_id.and_then(|pid| {
            profiles
                .iter()
                .find(|p| p.id == pid && p.is_enabled)
                .cloned()
        });

        let selected = preferred
            .or_else(|| {
                profiles
                    .iter()
                    .find(|p| p.is_enabled && (!p.requires_api_key() || p.has_api_key))
                    .cloned()
            })
            .ok_or_else(|| BistreError::new(DiagnosticKey::ProviderNotConfigured))?;

        let api_key = self.load_key_ring(&selected.id)?;
        if selected.requires_api_key() && api_key.is_empty() {
            return Err(BistreError::new(DiagnosticKey::ProviderNotConfigured));
        }

        let model = thread
            .model_id_override
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .or_else(|| {
                assistant
                    .map(|a| a.default_model_id.trim())
                    .filter(|s| !s.is_empty())
            })
            .or_else(|| {
                let gm = default_models.global_model_id.trim();
                if !gm.is_empty()
                    && (default_models.global_provider_id.is_empty()
                        || default_models.global_provider_id == selected.id)
                {
                    Some(gm)
                } else {
                    None
                }
            })
            .or_else(|| {
                let active_m = settings.active_model_id.trim();
                if !active_m.is_empty()
                    && (settings.active_provider_id.is_empty()
                        || settings.active_provider_id == selected.id)
                {
                    Some(active_m)
                } else {
                    None
                }
            })
            .unwrap_or(selected.default_model.trim())
            .to_owned();

        if model.is_empty() {
            return Err(BistreError::new(DiagnosticKey::ProviderModelRequired));
        }

        let prov_adv = provider_prefs::load_provider_advanced(&self.storage, &selected.id);
        let wired_dialect = prov_adv.speaking(&selected).dialect;
        let scope = registry::CatalogScope::of(&selected);
        let reasoning_effort = self.resolve_reasoning_effort(
            &scope,
            &selected.id,
            &model,
            &settings.reasoning_effort,
            prov_adv.default_thinking_effort,
        );
        let gen_params = GenerationParams {
            temperature_milli: thread
                .temperature_milli
                .or_else(|| assistant.and_then(|a| a.temperature_milli)),
            max_output_tokens: thread
                .max_output_tokens
                .or_else(|| assistant.and_then(|a| a.max_output_tokens))
                .or_else(|| prov_adv.max_output_tokens(&model))
                .or_else(|| self.anthropic_output_limit(&scope, wired_dialect, &model)),
            top_p_milli: thread
                .top_p_milli
                .or_else(|| assistant.and_then(|a| a.top_p_milli)),
            reasoning_effort,
        };

        Ok((selected, api_key, model, gen_params))
    }

    /// Resolves the request's thinking effort: explicit global/composer choice wins over the
    /// provider's default effort, unless the catalog or a prior 400 heal marks the model
    /// non-reasoning.
    fn resolve_reasoning_effort(
        &self,
        scope: &registry::CatalogScope,
        provider_id: &str,
        model: &str,
        global_effort: &str,
        provider_default: ReasoningEffort,
    ) -> ReasoningEffort {
        let rates = self.pricing.snapshot().lookup(scope, model);
        let catalog_says_no = rates.and_then(|r| r.reasoning) == Some(false);
        let runtime_says_no = lock_or_recover(&self.reasoning_unsupported, "reasoning_unsupported")
            .contains(&(provider_id.to_owned(), model.to_owned()));
        if catalog_says_no || runtime_says_no {
            return ReasoningEffort::ModelDefault;
        }
        let wanted = match ReasoningEffort::parse(global_effort) {
            ReasoningEffort::ModelDefault => provider_default,
            explicit => explicit,
        };
        // A level the catalog says the model lacks becomes its nearest listed level.
        rates
            .and_then(|r| r.effort_levels)
            .map_or(wanted, |levels| levels.clamp(wanted))
    }

    /// Anthropic requires `max_tokens`; it is the model's own limit from the registry,
    /// never a fixed number (the request body keeps a fallback when the model is unknown).
    fn anthropic_output_limit(
        &self,
        scope: &registry::CatalogScope,
        dialect: ProviderDialect,
        model: &str,
    ) -> Option<u32> {
        (dialect == ProviderDialect::Anthropic)
            .then(|| {
                self.pricing
                    .snapshot()
                    .lookup(scope, model)
                    .and_then(|r| r.max_output_tokens)
            })
            .flatten()
    }

    /// Cancels a run still going in `thread_id` and waits, at most
    /// [`PREVIOUS_RUN_STOP_TIMEOUT`], until it has finished and committed, so a new run (send,
    /// edit, regenerate) never overlaps it or commits after it.
    pub(crate) async fn stop_previous_run(&self, thread_id: &str) {
        let done = lock_or_recover(&self.run_done, "run_done")
            .get(thread_id)
            .cloned();
        let Some(mut done) = done else { return };
        if *done.borrow() {
            return;
        }
        if let Some(flag) = lock_or_recover(&self.cancellations, "cancellations").get(thread_id) {
            flag.store(true, Ordering::SeqCst);
        }
        self.wake_run(thread_id);
        // Finished, or its task is gone (the sender dropped): either way it is over.
        if tokio::time::timeout(PREVIOUS_RUN_STOP_TIMEOUT, done.wait_for(|d| *d))
            .await
            .is_err()
        {
            tracing::warn!(
                thread_id,
                "previous run did not stop in time; starting the new run anyway"
            );
        }
    }

    /// The shared services one run's task needs, bound to that run's `wake` signal.
    fn stream_services(&self, wake: &Arc<Notify>) -> StreamServices {
        StreamServices {
            http: self.http.clone(),
            web: self.web.clone(),
            mcp_http: self.mcp_http.clone(),
            vault: Arc::clone(&self.vault),
            pricing: Arc::clone(&self.pricing),
            wake: Arc::clone(wake),
            data_dir: self.data_dir.clone(),
            reasoning_unsupported: Arc::clone(&self.reasoning_unsupported),
            provider_backoff: Arc::clone(&self.provider_backoff),
            read_ledger: Arc::clone(&self.read_ledger),
            broker: Arc::clone(&self.broker),
            pending_approvals: Arc::clone(&self.pending_approvals),
            thread_auto_approvals: Arc::clone(&self.thread_auto_approvals),
            power: Arc::clone(&self.power),
            unpriced_allowed: Arc::clone(&self.unpriced_allowed),
            host_actions: Arc::clone(&self.host_actions),
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "Explicit immutable launch context passed into spawned Tokio streaming task."
    )]
    fn spawn_live_stream(
        &self,
        thread: &ThreadSummary,
        parent_user_node_id: String,
        provider: ProviderProfile,
        api_key: KeyRing,
        model: String,
        system_prompt: String,
        gen_params: GenerationParams,
        stateless_default: bool,
        origin: agent::RunApprovalPolicy,
    ) -> BistreResult<String> {
        let durable_run = self.storage.create_agent_run(CreateAgentRunParams {
            thread_id: thread.id.clone(),
            parent_run_id: None,
            root_node_id: Some(parent_user_node_id.clone()),
            mode: thread.mode,
            max_steps: engine_runs::MAX_RUN_STEPS,
            unattended_policy: origin.policy,
            worktree_path: origin.sandbox.map(|p| p.display().to_string()),
        })?;

        let pending_id = Uuid::now_v7().to_string();
        let (done_tx, done_rx) = tokio::sync::watch::channel(false);
        lock_or_recover(&self.run_done, "run_done").insert(thread.id.clone(), done_rx);
        let cancel_flag = Arc::new(AtomicBool::new(false));
        let mut guard = lock_or_recover(&self.cancellations, "cancellations");
        if let Some(prev) = guard.insert(thread.id.clone(), Arc::clone(&cancel_flag)) {
            prev.store(true, Ordering::SeqCst);
        }

        let wake = Arc::new(Notify::new());
        {
            let mut guard = lock_or_recover(&self.wakers, "wakers");
            if let Some(prev_wake) = guard.insert(thread.id.clone(), Arc::clone(&wake)) {
                prev_wake.notify_one();
            }
        }
        let wakers = Arc::clone(&self.wakers);
        let services = self.stream_services(&wake);
        let storage = Arc::clone(&self.storage);
        let power = Arc::clone(&self.power);
        let events_tx = self.events_tx.clone();
        let active_runs = Arc::clone(&self.active_runs);
        let cancellations = Arc::clone(&self.cancellations);
        let thread_id = thread.id.clone();
        let stream_node_id = pending_id.clone();
        let run_id = durable_run.id.clone();

        active_runs.fetch_add(1, Ordering::SeqCst);
        let power_lease = power.acquire_run_lease(format!("Bistre run {}", thread.title));
        let started_ev = EngineEvent::RunStarted {
            thread_id: thread_id.clone(),
            node_id: stream_node_id.clone(),
        };
        emit_logged(&storage, &events_tx, Some(thread_id.clone()), started_ev);
        let run_ev = EngineEvent::RunStateChanged { run: durable_run };
        emit_logged(&storage, &events_tx, Some(thread_id.clone()), run_ev);
        emit(
            &events_tx,
            EngineEvent::PowerStatusChanged {
                status: power.status(),
            },
        );

        let mut tasks = lock_or_recover(&self.run_tasks, "run_tasks");
        // Reap finished runs so the set stays bounded by the number of live runs.
        while tasks.try_join_next().is_some() {}
        tasks.spawn(async move {
            let lease_guard = power_lease;
            let final_node_id = execute_durable_stream_loop(
                &storage,
                &services,
                &events_tx,
                &cancel_flag,
                &thread_id,
                &run_id,
                parent_user_node_id,
                stream_node_id,
                &provider,
                &api_key,
                &model,
                &system_prompt,
                gen_params,
                stateless_default,
            )
            .await;
            done_tx.send_replace(true);
            lock_or_recover(&services.thread_auto_approvals, "approval_memory").end_run(&run_id);
            lock_or_recover(&services.unpriced_allowed, "unpriced_allowed").remove(&thread_id);
            services.host_actions.clear_run(&run_id);

            // Only remove our own cancel/wake handles (never clobber a newer overlapping run).
            {
                let mut guard = lock_or_recover(&cancellations, "cancellations");
                if guard
                    .get(&thread_id)
                    .is_some_and(|cur| Arc::ptr_eq(cur, &cancel_flag))
                {
                    guard.remove(&thread_id);
                }
            }
            {
                let mut guard = lock_or_recover(&wakers, "wakers");
                if guard
                    .get(&thread_id)
                    .is_some_and(|cur| Arc::ptr_eq(cur, &wake))
                {
                    guard.remove(&thread_id);
                }
            }
            active_runs.fetch_sub(1, Ordering::SeqCst);
            drop(lease_guard);
            emit(
                &events_tx,
                EngineEvent::PowerStatusChanged {
                    status: power.status(),
                },
            );
            let fin = EngineEvent::RunFinished {
                thread_id: thread_id.clone(),
                node_id: final_node_id.0,
                cancelled: final_node_id.1,
            };
            emit_logged(&storage, &events_tx, Some(thread_id), fin);
        });

        Ok(pending_id)
    }

    pub(crate) fn stage_verified_update(
        &self,
        check: UpdateCheckResult,
        allow_reinstall: bool,
    ) -> BoxFuture<'_, BistreResult<String>> {
        Box::pin(async move {
            let verified = lock_or_recover(&self.verified_update, "verified_update")
                .clone()
                .filter(|m| m.latest_version() == check.latest_version)
                .ok_or_else(|| {
                    BistreError::with_detail(
                        DiagnosticKey::OtaIntegrityFailed,
                        "ota_manifest_unverified",
                    )
                })?;
            ota::stage_update_artifact_with_mode(
                &self.ota_http,
                &self.data_dir,
                &verified,
                CORE_VERSION,
                self.active_runs.load(Ordering::Relaxed),
                allow_reinstall,
            )
            .await
        })
    }
}
#[cfg(test)]
mod attachment_send_tests;
#[cfg(test)]
mod prompt_surface_tests;
