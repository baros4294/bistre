import 'dart:async';
import 'dart:convert';

import 'package:bistre_app/bridge/bistre_engine.dart';

import 'fake_context.dart';

import 'gallery_harness.dart' show kTestDialectDescriptors;

part 'fake_engine_gateway_runs.dart';

/// In-memory [BistreEngineGateway] used by widget tests (no native library).
class FakeEngineGateway with _FakeRunsAndPower implements BistreEngineGateway {
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

  /// When set, the update check fails with this diagnostic (for example
  /// `diag.ota.integrity_failed:asset_mismatch`).
  String? updateCheckFailure;

  /// When set, staging the update fails with this diagnostic.
  String? stageUpdateFailure;

  @override
  Future<EngineUpdateCheck> checkForUpdates({String? feedUrlOverride}) async {
    final failure = updateCheckFailure;
    if (failure != null) throw Exception(failure);
    return _updateCheckFixture;
  }

  static const EngineUpdateCheck _updateCheckFixture = EngineUpdateCheck(
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
  Future<String> stageUpdate(EngineUpdateCheck check) async {
    final failure = stageUpdateFailure;
    if (failure != null) throw Exception(failure);
    return '.bistre-dev/updates/bistre-0.2.0.zip';
  }

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
  Future<int?> modelContextTokens(String model) async => 128000;

  @override
  Future<String> approveToolCall({
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
  }) async => 'permit-$toolName';

  @override
  Future<void> allowUnpricedOnce(String threadId) =>
      _record('allowUnpricedOnce', <String, Object?>{'threadId': threadId});

  /// Hooks reported for any workspace root (`null`: no hooks file).
  EngineWorkspaceHooksStatus? workspaceHooks;

  @override
  List<EngineDialectDescriptor> dialectDescriptors() => kTestDialectDescriptors;

  /// Web sources per chat id (B2).
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
  Future<List<String>> getProviderApiKeys(String providerId) async {
    final prov = _providers.where((p) => p.id == providerId).firstOrNull;
    if (prov == null || !prov.hasApiKey) return const <String>[];
    return const <String>['sk-test-primary-key'];
  }

  @override
  Future<EngineModelCatalogInfo?> lookupModelCatalogInfo(
    String modelId,
  ) async => const EngineModelCatalogInfo(
    contextWindow: 1048576,
    maxOutputTokens: 65536,
    inputPerMtokMicros: 300000,
    outputPerMtokMicros: 2500000,
    cachedInputPerMtokMicros: 75000,
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
  Future<String> exportAllThreadsJson() async =>
      '{"format_version":1,"threads":[]}';

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
  Future<void> stopLiveVoiceSession(String sessionId) async {}

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
