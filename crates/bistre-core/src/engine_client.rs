//! The `EngineClient` boundary shared by in-process, daemon IPC, and remote bridge engines.

use super::{
    AgentRunRecord, AppHealthSnapshot, AppSettings, AssistantPatch, AssistantRecord, BistreResult,
    BoxFuture, CharacterCardRecord, CronJobRecord, CursorEventRecord, DraftRecord, EngineEvent,
    MemoryEntryRecord, MoneyMicros, NodeRecord, NodeRole, PowerGuardStatus, ProviderDialect,
    ProviderModelInfo, ProviderPatch, ProviderProfile, RegexRuleRecord, RunStepRecord, SearchHit,
    SignedPackManifest, SteeringMessage, StorageStats, StoryChapterRecord, StoryEntryRecord,
    StoryProgressionRecord, StorySceneRecord, StorySnapshotRecord, StoryThreadStateRecord,
    SystemPowerEvent, ThreadMode, ThreadPatch, ThreadSummary, UpdateCheckResult, UserPersonaRecord,
    WorkspaceCheckpointRecord, WorkspaceSummary, broadcast, hooks, mcp, skills, story, subagents,
    tools,
};

/// What the next request for one branch sends, split the way the composer's context breakdown
/// shows it. Counts are estimates (about 4 characters per token, plus a small frame per turn).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ContextUsage {
    /// The assistant's or chat's system prompt.
    pub system_tokens: u64,
    /// Write mode only: story notes, cards, persona, lore, and chapters added to the prompt.
    pub story_tokens: u64,
    /// The turns the request resends (after any compaction or context pin).
    pub history_tokens: u64,
    /// How many turns that is.
    pub history_turns: u32,
    /// The unsent composer draft.
    pub draft_tokens: u64,
}

impl ContextUsage {
    /// Everything the next request would send, draft included.
    #[must_use]
    pub fn total(&self) -> u64 {
        self.system_tokens
            .saturating_add(self.story_tokens)
            .saturating_add(self.history_tokens)
            .saturating_add(self.draft_tokens)
    }
}

/// Unified engine boundary implemented by:
/// - `InProcessEngine` (Android embedded & desktop direct mode)
/// - `LocalIpcEngine` (Desktop UDS/Named Pipe to `bistre-daemon`)
/// - `RemoteBridgeEngine` (LAN/Tailscale TLS 1.3 mTLS WebSocket)
pub trait EngineClient: Send + Sync {
    fn health(&self) -> BoxFuture<'_, BistreResult<AppHealthSnapshot>>;
    fn list_workspaces(&self) -> BoxFuture<'_, BistreResult<Vec<WorkspaceSummary>>>;
    fn list_providers(&self) -> BoxFuture<'_, BistreResult<Vec<ProviderProfile>>>;
    fn update_provider(
        &self,
        provider_id: String,
        patch: ProviderPatch,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>>;
    fn set_provider_api_key(
        &self,
        provider_id: String,
        api_key: String,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>>;
    fn clear_provider_api_key(
        &self,
        provider_id: String,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>>;
    #[expect(
        clippy::too_many_arguments,
        reason = "Explicit provider creation fields map directly across EngineClient implementations."
    )]
    fn create_provider(
        &self,
        name: String,
        dialect: ProviderDialect,
        base_url: String,
        default_model: String,
        icon_slug: String,
        custom_icon_path: String,
        api_key: Option<String>,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>>;
    fn create_custom_provider(
        &self,
        name: String,
        base_url: String,
        default_model: String,
        api_key: Option<String>,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>>;
    fn delete_provider(&self, provider_id: String) -> BoxFuture<'_, BistreResult<()>>;
    fn fetch_provider_models(
        &self,
        provider_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<ProviderModelInfo>>>;
    fn list_assistants(&self) -> BoxFuture<'_, BistreResult<Vec<AssistantRecord>>>;
    fn create_assistant(
        &self,
        name: String,
        role_subtitle: String,
        system_prompt: String,
        default_mode: ThreadMode,
        badge_code: String,
    ) -> BoxFuture<'_, BistreResult<AssistantRecord>>;
    fn update_assistant(
        &self,
        assistant_id: String,
        patch: AssistantPatch,
    ) -> BoxFuture<'_, BistreResult<AssistantRecord>>;
    fn delete_assistant(&self, assistant_id: String) -> BoxFuture<'_, BistreResult<()>>;
    fn create_thread(
        &self,
        workspace_id: Option<String>,
        title: String,
        mode: ThreadMode,
        topic: Option<String>,
        assistant_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>>;
    fn update_thread(
        &self,
        thread_id: String,
        patch: ThreadPatch,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>>;
    fn delete_thread(&self, thread_id: String) -> BoxFuture<'_, BistreResult<()>>;
    fn list_threads(
        &self,
        workspace_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<ThreadSummary>>>;
    fn append_node(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        role: NodeRole,
        content: String,
        provider_meta_json: Option<String>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>>;
    fn send_and_stream_reply(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        user_content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>>;
    fn regenerate_reply(
        &self,
        thread_id: String,
        user_node_id: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    fn edit_user_node_and_stream(
        &self,
        thread_id: String,
        node_id: String,
        new_content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>>;
    fn delete_node(&self, thread_id: String, node_id: String) -> BoxFuture<'_, BistreResult<()>>;
    fn export_thread(
        &self,
        thread_id: String,
        format: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    fn backup_database(&self, dest_path: String) -> BoxFuture<'_, BistreResult<()>>;
    fn storage_stats(&self) -> BoxFuture<'_, BistreResult<StorageStats>>;
    fn wallet_daily_spend_micros(&self) -> BoxFuture<'_, BistreResult<MoneyMicros>>;
    fn check_for_updates(
        &self,
        feed_url_override: Option<String>,
    ) -> BoxFuture<'_, BistreResult<UpdateCheckResult>>;
    fn stage_update(&self, check: UpdateCheckResult) -> BoxFuture<'_, BistreResult<String>>;
    fn cancel_active_run(&self, thread_id: String) -> BoxFuture<'_, BistreResult<bool>>;
    /// Ends a backoff wait immediately (`Retry now`). Returns `false` when no run is waiting.
    fn retry_run_now(&self, thread_id: String) -> BoxFuture<'_, BistreResult<bool>>;
    fn list_nodes(&self, thread_id: String) -> BoxFuture<'_, BistreResult<Vec<NodeRecord>>>;
    fn save_draft(
        &self,
        thread_id: String,
        text: String,
    ) -> BoxFuture<'_, BistreResult<DraftRecord>>;
    fn load_draft(&self, thread_id: String) -> BoxFuture<'_, BistreResult<Option<DraftRecord>>>;
    fn load_settings(&self) -> BoxFuture<'_, BistreResult<AppSettings>>;
    fn save_settings(&self, settings: AppSettings) -> BoxFuture<'_, BistreResult<AppSettings>>;
    fn wallet_spend_micros(&self) -> BoxFuture<'_, BistreResult<MoneyMicros>>;
    fn search_nodes(
        &self,
        query: String,
        thread_id: Option<String>,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<SearchHit>>>;
    fn verify_data_pack(
        &self,
        public_key_b64: String,
        manifest_bytes: Vec<u8>,
        manifest_sig_text: String,
        pack_payload: Vec<u8>,
    ) -> BoxFuture<'_, BistreResult<SignedPackManifest>>;
    fn list_agent_runs(
        &self,
        thread_id: Option<String>,
        only_active: bool,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<AgentRunRecord>>>;
    fn list_run_steps(&self, run_id: String) -> BoxFuture<'_, BistreResult<Vec<RunStepRecord>>>;
    fn enqueue_steering(
        &self,
        thread_id: String,
        content: String,
    ) -> BoxFuture<'_, BistreResult<SteeringMessage>>;
    fn list_pending_steering(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<SteeringMessage>>>;
    fn delete_steering(&self, steering_id: String) -> BoxFuture<'_, BistreResult<()>>;
    fn power_guard_status(&self) -> BoxFuture<'_, BistreResult<PowerGuardStatus>>;
    fn notify_power_event(&self, event: SystemPowerEvent) -> BoxFuture<'_, BistreResult<u32>>;
    fn set_android_power_state(
        &self,
        fgs_active: bool,
        battery_unrestricted: bool,
    ) -> BoxFuture<'_, BistreResult<PowerGuardStatus>>;
    fn resolve_indeterminate_run(
        &self,
        run_id: String,
        confirm_completed: bool,
    ) -> BoxFuture<'_, BistreResult<AgentRunRecord>>;
    fn replay_events_after(
        &self,
        after_cursor: u64,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<CursorEventRecord>>>;
    fn latest_event_cursor(&self) -> BoxFuture<'_, BistreResult<u64>>;
    /// The model's conversation limit in tokens, from the cached public model lists.
    fn model_context_tokens(&self, model: String) -> BoxFuture<'_, BistreResult<Option<u32>>>;
    /// What the next request sends for the branch ending at `leaf_node_id`, by category,
    /// counting `draft` as the message about to be sent.
    fn context_usage(
        &self,
        thread_id: String,
        leaf_node_id: String,
        draft: String,
    ) -> BoxFuture<'_, BistreResult<ContextUsage>>;
    /// Starts a public price-list refresh now (the user's "Update prices now").
    fn refresh_prices(&self) -> BoxFuture<'_, BistreResult<()>>;
    /// Records the user's approval of one exact tool call; returns a one-use permit id.
    fn approve_tool_call(
        &self,
        thread_id: String,
        tool_name: String,
        arguments_json: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    /// Runs a tool. Tier 0 is auto-approved by core policy; every other tier needs the
    /// `permit_id` from `approve_tool_call` for exactly these arguments.
    fn execute_workspace_tool(
        &self,
        workspace_root: String,
        thread_id: String,
        tool_name: String,
        arguments_json: String,
        permit_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<tools::ToolExecutionOutput>>;
    fn rewind_checkpoint(
        &self,
        workspace_root: String,
        checkpoint_id: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    fn list_checkpoints(
        &self,
        thread_id: String,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<WorkspaceCheckpointRecord>>>;
    fn compact_thread(
        &self,
        thread_id: String,
        keep_recent_turns: u32,
        custom_summary: Option<String>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>>;
    fn undo_compaction(
        &self,
        thread_id: String,
        compaction_node_id: String,
    ) -> BoxFuture<'_, BistreResult<()>>;
    fn set_context_start_pin(
        &self,
        thread_id: String,
        node_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Option<String>>>;
    fn get_context_start_pin(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<String>>>;
    fn discover_mcp_server(
        &self,
        server: mcp::McpServerConfig,
    ) -> BoxFuture<'_, BistreResult<mcp::McpDiscoveryReport>>;
    fn call_mcp_tool(
        &self,
        server: mcp::McpServerConfig,
        tool_name: String,
        arguments_json: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    fn get_kv_meta(&self, key: String) -> BoxFuture<'_, BistreResult<Option<String>>>;
    fn set_kv_meta(&self, key: String, value: String) -> BoxFuture<'_, BistreResult<()>>;
    fn list_memory_entries(
        &self,
        scope: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<MemoryEntryRecord>>>;
    fn upsert_memory_entry(
        &self,
        id: Option<String>,
        scope: String,
        scope_id: String,
        key: String,
        content: String,
        pinned: bool,
    ) -> BoxFuture<'_, BistreResult<MemoryEntryRecord>>;
    fn delete_memory_entry(&self, entry_id: String) -> BoxFuture<'_, BistreResult<()>>;
    fn discover_workspace_skills(
        &self,
        workspace_root: String,
    ) -> BoxFuture<'_, BistreResult<Vec<skills::SkillIndexEntry>>>;
    fn load_skill_body(
        &self,
        workspace_root: String,
        skill_path: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    fn list_workspace_hooks(
        &self,
        workspace_root: String,
    ) -> BoxFuture<'_, BistreResult<Vec<hooks::WorkspaceHookConfig>>>;
    fn list_cron_jobs(&self) -> BoxFuture<'_, BistreResult<Vec<CronJobRecord>>>;
    fn upsert_cron_job(&self, job: CronJobRecord) -> BoxFuture<'_, BistreResult<CronJobRecord>>;
    fn delete_cron_job(&self, job_id: String) -> BoxFuture<'_, BistreResult<()>>;
    fn prepare_subagent_sandbox(
        &self,
        workspace_root: String,
    ) -> BoxFuture<'_, BistreResult<subagents::SubagentSandbox>>;
    fn list_character_cards(&self) -> BoxFuture<'_, BistreResult<Vec<CharacterCardRecord>>>;
    fn upsert_character_card(
        &self,
        card: CharacterCardRecord,
    ) -> BoxFuture<'_, BistreResult<CharacterCardRecord>>;
    fn delete_character_card(&self, card_id: String) -> BoxFuture<'_, BistreResult<()>>;
    fn import_character_card_file(
        &self,
        file_path: String,
    ) -> BoxFuture<'_, BistreResult<CharacterCardRecord>>;
    fn export_character_card_ccv3(&self, card_id: String) -> BoxFuture<'_, BistreResult<String>>;
    fn list_user_personas(&self) -> BoxFuture<'_, BistreResult<Vec<UserPersonaRecord>>>;
    fn upsert_user_persona(
        &self,
        persona: UserPersonaRecord,
    ) -> BoxFuture<'_, BistreResult<UserPersonaRecord>>;
    fn list_story_entries(
        &self,
        book_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<StoryEntryRecord>>>;
    fn upsert_story_entry(
        &self,
        entry: StoryEntryRecord,
    ) -> BoxFuture<'_, BistreResult<StoryEntryRecord>>;
    fn delete_story_entry(&self, entry_id: String) -> BoxFuture<'_, BistreResult<()>>;
    fn list_story_progressions(
        &self,
        entry_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<StoryProgressionRecord>>>;
    fn add_story_progression(
        &self,
        prog: StoryProgressionRecord,
    ) -> BoxFuture<'_, BistreResult<StoryProgressionRecord>>;
    fn list_story_chapters(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<StoryChapterRecord>>>;
    fn upsert_story_chapter(
        &self,
        chapter: StoryChapterRecord,
    ) -> BoxFuture<'_, BistreResult<StoryChapterRecord>>;
    fn list_story_scenes(
        &self,
        chapter_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<StorySceneRecord>>>;
    fn upsert_story_scene(
        &self,
        scene: StorySceneRecord,
    ) -> BoxFuture<'_, BistreResult<StorySceneRecord>>;
    fn load_story_thread_state(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<StoryThreadStateRecord>>;
    fn save_story_thread_state(
        &self,
        state: StoryThreadStateRecord,
    ) -> BoxFuture<'_, BistreResult<StoryThreadStateRecord>>;
    fn list_regex_rules(&self) -> BoxFuture<'_, BistreResult<Vec<RegexRuleRecord>>>;
    fn upsert_regex_rule(
        &self,
        rule: RegexRuleRecord,
    ) -> BoxFuture<'_, BistreResult<RegexRuleRecord>>;
    fn list_story_snapshots(
        &self,
        entity_type: String,
        entity_id: String,
        limit: u32,
    ) -> BoxFuture<'_, BistreResult<Vec<StorySnapshotRecord>>>;
    fn inspect_story_prompt(
        &self,
        thread_id: String,
        active_scene_beats: Option<String>,
    ) -> BoxFuture<'_, BistreResult<story::prompt_assembler::CompiledPromptReport>>;
    fn subscribe_events(&self) -> broadcast::Receiver<EngineEvent>;
    fn shutdown(&self) -> BoxFuture<'_, BistreResult<()>>;
}
