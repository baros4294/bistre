import 'dart:async';
import 'dart:convert';

import 'package:bistre_app/bridge/bistre_engine.dart';

import 'fake_context.dart';

part 'fake_engine_gateway_chat.dart';
part 'fake_engine_gateway_harness.dart';
part 'fake_engine_gateway_library.dart';
part 'fake_engine_gateway_runs.dart';
part 'fake_engine_gateway_sharing.dart';

/// In-memory [BistreEngineGateway] used by widget tests (no native library).
class FakeEngineGateway
    with
        _FakeRunsAndPower,
        _FakeSharingAndHistory,
        _FakeHarnessAndStory,
        _FakeChatActions,
        _FakeLibrary
    implements BistreEngineGateway {
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
        dialect: 'google_gemini',
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

  @override
  List<EngineThread> get chatThreads => _threads;
  final List<EngineNode> _nodes = <EngineNode>[];
  final Map<String, String> _drafts = <String, String>{};
  EngineSettings _settings = const EngineSettings();
  int _clock = 10;
  int _replySeq = 0;
  final StreamController<BistreEvent> _events =
      StreamController<BistreEvent>.broadcast();

  /// Every recorded call, in order.
  final List<FakeCall> calls = <FakeCall>[];
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};

  /// Holds the next calls of [method] until [release], so a test can act (switch chats,
  /// press Enter) while an engine call is still in flight.
  void gate(String method) => _gates.putIfAbsent(method, Completer<void>.new);

  /// Lets held calls of [method] continue and removes the gate.
  void release(String method) {
    final gate = _gates.remove(method);
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> _record(String method, Map<String, Object?> args) async {
    calls.add(FakeCall(method, args));
    final gate = _gates[method];
    if (gate != null) await gate.future;
  }

  /// Calls of [method], oldest first.
  Iterable<FakeCall> callsTo(String method) =>
      calls.where((c) => c.method == method);

  /// Pushes an engine event to every subscriber.
  void emit(BistreEvent event) => _events.add(event);

  /// Adds a thread with an explicit `updatedAtMs` (day-group and ordering tests).
  EngineThread seedThread({required String title, required int updatedAtMs}) {
    final t = EngineThread(
      id: 'thread-${_threads.length + 1}',
      workspaceId: 'ws-default',
      title: title,
      mode: 'chat',
      createdAtMs: updatedAtMs,
      updatedAtMs: updatedAtMs,
    );
    _threads.add(t);
    return t;
  }

  /// Records a committed message in [threadId] (with reply metadata for assistant turns).
  EngineNode seedNode({
    required String threadId,
    String? parentId,
    required String role,
    required String content,
    Map<String, Object?>? meta,
  }) {
    final n = EngineNode(
      id: 'node-${_nodes.length + 1}',
      threadId: threadId,
      parentId: parentId,
      role: role,
      content: content,
      createdAtMs: ++_clock,
      providerMetaJson: meta == null ? null : jsonEncode(meta),
    );
    _nodes.add(n);
    return n;
  }

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
  ) async {
    final failure = fetchModelsFailure;
    if (failure != null) throw Exception(failure);
    return const <EngineProviderModel>[
      EngineProviderModel(id: 'gpt-4.1', displayName: 'GPT-4.1'),
      EngineProviderModel(id: 'o4-mini', displayName: 'o4-mini'),
    ];
  }

  /// When set, `fetchProviderModels` fails with this error (a diagnostic key string).
  String? fetchModelsFailure;

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
    String? projectId,
  }) async {
    final ts = ++_clock;
    final t = EngineThread(
      id: 'thread-${_threads.length + 1}',
      workspaceId: projectId ?? 'ws-default',
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
    await _record('updateThread', <String, Object?>{
      'threadId': threadId,
      'title': title,
      'mode': mode,
    });
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
    await _record('deleteThread', <String, Object?>{'threadId': threadId});
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
    List<EngineNodeAttachment> attachments = const <EngineNodeAttachment>[],
  }) async {
    final n = EngineNode(
      id: 'node-${_nodes.length + 1}',
      threadId: threadId,
      parentId: parentId,
      role: role,
      content: content,
      createdAtMs: ++_clock,
      attachments: attachments,
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
    await _record('sendAndStreamReply', <String, Object?>{
      'threadId': threadId,
      'parentId': parentId,
      'userContent': userContent,
    });
    if (!_providers.any((p) => p.isReady)) {
      throw StateError('diag.provider.not_configured');
    }
    final userNode = await appendNode(
      threadId: threadId,
      parentId: parentId,
      role: 'user',
      content: userContent,
    );
    // Like the real engine, sending does not touch the stored draft; the composer saves
    // its own (now empty) text.
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
  Future<EngineThread> forkThread({
    required String threadId,
    required String nodeId,
  }) async {
    await _record('forkThread', <String, Object?>{
      'threadId': threadId,
      'nodeId': nodeId,
    });
    final source = _threads.firstWhere((t) => t.id == threadId);
    final byId = <String, EngineNode>{
      for (final n in _nodes)
        if (n.threadId == threadId) n.id: n,
    };
    final path = <EngineNode>[];
    for (var n = byId[nodeId]; n != null; n = byId[n.parentId]) {
      path.insert(0, n);
    }
    final fork = await createThread(
      source.title,
      source.mode,
      assistantId: source.assistantId,
    );
    String? parent;
    for (final n in path) {
      parent = seedNode(
        threadId: fork.id,
        parentId: parent,
        role: n.role,
        content: n.content,
      ).id;
    }
    return fork;
  }

  @override
  Future<void> deleteFromNode({
    required String threadId,
    required String nodeId,
  }) async {
    await _record('deleteFromNode', <String, Object?>{
      'threadId': threadId,
      'nodeId': nodeId,
    });
    final doomed = <String>{nodeId};
    for (var grew = true; grew;) {
      grew = false;
      for (final n in _nodes) {
        if (n.threadId == threadId &&
            doomed.contains(n.parentId) &&
            doomed.add(n.id)) {
          grew = true;
        }
      }
    }
    _nodes.removeWhere((n) => n.threadId == threadId && doomed.contains(n.id));
  }

  @override
  Future<void> clearThreadMessages(String threadId) async {
    await _record('clearThreadMessages', <String, Object?>{
      'threadId': threadId,
    });
    _nodes.removeWhere((n) => n.threadId == threadId);
  }

  @override
  Future<String> regenerateReply({
    required String threadId,
    required String userNodeId,
  }) async {
    await _record('regenerateReply', <String, Object?>{
      'threadId': threadId,
      'userNodeId': userNodeId,
    });
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
  Future<bool> cancelActiveRun(String threadId) async {
    await _record('cancelActiveRun', <String, Object?>{'threadId': threadId});
    return false;
  }

  @override
  Future<bool> retryRunNow(String threadId) async => false;

  @override
  Future<List<EngineNode>> listNodes(String threadId) async {
    await _record('listNodes', <String, Object?>{'threadId': threadId});
    return _nodes.where((n) => n.threadId == threadId).toList(growable: false);
  }

  @override
  Future<void> saveDraft(String threadId, String text) async {
    await _record('saveDraft', <String, Object?>{
      'threadId': threadId,
      'text': text,
    });
    _drafts[threadId] = text;
  }

  @override
  Future<String?> loadDraft(String threadId) async {
    await _record('loadDraft', <String, Object?>{'threadId': threadId});
    return _drafts[threadId];
  }

  @override
  Future<EngineSettings> loadSettings() async => _settings;

  @override
  Future<EngineSettings> saveSettings(EngineSettings settings) async {
    await _record('saveSettings', const <String, Object?>{});
    _settings = settings;
    return _settings;
  }

  @override
  Future<int> getWalletSpendMicros() async => 0;

  @override
  Future<int> getWalletDailySpendMicros() async => 0;

  List<EnginePurposeUsage> purposeUsage = const <EnginePurposeUsage>[];

  @override
  Future<List<EnginePurposeUsage>> getWalletUsageByPurpose(
    DateTime since,
  ) async => purposeUsage;

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

  /// Optional title returned by [generateThreadTitle].
  String? generatedTitleOverride;

  /// Optional error thrown by [inspectNextRequest] (to test blocked inspection).
  Object? inspectNextRequestError;

  @override
  Future<EngineThread> generateThreadTitle(String threadId) async {
    await _record('generateThreadTitle', {'threadId': threadId});
    final idx = _threads.indexWhere((t) => t.id == threadId);
    if (idx < 0) throw StateError('diag.storage.not_found');
    final nextTitle = generatedTitleOverride ?? 'Generated title';
    final t = _threads[idx];
    final updated = EngineThread(
      id: t.id,
      workspaceId: t.workspaceId,
      title: nextTitle,
      mode: t.mode,
      topic: t.topic,
      assistantId: t.assistantId,
      isPinned: t.isPinned,
      activeHeadNodeId: t.activeHeadNodeId,
      providerIdOverride: t.providerIdOverride,
      modelIdOverride: t.modelIdOverride,
      systemPromptOverride: t.systemPromptOverride,
      temperatureMilli: t.temperatureMilli,
      maxOutputTokens: t.maxOutputTokens,
      topPMilli: t.topPMilli,
      createdAtMs: t.createdAtMs,
      updatedAtMs: ++_clock,
    );
    _threads[idx] = updated;
    return updated;
  }

  @override
  Future<EngineNode> translateNode({
    required String threadId,
    required String nodeId,
    String? targetLanguage,
  }) async {
    await _record('translateNode', {
      'threadId': threadId,
      'nodeId': nodeId,
      'targetLanguage': targetLanguage,
    });
    final src = _nodes.firstWhere(
      (n) => n.id == nodeId && n.threadId == threadId,
      orElse: () => throw StateError('diag.storage.not_found'),
    );
    final lang = targetLanguage ?? 'English';
    final created = EngineNode(
      id: 'node-${_nodes.length + 1}',
      threadId: threadId,
      parentId: src.parentId,
      role: src.role,
      content: '[$lang] ${src.content}',
      providerMetaJson: jsonEncode(<String, Object?>{
        'translated_from': src.id,
        'target_language': lang,
      }),
      createdAtMs: ++_clock,
    );
    _nodes.add(created);
    _events.add(NodeCommittedEvent(created));
    return created;
  }

  @override
  Future<EngineInspectedRequest> inspectNextRequest({
    required String threadId,
    required String draft,
  }) async {
    await _record('inspectNextRequest', {'threadId': threadId, 'draft': draft});
    if (inspectNextRequestError case final err?) {
      if (err is Error) throw err;
      if (err is Exception) throw err;
      throw StateError('$err');
    }
    return EngineInspectedRequest(
      method: 'POST',
      url: 'https://api.openai.com/v1/responses',
      dialect: 'openai',
      model: _settings.activeModelId.isEmpty
          ? 'gpt-4.1'
          : _settings.activeModelId,
      headers: const <(String, String)>[('content-type', 'application/json')],
      bodyJson: jsonEncode(<String, Object?>{
        'model': _settings.activeModelId.isEmpty
            ? 'gpt-4.1'
            : _settings.activeModelId,
        'store': false,
        'input': <Object?>[
          if (draft.trim().isNotEmpty)
            <String, Object?>{'role': 'user', 'content': draft.trim()},
        ],
      }),
    );
  }

  @override
  Stream<BistreEvent> subscribeEvents() => _events.stream;

  @override
  Future<void> shutdown() async {
    await _record('shutdown', <String, Object?>{});
    await _events.close();
  }
}

/// One recorded gateway call.
class FakeCall {
  const FakeCall(this.method, this.args);

  final String method;
  final Map<String, Object?> args;

  @override
  String toString() => '$method($args)';
}
