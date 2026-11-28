//! The `EngineClient` boundary shared by the in-process and daemon IPC engines.

use super::{
    AgentRunRecord, AppHealthSnapshot, AppSettings, AssistantPatch, AssistantRecord,
    AttachmentInput, BistreResult, BoxFuture, CharacterCardRecord, CronJobRecord,
    CursorEventRecord, DraftRecord, EngineEvent, MemoryEntryRecord, ModelCatalogInfo, MoneyMicros,
    NodeRecord, NodeRole, PowerGuardStatus, ProjectRecord, ProviderDialect, ProviderModelInfo,
    ProviderPatch, ProviderProfile, RegexRuleRecord, RunStepRecord, SearchHit, SignedPackManifest,
    SteeringMessage, StorageFileEntry, StorageStats, StoryChapterRecord, StoryEntryRecord,
    StoryProgressionRecord, StorySceneRecord, StorySnapshotRecord, StoryThreadStateRecord,
    SystemPowerEvent, ThreadMode, ThreadPatch, ThreadSummary, UpdateCheckResult, UserPersonaRecord,
    WorkspaceCheckpointRecord, broadcast, hooks, mcp, ota_install, skills, story, tools,
};

/// Unified engine boundary implemented by:
/// - `InProcessEngine` (Android embedded & desktop direct mode)
/// - `LocalIpcEngine` (Desktop UDS/Named Pipe to `bistre-daemon`)
pub trait EngineClient: Send + Sync {
    fn health(&self) -> BoxFuture<'_, BistreResult<AppHealthSnapshot>>;
    fn list_projects(&self) -> BoxFuture<'_, BistreResult<Vec<ProjectRecord>>>;
    /// Creates (empty id) or updates a project.
    fn save_project(&self, project: ProjectRecord) -> BoxFuture<'_, BistreResult<ProjectRecord>>;
    /// Deletes a project; its chats stay, outside any project.
    fn delete_project(&self, project_id: String) -> BoxFuture<'_, BistreResult<()>>;
    /// Moves a chat into a project, or out of every project with `None`.
    fn move_thread_to_project(
        &self,
        thread_id: String,
        project_id: Option<String>,
    ) -> BoxFuture<'_, BistreResult<()>>;
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
    fn get_provider_api_keys(
        &self,
        provider_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<String>>>;
    /// The catalog's prices and limits for `model_id` as `provider_id` serves it.
    fn lookup_model_catalog_info(
        &self,
        provider_id: String,
        model_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<ModelCatalogInfo>>>;
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
    fn send_and_stream_reply_with_attachments(
        &self,
        thread_id: String,
        parent_id: Option<String>,
        user_content: String,
        attachments: Vec<AttachmentInput>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>>;
    fn steer_active_run_now(
        &self,
        thread_id: String,
        content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>>;
    fn import_threads_json(&self, raw_json: String) -> BoxFuture<'_, BistreResult<u32>>;
    fn export_settings_json(&self) -> BoxFuture<'_, BistreResult<String>>;
    /// Imports settings JSON. A file that would loosen trust or the spending limit fails with
    /// `diag.import.loosens_safety` unless `allow_loosening` (the user confirmed); every import
    /// revokes outstanding tool permits.
    fn import_settings_json(
        &self,
        raw_json: String,
        allow_loosening: bool,
    ) -> BoxFuture<'_, BistreResult<AppSettings>>;
    fn list_storage_files(&self) -> BoxFuture<'_, BistreResult<Vec<StorageFileEntry>>>;
    fn delete_storage_file(&self, rel_path: String) -> BoxFuture<'_, BistreResult<bool>>;
    fn clean_unused_storage_files(&self) -> BoxFuture<'_, BistreResult<u64>>;
    fn synthesize_speech(
        &self,
        provider_id: String,
        model_id: String,
        text: String,
        voice: Option<String>,
    ) -> BoxFuture<'_, BistreResult<Vec<u8>>>;
    fn start_live_voice_session(
        &self,
        provider_id: String,
        model_id: String,
        voice: String,
        system_prompt: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    fn send_live_voice_pcm_chunk(
        &self,
        session_id: String,
        pcm_base64: String,
    ) -> BoxFuture<'_, BistreResult<()>>;
    fn send_live_voice_text(
        &self,
        session_id: String,
        text: String,
    ) -> BoxFuture<'_, BistreResult<()>>;
    fn stop_live_voice_session(&self, session_id: String) -> BoxFuture<'_, BistreResult<()>>;
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
    fn fork_thread(
        &self,
        thread_id: String,
        node_id: String,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>>;
    fn delete_from_node(
        &self,
        thread_id: String,
        node_id: String,
    ) -> BoxFuture<'_, BistreResult<()>>;
    fn clear_thread_messages(&self, thread_id: String) -> BoxFuture<'_, BistreResult<()>>;
    /// Leaves `node_id` out of the chat's context (or brings it back); returns the new list.
    fn set_node_excluded(
        &self,
        thread_id: String,
        node_id: String,
        excluded: bool,
    ) -> BoxFuture<'_, BistreResult<Vec<String>>>;
    fn list_excluded_nodes(&self, thread_id: String) -> BoxFuture<'_, BistreResult<Vec<String>>>;
    /// Saves `content` as a new version of the reply `node_id`.
    fn edit_reply(
        &self,
        thread_id: String,
        node_id: String,
        content: String,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>>;
    /// Answers a question about the chat without adding it to the chat.
    fn ask_side_question(
        &self,
        thread_id: String,
        question: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    /// Opens a new chat that starts from a summary of this one.
    fn summarize_into_new_chat(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>>;
    fn get_thread_goal(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<crate::goal::ThreadGoal>>>;
    /// Sets a new open goal for the chat; blank text clears it.
    fn set_thread_goal(
        &self,
        thread_id: String,
        objective: String,
    ) -> BoxFuture<'_, BistreResult<Option<crate::goal::ThreadGoal>>>;
    /// The raw request and response of a recent reply (`request_id` metadata).
    fn raw_exchange(
        &self,
        request_id: String,
    ) -> BoxFuture<'_, BistreResult<Option<crate::raw_exchange::RawExchange>>>;
    /// Regenerate whose reply follows `guidance`; empty guidance is a plain Regenerate.
    fn regenerate_reply_guided(
        &self,
        thread_id: String,
        user_node_id: String,
        guidance: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    /// Drafts the user's next message, following `note` when given; nothing is saved.
    fn draft_next_message(
        &self,
        thread_id: String,
        note: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    /// The replacement for a manuscript excerpt under a rewrite mode; nothing is saved.
    fn rewrite_passage(
        &self,
        thread_id: String,
        mode: String,
        excerpt: String,
        context: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    /// A writing brief for a scene from its title and beats; nothing is saved.
    fn plan_scene(
        &self,
        thread_id: String,
        title: String,
        beats: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    /// An era summary of a chapter and its contradictions with earlier ones; nothing is saved.
    fn summarize_chapter(
        &self,
        thread_id: String,
        chapter_id: String,
    ) -> BoxFuture<'_, BistreResult<bistre_protocol::ChapterSummary>>;
    /// Every file of the chat, newest first.
    fn list_chat_files(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<crate::chat_files::ChatFile>>>;
    /// Bistre's own skills (`<data dir>/skills`).
    fn list_app_skills(&self) -> BoxFuture<'_, BistreResult<Vec<skills::SkillIndexEntry>>>;
    /// Installs a skill from a GitHub link or a folder, `SKILL.md`, or zip path.
    fn install_skill(&self, source: String)
    -> BoxFuture<'_, BistreResult<skills::SkillIndexEntry>>;
    /// Saves a reply as a new skill named by its chat.
    fn save_reply_as_skill(
        &self,
        thread_id: String,
        node_id: String,
    ) -> BoxFuture<'_, BistreResult<skills::SkillIndexEntry>>;
    fn remove_app_skill(&self, skill_path: String) -> BoxFuture<'_, BistreResult<()>>;
    /// Writes every chat with its files to a zip; returns the files written.
    fn export_chats_zip(&self, dest_path: String) -> BoxFuture<'_, BistreResult<u32>>;
    /// Imports the chats and files of a chats zip; returns the chats imported.
    fn import_chats_zip(&self, src_path: String) -> BoxFuture<'_, BistreResult<u32>>;
    /// Asks the next start to erase everything Bistre keeps on this device.
    fn request_data_wipe(&self) -> BoxFuture<'_, BistreResult<()>>;
    /// Withdraws a pending erase; returns whether one was pending.
    fn cancel_data_wipe(&self) -> BoxFuture<'_, BistreResult<bool>>;
    fn data_wipe_pending(&self) -> BoxFuture<'_, BistreResult<bool>>;
    /// Saves a character card with its lore as a PNG card on its picture.
    fn export_character_card_png(
        &self,
        card_id: String,
        dest_path: String,
    ) -> BoxFuture<'_, BistreResult<()>>;
    fn export_thread(
        &self,
        thread_id: String,
        format: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    fn backup_database(&self, dest_path: String) -> BoxFuture<'_, BistreResult<()>>;
    fn storage_stats(&self) -> BoxFuture<'_, BistreResult<StorageStats>>;
    fn wallet_daily_spend_micros(&self) -> BoxFuture<'_, BistreResult<MoneyMicros>>;
    /// Searches the public MCP Registry; entries come back turned off, ready to add.
    fn search_mcp_registry(
        &self,
        query: String,
        cursor: Option<String>,
    ) -> BoxFuture<'_, BistreResult<crate::mcp_registry::McpRegistryPage>>;
    /// Settled spend of one chat, all purposes, all time.
    fn thread_spend_micros(&self, thread_id: String) -> BoxFuture<'_, BistreResult<MoneyMicros>>;
    /// Settled spend since `since_unix_ms`, one entry per purpose with any use.
    fn wallet_usage_by_purpose(
        &self,
        since_unix_ms: i64,
    ) -> BoxFuture<'_, BistreResult<Vec<bistre_protocol::PurposeUsage>>>;
    fn check_for_updates(
        &self,
        feed_url_override: Option<String>,
    ) -> BoxFuture<'_, BistreResult<UpdateCheckResult>>;
    fn stage_update(&self, check: UpdateCheckResult) -> BoxFuture<'_, BistreResult<String>>;
    fn reinstall_update(&self, check: UpdateCheckResult) -> BoxFuture<'_, BistreResult<String>>;
    /// The staged update a restart would install, if any.
    fn pending_update_version(&self) -> BoxFuture<'_, BistreResult<Option<String>>>;
    /// Hands the staged update to the platform installer; desktop apps quit after it.
    fn install_staged_update(&self) -> BoxFuture<'_, BistreResult<ota_install::StagedInstall>>;
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
    /// The model's conversation limit in tokens as `provider_id` serves it: a saved
    /// override, else the cached public model lists.
    fn model_context_tokens(
        &self,
        provider_id: String,
        model: String,
    ) -> BoxFuture<'_, BistreResult<Option<u32>>>;
    /// What the next request sends for the branch ending at `leaf_node_id`, by category
    /// , counting `draft` as the message about to be sent.
    fn context_breakdown(
        &self,
        thread_id: String,
        leaf_node_id: String,
        draft: String,
    ) -> BoxFuture<'_, BistreResult<crate::context_breakdown::ContextBreakdown>>;
    /// Starts a public price-list refresh now (the user's "Update prices now").
    fn refresh_prices(&self) -> BoxFuture<'_, BistreResult<()>>;
    /// Records the user's approval of one exact tool call; returns a one-use permit id.
    fn approve_tool_call(
        &self,
        thread_id: String,
        tool_name: String,
        arguments_json: String,
    ) -> BoxFuture<'_, BistreResult<String>>;
    /// Lets the chat's next run send requests whose price is unknown while a spending cap is
    /// active ("Allow once"); the allowance ends with that run.
    fn allow_unpriced_once(&self, thread_id: String) -> BoxFuture<'_, BistreResult<()>>;
    /// Validates and saves a provider's custom headers and body fields, bound to its
    /// current origin; an invalid header or body is refused with a `DiagnosticKey`.
    fn save_provider_overrides(
        &self,
        provider_id: String,
        headers_json: String,
        body_json: String,
    ) -> BoxFuture<'_, BistreResult<()>>;
    /// The same "Allow once" for the next read-aloud or live-voice request.
    fn allow_unpriced_media_once(&self) -> BoxFuture<'_, BistreResult<()>>;
    /// The `ToolApprovalRequested` events whose runs still wait for the user, for an app that
    /// missed them (lagged events, a window opened while a run waited).
    fn pending_tool_approvals(&self) -> BoxFuture<'_, BistreResult<Vec<EngineEvent>>>;
    /// Delivers the user's decision (`approve_once` / `approve_for_thread` / `deny` / `stop`)
    /// to the run paused at `ToolApprovalRequested` with exactly this thread, run, and call id.
    fn respond_tool_approval(
        &self,
        thread_id: String,
        run_id: String,
        call_id: String,
        decision: bistre_protocol::ToolApprovalDecision,
    ) -> BoxFuture<'_, BistreResult<bool>>;
    /// Delivers the native host-bridge result for a `HostActionRequested` event (`computer_use`).
    fn respond_host_action(
        &self,
        request_id: String,
        ok: bool,
        output_text: String,
        image_base64: Option<String>,
    ) -> BoxFuture<'_, BistreResult<bool>>;
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
    /// Condenses the chat into a summary (`custom_summary` as written, or one the Summary
    /// model writes, following the user's `instructions` on what to keep).
    fn compact_thread(
        &self,
        thread_id: String,
        keep_recent_turns: u32,
        custom_summary: Option<String>,
        instructions: Option<String>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>>;
    /// Replaces the text of a compaction summary; the messages it condenses stay saved.
    fn rewrite_compaction_summary(
        &self,
        thread_id: String,
        node_id: String,
        content: String,
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
    /// Saves the server's Bearer token in the vault; a blank token removes it.
    fn set_mcp_token(&self, server_id: String, token: String) -> BoxFuture<'_, BistreResult<()>>;
    /// Whether the server has a token saved.
    fn has_mcp_token(&self, server_id: String) -> BoxFuture<'_, BistreResult<bool>>;
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
    /// Web sources used by the replies in a chat (search results and citations).
    fn list_thread_grounding(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<Vec<crate::engine_grounding::NodeGrounding>>>;
    /// The workspace's `.bistre/hooks.json` hooks, their digest, and whether the user approved
    /// exactly this file. `None` when the workspace has no hooks file.
    fn workspace_hooks_status(
        &self,
        workspace_root: String,
    ) -> BoxFuture<'_, BistreResult<Option<hooks::WorkspaceHooksStatus>>>;
    /// Approves the hooks file whose digest the user reviewed; a file changed since then is
    /// refused (`hooks_changed`) so the user approves only what they saw.
    fn approve_workspace_hooks(
        &self,
        workspace_root: String,
        digest: String,
    ) -> BoxFuture<'_, BistreResult<()>>;
    fn list_cron_jobs(&self) -> BoxFuture<'_, BistreResult<Vec<CronJobRecord>>>;
    fn upsert_cron_job(&self, job: CronJobRecord) -> BoxFuture<'_, BistreResult<CronJobRecord>>;
    fn delete_cron_job(&self, job_id: String) -> BoxFuture<'_, BistreResult<()>>;
    /// Starts a due job's run in a new chat under its unattended policy; returns the chat id.
    fn start_scheduled_run(&self, job: CronJobRecord) -> BoxFuture<'_, BistreResult<String>>;
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
    /// Builds the exact credential-free wire request core would send next for `thread_id`.
    fn inspect_next_request(
        &self,
        thread_id: String,
        draft: String,
    ) -> BoxFuture<'_, BistreResult<crate::engine_story::InspectedRequest>>;
    /// Generates and saves a short title for `thread_id` using Settings > Default models > Chat titles.
    fn generate_thread_title(
        &self,
        thread_id: String,
    ) -> BoxFuture<'_, BistreResult<ThreadSummary>>;
    /// Translates `node_id` into `target_language` (or Settings > Default models > Target language)
    /// and commits the translation as a new sibling version on the same parent.
    fn translate_node(
        &self,
        thread_id: String,
        node_id: String,
        target_language: Option<String>,
    ) -> BoxFuture<'_, BistreResult<NodeRecord>>;
    fn export_provider_share_code(
        &self,
        provider_id: String,
        include_api_key: bool,
    ) -> BoxFuture<'_, BistreResult<String>>;
    fn import_provider_share_code(
        &self,
        code: String,
    ) -> BoxFuture<'_, BistreResult<ProviderProfile>>;
    fn list_nodes_window(
        &self,
        thread_id: String,
        before_node_id: Option<String>,
        limit: usize,
    ) -> BoxFuture<'_, BistreResult<Vec<NodeRecord>>>;
    fn thread_history_rev(&self, thread_id: String) -> BoxFuture<'_, BistreResult<i64>>;
    fn subscribe_events(&self) -> broadcast::Receiver<EngineEvent>;
    fn shutdown(&self) -> BoxFuture<'_, BistreResult<()>>;
}
