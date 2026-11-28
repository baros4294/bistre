part of 'gallery_harness.dart';

/// Updates, runs, tools, memory, schedules, and Story Studio of [GalleryGateway] (split by
/// responsibility).
mixin _GalleryRunsAndStory implements BistreEngineGateway {
  List<EngineProvider> get _providers;
  List<EngineThread> get _threads;
  List<EngineNode> get _nodes;

  @override
  Future<EngineUpdateCheck> checkForUpdates({String? feedUrlOverride}) async =>
      const EngineUpdateCheck(
        currentVersion: '0.1.0',
        latestVersion: '0.2.0',
        updateAvailable: true,
        track: 'track_b',
        ownershipMode: 'direct_github',
        signatureVerified: true,
        activeRunsBlocking: false,
        releaseNotes: 'Windows 11 DWM Sepia title bar, offline full-color AI lab icons, local custom fonts, unlimited daily budget option, and per-chat inspector drawer.',
        downloadUrl: 'https://example.invalid/bistre-0.2.0.zip',
        sha256Hex: '0000',
        downloadSizeBytes: 12400000,
        checkedAtMs: 1700000000000,
      );

  @override
  Future<String> stageUpdate(EngineUpdateCheck check) async =>
      '.bistre-dev/updates/bistre-0.2.0.zip';

  @override
  Future<String> reinstallUpdate(EngineUpdateCheck check) async =>
      '.bistre-dev/updates/bistre-${check.currentVersion}.zip';

  @override
  Future<String?> pendingUpdateVersion() async => null;

  @override
  Future<String> installStagedUpdate() async => '';

  @override
  Future<bool> respondHostAction({
    required String requestId,
    required bool ok,
    required String outputText,
    String? imageBase64,
  }) async => true;

  @override
  Future<List<EngineSearchHit>> searchNodes(
    String query, {
    String? threadId,
    int limit = 20,
  }) async => const <EngineSearchHit>[];

  @override
  Future<String> verifyDataPack({
    required String publicKeyB64,
    required List<int> manifestBytes,
    required String manifestSigText,
    required List<int> packPayload,
  }) async => '1.0.0';

  @override
  Future<List<EngineAgentRun>> listAgentRuns({
    String? threadId,
    bool onlyActive = false,
    int limit = 50,
  }) async => const <EngineAgentRun>[
    EngineAgentRun(
      id: 'run-1',
      threadId: 't-code',
      mode: 'code',
      status: 'running',
      stepIndex: 3,
      maxSteps: 24,
      unattendedPolicy: 'pause_and_notify',
      lastHeartbeatMs: 1700000000000,
      costMicros: 14200,
      createdAtMs: 1700000000000,
      updatedAtMs: 1700000005000,
    ),
  ];

  @override
  Future<EngineSteeringMessage> enqueueSteering({
    required String threadId,
    required String content,
  }) async => EngineSteeringMessage(
    id: 'steer-1',
    threadId: threadId,
    content: content,
    status: 'pending',
    createdAtMs: 1700000006000,
  );

  @override
  Future<List<EngineSteeringMessage>> listPendingSteering(
    String threadId,
  ) async => const <EngineSteeringMessage>[];

  @override
  Future<void> deleteSteering(String steeringId) async {}

  @override
  Future<EnginePowerGuardStatus> powerGuardStatus() async =>
      const EnginePowerGuardStatus(
        keepAwakeActive: true,
        daemonConnected: true,
        sleepPreventedReason: 'Active agent run',
        activeRunCount: 1,
      );

  @override
  Future<int> notifyPowerEvent(String eventKind, {bool? onAc}) async => 0;

  @override
  Future<EnginePowerGuardStatus> setAndroidPowerState({
    required bool fgsActive,
    required bool batteryUnrestricted,
  }) async => EnginePowerGuardStatus(
    platform: 'android',
    androidFgsActive: fgsActive,
    androidBatteryUnrestricted: batteryUnrestricted,
  );

  @override
  Future<EngineAgentRun> resolveIndeterminateRun({
    required String runId,
    required bool confirmCompleted,
  }) async => (await listAgentRuns()).first;

  final Map<String, String> _kvMeta = <String, String>{};
  final Map<String, String> _contextPins = <String, String>{};

  int refreshPricesCalls = 0;

  @override
  Future<void> refreshPrices() async => refreshPricesCalls++;

  /// When set, the breakdown core would report (tests); otherwise one is estimated.
  EngineContextBreakdown? contextBreakdownFixture;

  @override
  Future<EngineContextBreakdown> contextBreakdown(
    String threadId,
    String leafNodeId, {
    String draft = '',
  }) async {
    final fixture = contextBreakdownFixture;
    if (fixture != null) return fixture;
    return estimateFakeBreakdown(await listNodes(threadId), leafNodeId, draft);
  }

  @override
  Future<int?> modelContextTokens(String providerId, String model) async =>
      128000;

  @override
  Future<String> approveToolCall({
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
  }) async => 'permit-$toolName';

  @override
  Future<void> allowUnpricedOnce(String threadId) async {}

  @override
  Future<void> allowUnpricedMediaOnce() async {}

  /// The hooks file every folder reports; null (none) unless a scene seeds one.
  EngineWorkspaceHooksStatus? workspaceHooks;

  @override
  Future<EngineWorkspaceHooksStatus?> workspaceHooksStatus(
    String workspaceRoot,
  ) async => workspaceHooks;

  @override
  List<EngineDialectDescriptor> dialectDescriptors() => kTestDialectDescriptors;

  @override
  String defaultTitlePrompt() => kTestDefaultTitlePrompt;

  @override
  EngineResolvedEndpoint resolveProviderEndpoint(
    String dialect,
    String baseUrl,
  ) {
    final d = kTestDialectDescriptors.firstWhere((x) => x.id == dialect);
    final base = baseUrl.trim().isEmpty ? d.defaultBaseUrl : baseUrl.trim();
    return EngineResolvedEndpoint(
      chatUrl: '$base${d.endpointPath}',
      modelsUrl: '$base/models',
    );
  }

  /// Web sources per chat, seeded by gallery scenes.
  final Map<String, List<EngineGroundingSource>> grounding =
      <String, List<EngineGroundingSource>>{};

  /// Adds a chat, message, or provider fixture before the app reads them.
  void seedThread(EngineThread thread) => _threads.insert(0, thread);
  void seedNode(EngineNode node) => _nodes.add(node);
  void seedProvider(EngineProvider provider) => _providers.add(provider);

  @override
  Future<List<EngineGroundingSource>> listThreadGrounding(
    String threadId,
  ) async => grounding[threadId] ?? const <EngineGroundingSource>[];

  @override
  Future<void> approveWorkspaceHooks(
    String workspaceRoot,
    String digest,
  ) async {}

  @override
  Future<void> saveProviderOverrides({
    required String providerId,
    required String headersJson,
    required String bodyJson,
  }) async {}

  @override
  Future<List<BistreEvent>> pendingToolApprovals() async =>
      const <BistreEvent>[];

  @override
  Future<bool> respondToolApproval({
    required String threadId,
    required String runId,
    required String callId,
    required String decision,
  }) async => true;

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
  }) async => 'file.rs';

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
    toolNames: <String>['workspace_search'],
  );

  @override
  Future<String?> getKvMeta(String key) async => _kvMeta[key];

  @override
  Future<void> setKvMeta(String key, String value) async {
    _kvMeta[key] = value;
  }

  @override
  Future<List<EngineMemoryEntry>> listMemoryEntries({String? scope}) async =>
      const <EngineMemoryEntry>[
        EngineMemoryEntry(
          id: 'mem-1',
          scope: 'global',
          scopeId: 'default',
          key: 'style',
          content: 'Prefer concise Rust solutions with zero unwrap calls.',
          pinned: true,
        ),
      ];

  @override
  Future<EngineMemoryEntry> upsertMemoryEntry({
    String? id,
    required String scope,
    required String scopeId,
    required String key,
    required String content,
    bool pinned = false,
  }) async => EngineMemoryEntry(
    id: id ?? 'mem-new',
    scope: scope,
    scopeId: scopeId,
    key: key,
    content: content,
    pinned: pinned,
  );

  @override
  Future<void> deleteMemoryEntry(String entryId) async {}

  @override
  Future<List<EngineSkillIndex>> discoverWorkspaceSkills(
    String workspaceRoot,
  ) async => const <EngineSkillIndex>[
    EngineSkillIndex(
      name: 'fullstack-architect',
      description: 'Layer boundaries, UI craft, and engineering gates.',
      path: '.agents/skills/fullstack-architect/SKILL.md',
    ),
  ];

  @override
  Future<String> loadSkillBody(String workspaceRoot, String skillPath) async =>
      '# Fullstack Architect\nKeep strict layer separation.';

  @override
  Future<List<EngineCronJob>> listCronJobs() async => const <EngineCronJob>[
    EngineCronJob(
      id: 'cron-1',
      name: 'Morning codebase digest',
      scheduleExpr: '0 9 * * *',
      prompt: 'Summarize overnight commits and open issues.',
    ),
  ];

  @override
  Future<EngineCronJob> upsertCronJob(EngineCronJob job) async => job;

  @override
  Future<void> deleteCronJob(String jobId) async {}

  final List<EngineCharacterCard> _cards = <EngineCharacterCard>[
    const EngineCharacterCard(
      id: 'char-lyra',
      name: 'Lyra Vance',
      description: 'Archivist of the Sunken Library. Observant, measured, carries a brass compass.',
      firstMessage: '*She sets the brass lantern onto the wet slate.* "You actually found the harbour cipher."',
      alternateGreetings: <String>[
        '*Rain drums against the iron skylights.* "We have twenty minutes before the tide seals the vault."',
      ],
    ),
    const EngineCharacterCard(
      id: 'char-rowan',
      name: 'Rowan Hale',
      description: 'Harbour cartographer who mapped the lower locks.',
    ),
  ];

  final List<EngineUserPersona> _personas = <EngineUserPersona>[
    const EngineUserPersona(
      id: 'persona-1',
      name: 'Avery Mercer',
      description: 'Independent restorer of flooded maritime manuscripts.',
      isDefault: true,
    ),
  ];

  final List<EngineStoryEntry> _storyEntries = <EngineStoryEntry>[
    const EngineStoryEntry(
      id: 'lore-vault',
      category: 'location',
      name: 'Sunken Library',
      keys: <String>['library', 'vault', 'archive'],
      content:
          'Three submerged limestone halls beneath the eastern breakwater.',
      constant: true,
    ),
    const EngineStoryEntry(
      id: 'lore-cipher',
      name: 'Harbour Cipher',
      keys: <String>['cipher', 'brass'],
      content: 'Tidal lock bearings engraved in copperplate numerals.',
    ),
  ];

  final List<EngineStoryProgression> _progressions = <EngineStoryProgression>[
    const EngineStoryProgression(
      id: 'prog-1',
      entryId: 'lore-vault',
      chapterOrder: 1,
      deltaText: 'Outer floodgate jammed open after the autumn storm.',
    ),
    const EngineStoryProgression(
      id: 'prog-2',
      entryId: 'lore-cipher',
      chapterOrder: 2,
      deltaText: 'Lyra decoded the second ring pointing to Lock 7.',
    ),
  ];

  final List<EngineStoryChapter> _chapters = <EngineStoryChapter>[
    const EngineStoryChapter(
      id: 'ch-1',
      threadId: 't-write',
      title: 'The Lantern & The Lock',
      eraSummary: 'Lyra and Avery recovered the brass cipher at low tide.',
    ),
    const EngineStoryChapter(
      id: 'ch-2',
      threadId: 't-write',
      orderIndex: 2,
      title: 'Submerged Reading Room',
    ),
  ];

  final List<EngineStoryScene> _scenes = <EngineStoryScene>[
    const EngineStoryScene(
      id: 'sc-1',
      chapterId: 'ch-1',
      title: 'East Breakwater Steps',
      beatsText: '1. Low tide reveals the iron grate beneath the pier.\n2. Lyra checks the brass lantern wick against salt spray.\n3. Avery spots the chalk tally left by Rowan an hour earlier.',
      proseText: 'Salt mist clung to the iron rungs as the tide withdrew. Lyra tilted her brass lantern low over the flagstones, catching the faint chalk tally Rowan had promised to leave beside the third bollard.\n\n"He kept his word," she murmured, pulling her coat tighter against the harbour wind. "Ten minutes before the siphon turns."',
      wordCount: 57,
    ),
    const EngineStoryScene(
      id: 'sc-2',
      chapterId: 'ch-1',
      orderIndex: 2,
      title: 'The Copperplate Folio',
      beatsText: '1. Unlock the cedar chest.\n2. Match the compass bearings to the tidal chart.',
    ),
  ];

  EngineStoryThreadState _storyState = const EngineStoryThreadState(
    threadId: 't-write',
    activeCharacterIds: <String>['char-lyra', 'char-rowan'],
    userPersonaId: 'persona-1',
    authorNote: 'Maintain crisp sensory atmosphere, warm maritime detail, and measured dialogue.',
    storyMemory: 'Avery and Lyra are tracing the lost harbour charts before the winter flood.',
    dialogueStyling: true,
    currentChapterOrder: 2,
  );

  final List<EngineRegexRule> _regexRules = <EngineRegexRule>[
    const EngineRegexRule(
      id: 'rx-1',
      name: 'Hide OOC notes',
      pattern: r'\(\(OOC:[^)]*\)\)',
    ),
  ];

  @override
  Future<List<EngineCharacterCard>> listCharacterCards() async => _cards;

  @override
  Future<EngineCharacterCard> upsertCharacterCard(
    EngineCharacterCard card,
  ) async => card;

  @override
  Future<void> deleteCharacterCard(String cardId) async {}

  @override
  Future<EngineCharacterCard> importCharacterCardFile(String filePath) async =>
      _cards.first;

  @override
  Future<String> exportCharacterCardCcv3(String cardId) async => '{}';

  @override
  Future<List<EngineUserPersona>> listUserPersonas() async => _personas;

  @override
  Future<EngineUserPersona> upsertUserPersona(
    EngineUserPersona persona,
  ) async => persona;

  @override
  Future<List<EngineStoryEntry>> listStoryEntries({String? bookId}) async =>
      _storyEntries;

  @override
  Future<EngineStoryEntry> upsertStoryEntry(EngineStoryEntry entry) async =>
      entry;

  @override
  Future<void> deleteStoryEntry(String entryId) async {}

  @override
  Future<List<EngineStoryProgression>> listStoryProgressions({
    String? entryId,
  }) async => _progressions;

  @override
  Future<EngineStoryProgression> addStoryProgression(
    EngineStoryProgression progression,
  ) async => progression;

  @override
  Future<List<EngineStoryChapter>> listStoryChapters(String threadId) async =>
      _chapters;

  @override
  Future<EngineStoryChapter> upsertStoryChapter(
    EngineStoryChapter chapter,
  ) async => chapter;

  @override
  Future<List<EngineStoryScene>> listStoryScenes(String chapterId) async =>
      _scenes.where((s) => s.chapterId == chapterId).toList(growable: false);

  @override
  Future<EngineStoryScene> upsertStoryScene(EngineStoryScene scene) async =>
      scene;

  @override
  Future<EngineStoryThreadState> loadStoryThreadState(String threadId) async =>
      _storyState;

  @override
  Future<EngineStoryThreadState> saveStoryThreadState(
    EngineStoryThreadState state,
  ) async {
    _storyState = state;
    return _storyState;
  }

  @override
  Future<List<EngineRegexRule>> listRegexRules() async => _regexRules;

  @override
  Future<EngineRegexRule> upsertRegexRule(EngineRegexRule rule) async => rule;

  @override
  Future<List<EngineStorySnapshot>> listStorySnapshots({
    required String entityType,
    required String entityId,
    int limit = 10,
  }) async => const <EngineStorySnapshot>[];

  @override
  Future<String> rewritePassage({
    required String threadId,
    required String mode,
    required String excerpt,
    required String context,
  }) async => excerpt;

  @override
  Future<String> planScene({
    required String threadId,
    required String title,
    required String beats,
  }) async => beats;

  @override
  Future<EngineChapterSummary> summarizeChapter({
    required String threadId,
    required String chapterId,
  }) async => const EngineChapterSummary(eraSummary: '');

  @override
  Future<EnginePromptReport> inspectStoryPrompt({
    required String threadId,
    String? activeSceneBeats,
  }) async => const EnginePromptReport(
    blocks: <EnginePromptBlock>[
      EnginePromptBlock(
        id: 'system_base',
        label: 'System prompt',
        role: 'system',
        content: 'Write grounded maritime literary fiction with crisp pacing.',
        estimatedTokens: 142,
        isStaticPrefix: true,
      ),
      EnginePromptBlock(
        id: 'char_lyra',
        label: 'Character · Lyra Vance',
        role: 'system',
        content: 'Archivist of the Sunken Library. Observant, measured, carries a brass compass.',
        estimatedTokens: 286,
        isStaticPrefix: true,
      ),
      EnginePromptBlock(
        id: 'story_memory',
        label: 'Story Memory',
        role: 'system',
        content: 'Avery and Lyra are tracing the lost harbour charts before the winter flood.',
        estimatedTokens: 164,
        isStaticPrefix: true,
      ),
      EnginePromptBlock(
        id: 'era_summaries',
        label: 'Continuity Era Summaries',
        role: 'system',
        content: 'Ch 1: Lyra and Avery recovered the brass cipher at low tide.',
        estimatedTokens: 98,
        isStaticPrefix: true,
      ),
      EnginePromptBlock(
        id: 'lore_vault',
        label: 'Lorebook · Sunken Library',
        role: 'system',
        content: 'Three submerged limestone halls beneath the eastern breakwater. [Ch 1] Outer floodgate jammed open.',
        estimatedTokens: 124,
        isStaticPrefix: false,
      ),
      EnginePromptBlock(
        id: 'author_note',
        label: "Author's Note (@D4)",
        role: 'system',
        content: 'Maintain crisp sensory atmosphere, warm maritime detail, and measured dialogue.',
        estimatedTokens: 66,
        isStaticPrefix: false,
      ),
    ],
    cacheBoundaryIndex: 4,
    totalEstimatedTokens: 880,
    staticPrefixTokens: 690,
    loreTrace: <EngineLoreTraceItem>[
      EngineLoreTraceItem(
        entryId: 'lore-vault',
        name: 'Sunken Library',
        fired: true,
        reason: 'constant',
        estimatedTokens: 124,
      ),
      EngineLoreTraceItem(
        entryId: 'lore-cipher',
        name: 'Harbour Cipher',
        fired: true,
        reason: 'keyword_match',
        estimatedTokens: 82,
      ),
      EngineLoreTraceItem(
        entryId: 'lore-lighthouse',
        name: 'North Lighthouse',
        fired: false,
        reason: 'no_keyword_match',
        estimatedTokens: 0,
      ),
    ],
    loreTokensUsed: 206,
  );
}
