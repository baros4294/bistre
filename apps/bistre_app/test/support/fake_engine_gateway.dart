import 'dart:async';
import 'dart:convert';

import 'package:bistre_app/bridge/bistre_engine.dart';

/// In-memory [BistreEngineGateway] used by widget tests (no native library).
class FakeEngineGateway implements BistreEngineGateway {
  FakeEngineGateway({bool seedConnectedOpenAi = false}) {
    _providers.addAll(<EngineProvider>[
      EngineProvider(
        id: 'openai',
        name: 'OpenAI',
        dialect: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        defaultModel: seedConnectedOpenAi ? 'gpt-4.1' : '',
        keyHint: seedConnectedOpenAi ? '••••4242' : '',
        hasApiKey: seedConnectedOpenAi,
        isEnabled: true,
        isBuiltin: true,
        useServerStateCache: false,
        iconSlug: 'openai',
        createdAtMs: 1,
        updatedAtMs: 1,
      ),
      const EngineProvider(
        id: 'google_gemini',
        name: 'Google Gemini',
        dialect: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        defaultModel: '',
        keyHint: '',
        hasApiKey: false,
        isEnabled: true,
        isBuiltin: true,
        useServerStateCache: false,
        iconSlug: 'gemini',
        createdAtMs: 2,
        updatedAtMs: 2,
      ),
      const EngineProvider(
        id: 'anthropic',
        name: 'Anthropic',
        dialect: 'anthropic',
        baseUrl: 'https://api.anthropic.com/v1',
        defaultModel: '',
        keyHint: '',
        hasApiKey: false,
        isEnabled: true,
        isBuiltin: true,
        useServerStateCache: false,
        iconSlug: 'claude',
        createdAtMs: 3,
        updatedAtMs: 3,
      ),
    ]);
    if (seedConnectedOpenAi) {
      _settings = const EngineSettings(
        activeProviderId: 'openai',
        activeModelId: 'gpt-4.1',
      );
    }
  }

  final List<EngineProvider> _providers = <EngineProvider>[];
  final List<EngineAssistant> _assistants = <EngineAssistant>[
    const EngineAssistant(
      id: 'default_assistant',
      name: 'Default',
      roleSubtitle: '',
      systemPrompt: '',
      defaultMode: 'chat',
      badgeCode: 'DF',
      isBuiltin: true,
      createdAtMs: 1,
    ),
  ];
  final List<EngineThread> _threads = <EngineThread>[];
  final List<EngineNode> _nodes = <EngineNode>[];
  final Map<String, String> _drafts = <String, String>{};
  EngineSettings _settings = const EngineSettings();
  int _clock = 10;
  int _replySeq = 0;
  final StreamController<BistreEvent> _events =
      StreamController<BistreEvent>.broadcast();

  @override
  Future<EngineHealth> init(String dataDir) async => getHealth();

  @override
  Future<EngineHealth> getHealth() async => EngineHealth(
    coreVersion: '0.1.0',
    schemaVersion: 5,
    walModeActive: true,
    threadCount: _threads.length,
    nodeCount: _nodes.length,
    activeRuns: 0,
    statusKey: 'diag.ok',
  );

  @override
  Future<List<EngineProvider>> listProviders() async =>
      List<EngineProvider>.unmodifiable(_providers);

  @override
  Future<EngineProvider> updateProvider({
    required String providerId,
    String? name,
    String? baseUrl,
    String? defaultModel,
    bool? isEnabled,
    bool? useServerStateCache,
    String? iconSlug,
    String? customIconPath,
  }) async {
    final idx = _providers.indexWhere((p) => p.id == providerId);
    final old = _providers[idx];
    final next = EngineProvider(
      id: old.id,
      name: name ?? old.name,
      dialect: old.dialect,
      baseUrl: baseUrl ?? old.baseUrl,
      defaultModel: defaultModel ?? old.defaultModel,
      keyHint: old.keyHint,
      hasApiKey: old.hasApiKey,
      isEnabled: isEnabled ?? old.isEnabled,
      isBuiltin: old.isBuiltin,
      useServerStateCache: useServerStateCache ?? old.useServerStateCache,
      iconSlug: iconSlug ?? old.iconSlug,
      customIconPath: customIconPath ?? old.customIconPath,
      createdAtMs: old.createdAtMs,
      updatedAtMs: ++_clock,
    );
    _providers[idx] = next;
    return next;
  }

  @override
  Future<EngineProvider> setProviderApiKey({
    required String providerId,
    required String apiKey,
  }) async {
    final idx = _providers.indexWhere((p) => p.id == providerId);
    final old = _providers[idx];
    final tail = apiKey.length >= 4
        ? apiKey.substring(apiKey.length - 4)
        : apiKey;
    final next = EngineProvider(
      id: old.id,
      name: old.name,
      dialect: old.dialect,
      baseUrl: old.baseUrl,
      defaultModel: old.defaultModel,
      keyHint: '••••$tail',
      hasApiKey: true,
      isEnabled: true,
      isBuiltin: old.isBuiltin,
      useServerStateCache: old.useServerStateCache,
      iconSlug: old.iconSlug,
      customIconPath: old.customIconPath,
      createdAtMs: old.createdAtMs,
      updatedAtMs: ++_clock,
    );
    _providers[idx] = next;
    if (_settings.activeProviderId.isEmpty) {
      _settings = _settings.copyWith(activeProviderId: providerId);
    }
    return next;
  }

  @override
  Future<EngineProvider> clearProviderApiKey(String providerId) async {
    final idx = _providers.indexWhere((p) => p.id == providerId);
    final old = _providers[idx];
    final next = EngineProvider(
      id: old.id,
      name: old.name,
      dialect: old.dialect,
      baseUrl: old.baseUrl,
      defaultModel: old.defaultModel,
      keyHint: '',
      hasApiKey: false,
      isEnabled: old.isEnabled,
      isBuiltin: old.isBuiltin,
      useServerStateCache: old.useServerStateCache,
      iconSlug: old.iconSlug,
      customIconPath: old.customIconPath,
      createdAtMs: old.createdAtMs,
      updatedAtMs: ++_clock,
    );
    _providers[idx] = next;
    return next;
  }

  @override
  Future<EngineProvider> createProvider({
    required String name,
    required String dialect,
    required String baseUrl,
    required String defaultModel,
    required String iconSlug,
    String customIconPath = '',
    String? apiKey,
  }) async {
    final hasKey = apiKey != null && apiKey.trim().isNotEmpty;
    final created = EngineProvider(
      id: 'prov-${_providers.length + 1}',
      name: name,
      dialect: dialect,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      keyHint: hasKey ? '••••cust' : '',
      hasApiKey: hasKey,
      isEnabled: true,
      isBuiltin: false,
      useServerStateCache: false,
      iconSlug: iconSlug,
      customIconPath: customIconPath,
      createdAtMs: ++_clock,
      updatedAtMs: _clock,
    );
    _providers.add(created);
    return created;
  }

  @override
  Future<EngineProvider> createCustomProvider({
    required String name,
    required String baseUrl,
    required String defaultModel,
    String? apiKey,
  }) => createProvider(
    name: name,
    dialect: 'custom_openai',
    baseUrl: baseUrl,
    defaultModel: defaultModel,
    iconSlug: 'server',
    apiKey: apiKey,
  );

  @override
  Future<void> deleteProvider(String providerId) async {
    // Every provider (including starter OpenAI/Gemini/Anthropic) is deletable.
    _providers.removeWhere((p) => p.id == providerId);
  }

  @override
  Future<List<EngineProviderModel>> fetchProviderModels(
    String providerId,
  ) async => const <EngineProviderModel>[
    EngineProviderModel(id: 'gpt-4.1', displayName: 'GPT-4.1'),
    EngineProviderModel(id: 'o4-mini', displayName: 'o4-mini'),
  ];

  @override
  Future<List<EngineAssistant>> listAssistants() async =>
      List<EngineAssistant>.unmodifiable(_assistants);

  @override
  Future<EngineAssistant> createAssistant({
    required String name,
    required String roleSubtitle,
    required String systemPrompt,
    required String defaultMode,
    required String badgeCode,
  }) async {
    final created = EngineAssistant(
      id: 'asst-${_assistants.length + 1}',
      name: name,
      roleSubtitle: roleSubtitle,
      systemPrompt: systemPrompt,
      defaultMode: defaultMode,
      badgeCode: badgeCode,
      isBuiltin: false,
      createdAtMs: ++_clock,
    );
    _assistants.add(created);
    return created;
  }

  @override
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
  }) async {
    final idx = _assistants.indexWhere((a) => a.id == assistantId);
    final old = _assistants[idx];
    final next = EngineAssistant(
      id: old.id,
      name: name ?? old.name,
      roleSubtitle: roleSubtitle ?? old.roleSubtitle,
      systemPrompt: systemPrompt ?? old.systemPrompt,
      defaultMode: defaultMode ?? old.defaultMode,
      badgeCode: badgeCode ?? old.badgeCode,
      iconSlug: iconSlug ?? old.iconSlug,
      defaultProviderId: defaultProviderId ?? old.defaultProviderId,
      defaultModelId: defaultModelId ?? old.defaultModelId,
      temperatureMilli: clearTemperature
          ? null
          : (temperatureMilli ?? old.temperatureMilli),
      maxOutputTokens: clearMaxOutputTokens
          ? null
          : (maxOutputTokens ?? old.maxOutputTokens),
      topPMilli: clearTopP ? null : (topPMilli ?? old.topPMilli),
      isBuiltin: old.isBuiltin,
      createdAtMs: old.createdAtMs,
    );
    _assistants[idx] = next;
    return next;
  }

  @override
  Future<void> deleteAssistant(String assistantId) async {
    if (_assistants.length <= 1) return;
    _assistants.removeWhere((a) => a.id == assistantId);
  }

  @override
  Future<EngineThread> createThread(
    String title,
    String mode, {
    String? topic,
    String? assistantId,
  }) async {
    final ts = ++_clock;
    final t = EngineThread(
      id: 'thread-${_threads.length + 1}',
      workspaceId: 'ws-default',
      title: title,
      mode: mode,
      topic: topic ?? 'general',
      assistantId: assistantId ?? 'default_assistant',
      createdAtMs: ts,
      updatedAtMs: ts,
    );
    _threads.add(t);
    return t;
  }

  @override
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
  }) async {
    final idx = _threads.indexWhere((t) => t.id == threadId);
    final old = _threads[idx];
    final updated = EngineThread(
      id: old.id,
      workspaceId: old.workspaceId,
      title: title ?? old.title,
      mode: mode ?? old.mode,
      topic: topic ?? old.topic,
      assistantId: assistantId ?? old.assistantId,
      isPinned: isPinned ?? old.isPinned,
      activeHeadNodeId: old.activeHeadNodeId,
      providerIdOverride: clearProviderOverride
          ? null
          : (providerIdOverride ?? old.providerIdOverride),
      modelIdOverride: clearModelOverride
          ? null
          : (modelIdOverride ?? old.modelIdOverride),
      systemPromptOverride: clearSystemPromptOverride
          ? null
          : (systemPromptOverride ?? old.systemPromptOverride),
      temperatureMilli: clearTemperature
          ? null
          : (temperatureMilli ?? old.temperatureMilli),
      maxOutputTokens: clearMaxOutputTokens
          ? null
          : (maxOutputTokens ?? old.maxOutputTokens),
      topPMilli: clearTopP ? null : (topPMilli ?? old.topPMilli),
      createdAtMs: old.createdAtMs,
      updatedAtMs: ++_clock,
    );
    _threads[idx] = updated;
    return updated;
  }

  @override
  Future<void> deleteThread(String threadId) async {
    _threads.removeWhere((t) => t.id == threadId);
    _nodes.removeWhere((n) => n.threadId == threadId);
    _drafts.remove(threadId);
  }

  @override
  Future<List<EngineThread>> listThreads() async {
    final sorted = List<EngineThread>.of(_threads)
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) {
          return a.isPinned ? -1 : 1;
        }
        return b.updatedAtMs.compareTo(a.updatedAtMs);
      });
    return sorted;
  }

  @override
  Future<EngineNode> appendNode({
    required String threadId,
    String? parentId,
    required String role,
    required String content,
  }) async {
    final n = EngineNode(
      id: 'node-${_nodes.length + 1}',
      threadId: threadId,
      parentId: parentId,
      role: role,
      content: content,
      createdAtMs: ++_clock,
    );
    _nodes.add(n);
    _events.add(NodeCommittedEvent(n));
    return n;
  }

  @override
  Future<EngineNode> sendAndStreamReply({
    required String threadId,
    String? parentId,
    required String userContent,
  }) async {
    if (!_providers.any((p) => p.isReady)) {
      throw StateError('diag.provider.not_configured');
    }
    final userNode = await appendNode(
      threadId: threadId,
      parentId: parentId,
      role: 'user',
      content: userContent,
    );
    _drafts.remove(threadId);
    _emitSimulatedAssistantReply(threadId, userNode.id);
    return userNode;
  }

  @override
  Future<EngineNode> editUserNodeAndStream({
    required String threadId,
    required String nodeId,
    required String newContent,
  }) async {
    final orig = _nodes.firstWhere((n) => n.id == nodeId);
    final edited = await appendNode(
      threadId: threadId,
      parentId: orig.parentId,
      role: 'user',
      content: newContent,
    );
    _emitSimulatedAssistantReply(threadId, edited.id);
    return edited;
  }

  @override
  Future<void> deleteNode({
    required String threadId,
    required String nodeId,
  }) async {
    _nodes.removeWhere((n) => n.threadId == threadId && n.id == nodeId);
  }

  @override
  Future<String> regenerateReply({
    required String threadId,
    required String userNodeId,
  }) async {
    if (!_providers.any((p) => p.isReady)) {
      throw StateError('diag.provider.not_configured');
    }
    return _emitSimulatedAssistantReply(threadId, userNodeId);
  }

  String _emitSimulatedAssistantReply(String threadId, String parentUserId) {
    final seq = ++_replySeq;
    final replyId = 'reply-$seq';
    final body = 'Reply draft #$seq\n\n```rust\nfn main() {}\n```';
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _events
        ..add(RunStartedEvent(threadId: threadId, nodeId: replyId))
        ..add(
          DeltaBatchEvent(threadId: threadId, nodeId: replyId, textDelta: body),
        );
      final assistantNode = EngineNode(
        id: replyId,
        threadId: threadId,
        parentId: parentUserId,
        role: 'assistant',
        content: body,
        createdAtMs: ++_clock,
        providerMetaJson: jsonEncode(<String, Object?>{
          'model_id': 'gpt-4.1',
          'provider_name': 'OpenAI',
          'icon_slug': 'openai',
          'input_tokens': 140,
          'output_tokens': 48,
          'cost_micros': 1250,
        }),
      );
      _nodes.add(assistantNode);
      _events
        ..add(NodeCommittedEvent(assistantNode))
        ..add(
          RunFinishedEvent(
            threadId: threadId,
            nodeId: replyId,
            cancelled: false,
          ),
        );
    });
    return replyId;
  }

  @override
  Future<bool> cancelActiveRun(String threadId) async => false;

  @override
  Future<bool> retryRunNow(String threadId) async => false;

  @override
  Future<List<EngineNode>> listNodes(String threadId) async =>
      _nodes.where((n) => n.threadId == threadId).toList(growable: false);

  @override
  Future<void> saveDraft(String threadId, String text) async {
    _drafts[threadId] = text;
  }

  @override
  Future<String?> loadDraft(String threadId) async => _drafts[threadId];

  @override
  Future<EngineSettings> loadSettings() async => _settings;

  @override
  Future<EngineSettings> saveSettings(EngineSettings settings) async {
    _settings = settings;
    return _settings;
  }

  @override
  Future<int> getWalletSpendMicros() async => 0;

  @override
  Future<int> getWalletDailySpendMicros() async => 0;

  @override
  Future<EngineStorageStats> getStorageStats() async => EngineStorageStats(
    dataDir: '.bistre-dev',
    dbSizeBytes: 65536,
    coreVersion: '0.1.0',
    schemaVersion: 5,
    walModeActive: true,
    threadCount: _threads.length,
    nodeCount: _nodes.length,
    activeRuns: 0,
  );

  @override
  Future<String> exportThread({
    required String threadId,
    required String format,
  }) async => '# Export ($format)';

  @override
  Future<void> backupDatabase(String destPath) async {}

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
        releaseNotes: 'Native Win11 titlebar + offline color lab icons.',
        downloadUrl: 'https://example.invalid/bistre-0.2.0.zip',
        sha256Hex: '0000',
        downloadSizeBytes: 12400000,
        checkedAtMs: 1700000000000,
      );

  @override
  Future<String> stageUpdate(EngineUpdateCheck check) async =>
      '.bistre-dev/updates/bistre-0.2.0.zip';

  @override
  Future<List<EngineSearchHit>> searchNodes(
    String query, {
    String? threadId,
    int limit = 20,
  }) async {
    final lower = query.toLowerCase();
    return _nodes
        .where(
          (n) =>
              (threadId == null || n.threadId == threadId) &&
              n.content.toLowerCase().contains(lower),
        )
        .map(
          (n) => EngineSearchHit(
            nodeId: n.id,
            threadId: n.threadId,
            role: n.role,
            snippet: n.content,
            createdAtMs: n.createdAtMs,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<String> verifyDataPack({
    required String publicKeyB64,
    required List<int> manifestBytes,
    required String manifestSigText,
    required List<int> packPayload,
  }) async => '1.0.0';

  final List<EngineAgentRun> _runs = <EngineAgentRun>[];
  final List<EngineSteeringMessage> _steering = <EngineSteeringMessage>[];
  EnginePowerGuardStatus _powerStatus = const EnginePowerGuardStatus();

  @override
  Future<List<EngineAgentRun>> listAgentRuns({
    String? threadId,
    bool onlyActive = false,
    int limit = 50,
  }) async => _runs
      .where(
        (r) =>
            (threadId == null || r.threadId == threadId) &&
            (!onlyActive || r.isActive),
      )
      .take(limit)
      .toList(growable: false);

  @override
  Future<EngineSteeringMessage> enqueueSteering({
    required String threadId,
    required String content,
  }) async {
    final msg = EngineSteeringMessage(
      id: 'steer-${_steering.length + 1}',
      threadId: threadId,
      content: content,
      status: 'pending',
      createdAtMs: ++_clock,
    );
    _steering.add(msg);
    _events.add(
      SteeringQueueChangedEvent(
        threadId: threadId,
        pendingCount: _steering.where((s) => s.threadId == threadId).length,
      ),
    );
    return msg;
  }

  @override
  Future<List<EngineSteeringMessage>> listPendingSteering(
    String threadId,
  ) async => _steering
      .where((s) => s.threadId == threadId && s.status == 'pending')
      .toList(growable: false);

  @override
  Future<void> deleteSteering(String steeringId) async {
    _steering.removeWhere((s) => s.id == steeringId);
  }

  @override
  Future<EnginePowerGuardStatus> powerGuardStatus() async => _powerStatus;

  @override
  Future<int> notifyPowerEvent(String eventKind, {bool? onAc}) async => 0;

  @override
  Future<EnginePowerGuardStatus> setAndroidPowerState({
    required bool fgsActive,
    required bool batteryUnrestricted,
  }) async {
    _powerStatus = EnginePowerGuardStatus(
      platform: 'android',
      androidFgsActive: fgsActive,
      androidBatteryUnrestricted: batteryUnrestricted,
    );
    return _powerStatus;
  }

  @override
  Future<EngineAgentRun> resolveIndeterminateRun({
    required String runId,
    required bool confirmCompleted,
  }) async {
    final idx = _runs.indexWhere((r) => r.id == runId);
    final old = _runs[idx];
    final next = EngineAgentRun(
      id: old.id,
      threadId: old.threadId,
      mode: old.mode,
      status: 'running',
      stepIndex: old.stepIndex,
      maxSteps: old.maxSteps,
      unattendedPolicy: old.unattendedPolicy,
      lastHeartbeatMs: ++_clock,
      costMicros: old.costMicros,
      createdAtMs: old.createdAtMs,
      updatedAtMs: _clock,
    );
    _runs[idx] = next;
    return next;
  }

  final Map<String, String> _kvMeta = <String, String>{};
  final Map<String, String> _contextPins = <String, String>{};

  int refreshPricesCalls = 0;

  @override
  Future<void> refreshPrices() async => refreshPricesCalls++;

  @override
  Future<String> approveToolCall({
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
  }) async => 'permit-$toolName';

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
  Future<EngineNode> compactThread({
    required String threadId,
    int keepRecentTurns = 4,
    String? customSummary,
  }) async {
    final summary = EngineNode(
      id: 'compact-${++_clock}',
      threadId: threadId,
      parentId: _nodes.where((n) => n.threadId == threadId).lastOrNull?.id,
      role: 'compaction_summary',
      content: customSummary ?? 'Condensed summary of earlier turns.',
      createdAtMs: _clock,
    );
    _nodes.add(summary);
    return summary;
  }

  @override
  Future<void> undoCompaction({
    required String threadId,
    required String compactionNodeId,
  }) async {
    _nodes.removeWhere((n) => n.id == compactionNodeId);
  }

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
  Future<List<EngineLocalServer>> discoverLocalServers() async =>
      const <EngineLocalServer>[];

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
  Stream<BistreEvent> subscribeEvents() => _events.stream;

  @override
  Future<void> shutdown() async {
    await _events.close();
  }
}
