//! Pure Rust domain engine for Bistre (ADR-0003).
//!
//! Invariants:
//! - Zero dependency on Flutter, `flutter_rust_bridge`, GUI toolkits, or OS tray crates.
//! - Unifies Embedded (Android), Local Daemon (Desktop IPC), and Remote Bridge behind `EngineClient`.
//! - Stores API keys strictly in node-local `SecretVault` (Windows DPAPI / OS vault), never plaintext SQLite.
//! - Streams real responses over pure `rustls` + `reqwest 0.13` across Big 3 + Custom dialects (Spec 02).

pub mod agent;
pub mod approval;
pub mod compaction;
pub mod credentials;
pub mod cron;
pub mod error_policy;
mod events;
pub mod hooks;
pub mod http_clients;
pub mod import_policy;
pub mod ipc_client;
pub mod mcp;
pub mod net;
pub mod ota;
pub mod power;
pub mod process_util;
pub mod providers;
pub mod registry;
pub mod skills;
pub mod sse;
pub mod ssrf;
pub mod story;
pub mod subagents;
pub mod tools;
pub mod vault_key;
pub mod wallet;

mod engine_client;
mod engine_impl;
mod engine_runs;
#[cfg(test)]
mod tests;

pub use bistre_crypto::VaultKey;
use bistre_protocol::lock_or_recover;
pub use engine_client::EngineClient;
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
    AgentRunRecord, AppHealthSnapshot, AppSettings, AssistantPatch, AssistantRecord, BistreError,
    BistreResult, CharacterCardRecord, CronJobRecord, CursorEventRecord, DiagnosticKey,
    DraftRecord, EngineEvent, GenerationParams, MemoryEntryRecord, MoneyMicros, NodeRecord,
    NodeRole, PowerGuardStatus, ProviderDialect, ProviderModelInfo, ProviderPatch, ProviderProfile,
    RegexRuleRecord, RunStatus, RunStepKind, RunStepRecord, SearchHit, SignedPackManifest,
    SteeringMessage, StorageStats, StoryChapterRecord, StoryEntryRecord, StoryProgressionRecord,
    StorySceneRecord, StorySnapshotRecord, StoryThreadStateRecord, StreamChunk, SystemPowerEvent,
    ThreadMode, ThreadPatch, ThreadSummary, ToolRiskTier, UpdateCheckResult, UserPersonaRecord,
    WorkspaceCheckpointRecord, WorkspaceSummary,
};
use bistre_storage::{AgentRunUpdate, CreateAgentRunParams, StorageHandle};
use credentials::KeyRing;
use power::{NoopPowerGuardBackend, PowerCoordinator, PowerGuardBackend, PowerLeasePolicy};
use tokio::sync::{Notify, broadcast};
use uuid::Uuid;
use zeroize::Zeroizing;

/// Crate semver exposed in health diagnostics.
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

const EVENT_BUS_CAPACITY: usize = 256;

/// Boxed future type for object-safe async `EngineClient` implementations.
pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// In-process pure-Rust engine backed by `StorageHandle`, `LocalSecretVault`, `PowerCoordinator`, and pure `rustls` HTTP.
pub struct InProcessEngine {
    data_dir: PathBuf,
    storage: Arc<StorageHandle>,
    vault: Arc<dyn SecretVault>,
    http: reqwest::Client,
    /// Hardened transport for every model-directed fetch (never the provider client).
    web: ssrf::PublicWebTransport,
    /// Loopback-or-public MCP HTTP transport (redirects refused, per-call timeout).
    mcp_http: mcp::McpHttpTransport,
    /// Live single-flight pricing registry (no hardcoded model rates).
    pricing: Arc<registry::PricingRegistry>,
    /// Per-thread backoff wakers (`Retry now` and cancel wake a waiting run instantly).
    wakers: Arc<Mutex<HashMap<String, Arc<Notify>>>>,
    /// Run-scoped stale-read guard for workspace edits.
    read_ledger: tools::ReadLedger,
    /// Single tool dispatch gate (one-use permits, synchronous revocation).
    broker: approval::ToolApprovalBroker,
    power: Arc<PowerCoordinator>,
    events_tx: broadcast::Sender<EngineEvent>,
    active_runs: Arc<AtomicU32>,
    cancellations: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
    /// The last signature-verified OTA manifest; `stage_update` acts only on this, never on
    /// fields round-tripped through the UI.
    verified_update: Arc<Mutex<Option<ota::VerifiedManifest>>>,
    /// Every spawned run; shutdown cancels and drains them before closing storage.
    run_tasks: Arc<Mutex<tokio::task::JoinSet<()>>>,
    /// Release key override (tests only); unset uses `ota::OFFICIAL_RELEASE_PUBKEY_B64`.
    ota_release_key: std::sync::OnceLock<String>,
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
        let dir = data_dir.as_ref().to_path_buf();
        let db_path = dir.join("bistre.sqlite");
        let storage = StorageHandle::open(db_path)?;
        // No run exists yet, so any outstanding reservation is from a crash; release it.
        storage.release_all_wallet_reservations()?;
        let vault: Arc<dyn SecretVault> = Arc::new(LocalSecretVault::open(&dir, vault_key)?);
        let http = providers::build_http_client()?;
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
        if settings.as_ref().is_some_and(|s| s.pricing_auto_refresh) {
            pricing.ensure_fresh(&web);
        }
        let (events_tx, _) = broadcast::channel(EVENT_BUS_CAPACITY);
        Ok(Arc::new(Self {
            data_dir: dir,
            storage,
            vault,
            http,
            web,
            mcp_http: mcp::McpHttpTransport::new(),
            pricing,
            wakers: Arc::new(Mutex::new(HashMap::new())),
            read_ledger: tools::ReadLedger::default(),
            broker: approval::ToolApprovalBroker::new(),
            power,
            events_tx,
            active_runs: Arc::new(AtomicU32::new(0)),
            cancellations: Arc::new(Mutex::new(HashMap::new())),
            verified_update: Arc::new(Mutex::new(None)),
            run_tasks: Arc::new(Mutex::new(tokio::task::JoinSet::new())),
            ota_release_key: std::sync::OnceLock::new(),
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

        let requested_provider_id = thread
            .provider_id_override
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .or_else(|| {
                assistant
                    .map(|a| a.default_provider_id.trim())
                    .filter(|s| !s.is_empty())
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
                    .find(|p| p.is_enabled && (!p.dialect.requires_api_key() || p.has_api_key))
                    .cloned()
            })
            .ok_or_else(|| BistreError::new(DiagnosticKey::ProviderNotConfigured))?;

        let api_key = self.load_key_ring(&selected.id)?;
        if selected.dialect.requires_api_key() && api_key.is_empty() {
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

        let gen_params = GenerationParams {
            temperature_milli: thread
                .temperature_milli
                .or_else(|| assistant.and_then(|a| a.temperature_milli)),
            max_output_tokens: thread
                .max_output_tokens
                .or_else(|| assistant.and_then(|a| a.max_output_tokens)),
            top_p_milli: thread
                .top_p_milli
                .or_else(|| assistant.and_then(|a| a.top_p_milli)),
        };

        Ok((selected, api_key, model, gen_params))
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
    ) -> BistreResult<String> {
        let settings = self.storage.load_settings()?;
        let durable_run = self.storage.create_agent_run(CreateAgentRunParams {
            thread_id: thread.id.clone(),
            parent_run_id: None,
            root_node_id: Some(parent_user_node_id.clone()),
            mode: thread.mode,
            max_steps: engine_runs::MAX_RUN_STEPS,
            unattended_policy: settings.unattended_policy,
            worktree_path: None,
        })?;

        let pending_id = Uuid::now_v7().to_string();
        let cancel_flag = Arc::new(AtomicBool::new(false));
        let mut guard = lock_or_recover(&self.cancellations, "cancellations");
        if let Some(prev) = guard.insert(thread.id.clone(), Arc::clone(&cancel_flag)) {
            prev.store(true, Ordering::SeqCst);
        }

        let wake = Arc::new(Notify::new());
        {
            let mut guard = lock_or_recover(&self.wakers, "wakers");
            guard.insert(thread.id.clone(), Arc::clone(&wake));
        }
        let wakers = Arc::clone(&self.wakers);
        let services = StreamServices {
            http: self.http.clone(),
            pricing: Arc::clone(&self.pricing),
            wake,
        };
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

            {
                let mut guard = lock_or_recover(&cancellations, "cancellations");
                guard.remove(&thread_id);
            }
            {
                let mut guard = lock_or_recover(&wakers, "wakers");
                guard.remove(&thread_id);
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
}
