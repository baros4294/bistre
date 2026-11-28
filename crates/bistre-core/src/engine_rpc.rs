//! The one table of `EngineClient` methods the daemon answers, and `LocalIpcEngine`, the app's
//! side of that connection (ADR-0003).
//!
//! [`with_engine_rpc_table`] lists every method once. It generates both the daemon's dispatch
//! ([`dispatch_engine_rpc`]) and `LocalIpcEngine`'s `EngineClient` impl, so the compiler refuses
//! a trait method missing from the table, and the daemon answers every method the app can call.
//! Arguments travel as a JSON array in parameter order; byte payloads travel as base64.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use base64::Engine as _;
use bistre_protocol::{
    BistreError, DaemonEventFrame, DaemonRpcRequest, DiagnosticKey, lock_or_recover,
};
use serde::Serialize;
use serde::de::DeserializeOwned;

use super::{
    AgentRunRecord, AppHealthSnapshot, AppSettings, AssistantPatch, AssistantRecord,
    AttachmentInput, BistreResult, BoxFuture, CharacterCardRecord, CronJobRecord,
    CursorEventRecord, DraftRecord, EngineClient, EngineEvent, MemoryEntryRecord, ModelCatalogInfo,
    MoneyMicros, NodeRecord, NodeRole, PowerGuardStatus, ProjectRecord, ProviderDialect,
    ProviderModelInfo, ProviderPatch, ProviderProfile, RegexRuleRecord, RunStepRecord, SearchHit,
    SignedPackManifest, SteeringMessage, StorageFileEntry, StorageStats, StoryChapterRecord,
    StoryEntryRecord, StoryProgressionRecord, StorySceneRecord, StorySnapshotRecord,
    StoryThreadStateRecord, SystemPowerEvent, ThreadMode, ThreadPatch, ThreadSummary,
    UpdateCheckResult, UserPersonaRecord, WorkspaceCheckpointRecord, broadcast, hooks, mcp,
    ota_install, skills, story, tools,
};
use crate::ipc_client::{
    DaemonStream, IPC_REPLY_TIMEOUT, IPC_WORK_REPLY_TIMEOUT, open_daemon_stream,
    read_ipc_frame_when_ready, send_daemon_rpc, write_ipc_frame,
};

/// How long a call may wait for the daemon's reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RpcWait {
    /// A quick read or write: [`IPC_REPLY_TIMEOUT`].
    Reply,
    /// Long work in the daemon (a run, a download, a tool call): [`IPC_WORK_REPLY_TIMEOUT`].
    Work,
}

impl RpcWait {
    const fn limit(self) -> Duration {
        match self {
            Self::Reply => IPC_REPLY_TIMEOUT,
            Self::Work => IPC_WORK_REPLY_TIMEOUT,
        }
    }
}

/// The method name that opens the event stream instead of answering once.
pub const SUBSCRIBE_EVENTS: &str = "subscribe_events";

/// The methods written by hand on both sides, because their bytes travel as base64.
const BYTE_METHODS: [&str; 2] = ["synthesize_speech", "verify_data_pack"];

/// Calls `$callback!` with every `EngineClient` method the daemon answers:
/// `Wait fn name(arg: Type, ...) -> Return;`. `subscribe_events` (a stream) and `shutdown` (the
/// app leaving, not the daemon stopping) are not calls; the two byte methods are in
/// [`BYTE_METHODS`].
macro_rules! with_engine_rpc_table {
    ($callback:ident) => {
        $callback! {
            Reply fn health() -> AppHealthSnapshot;
            Reply fn list_projects() -> Vec<ProjectRecord>;
            Reply fn save_project(project: ProjectRecord) -> ProjectRecord;
            Reply fn delete_project(project_id: String) -> ();
            Reply fn move_thread_to_project(thread_id: String, project_id: Option<String>) -> ();
            Reply fn list_providers() -> Vec<ProviderProfile>;
            Reply fn update_provider(provider_id: String, patch: ProviderPatch) -> ProviderProfile;
            Reply fn set_provider_api_key(provider_id: String, api_key: String) -> ProviderProfile;
            Reply fn clear_provider_api_key(provider_id: String) -> ProviderProfile;
            Reply fn get_provider_api_keys(provider_id: String) -> Vec<String>;
            Work fn lookup_model_catalog_info(provider_id: String, model_id: String) -> Option<ModelCatalogInfo>;
            Reply fn create_provider(
                name: String,
                dialect: ProviderDialect,
                base_url: String,
                default_model: String,
                icon_slug: String,
                custom_icon_path: String,
                api_key: Option<String>,
            ) -> ProviderProfile;
            Reply fn create_custom_provider(
                name: String,
                base_url: String,
                default_model: String,
                api_key: Option<String>,
            ) -> ProviderProfile;
            Reply fn delete_provider(provider_id: String) -> ();
            Work fn fetch_provider_models(provider_id: String) -> Vec<ProviderModelInfo>;
            Reply fn list_assistants() -> Vec<AssistantRecord>;
            Reply fn create_assistant(
                name: String,
                role_subtitle: String,
                system_prompt: String,
                default_mode: ThreadMode,
                badge_code: String,
            ) -> AssistantRecord;
            Reply fn update_assistant(assistant_id: String, patch: AssistantPatch) -> AssistantRecord;
            Reply fn delete_assistant(assistant_id: String) -> ();
            Reply fn create_thread(
                workspace_id: Option<String>,
                title: String,
                mode: ThreadMode,
                topic: Option<String>,
                assistant_id: Option<String>,
            ) -> ThreadSummary;
            Reply fn update_thread(thread_id: String, patch: ThreadPatch) -> ThreadSummary;
            Reply fn delete_thread(thread_id: String) -> ();
            Reply fn list_threads(workspace_id: Option<String>) -> Vec<ThreadSummary>;
            Reply fn append_node(
                thread_id: String,
                parent_id: Option<String>,
                role: NodeRole,
                content: String,
                provider_meta_json: Option<String>,
            ) -> NodeRecord;
            Work fn send_and_stream_reply(
                thread_id: String,
                parent_id: Option<String>,
                user_content: String,
            ) -> NodeRecord;
            Work fn send_and_stream_reply_with_attachments(
                thread_id: String,
                parent_id: Option<String>,
                user_content: String,
                attachments: Vec<AttachmentInput>,
            ) -> NodeRecord;
            Work fn steer_active_run_now(thread_id: String, content: String) -> NodeRecord;
            Work fn import_threads_json(raw_json: String) -> u32;
            Reply fn export_settings_json() -> String;
            Reply fn import_settings_json(raw_json: String, allow_loosening: bool) -> AppSettings;
            Reply fn list_storage_files() -> Vec<StorageFileEntry>;
            Reply fn delete_storage_file(rel_path: String) -> bool;
            Work fn clean_unused_storage_files() -> u64;
            Work fn start_live_voice_session(
                provider_id: String,
                model_id: String,
                voice: String,
                system_prompt: String,
            ) -> String;
            Reply fn send_live_voice_pcm_chunk(session_id: String, pcm_base64: String) -> ();
            Reply fn send_live_voice_text(session_id: String, text: String) -> ();
            Reply fn stop_live_voice_session(session_id: String) -> ();
            Work fn regenerate_reply(thread_id: String, user_node_id: String) -> String;
            Work fn edit_user_node_and_stream(
                thread_id: String,
                node_id: String,
                new_content: String,
            ) -> NodeRecord;
            Reply fn delete_node(thread_id: String, node_id: String) -> ();
            Work fn fork_thread(thread_id: String, node_id: String) -> ThreadSummary;
            Work fn delete_from_node(thread_id: String, node_id: String) -> ();
            Work fn clear_thread_messages(thread_id: String) -> ();
            Reply fn set_node_excluded(
                thread_id: String,
                node_id: String,
                excluded: bool,
            ) -> Vec<String>;
            Reply fn list_excluded_nodes(thread_id: String) -> Vec<String>;
            Work fn edit_reply(thread_id: String, node_id: String, content: String) -> NodeRecord;
            Work fn ask_side_question(thread_id: String, question: String) -> String;
            Work fn summarize_into_new_chat(thread_id: String) -> ThreadSummary;
            Reply fn get_thread_goal(thread_id: String) -> Option<crate::goal::ThreadGoal>;
            Reply fn set_thread_goal(
                thread_id: String,
                objective: String,
            ) -> Option<crate::goal::ThreadGoal>;
            Reply fn raw_exchange(request_id: String) -> Option<crate::raw_exchange::RawExchange>;
            Work fn regenerate_reply_guided(
                thread_id: String,
                user_node_id: String,
                guidance: String,
            ) -> String;
            Work fn draft_next_message(thread_id: String, note: String) -> String;
            Work fn rewrite_passage(
                thread_id: String,
                mode: String,
                excerpt: String,
                context: String,
            ) -> String;
            Work fn plan_scene(thread_id: String, title: String, beats: String) -> String;
            Work fn summarize_chapter(
                thread_id: String,
                chapter_id: String,
            ) -> bistre_protocol::ChapterSummary;
            Reply fn list_chat_files(thread_id: String) -> Vec<crate::chat_files::ChatFile>;
            Reply fn list_app_skills() -> Vec<skills::SkillIndexEntry>;
            Work fn install_skill(source: String) -> skills::SkillIndexEntry;
            Work fn save_reply_as_skill(thread_id: String, node_id: String) -> skills::SkillIndexEntry;
            Reply fn remove_app_skill(skill_path: String) -> ();
            Work fn export_chats_zip(dest_path: String) -> u32;
            Work fn import_chats_zip(src_path: String) -> u32;
            Work fn export_character_card_png(card_id: String, dest_path: String) -> ();
            Work fn request_data_wipe() -> ();
            Work fn cancel_data_wipe() -> bool;
            Reply fn data_wipe_pending() -> bool;
            Work fn export_thread(thread_id: String, format: String) -> String;
            Work fn backup_database(dest_path: String) -> ();
            Reply fn storage_stats() -> StorageStats;
            Reply fn wallet_daily_spend_micros() -> MoneyMicros;
            Work fn search_mcp_registry(
                query: String,
                cursor: Option<String>,
            ) -> crate::mcp_registry::McpRegistryPage;
            Reply fn thread_spend_micros(thread_id: String) -> MoneyMicros;
            Reply fn wallet_usage_by_purpose(since_unix_ms: i64) -> Vec<bistre_protocol::PurposeUsage>;
            Work fn check_for_updates(feed_url_override: Option<String>) -> UpdateCheckResult;
            Work fn stage_update(check: UpdateCheckResult) -> String;
            Work fn reinstall_update(check: UpdateCheckResult) -> String;
            Reply fn pending_update_version() -> Option<String>;
            Work fn install_staged_update() -> ota_install::StagedInstall;
            Reply fn cancel_active_run(thread_id: String) -> bool;
            Reply fn retry_run_now(thread_id: String) -> bool;
            Reply fn list_nodes(thread_id: String) -> Vec<NodeRecord>;
            Reply fn save_draft(thread_id: String, text: String) -> DraftRecord;
            Reply fn load_draft(thread_id: String) -> Option<DraftRecord>;
            Reply fn load_settings() -> AppSettings;
            Reply fn save_settings(settings: AppSettings) -> AppSettings;
            Reply fn wallet_spend_micros() -> MoneyMicros;
            Reply fn search_nodes(query: String, thread_id: Option<String>, limit: u32) -> Vec<SearchHit>;
            Reply fn list_agent_runs(
                thread_id: Option<String>,
                only_active: bool,
                limit: u32,
            ) -> Vec<AgentRunRecord>;
            Reply fn list_run_steps(run_id: String) -> Vec<RunStepRecord>;
            Reply fn enqueue_steering(thread_id: String, content: String) -> SteeringMessage;
            Reply fn list_pending_steering(thread_id: String) -> Vec<SteeringMessage>;
            Reply fn delete_steering(steering_id: String) -> ();
            Reply fn power_guard_status() -> PowerGuardStatus;
            Reply fn notify_power_event(event: SystemPowerEvent) -> u32;
            Reply fn set_android_power_state(
                fgs_active: bool,
                battery_unrestricted: bool,
            ) -> PowerGuardStatus;
            Reply fn resolve_indeterminate_run(run_id: String, confirm_completed: bool) -> AgentRunRecord;
            Reply fn replay_events_after(after_cursor: u64, limit: u32) -> Vec<CursorEventRecord>;
            Reply fn latest_event_cursor() -> u64;
            Reply fn model_context_tokens(provider_id: String, model: String) -> Option<u32>;
            Work fn context_breakdown(
                thread_id: String,
                leaf_node_id: String,
                draft: String,
            ) -> crate::context_breakdown::ContextBreakdown;
            Work fn refresh_prices() -> ();
            Reply fn approve_tool_call(
                thread_id: String,
                tool_name: String,
                arguments_json: String,
            ) -> String;
            Reply fn allow_unpriced_once(thread_id: String) -> ();
            Reply fn save_provider_overrides(
                provider_id: String,
                headers_json: String,
                body_json: String,
            ) -> ();
            Reply fn allow_unpriced_media_once() -> ();
            Reply fn respond_tool_approval(
                thread_id: String,
                run_id: String,
                call_id: String,
                decision: bistre_protocol::ToolApprovalDecision,
            ) -> bool;
            Reply fn respond_host_action(
                request_id: String,
                ok: bool,
                output_text: String,
                image_base64: Option<String>,
            ) -> bool;
            Work fn execute_workspace_tool(
                workspace_root: String,
                thread_id: String,
                tool_name: String,
                arguments_json: String,
                permit_id: Option<String>,
            ) -> tools::ToolExecutionOutput;
            Work fn rewind_checkpoint(workspace_root: String, checkpoint_id: String) -> String;
            Reply fn list_checkpoints(thread_id: String, limit: u32) -> Vec<WorkspaceCheckpointRecord>;
            Work fn compact_thread(
                thread_id: String,
                keep_recent_turns: u32,
                custom_summary: Option<String>,
                instructions: Option<String>,
            ) -> NodeRecord;
            Reply fn rewrite_compaction_summary(
                thread_id: String,
                node_id: String,
                content: String,
            ) -> NodeRecord;
            Reply fn undo_compaction(thread_id: String, compaction_node_id: String) -> ();
            Reply fn set_context_start_pin(thread_id: String, node_id: Option<String>) -> Option<String>;
            Reply fn get_context_start_pin(thread_id: String) -> Option<String>;
            Work fn discover_mcp_server(server: mcp::McpServerConfig) -> mcp::McpDiscoveryReport;
            Work fn set_mcp_token(server_id: String, token: String) -> ();
            Work fn has_mcp_token(server_id: String) -> bool;
            Work fn call_mcp_tool(
                server: mcp::McpServerConfig,
                tool_name: String,
                arguments_json: String,
            ) -> String;
            Reply fn get_kv_meta(key: String) -> Option<String>;
            Reply fn set_kv_meta(key: String, value: String) -> ();
            Reply fn list_memory_entries(scope: Option<String>) -> Vec<MemoryEntryRecord>;
            Reply fn upsert_memory_entry(
                id: Option<String>,
                scope: String,
                scope_id: String,
                key: String,
                content: String,
                pinned: bool,
            ) -> MemoryEntryRecord;
            Reply fn delete_memory_entry(entry_id: String) -> ();
            Work fn discover_workspace_skills(workspace_root: String) -> Vec<skills::SkillIndexEntry>;
            Reply fn load_skill_body(workspace_root: String, skill_path: String) -> String;
            Reply fn list_thread_grounding(thread_id: String) -> Vec<crate::engine_grounding::NodeGrounding>;
            Reply fn workspace_hooks_status(workspace_root: String) -> Option<hooks::WorkspaceHooksStatus>;
            Reply fn approve_workspace_hooks(workspace_root: String, digest: String) -> ();
            Reply fn list_cron_jobs() -> Vec<CronJobRecord>;
            Reply fn upsert_cron_job(job: CronJobRecord) -> CronJobRecord;
            Reply fn delete_cron_job(job_id: String) -> ();
            Work fn start_scheduled_run(job: CronJobRecord) -> String;
            Reply fn list_character_cards() -> Vec<CharacterCardRecord>;
            Reply fn upsert_character_card(card: CharacterCardRecord) -> CharacterCardRecord;
            Reply fn delete_character_card(card_id: String) -> ();
            Work fn import_character_card_file(file_path: String) -> CharacterCardRecord;
            Reply fn export_character_card_ccv3(card_id: String) -> String;
            Reply fn list_user_personas() -> Vec<UserPersonaRecord>;
            Reply fn upsert_user_persona(persona: UserPersonaRecord) -> UserPersonaRecord;
            Reply fn list_story_entries(book_id: Option<String>) -> Vec<StoryEntryRecord>;
            Reply fn upsert_story_entry(entry: StoryEntryRecord) -> StoryEntryRecord;
            Reply fn delete_story_entry(entry_id: String) -> ();
            Reply fn list_story_progressions(entry_id: Option<String>) -> Vec<StoryProgressionRecord>;
            Reply fn add_story_progression(prog: StoryProgressionRecord) -> StoryProgressionRecord;
            Reply fn list_story_chapters(thread_id: String) -> Vec<StoryChapterRecord>;
            Reply fn upsert_story_chapter(chapter: StoryChapterRecord) -> StoryChapterRecord;
            Reply fn list_story_scenes(chapter_id: String) -> Vec<StorySceneRecord>;
            Reply fn upsert_story_scene(scene: StorySceneRecord) -> StorySceneRecord;
            Reply fn load_story_thread_state(thread_id: String) -> StoryThreadStateRecord;
            Reply fn save_story_thread_state(state: StoryThreadStateRecord) -> StoryThreadStateRecord;
            Reply fn list_regex_rules() -> Vec<RegexRuleRecord>;
            Reply fn upsert_regex_rule(rule: RegexRuleRecord) -> RegexRuleRecord;
            Reply fn list_story_snapshots(
                entity_type: String,
                entity_id: String,
                limit: u32,
            ) -> Vec<StorySnapshotRecord>;
            Work fn inspect_story_prompt(
                thread_id: String,
                active_scene_beats: Option<String>,
            ) -> story::prompt_assembler::CompiledPromptReport;
            Work fn inspect_next_request(
                thread_id: String,
                draft: String,
            ) -> crate::engine_story::InspectedRequest;
            Work fn generate_thread_title(thread_id: String) -> ThreadSummary;
            Work fn translate_node(
                thread_id: String,
                node_id: String,
                target_language: Option<String>,
            ) -> NodeRecord;
            Reply fn export_provider_share_code(provider_id: String, include_api_key: bool) -> String;
            Reply fn import_provider_share_code(code: String) -> ProviderProfile;
            Reply fn list_nodes_window(
                thread_id: String,
                before_node_id: Option<String>,
                limit: usize,
            ) -> Vec<NodeRecord>;
            Reply fn thread_history_rev(thread_id: String) -> i64;
        }
    };
}

pub(crate) use with_engine_rpc_table;

macro_rules! rpc_method_names {
    ($($wait:ident fn $name:ident ($($arg:ident : $ty:ty),* $(,)?) -> $ret:ty;)*) => {
        /// Every method name the daemon answers once (the event stream is [`SUBSCRIBE_EVENTS`]).
        pub const ENGINE_RPC_METHODS: &[&str] =
            &[$(stringify!($name),)* BYTE_METHODS[0], BYTE_METHODS[1]];
    };
}
with_engine_rpc_table!(rpc_method_names);

fn parse_params<T: DeserializeOwned>(params: serde_json::Value) -> BistreResult<T> {
    serde_json::from_value(params)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "rpc_params"))
}

fn to_payload<T: Serialize>(value: &T) -> BistreResult<serde_json::Value> {
    serde_json::to_value(value)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "rpc_encode"))
}

fn from_base64(raw: &str) -> BistreResult<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
        .decode(raw)
        .map_err(|_| BistreError::with_detail(DiagnosticKey::InvalidInput, "rpc_base64"))
}

fn to_base64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

macro_rules! rpc_dispatch {
    ($($wait:ident fn $name:ident ($($arg:ident : $ty:ty),* $(,)?) -> $ret:ty;)*) => {
        /// Answers one call by name with the engine's own method. An unknown name is refused
        /// (`unknown_rpc_method`); arguments that do not parse are refused (`rpc_params`).
        pub async fn dispatch_engine_rpc(
            engine: &dyn EngineClient,
            method: &str,
            params: serde_json::Value,
        ) -> BistreResult<serde_json::Value> {
            match method {
                $(stringify!($name) => {
                    let ($($arg,)*): ($($ty,)*) = parse_params(params)?;
                    to_payload(&engine.$name($($arg),*).await?)
                })*
                "synthesize_speech" => {
                    let (provider_id, model_id, text, voice): (String, String, String, Option<String>) =
                        parse_params(params)?;
                    let audio = engine.synthesize_speech(provider_id, model_id, text, voice).await?;
                    to_payload(&to_base64(&audio))
                }
                "verify_data_pack" => {
                    let (public_key_b64, manifest_b64, manifest_sig_text, payload_b64): (
                        String,
                        String,
                        String,
                        String,
                    ) = parse_params(params)?;
                    to_payload(
                        &engine
                            .verify_data_pack(
                                public_key_b64,
                                from_base64(&manifest_b64)?,
                                manifest_sig_text,
                                from_base64(&payload_b64)?,
                            )
                            .await?,
                    )
                }
                _ => Err(BistreError::with_detail(
                    DiagnosticKey::InvalidInput,
                    "unknown_rpc_method",
                )),
            }
        }
    };
}
with_engine_rpc_table!(rpc_dispatch);

/// Runs a daemon restart for `LocalIpcEngine` when its connection is lost.
pub type DaemonRelauncher = Arc<dyn Fn() -> BistreResult<()> + Send + Sync>;

/// The app's engine on desktop when `bistre-daemon` owns the data folder: every call goes to
/// the daemon over the user-only pipe or socket, and its events arrive on one long-lived
/// subscription that replays what was logged while it was away.
pub struct LocalIpcEngine {
    endpoint: String,
    next_request_id: AtomicU64,
    events_tx: broadcast::Sender<EngineEvent>,
    follower: std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl std::fmt::Debug for LocalIpcEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocalIpcEngine")
            .field("endpoint", &self.endpoint)
            .finish_non_exhaustive()
    }
}

/// Events buffered for the app's subscribers (the same bound as the in-process engine).
const EVENT_BUFFER: usize = 1024;

impl LocalIpcEngine {
    /// Connects to the daemon at `endpoint` and starts following its events. `relaunch` starts
    /// the daemon again when the connection is lost (at most [`MAX_RELAUNCHES`] per
    /// [`RELAUNCH_WINDOW`]).
    pub async fn connect(
        endpoint: String,
        relaunch: Option<DaemonRelauncher>,
    ) -> BistreResult<Arc<Self>> {
        let (events_tx, _) = broadcast::channel(EVENT_BUFFER);
        // The first subscription must succeed: it is also what keeps the daemon attached.
        let stream = subscribe(&endpoint, None).await?;
        let engine = Arc::new(Self {
            endpoint: endpoint.clone(),
            next_request_id: AtomicU64::new(1),
            events_tx: events_tx.clone(),
            follower: std::sync::Mutex::new(None),
        });
        let follower = tokio::spawn(follow_events(endpoint, stream, events_tx, relaunch));
        *lock_or_recover(&engine.follower, "ipc_follower") = Some(follower);
        Ok(engine)
    }

    /// The core version of the daemon answering at `endpoint`.
    pub async fn probe_version(endpoint: &str) -> BistreResult<String> {
        let request = DaemonRpcRequest {
            request_id: 0,
            method: "health".to_owned(),
            params: serde_json::Value::Null,
        };
        let response =
            send_daemon_rpc(endpoint, request, crate::ipc_client::IPC_FRAME_TIMEOUT).await?;
        if let Some(err) = response.error {
            return Err(err);
        }
        let health: AppHealthSnapshot = serde_json::from_value(response.payload)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "rpc_decode"))?;
        Ok(health.core_version)
    }

    async fn call<P, R>(&self, method: &str, wait: RpcWait, params: P) -> BistreResult<R>
    where
        P: Serialize,
        R: DeserializeOwned,
    {
        let request_id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
        let request = DaemonRpcRequest {
            request_id,
            method: method.to_owned(),
            params: to_payload(&params)?,
        };
        let response = send_daemon_rpc(&self.endpoint, request, wait.limit()).await?;
        if response.request_id != request_id {
            return Err(BistreError::with_detail(
                DiagnosticKey::DaemonUnavailable,
                "ipc_reply_mismatch",
            ));
        }
        if let Some(err) = response.error {
            return Err(err);
        }
        serde_json::from_value(response.payload)
            .map_err(|_| BistreError::with_detail(DiagnosticKey::InternalError, "rpc_decode"))
    }

    fn stop_following(&self) {
        if let Some(task) = lock_or_recover(&self.follower, "ipc_follower").take() {
            task.abort();
        }
    }
}

impl Drop for LocalIpcEngine {
    fn drop(&mut self) {
        self.stop_following();
    }
}

macro_rules! rpc_client_methods {
    ($($wait:ident fn $name:ident ($($arg:ident : $ty:ty),* $(,)?) -> $ret:ty;)*) => {
        $(fn $name(&self, $($arg: $ty),*) -> BoxFuture<'_, BistreResult<$ret>> {
            Box::pin(self.call(stringify!($name), RpcWait::$wait, ($($arg,)*)))
        })*
    };
}

impl EngineClient for LocalIpcEngine {
    with_engine_rpc_table!(rpc_client_methods);

    fn synthesize_speech(
        &self,
        provider_id: String,
        model_id: String,
        text: String,
        voice: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<u8>>> {
        Box::pin(async move {
            let audio: String = self
                .call(
                    BYTE_METHODS[0],
                    RpcWait::Work,
                    (provider_id, model_id, text, voice),
                )
                .await?;
            from_base64(&audio)
        })
    }

    fn verify_data_pack(
        &self,
        public_key_b64: String,
        manifest_bytes: Vec<u8>,
        manifest_sig_text: String,
        pack_payload: Vec<u8>,
    ) -> BoxFuture<'_, BistreResult<SignedPackManifest>> {
        let params = (
            public_key_b64,
            to_base64(&manifest_bytes),
            manifest_sig_text,
            to_base64(&pack_payload),
        );
        Box::pin(self.call(BYTE_METHODS[1], RpcWait::Work, params))
    }

    fn subscribe_events(&self) -> broadcast::Receiver<EngineEvent> {
        self.events_tx.subscribe()
    }

    /// The app is leaving: end the event subscription so the daemon knows it was left alone.
    /// The daemon keeps running while work is live and exits on its own once idle.
    fn shutdown(&self) -> BoxFuture<'_, BistreResult<()>> {
        self.stop_following();
        Box::pin(async { Ok(()) })
    }
}

/// Opens the event stream. With `after`, the daemon first replays what it logged after that
/// cursor; the first frame without an event says where the stream stands.
async fn subscribe(endpoint: &str, after: Option<u64>) -> BistreResult<DaemonStream> {
    let mut stream = open_daemon_stream(endpoint).await?;
    let request = DaemonRpcRequest {
        request_id: 0,
        method: SUBSCRIBE_EVENTS.to_owned(),
        params: to_payload(&(after,))?,
    };
    write_ipc_frame(&mut stream, &request).await?;
    Ok(stream)
}

/// Daemon restarts allowed within [`RELAUNCH_WINDOW`] before the app stops trying.
pub const MAX_RELAUNCHES: usize = 3;
/// The window [`MAX_RELAUNCHES`] counts over.
pub const RELAUNCH_WINDOW: Duration = Duration::from_mins(10);
/// Reconnect attempts after the stream drops (backoff 100 ms doubling to 2 s).
const RECONNECT_ATTEMPTS: u32 = 6;

/// Forwards the daemon's events to the app's subscribers and, when the connection drops,
/// reconnects (starting the daemon again within the budget), replaying from the last cursor.
/// When the daemon cannot be reached again it says so once and stops: nothing polls.
async fn follow_events(
    endpoint: String,
    first: DaemonStream,
    tx: broadcast::Sender<EngineEvent>,
    relaunch: Option<DaemonRelauncher>,
) {
    let mut relaunches: std::collections::VecDeque<std::time::Instant> =
        std::collections::VecDeque::new();
    let mut stream = first;
    let mut cursor: Option<u64> = None;
    loop {
        let ended = forward_frames(&mut stream, &tx, &mut cursor).await;
        tracing::info!(key = ended.key.as_key(), "daemon event stream ended");
        let Some(next) = reconnect(&endpoint, cursor, relaunch.as_ref(), &mut relaunches).await
        else {
            crate::events::emit(
                &tx,
                EngineEvent::DiagnosticRaised {
                    key: DiagnosticKey::DaemonUnavailable,
                    detail_code: Some("daemon_lost".to_owned()),
                },
            );
            return;
        };
        stream = next;
    }
}

/// Reads frames until the stream ends, forwarding each event and keeping the cursor.
async fn forward_frames(
    stream: &mut DaemonStream,
    tx: &broadcast::Sender<EngineEvent>,
    cursor: &mut Option<u64>,
) -> BistreError {
    loop {
        match read_ipc_frame_when_ready::<_, DaemonEventFrame>(stream).await {
            Ok(frame) => {
                *cursor = Some(cursor.map_or(frame.cursor, |c| c.max(frame.cursor)));
                if let Some(event) = frame.event {
                    crate::events::emit(tx, event);
                }
            }
            Err(err) => return err,
        }
    }
}

async fn reconnect(
    endpoint: &str,
    cursor: Option<u64>,
    relaunch: Option<&DaemonRelauncher>,
    relaunches: &mut std::collections::VecDeque<std::time::Instant>,
) -> Option<DaemonStream> {
    for attempt in 0..RECONNECT_ATTEMPTS {
        let backoff = Duration::from_millis(100_u64.saturating_mul(1 << attempt).min(2_000));
        tokio::time::sleep(backoff).await;
        match subscribe(endpoint, cursor).await {
            Ok(sub) => return Some(sub),
            Err(err) => {
                tracing::info!(key = err.key.as_key(), attempt, "daemon reconnect failed");
            }
        }
        if attempt == 0
            && let Some(relaunch) = relaunch
        {
            let now = std::time::Instant::now();
            while relaunches
                .front()
                .is_some_and(|t| now.duration_since(*t) > RELAUNCH_WINDOW)
            {
                relaunches.pop_front();
            }
            if relaunches.len() < MAX_RELAUNCHES {
                relaunches.push_back(now);
                if let Err(err) = relaunch() {
                    tracing::warn!(key = err.key.as_key(), "daemon could not be started again");
                }
            }
        }
    }
    None
}
