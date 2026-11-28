part of 'bistre_engine.dart';

/// Thin transport interface isolating Flutter widgets from native FFI loading during widget tests.
abstract interface class BistreEngineGateway {
  Future<EngineHealth> init(String dataDir);
  Future<EngineHealth> getHealth();
  Future<EngineStorageStats> getStorageStats();
  Future<List<EngineProvider>> listProviders();
  Future<EngineProvider> createProvider({
    required String name,
    required String dialect,
    required String baseUrl,
    required String defaultModel,
    required String iconSlug,
    required String customIconPath,
    String? apiKey,
  });
  Future<EngineProvider> updateProvider({
    required String providerId,
    String? name,
    String? baseUrl,
    String? defaultModel,
    bool? isEnabled,
    bool? useServerStateCache,
    String? iconSlug,
    String? customIconPath,
  });
  Future<EngineProvider> setProviderApiKey({
    required String providerId,
    required String apiKey,
  });
  Future<EngineProvider> clearProviderApiKey(String providerId);
  Future<List<String>> getProviderApiKeys(String providerId);

  /// The catalog's prices and limits of [modelId] as [providerId] serves it.
  Future<EngineModelCatalogInfo?> lookupModelCatalogInfo(
    String providerId,
    String modelId,
  );
  Future<EngineProvider> createCustomProvider({
    required String name,
    required String baseUrl,
    required String defaultModel,
    String? apiKey,
  });
  Future<void> deleteProvider(String providerId);
  Future<List<EngineProviderModel>> fetchProviderModels(String providerId);
  Future<List<EngineAssistant>> listAssistants();
  Future<EngineAssistant> createAssistant({
    required String name,
    required String roleSubtitle,
    required String systemPrompt,
    required String defaultMode,
    required String badgeCode,
  });
  Future<EngineAssistant> updateAssistant({
    required String assistantId,
    String? name,
    String? roleSubtitle,
    String? systemPrompt,
    String? defaultMode,
    String? badgeCode,
    String? iconSlug,
    String? defaultProviderId,
    String? defaultModelId,
    int? temperatureMilli,
    bool clearTemperature = false,
    int? maxOutputTokens,
    bool clearMaxOutputTokens = false,
    int? topPMilli,
    bool clearTopP = false,
  });
  Future<void> deleteAssistant(String assistantId);

  /// Creates a chat, in [projectId] when given.
  Future<EngineThread> createThread(
    String title,
    String mode, {
    String? topic,
    String? assistantId,
    String? projectId,
  });

  /// Every project, oldest first.
  Future<List<EngineProject>> listProjects();

  /// Creates (empty id) or updates a project and returns it as saved.
  Future<EngineProject> saveProject(EngineProject project);

  /// Deletes a project; its chats stay, outside any project.
  Future<void> deleteProject(String projectId);

  /// Moves a chat into [projectId], or out of every project with null.
  Future<void> moveThreadToProject(String threadId, String? projectId);
  Future<EngineThread> updateThread({
    required String threadId,
    String? title,
    bool? isPinned,
    String? topic,
    String? mode,
    String? assistantId,
    String? providerIdOverride,
    bool clearProviderOverride = false,
    String? modelIdOverride,
    bool clearModelOverride = false,
    String? systemPromptOverride,
    bool clearSystemPromptOverride = false,
    int? temperatureMilli,
    bool clearTemperature = false,
    int? maxOutputTokens,
    bool clearMaxOutputTokens = false,
    int? topPMilli,
    bool clearTopP = false,
  });
  Future<void> deleteThread(String threadId);
  Future<List<EngineThread>> listThreads();
  Future<EngineNode> appendNode({
    required String threadId,
    String? parentId,
    required String role,
    required String content,
  });
  Future<EngineNode> sendAndStreamReply({
    required String threadId,
    String? parentId,
    required String userContent,
  });
  Future<EngineNode> sendAndStreamReplyWithAttachments({
    required String threadId,
    String? parentId,
    required String userContent,
    required List<EngineAttachmentInput> attachments,
  });
  Future<EngineNode> steerActiveRunNow({
    required String threadId,
    required String content,
  });
  Future<int> importThreadsJson(String rawJson);
  Future<String> exportSettingsJson();

  /// Imports settings JSON; a file that would loosen trust or the spending limit fails with
  /// `diag.import.loosens_safety` unless [allowLoosening] (the user confirmed).
  Future<EngineSettings> importSettingsJson(
    String rawJson, {
    bool allowLoosening = false,
  });
  Future<List<EngineStorageFileEntry>> listStorageFiles();
  Future<bool> deleteStorageFile(String relPath);
  Future<int> cleanUnusedStorageFiles();
  Future<List<int>> synthesizeSpeech({
    required String providerId,
    required String modelId,
    required String text,
    String? voice,
  });
  Future<String> startLiveVoiceSession({
    required String providerId,
    required String modelId,
    required String voice,
    required String systemPrompt,
  });
  Future<void> sendLiveVoicePcmChunk({
    required String sessionId,
    required String pcmBase64,
  });
  Future<void> sendLiveVoiceText({
    required String sessionId,
    required String text,
  });
  Future<void> stopLiveVoiceSession(String sessionId);
  Future<String> regenerateReply({
    required String threadId,
    required String userNodeId,
  });
  Future<EngineNode> editUserNodeAndStream({
    required String threadId,
    required String nodeId,
    required String newContent,
  });
  Future<void> deleteNode({required String threadId, required String nodeId});

  /// Copies the branch ending at [nodeId] into a new chat and returns it.
  Future<EngineThread> forkThread({
    required String threadId,
    required String nodeId,
  });

  /// Removes [nodeId] and every message after it.
  Future<void> deleteFromNode({
    required String threadId,
    required String nodeId,
  });

  /// Removes every message of a chat and keeps the chat.
  Future<void> clearThreadMessages(String threadId);

  /// Leaves [nodeId] out of the chat's context (or brings it back); the new left-out ids.
  Future<List<String>> setNodeExcluded({
    required String threadId,
    required String nodeId,
    required bool excluded,
  });

  /// The ids of the chat's left-out messages.
  Future<List<String>> listExcludedNodes(String threadId);

  /// Saves [content] as a new version of the reply [nodeId].
  Future<EngineNode> editReply({
    required String threadId,
    required String nodeId,
    required String content,
  });

  /// Answers [question] about the chat with its own model; nothing is added to the chat.
  Future<String> askSideQuestion({
    required String threadId,
    required String question,
  });

  /// Opens a new chat that starts from a summary of [threadId].
  Future<EngineThread> summarizeIntoNewChat(String threadId);

  /// The chat's goal, or null.
  Future<EngineThreadGoal?> getThreadGoal(String threadId);

  /// Sets a new open goal; blank [objective] clears it.
  Future<EngineThreadGoal?> setThreadGoal({
    required String threadId,
    required String objective,
  });

  /// The raw request and response of a recent reply ([requestId] metadata), or null when
  /// core no longer keeps it.
  Future<EngineRawExchange?> rawExchange(String requestId);

  /// Every file of the chat, newest first (all branches, loaded or not).
  Future<List<EngineChatFile>> listChatFiles(String threadId);

  /// Bistre's own skills, offered in every chat with tools on.
  Future<List<EngineSkillIndex>> listAppSkills();

  /// Installs a skill from a GitHub link or a folder, `SKILL.md`, or zip path.
  Future<EngineSkillIndex> installSkill(String source);

  /// Saves a reply as a new skill named by its chat.
  Future<EngineSkillIndex> saveReplyAsSkill({
    required String threadId,
    required String nodeId,
  });
  Future<void> removeAppSkill(String skillPath);

  /// Drafts the user's next message, following [note] when given; nothing is saved.
  Future<String> draftNextMessage({
    required String threadId,
    required String note,
  });

  /// Regenerate whose reply follows [guidance].
  Future<String> regenerateReplyGuided({
    required String threadId,
    required String userNodeId,
    required String guidance,
  });

  /// Writes every chat with its files to a zip; returns the files written.
  Future<int> exportChatsZip(String destPath);

  /// Imports the chats and files of a chats zip; returns the chats imported.
  Future<int> importChatsZip(String srcPath);

  /// Saves a character card with its lore as a PNG card on its picture.
  Future<void> exportCharacterCardPng({
    required String cardId,
    required String destPath,
  });

  /// Saves an MCP server's token in the vault; a blank token removes it.
  Future<void> setMcpToken({required String serverId, required String token});

  /// Whether an MCP server has a token saved.
  Future<bool> hasMcpToken(String serverId);

  /// Asks the next start to erase everything Bistre keeps on this device.
  Future<void> requestDataWipe();

  /// Withdraws a pending erase; returns whether one was pending.
  Future<bool> cancelDataWipe();
  Future<bool> dataWipePending();
  Future<String> exportThread({
    required String threadId,
    required String format,
  });
  Future<void> backupDatabase(String destPath);
  Future<bool> cancelActiveRun(String threadId);

  /// Ends a run's backoff wait immediately (`Retry now`).
  Future<bool> retryRunNow(String threadId);
  Future<List<EngineNode>> listNodes(String threadId);
  Future<void> saveDraft(String threadId, String text);
  Future<String?> loadDraft(String threadId);
  Future<EngineSettings> loadSettings();
  Future<EngineSettings> saveSettings(EngineSettings settings);
  Future<int> getWalletSpendMicros();
  Future<int> getWalletDailySpendMicros();

  /// Settled spend since [since], one entry per purpose with any use, chat first.
  Future<List<EnginePurposeUsage>> getWalletUsageByPurpose(DateTime since);
  Future<EngineUpdateCheck> checkForUpdates({String? feedUrlOverride});
  Future<String> stageUpdate(EngineUpdateCheck check);
  Future<String> reinstallUpdate(EngineUpdateCheck check);

  /// The staged version that installs over this build, or null.
  Future<String?> pendingUpdateVersion();

  /// Hands the staged update to the platform installer. Returns the APK the Android app
  /// opens in the system installer; empty on desktop, where the app quits next.
  Future<String> installStagedUpdate();
  Future<List<EngineSearchHit>> searchNodes(
    String query, {
    String? threadId,
    int limit = 20,
  });
  Future<String> verifyDataPack({
    required String publicKeyB64,
    required List<int> manifestBytes,
    required String manifestSigText,
    required List<int> packPayload,
  });
  Future<List<EngineAgentRun>> listAgentRuns({
    String? threadId,
    bool onlyActive = false,
    int limit = 50,
  });
  Future<EngineSteeringMessage> enqueueSteering({
    required String threadId,
    required String content,
  });
  Future<List<EngineSteeringMessage>> listPendingSteering(String threadId);
  Future<void> deleteSteering(String steeringId);
  Future<EnginePowerGuardStatus> powerGuardStatus();
  Future<int> notifyPowerEvent(String eventKind, {bool? onAc});
  Future<EnginePowerGuardStatus> setAndroidPowerState({
    required bool fgsActive,
    required bool batteryUnrestricted,
  });
  Future<EngineAgentRun> resolveIndeterminateRun({
    required String runId,
    required bool confirmCompleted,
  });

  /// Starts a public price-list refresh now.
  Future<void> refreshPrices();

  /// The model's conversation limit in tokens as [providerId] serves it, or null when
  /// unknown.
  Future<int?> modelContextTokens(String providerId, String model);

  /// Estimated tokens the next request sends for the branch ending at [leafNodeId] (core
  /// applies compaction and the context pin exactly as a run does).
  /// What the next request sends for the branch ending at [leafNodeId], by category, with
  /// [draft] as the message about to be sent.
  Future<EngineContextBreakdown> contextBreakdown(
    String threadId,
    String leafNodeId, {
    String draft = '',
  });

  /// Records the user's approval of one exact call; returns a one-use permit id.
  Future<String> approveToolCall({
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
  });

  /// "Allow once": the chat's next run may send requests whose price is unknown while a
  /// spending cap is active (`diag.wallet.price_unknown`).
  Future<void> allowUnpricedOnce(String threadId);

  /// "Allow once" for the next read-aloud or live-voice request whose price is unknown.
  Future<void> allowUnpricedMediaOnce();

  /// The workspace's `.bistre/hooks.json` for review; `null` when the folder has none.
  Future<EngineWorkspaceHooksStatus?> workspaceHooksStatus(
    String workspaceRoot,
  );

  /// Core's facts for every API format (default server URL, endpoint path).
  List<EngineDialectDescriptor> dialectDescriptors();

  /// Core's built-in title prompt, sent while the Default models setting is empty.
  String defaultTitlePrompt();

  /// The URLs a provider with this format and server URL is called at.
  EngineResolvedEndpoint resolveProviderEndpoint(
    String dialect,
    String baseUrl,
  );

  /// Web sources of every reply in a chat, oldest reply first.
  Future<List<EngineGroundingSource>> listThreadGrounding(String threadId);

  /// Approves the hooks file the user reviewed (by [digest]); a changed file is refused.
  Future<void> approveWorkspaceHooks(String workspaceRoot, String digest);

  /// Validates and saves a provider's custom headers and body fields (JSON objects).
  Future<void> saveProviderOverrides({
    required String providerId,
    required String headersJson,
    required String bodyJson,
  });

  /// The approval requests whose runs still wait for the user, as the events that asked.
  Future<List<BistreEvent>> pendingToolApprovals();

  /// Delivers a live tool-approval decision (`approve_once` / `approve_for_thread` / `deny` /
  /// `stop`) to the run [runId] of [threadId] paused at [callId].
  Future<bool> respondToolApproval({
    required String threadId,
    required String runId,
    required String callId,
    required String decision,
  });
  Future<bool> respondHostAction({
    required String requestId,
    required bool ok,
    required String outputText,
    String? imageBase64,
  });

  /// Runs a tool. Read-only tools need no permit; every other tool needs the
  /// [permitId] from [approveToolCall] for exactly these [arguments].
  Future<EngineToolOutput> executeWorkspaceTool({
    required String workspaceRoot,
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
    String? permitId,
  });
  Future<String> rewindCheckpoint({
    required String workspaceRoot,
    required String checkpointId,
  });
  Future<List<EngineCheckpoint>> listCheckpoints(
    String threadId, {
    int limit = 50,
  });

  /// [instructions] tell the Summary model what to keep.
  Future<EngineNode> compactThread({
    required String threadId,
    int keepRecentTurns = 4,
    String? customSummary,
    String? instructions,
  });

  /// Replaces a compaction summary's text; the messages it condenses stay saved.
  Future<EngineNode> rewriteCompactionSummary({
    required String threadId,
    required String nodeId,
    required String content,
  });
  Future<void> undoCompaction({
    required String threadId,
    required String compactionNodeId,
  });
  Future<String?> setContextStartPin({
    required String threadId,
    String? nodeId,
  });
  Future<String?> getContextStartPin(String threadId);
  Future<EngineMcpDiscoveryReport> discoverMcpServer(
    EngineMcpServerConfig server,
  );

  /// Searches the public MCP Registry ([cursor] continues a search).
  Future<EngineMcpRegistryPage> searchMcpRegistry(
    String query, {
    String? cursor,
  });
  Future<String?> getKvMeta(String key);
  Future<void> setKvMeta(String key, String value);
  Future<List<EngineMemoryEntry>> listMemoryEntries({String? scope});
  Future<EngineMemoryEntry> upsertMemoryEntry({
    String? id,
    required String scope,
    required String scopeId,
    required String key,
    required String content,
    bool pinned = false,
  });
  Future<void> deleteMemoryEntry(String entryId);
  Future<List<EngineSkillIndex>> discoverWorkspaceSkills(String workspaceRoot);
  Future<String> loadSkillBody(String workspaceRoot, String skillPath);
  Future<List<EngineCronJob>> listCronJobs();
  Future<EngineCronJob> upsertCronJob(EngineCronJob job);
  Future<void> deleteCronJob(String jobId);
  Future<List<EngineCharacterCard>> listCharacterCards();
  Future<EngineCharacterCard> upsertCharacterCard(EngineCharacterCard card);
  Future<void> deleteCharacterCard(String cardId);
  Future<EngineCharacterCard> importCharacterCardFile(String filePath);
  Future<String> exportCharacterCardCcv3(String cardId);
  Future<List<EngineUserPersona>> listUserPersonas();
  Future<EngineUserPersona> upsertUserPersona(EngineUserPersona persona);
  Future<List<EngineStoryEntry>> listStoryEntries({String? bookId});
  Future<EngineStoryEntry> upsertStoryEntry(EngineStoryEntry entry);
  Future<void> deleteStoryEntry(String entryId);
  Future<List<EngineStoryProgression>> listStoryProgressions({String? entryId});
  Future<EngineStoryProgression> addStoryProgression(
    EngineStoryProgression progression,
  );
  Future<List<EngineStoryChapter>> listStoryChapters(String threadId);
  Future<EngineStoryChapter> upsertStoryChapter(EngineStoryChapter chapter);
  Future<List<EngineStoryScene>> listStoryScenes(String chapterId);
  Future<EngineStoryScene> upsertStoryScene(EngineStoryScene scene);
  Future<EngineStoryThreadState> loadStoryThreadState(String threadId);
  Future<EngineStoryThreadState> saveStoryThreadState(
    EngineStoryThreadState state,
  );
  Future<List<EngineRegexRule>> listRegexRules();
  Future<EngineRegexRule> upsertRegexRule(EngineRegexRule rule);
  Future<List<EngineStorySnapshot>> listStorySnapshots({
    required String entityType,
    required String entityId,
    int limit = 10,
  });
  Future<EnginePromptReport> inspectStoryPrompt({
    required String threadId,
    String? activeSceneBeats,
  });

  /// The replacement for a manuscript [excerpt] under [mode] (`rewrite`, `expand`,
  /// `shorten`, `polish`), with the scene text [context] around it; nothing is saved.
  Future<String> rewritePassage({
    required String threadId,
    required String mode,
    required String excerpt,
    required String context,
  });

  /// A writing brief for a scene from its title and beats; nothing is saved.
  Future<String> planScene({
    required String threadId,
    required String title,
    required String beats,
  });

  /// The chapter's era summary and the earlier facts it contradicts; nothing is saved.
  Future<EngineChapterSummary> summarizeChapter({
    required String threadId,
    required String chapterId,
  });
  Future<EngineThread> generateThreadTitle(String threadId);
  Future<EngineNode> translateNode({
    required String threadId,
    required String nodeId,
    String? targetLanguage,
  });
  Future<EngineInspectedRequest> inspectNextRequest({
    required String threadId,
    required String draft,
  });

  /// A portable `ai-provider:v1:` code for [providerId]; the key is left out unless asked.
  Future<String> exportProviderShareCode({
    required String providerId,
    bool includeApiKey = false,
  });

  /// Adds a new provider (fresh id) from a share code made by [exportProviderShareCode].
  Future<EngineProvider> importProviderShareCode(String code);

  /// The newest [limit] (at most 500) nodes of [threadId] written before [beforeNodeId],
  /// oldest first.
  Future<List<EngineNode>> listNodesWindow({
    required String threadId,
    String? beforeNodeId,
    required int limit,
  });

  /// Settled spend of [threadId] in micro-USD, every purpose and all time.
  Future<int> getThreadSpendMicros(String threadId);

  /// A number that grows whenever [threadId]'s history changes.
  Future<int> threadHistoryRev(String threadId);
  Stream<BistreEvent> subscribeEvents();
  Future<void> shutdown();
}
