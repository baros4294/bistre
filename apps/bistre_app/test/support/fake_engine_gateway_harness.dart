part of 'fake_engine_gateway.dart';

/// Tools, hooks, MCP, memory, schedules, Story Studio, sharing, storage files, and voice of
/// [FakeEngineGateway] (split by responsibility).
mixin _FakeHarnessAndStory implements BistreEngineGateway {
  abstract int _clock;
  abstract EngineSettings _settings;
  List<EngineProvider> get _providers;
  Map<String, String> get _kvMeta;
  Map<String, String> get _contextPins;
  Future<void> _record(String method, Map<String, Object?> args);

  @override
  Future<String> approveToolCall({
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
  }) async => 'permit-$toolName';

  @override
  Future<void> allowUnpricedOnce(String threadId) =>
      _record('allowUnpricedOnce', <String, Object?>{'threadId': threadId});

  /// The catalog entry reported for every model (`null`: a priced text model).
  EngineModelCatalogInfo? modelInfo;

  /// Hooks reported for any workspace root (`null`: no hooks file).
  EngineWorkspaceHooksStatus? workspaceHooks;

  @override
  List<EngineDialectDescriptor> dialectDescriptors() => kTestDialectDescriptors;

  @override
  String defaultTitlePrompt() => kTestDefaultTitlePrompt;

  /// Web sources per chat id.
  final Map<String, List<EngineGroundingSource>> grounding =
      <String, List<EngineGroundingSource>>{};

  @override
  Future<List<EngineGroundingSource>> listThreadGrounding(
    String threadId,
  ) async {
    await _record('listThreadGrounding', <String, Object?>{
      'threadId': threadId,
    });
    return grounding[threadId] ?? const <EngineGroundingSource>[];
  }

  @override
  Future<EngineWorkspaceHooksStatus?> workspaceHooksStatus(
    String workspaceRoot,
  ) async => workspaceHooks;

  @override
  Future<void> approveWorkspaceHooks(
    String workspaceRoot,
    String digest,
  ) async {
    await _record('approveWorkspaceHooks', <String, Object?>{
      'workspaceRoot': workspaceRoot,
      'digest': digest,
    });
    final current = workspaceHooks;
    if (current != null && current.digest == digest) {
      workspaceHooks = EngineWorkspaceHooksStatus(
        hooks: current.hooks,
        digest: digest,
        approved: true,
      );
    }
  }

  @override
  Future<void> saveProviderOverrides({
    required String providerId,
    required String headersJson,
    required String bodyJson,
  }) => _record('saveProviderOverrides', <String, Object?>{
    'providerId': providerId,
    'headersJson': headersJson,
    'bodyJson': bodyJson,
  });

  @override
  Future<void> allowUnpricedMediaOnce() =>
      _record('allowUnpricedMediaOnce', <String, Object?>{});

  List<BistreEvent> pendingApprovals = <BistreEvent>[];

  @override
  Future<List<BistreEvent>> pendingToolApprovals() async {
    await _record('pendingToolApprovals', const <String, Object?>{});
    return pendingApprovals;
  }

  @override
  Future<bool> respondToolApproval({
    required String threadId,
    required String runId,
    required String callId,
    required String decision,
  }) async {
    await _record('respondToolApproval', <String, Object?>{
      'threadId': threadId,
      'runId': runId,
      'callId': callId,
      'decision': decision,
    });
    return true;
  }

  @override
  Future<EngineToolOutput> executeWorkspaceTool({
    required String workspaceRoot,
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
    String? permitId,
  }) async => EngineToolOutput(
    toolName: toolName,
    riskTier: 'tier0_read_only',
    ok: true,
    summary: '$toolName ok',
    outputText: 'ok',
  );

  @override
  Future<String> rewindCheckpoint({
    required String workspaceRoot,
    required String checkpointId,
  }) async => 'rewound.txt';

  @override
  Future<List<EngineCheckpoint>> listCheckpoints(
    String threadId, {
    int limit = 50,
  }) async => const <EngineCheckpoint>[];

  @override
  Future<String?> setContextStartPin({
    required String threadId,
    String? nodeId,
  }) async {
    if (nodeId == null) {
      _contextPins.remove(threadId);
      return null;
    }
    _contextPins[threadId] = nodeId;
    return nodeId;
  }

  @override
  Future<String?> getContextStartPin(String threadId) async =>
      _contextPins[threadId];

  @override
  Future<EngineMcpDiscoveryReport> discoverMcpServer(
    EngineMcpServerConfig server,
  ) async => const EngineMcpDiscoveryReport(
    negotiatedProtocol: '2026-07-28',
    toolNames: <String>['docs_search'],
  );

  @override
  Future<String?> getKvMeta(String key) async => _kvMeta[key];

  @override
  Future<void> setKvMeta(String key, String value) async {
    _kvMeta[key] = value;
  }

  final List<EngineMemoryEntry> _memories = <EngineMemoryEntry>[];
  final List<EngineCronJob> _cronJobs = <EngineCronJob>[];

  @override
  Future<List<EngineMemoryEntry>> listMemoryEntries({String? scope}) async =>
      List<EngineMemoryEntry>.of(_memories);

  @override
  Future<EngineMemoryEntry> upsertMemoryEntry({
    String? id,
    required String scope,
    required String scopeId,
    required String key,
    required String content,
    bool pinned = false,
  }) async {
    final entry = EngineMemoryEntry(
      id: id ?? 'mem-${++_clock}',
      scope: scope,
      scopeId: scopeId,
      key: key,
      content: content,
      pinned: pinned,
      updatedAtMs: _clock,
    );
    _memories.removeWhere((m) => m.id == entry.id);
    _memories.add(entry);
    return entry;
  }

  @override
  Future<void> deleteMemoryEntry(String entryId) async {
    _memories.removeWhere((m) => m.id == entryId);
  }

  @override
  Future<List<EngineSkillIndex>> discoverWorkspaceSkills(
    String workspaceRoot,
  ) async => const <EngineSkillIndex>[];

  @override
  Future<String> loadSkillBody(String workspaceRoot, String skillPath) async =>
      '';

  @override
  Future<List<EngineCronJob>> listCronJobs() async =>
      List<EngineCronJob>.of(_cronJobs);

  @override
  Future<EngineCronJob> upsertCronJob(EngineCronJob job) async {
    final saved = EngineCronJob(
      id: job.id.isEmpty ? 'cron-${++_clock}' : job.id,
      name: job.name,
      scheduleExpr: job.scheduleExpr,
      prompt: job.prompt,
      enabled: job.enabled,
      nextRunMs: job.nextRunMs > 0 ? job.nextRunMs : _clock + 60000,
    );
    _cronJobs.removeWhere((j) => j.id == saved.id);
    _cronJobs.add(saved);
    return saved;
  }

  @override
  Future<void> deleteCronJob(String jobId) async {
    _cronJobs.removeWhere((j) => j.id == jobId);
  }

  final List<EngineCharacterCard> _cards = <EngineCharacterCard>[];
  final List<EngineUserPersona> _personas = <EngineUserPersona>[];
  final List<EngineStoryEntry> _storyEntries = <EngineStoryEntry>[];
  final List<EngineStoryProgression> _progressions = <EngineStoryProgression>[];
  final List<EngineStoryChapter> _chapters = <EngineStoryChapter>[];
  final List<EngineStoryScene> _scenes = <EngineStoryScene>[];
  final Map<String, EngineStoryThreadState> _storyStates =
      <String, EngineStoryThreadState>{};
  final List<EngineRegexRule> _regexRules = <EngineRegexRule>[];

  @override
  Future<List<EngineCharacterCard>> listCharacterCards() async =>
      List<EngineCharacterCard>.of(_cards);

  @override
  Future<EngineCharacterCard> upsertCharacterCard(
    EngineCharacterCard card,
  ) async {
    final saved = EngineCharacterCard(
      id: card.id.isEmpty ? 'char-${++_clock}' : card.id,
      name: card.name,
      description: card.description,
      firstMessage: card.firstMessage,
      alternateGreetings: card.alternateGreetings,
      updatedAtMs: _clock,
    );
    _cards.removeWhere((c) => c.id == saved.id);
    _cards.add(saved);
    return saved;
  }

  @override
  Future<void> deleteCharacterCard(String cardId) async {
    _cards.removeWhere((c) => c.id == cardId);
  }

  @override
  Future<EngineCharacterCard> importCharacterCardFile(String filePath) =>
      upsertCharacterCard(EngineCharacterCard(name: filePath));

  @override
  Future<String> exportCharacterCardCcv3(String cardId) async =>
      '{"spec":"chara_card_v3","spec_version":"3.0","data":{"id":"$cardId"}}';

  @override
  Future<List<EngineUserPersona>> listUserPersonas() async =>
      List<EngineUserPersona>.of(_personas);

  @override
  Future<EngineUserPersona> upsertUserPersona(EngineUserPersona persona) async {
    final saved = EngineUserPersona(
      id: persona.id.isEmpty ? 'persona-${++_clock}' : persona.id,
      name: persona.name,
      description: persona.description,
      isDefault: persona.isDefault,
      updatedAtMs: _clock,
    );
    _personas.removeWhere((p) => p.id == saved.id);
    _personas.add(saved);
    return saved;
  }

  @override
  Future<List<EngineStoryEntry>> listStoryEntries({String? bookId}) async =>
      List<EngineStoryEntry>.of(_storyEntries);

  @override
  Future<EngineStoryEntry> upsertStoryEntry(EngineStoryEntry entry) async {
    final saved = EngineStoryEntry(
      id: entry.id.isEmpty ? 'entry-${++_clock}' : entry.id,
      bookId: entry.bookId,
      category: entry.category,
      name: entry.name,
      keys: entry.keys,
      content: entry.content,
      constant: entry.constant,
      updatedAtMs: _clock,
    );
    _storyEntries.removeWhere((e) => e.id == saved.id);
    _storyEntries.add(saved);
    return saved;
  }

  @override
  Future<void> deleteStoryEntry(String entryId) async {
    _storyEntries.removeWhere((e) => e.id == entryId);
  }

  @override
  Future<List<EngineStoryProgression>> listStoryProgressions({
    String? entryId,
  }) async => entryId == null
      ? List<EngineStoryProgression>.of(_progressions)
      : _progressions.where((p) => p.entryId == entryId).toList();

  @override
  Future<EngineStoryProgression> addStoryProgression(
    EngineStoryProgression progression,
  ) async {
    final saved = EngineStoryProgression(
      id: 'prog-${++_clock}',
      entryId: progression.entryId,
      chapterOrder: progression.chapterOrder,
      sceneOrder: progression.sceneOrder,
      deltaText: progression.deltaText,
      createdAtMs: _clock,
    );
    _progressions.add(saved);
    return saved;
  }

  @override
  Future<List<EngineStoryChapter>> listStoryChapters(String threadId) async =>
      _chapters.where((c) => c.threadId == threadId).toList();

  @override
  Future<EngineStoryChapter> upsertStoryChapter(
    EngineStoryChapter chapter,
  ) async {
    final saved = EngineStoryChapter(
      id: chapter.id.isEmpty ? 'ch-${++_clock}' : chapter.id,
      threadId: chapter.threadId,
      orderIndex: chapter.orderIndex,
      title: chapter.title,
      summary: chapter.summary,
      eraSummary: chapter.eraSummary,
      createdAtMs: _clock,
    );
    _chapters.removeWhere((c) => c.id == saved.id);
    _chapters.add(saved);
    return saved;
  }

  @override
  Future<List<EngineStoryScene>> listStoryScenes(String chapterId) async =>
      _scenes.where((s) => s.chapterId == chapterId).toList();

  @override
  Future<EngineStoryScene> upsertStoryScene(EngineStoryScene scene) async {
    final saved = EngineStoryScene(
      id: scene.id.isEmpty ? 'sc-${++_clock}' : scene.id,
      chapterId: scene.chapterId,
      orderIndex: scene.orderIndex,
      title: scene.title,
      beatsText: scene.beatsText,
      proseText: scene.proseText,
      povCharacterId: scene.povCharacterId,
      wordCount: scene.proseText.trim().isEmpty
          ? 0
          : scene.proseText.trim().split(RegExp(r'\s+')).length,
      updatedAtMs: _clock,
    );
    _scenes.removeWhere((s) => s.id == saved.id);
    _scenes.add(saved);
    return saved;
  }

  @override
  Future<EngineStoryThreadState> loadStoryThreadState(String threadId) async =>
      _storyStates[threadId] ?? EngineStoryThreadState(threadId: threadId);

  @override
  Future<EngineStoryThreadState> saveStoryThreadState(
    EngineStoryThreadState state,
  ) async {
    _storyStates[state.threadId] = state;
    return state;
  }

  @override
  Future<List<EngineRegexRule>> listRegexRules() async =>
      List<EngineRegexRule>.of(_regexRules);

  @override
  Future<EngineRegexRule> upsertRegexRule(EngineRegexRule rule) async {
    final saved = EngineRegexRule(
      id: rule.id.isEmpty ? 'rx-${++_clock}' : rule.id,
      name: rule.name,
      pattern: rule.pattern,
      replacement: rule.replacement,
      scope: rule.scope,
      enabled: rule.enabled,
      orderIndex: rule.orderIndex,
    );
    _regexRules.removeWhere((r) => r.id == saved.id);
    _regexRules.add(saved);
    return saved;
  }

  @override
  Future<List<EngineStorySnapshot>> listStorySnapshots({
    required String entityType,
    required String entityId,
    int limit = 10,
  }) async => const <EngineStorySnapshot>[];

  /// What [rewritePassage] returns.
  String rewrittenPassage = 'Rewritten passage';

  @override
  Future<String> rewritePassage({
    required String threadId,
    required String mode,
    required String excerpt,
    required String context,
  }) async {
    await _record('rewritePassage', <String, Object?>{
      'threadId': threadId,
      'mode': mode,
      'excerpt': excerpt,
      'context': context,
    });
    return rewrittenPassage;
  }

  @override
  Future<String> planScene({
    required String threadId,
    required String title,
    required String beats,
  }) async {
    await _record('planScene', <String, Object?>{
      'threadId': threadId,
      'title': title,
      'beats': beats,
    });
    return '1. Scene brief';
  }

  @override
  Future<EngineChapterSummary> summarizeChapter({
    required String threadId,
    required String chapterId,
  }) async {
    await _record('summarizeChapter', <String, Object?>{
      'threadId': threadId,
      'chapterId': chapterId,
    });
    return const EngineChapterSummary(
      eraSummary: '- Chapter summary',
      contradictions: <String>['An earlier chapter disagrees.'],
    );
  }

  @override
  Future<EnginePromptReport> inspectStoryPrompt({
    required String threadId,
    String? activeSceneBeats,
  }) async => EnginePromptReport(
    blocks: <EnginePromptBlock>[
      const EnginePromptBlock(
        id: 'system_base',
        label: 'System prompt',
        role: 'system',
        content: 'Grounded narrative studio',
        estimatedTokens: 120,
        isStaticPrefix: true,
      ),
      if (_cards.isNotEmpty)
        EnginePromptBlock(
          id: 'char_${_cards.first.id}',
          label: 'Character · ${_cards.first.name}',
          role: 'system',
          content: _cards.first.description,
          estimatedTokens: 210,
          isStaticPrefix: true,
        ),
      const EnginePromptBlock(
        id: 'author_note',
        label: "Author's Note (@D4)",
        role: 'system',
        content: 'Keep pacing tense and atmospheric.',
        estimatedTokens: 48,
        isStaticPrefix: false,
      ),
    ],
    cacheBoundaryIndex: _cards.isNotEmpty ? 2 : 1,
    totalEstimatedTokens: _cards.isNotEmpty ? 378 : 168,
    staticPrefixTokens: _cards.isNotEmpty ? 330 : 120,
    loreTrace: const <EngineLoreTraceItem>[
      EngineLoreTraceItem(
        entryId: 'e1',
        name: 'Iron Citadel',
        fired: true,
        reason: 'keyword:citadel',
        estimatedTokens: 96,
      ),
    ],
    loreTokensUsed: 96,
  );

  @override
  Future<List<String>> getProviderApiKeys(String providerId) async {
    final prov = _providers.where((p) => p.id == providerId).firstOrNull;
    if (prov == null || !prov.hasApiKey) return const <String>[];
    return const <String>['sk-test-primary-key'];
  }

  @override
  Future<EngineModelCatalogInfo?> lookupModelCatalogInfo(
    String providerId,
    String modelId,
  ) async =>
      modelInfo ??
      const EngineModelCatalogInfo(
        contextWindow: 1048576,
        maxOutputTokens: 65536,
        inputPerMtokMicros: 300000,
        outputPerMtokMicros: 2500000,
        cachedInputPerMtokMicros: 75000,
        cacheWritePerMtokMicros: 18750,
        cacheWrite1hPerMtokMicros: 1250000,
        reasoning: true,
      );

  @override
  Future<EngineNode> sendAndStreamReplyWithAttachments({
    required String threadId,
    String? parentId,
    required String userContent,
    required List<EngineAttachmentInput> attachments,
  }) => sendAndStreamReply(
    threadId: threadId,
    parentId: parentId,
    userContent: userContent,
  );

  @override
  Future<EngineNode> steerActiveRunNow({
    required String threadId,
    required String content,
  }) => sendAndStreamReply(threadId: threadId, userContent: content);

  @override
  Future<int> importThreadsJson(String rawJson) async => 1;

  @override
  Future<String> exportSettingsJson() async => '{}';

  @override
  Future<EngineSettings> importSettingsJson(
    String rawJson, {
    bool allowLoosening = false,
  }) async {
    await _record('importSettingsJson', <String, Object?>{
      'allowLoosening': allowLoosening,
    });
    if (importLoosensSafety && !allowLoosening) {
      throw StateError('diag.import.loosens_safety');
    }
    return _settings;
  }

  /// When true, an unconfirmed import fails like a file that would loosen safety.
  bool importLoosensSafety = false;

  @override
  Future<List<EngineStorageFileEntry>> listStorageFiles() async =>
      const <EngineStorageFileEntry>[];

  @override
  Future<bool> deleteStorageFile(String relPath) async => true;

  @override
  Future<int> cleanUnusedStorageFiles() async => 0;

  @override
  Future<List<int>> synthesizeSpeech({
    required String providerId,
    required String modelId,
    required String text,
    String? voice,
  }) async => const <int>[];

  @override
  Future<String> startLiveVoiceSession({
    required String providerId,
    required String modelId,
    required String voice,
    required String systemPrompt,
  }) async => 'live_fake_1';

  @override
  Future<void> sendLiveVoicePcmChunk({
    required String sessionId,
    required String pcmBase64,
  }) async {}

  @override
  Future<void> sendLiveVoiceText({
    required String sessionId,
    required String text,
  }) async {}

  @override
  Future<void> stopLiveVoiceSession(String sessionId) =>
      _record('stopLiveVoiceSession', {'sessionId': sessionId});
}
