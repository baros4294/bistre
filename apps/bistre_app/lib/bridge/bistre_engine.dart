import 'dart:async';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import '../platform/vault_key_host.dart';
import 'api.dart' as frb;
import 'api/chat.dart' as frb;
import 'api/harness.dart' as frb;
import 'api/library.dart' as frb;
import 'api/media.dart' as frb;
import 'api/projects.dart' as frb;
import 'api/providers.dart' as frb;
import 'api/runs.dart' as frb;
import 'api/story.dart' as frb;
import 'engine_models.dart';
import 'engine_story_models.dart';
import 'frb_generated.dart';

export 'engine_models.dart';
export 'engine_story_models.dart';

part 'bistre_engine_chat.dart';
part 'bistre_engine_gateway.dart';
part 'bistre_engine_library.dart';
part 'bistre_engine_mapping.dart';
part 'bistre_engine_story.dart';

/// Production FFI gateway backed by `flutter_rust_bridge 2.13` Native Assets.
class FrbBistreEngineGateway
    with
        _FrbUtilityAndVoiceMixin,
        _FrbStoryMixin,
        _FrbChatActionsMixin,
        _FrbLibraryMixin
    implements BistreEngineGateway {
  /// [externalLibrary] overrides the default loader (tests that run outside a
  /// bundled app, where the native library is not on the loader path).
  FrbBistreEngineGateway({ExternalLibrary? externalLibrary})
    : _externalLibrary = externalLibrary;

  final ExternalLibrary? _externalLibrary;
  bool _libInitialized = false;

  Future<void> _ensureLib() async {
    if (_libInitialized) return;
    await BistreRustLib.init(externalLibrary: _externalLibrary);
    _libInitialized = true;
  }

  @override
  Future<EngineHealth> init(String dataDir) async {
    await _ensureLib();
    final vaultKey = await obtainAndroidVaultKey();
    try {
      final h = await frb.initRuntime(dataDir: dataDir, vaultKey: vaultKey);
      return _mapHealth(h);
    } finally {
      // Best-effort wipe of the Dart copy; the Rust core keeps its own zeroizing copy.
      vaultKey?.fillRange(0, vaultKey.length, 0);
    }
  }

  @override
  Future<EngineHealth> getHealth() async => _mapHealth(await frb.getHealth());

  @override
  Future<EngineStorageStats> getStorageStats() async =>
      _mapStorageStats(await frb.getStorageStats());

  @override
  Future<List<EngineProvider>> listProviders() async =>
      (await frb.listProviders()).map(_mapProvider).toList(growable: false);

  @override
  Future<EngineProvider> createProvider({
    required String name,
    required String dialect,
    required String baseUrl,
    required String defaultModel,
    required String iconSlug,
    required String customIconPath,
    String? apiKey,
  }) async => _mapProvider(
    await frb.createProvider(
      name: name,
      dialect: dialect,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      iconSlug: iconSlug,
      customIconPath: customIconPath,
      apiKey: apiKey,
    ),
  );

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
  }) async => _mapProvider(
    await frb.updateProvider(
      providerId: providerId,
      name: name,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      isEnabled: isEnabled,
      useServerStateCache: useServerStateCache,
      iconSlug: iconSlug,
      customIconPath: customIconPath,
    ),
  );

  @override
  Future<EngineProvider> setProviderApiKey({
    required String providerId,
    required String apiKey,
  }) async => _mapProvider(
    await frb.setProviderApiKey(providerId: providerId, apiKey: apiKey),
  );

  @override
  Future<EngineProvider> clearProviderApiKey(String providerId) async =>
      _mapProvider(await frb.clearProviderApiKey(providerId: providerId));

  @override
  Future<EngineProvider> createCustomProvider({
    required String name,
    required String baseUrl,
    required String defaultModel,
    String? apiKey,
  }) async => _mapProvider(
    await frb.createCustomProvider(
      name: name,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      apiKey: apiKey,
    ),
  );

  @override
  Future<void> deleteProvider(String providerId) =>
      frb.deleteProvider(providerId: providerId);

  @override
  Future<List<EngineProviderModel>> fetchProviderModels(
    String providerId,
  ) async =>
      (await frb.fetchProviderModels(providerId: providerId))
          .map((m) => EngineProviderModel(id: m.id, displayName: m.displayName))
          .toList(growable: false);

  @override
  Future<List<EngineAssistant>> listAssistants() async =>
      (await frb.listAssistants()).map(_mapAssistant).toList(growable: false);

  @override
  Future<EngineAssistant> createAssistant({
    required String name,
    required String roleSubtitle,
    required String systemPrompt,
    required String defaultMode,
    required String badgeCode,
  }) async => _mapAssistant(
    await frb.createAssistant(
      name: name,
      roleSubtitle: roleSubtitle,
      systemPrompt: systemPrompt,
      defaultMode: defaultMode,
      badgeCode: badgeCode,
    ),
  );

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
  }) async => _mapAssistant(
    await frb.updateAssistant(
      assistantId: assistantId,
      name: name,
      roleSubtitle: roleSubtitle,
      systemPrompt: systemPrompt,
      defaultMode: defaultMode,
      badgeCode: badgeCode,
      iconSlug: iconSlug,
      defaultProviderId: defaultProviderId,
      defaultModelId: defaultModelId,
      temperatureMilli: temperatureMilli,
      clearTemperature: clearTemperature,
      maxOutputTokens: maxOutputTokens,
      clearMaxOutputTokens: clearMaxOutputTokens,
      topPMilli: topPMilli,
      clearTopP: clearTopP,
    ),
  );

  @override
  Future<void> deleteAssistant(String assistantId) =>
      frb.deleteAssistant(assistantId: assistantId);

  @override
  Future<EngineThread> createThread(
    String title,
    String mode, {
    String? topic,
    String? assistantId,
    String? projectId,
  }) async => _mapThread(
    await frb.createThread(
      projectId: projectId,
      title: title,
      mode: mode,
      topic: topic,
      assistantId: assistantId,
    ),
  );

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
  }) async => _mapThread(
    await frb.updateThread(
      threadId: threadId,
      title: title,
      isPinned: isPinned,
      topic: topic,
      mode: mode,
      assistantId: assistantId,
      providerIdOverride: providerIdOverride,
      clearProviderOverride: clearProviderOverride,
      modelIdOverride: modelIdOverride,
      clearModelOverride: clearModelOverride,
      systemPromptOverride: systemPromptOverride,
      clearSystemPromptOverride: clearSystemPromptOverride,
      temperatureMilli: temperatureMilli,
      clearTemperature: clearTemperature,
      maxOutputTokens: maxOutputTokens,
      clearMaxOutputTokens: clearMaxOutputTokens,
      topPMilli: topPMilli,
      clearTopP: clearTopP,
    ),
  );

  @override
  Future<void> deleteThread(String threadId) =>
      frb.deleteThread(threadId: threadId);

  @override
  Future<List<EngineThread>> listThreads() async =>
      (await frb.listThreads()).map(_mapThread).toList(growable: false);

  @override
  Future<EngineNode> appendNode({
    required String threadId,
    String? parentId,
    required String role,
    required String content,
  }) async => _mapNode(
    await frb.appendNode(
      threadId: threadId,
      parentId: parentId,
      role: role,
      content: content,
    ),
  );

  @override
  Future<EngineNode> sendAndStreamReply({
    required String threadId,
    String? parentId,
    required String userContent,
  }) async => _mapNode(
    await frb.sendAndStreamReply(
      threadId: threadId,
      parentId: parentId,
      userContent: userContent,
    ),
  );

  @override
  Future<String> regenerateReply({
    required String threadId,
    required String userNodeId,
  }) => frb.regenerateReply(threadId: threadId, userNodeId: userNodeId);

  @override
  Future<EngineNode> editUserNodeAndStream({
    required String threadId,
    required String nodeId,
    required String newContent,
  }) async => _mapNode(
    await frb.editUserNodeAndStream(
      threadId: threadId,
      nodeId: nodeId,
      newContent: newContent,
    ),
  );

  @override
  Future<void> deleteNode({required String threadId, required String nodeId}) =>
      frb.deleteNode(threadId: threadId, nodeId: nodeId);

  @override
  Future<EngineThread> forkThread({
    required String threadId,
    required String nodeId,
  }) async =>
      _mapThread(await frb.forkThread(threadId: threadId, nodeId: nodeId));

  @override
  Future<void> deleteFromNode({
    required String threadId,
    required String nodeId,
  }) => frb.deleteFromNode(threadId: threadId, nodeId: nodeId);

  @override
  Future<void> clearThreadMessages(String threadId) =>
      frb.clearThreadMessages(threadId: threadId);

  @override
  Future<String> exportThread({
    required String threadId,
    required String format,
  }) => frb.exportThread(threadId: threadId, format: format);

  @override
  Future<void> backupDatabase(String destPath) =>
      frb.backupDatabase(destPath: destPath);

  @override
  Future<bool> cancelActiveRun(String threadId) =>
      frb.cancelActiveRun(threadId: threadId);

  @override
  Future<bool> retryRunNow(String threadId) =>
      frb.retryRunNow(threadId: threadId);

  @override
  Future<List<EngineNode>> listNodes(String threadId) async =>
      (await frb.listNodes(threadId: threadId))
          .map(_mapNode)
          .toList(growable: false);

  @override
  Future<void> saveDraft(String threadId, String text) async {
    await frb.saveDraft(threadId: threadId, text: text);
  }

  @override
  Future<String?> loadDraft(String threadId) async =>
      (await frb.loadDraft(threadId: threadId))?.text;

  @override
  Future<EngineSettings> loadSettings() async =>
      _mapSettings(await frb.loadSettings());

  @override
  Future<EngineSettings> saveSettings(EngineSettings settings) async =>
      _mapSettings(await frb.saveSettings(settings: _toFfiSettings(settings)));

  @override
  Future<int> getWalletSpendMicros() async =>
      (await frb.getWalletSpendMicros()).toInt();

  @override
  Future<int> getWalletDailySpendMicros() async =>
      (await frb.getWalletDailySpendMicros()).toInt();

  @override
  Future<EngineUpdateCheck> checkForUpdates({String? feedUrlOverride}) async =>
      _mapUpdateCheck(
        await frb.checkForUpdates(feedUrlOverride: feedUrlOverride),
      );

  @override
  Future<String> stageUpdate(EngineUpdateCheck check) => frb.stageUpdate(
    check: frb.FfiUpdateCheckResult(
      currentVersion: check.currentVersion,
      latestVersion: check.latestVersion,
      updateAvailable: check.updateAvailable,
      track: check.track,
      ownershipMode: check.ownershipMode,
      signatureVerified: check.signatureVerified,
      activeRunsBlocking: check.activeRunsBlocking,
      releaseNotes: check.releaseNotes,
      downloadUrl: check.downloadUrl,
      sha256Hex: check.sha256Hex,
      downloadSizeBytes: BigInt.from(check.downloadSizeBytes),
      checkedAtMs: check.checkedAtMs,
    ),
  );

  @override
  Future<List<EngineSearchHit>> searchNodes(
    String query, {
    String? threadId,
    int limit = 20,
  }) async => (await frb.searchNodes(
    query: query,
    threadId: threadId,
    limit: limit,
  )).map(_mapHit).toList(growable: false);

  @override
  Future<String> verifyDataPack({
    required String publicKeyB64,
    required List<int> manifestBytes,
    required String manifestSigText,
    required List<int> packPayload,
  }) => frb.verifyDataPack(
    publicKeyB64: publicKeyB64,
    manifestBytes: manifestBytes,
    manifestSigText: manifestSigText,
    packPayload: packPayload,
  );

  @override
  Future<List<EngineAgentRun>> listAgentRuns({
    String? threadId,
    bool onlyActive = false,
    int limit = 50,
  }) async => (await frb.listAgentRuns(
    threadId: threadId,
    onlyActive: onlyActive,
    limit: limit,
  )).map(_mapAgentRun).toList(growable: false);

  @override
  Future<EngineSteeringMessage> enqueueSteering({
    required String threadId,
    required String content,
  }) async => _mapSteering(
    await frb.enqueueSteering(threadId: threadId, content: content),
  );

  @override
  Future<List<EngineSteeringMessage>> listPendingSteering(
    String threadId,
  ) async =>
      (await frb.listPendingSteering(threadId: threadId))
          .map(_mapSteering)
          .toList(growable: false);

  @override
  Future<void> deleteSteering(String steeringId) =>
      frb.deleteSteering(steeringId: steeringId);

  @override
  Future<EnginePowerGuardStatus> powerGuardStatus() async =>
      _mapPowerStatus(await frb.powerGuardStatus());

  @override
  Future<int> notifyPowerEvent(String eventKind, {bool? onAc}) =>
      frb.notifyPowerEvent(eventKind: eventKind, onAc: onAc);

  @override
  Future<EnginePowerGuardStatus> setAndroidPowerState({
    required bool fgsActive,
    required bool batteryUnrestricted,
  }) async => _mapPowerStatus(
    await frb.setAndroidPowerState(
      fgsActive: fgsActive,
      batteryUnrestricted: batteryUnrestricted,
    ),
  );

  @override
  Future<EngineAgentRun> resolveIndeterminateRun({
    required String runId,
    required bool confirmCompleted,
  }) async => _mapAgentRun(
    await frb.resolveIndeterminateRun(
      runId: runId,
      confirmCompleted: confirmCompleted,
    ),
  );

  @override
  Future<void> refreshPrices() => frb.refreshPrices();

  @override
  Future<int?> modelContextTokens(String providerId, String model) =>
      frb.modelContextTokens(providerId: providerId, model: model);

  @override
  Future<EngineContextBreakdown> contextBreakdown(
    String threadId,
    String leafNodeId, {
    String draft = '',
  }) async => _mapContextBreakdown(
    await frb.contextBreakdown(
      threadId: threadId,
      leafNodeId: leafNodeId,
      draft: draft,
    ),
  );

  @override
  Future<String> approveToolCall({
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
  }) => frb.approveToolCall(
    threadId: threadId,
    toolName: toolName,
    argumentsJson: jsonEncode(arguments),
  );

  @override
  Future<void> allowUnpricedOnce(String threadId) =>
      frb.allowUnpricedOnce(threadId: threadId);

  @override
  Future<void> allowUnpricedMediaOnce() => frb.allowUnpricedMediaOnce();

  @override
  Future<EngineWorkspaceHooksStatus?> workspaceHooksStatus(
    String workspaceRoot,
  ) async {
    final s = await frb.workspaceHooksStatus(workspaceRoot: workspaceRoot);
    return s == null ? null : _mapWorkspaceHooks(s);
  }

  @override
  Future<void> approveWorkspaceHooks(String workspaceRoot, String digest) =>
      frb.approveWorkspaceHooks(workspaceRoot: workspaceRoot, digest: digest);

  @override
  List<EngineDialectDescriptor> dialectDescriptors() => frb
      .providerDialectDescriptors()
      .map(
        (d) => EngineDialectDescriptor(
          id: d.id,
          defaultBaseUrl: d.defaultBaseUrl,
          endpointPath: d.endpointPath,
          requiresApiKey: d.requiresApiKey,
        ),
      )
      .toList(growable: false);

  @override
  String defaultTitlePrompt() => frb.defaultTitlePrompt();

  @override
  EngineResolvedEndpoint resolveProviderEndpoint(
    String dialect,
    String baseUrl,
  ) {
    final r = frb.resolveProviderEndpoint(dialect: dialect, baseUrl: baseUrl);
    return EngineResolvedEndpoint(chatUrl: r.chatUrl, modelsUrl: r.modelsUrl);
  }

  @override
  Future<List<EngineGroundingSource>> listThreadGrounding(
    String threadId,
  ) async {
    final rows = await frb.listThreadGrounding(threadId: threadId);
    return rows.map(_mapGroundingSource).toList(growable: false);
  }

  @override
  Future<void> saveProviderOverrides({
    required String providerId,
    required String headersJson,
    required String bodyJson,
  }) => frb.saveProviderOverrides(
    providerId: providerId,
    headersJson: headersJson,
    bodyJson: bodyJson,
  );

  @override
  Future<List<BistreEvent>> pendingToolApprovals() async =>
      (await frb.pendingToolApprovals()).map(_mapEvent).toList();

  @override
  Future<bool> respondToolApproval({
    required String threadId,
    required String runId,
    required String callId,
    required String decision,
  }) => frb.respondToolApproval(
    threadId: threadId,
    runId: runId,
    callId: callId,
    decision: decision,
  );

  @override
  Future<EngineToolOutput> executeWorkspaceTool({
    required String workspaceRoot,
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
    String? permitId,
  }) async {
    final raw = await frb.executeWorkspaceToolJson(
      workspaceRoot: workspaceRoot,
      threadId: threadId,
      toolName: toolName,
      argumentsJson: jsonEncode(arguments),
      permitId: permitId,
    );
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    return EngineToolOutput.fromJson(decoded);
  }

  @override
  Future<String> rewindCheckpoint({
    required String workspaceRoot,
    required String checkpointId,
  }) => frb.rewindCheckpoint(
    workspaceRoot: workspaceRoot,
    checkpointId: checkpointId,
  );

  @override
  Future<List<EngineCheckpoint>> listCheckpoints(
    String threadId, {
    int limit = 50,
  }) async {
    final cps = await frb.listCheckpoints(threadId: threadId, limit: limit);
    return cps
        .map(
          (c) => EngineCheckpoint(
            id: c.id,
            threadId: c.threadId,
            filePath: c.filePath,
            preHashBlake3: c.beforeBlake3,
            postHashBlake3: c.afterBlake3,
            createdAtMs: c.createdAtMs,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<String?> setContextStartPin({
    required String threadId,
    String? nodeId,
  }) => frb.setContextStartPin(threadId: threadId, nodeId: nodeId);

  @override
  Future<String?> getContextStartPin(String threadId) =>
      frb.getContextStartPin(threadId: threadId);

  @override
  Future<EngineMcpDiscoveryReport> discoverMcpServer(
    EngineMcpServerConfig server,
  ) async {
    final raw = await frb.discoverMcpServerJson(
      serverConfigJson: jsonEncode(server.toJson()),
    );
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    return EngineMcpDiscoveryReport.fromJson(decoded);
  }

  @override
  Future<String?> getKvMeta(String key) => frb.getKvMeta(key: key);

  @override
  Future<void> setKvMeta(String key, String value) =>
      frb.setKvMeta(key: key, value: value);

  @override
  Future<List<EngineMemoryEntry>> listMemoryEntries({String? scope}) async {
    final items = await frb.listMemoryEntries(scope: scope);
    return items.map(_mapMemoryEntry).toList(growable: false);
  }

  @override
  Future<EngineMemoryEntry> upsertMemoryEntry({
    String? id,
    required String scope,
    required String scopeId,
    required String key,
    required String content,
    bool pinned = false,
  }) async {
    final saved = await frb.upsertMemoryEntry(
      id: id,
      scope: scope,
      scopeId: scopeId,
      key: key,
      content: content,
      pinned: pinned,
    );
    return _mapMemoryEntry(saved);
  }

  @override
  Future<void> deleteMemoryEntry(String entryId) =>
      frb.deleteMemoryEntry(entryId: entryId);

  @override
  Future<List<EngineSkillIndex>> discoverWorkspaceSkills(
    String workspaceRoot,
  ) async {
    final raw = await frb.discoverWorkspaceSkillsJson(
      workspaceRoot: workspaceRoot,
    );
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) return const <EngineSkillIndex>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineSkillIndex.fromJson)
        .toList(growable: false);
  }

  @override
  Future<String> loadSkillBody(String workspaceRoot, String skillPath) =>
      frb.loadSkillBody(workspaceRoot: workspaceRoot, skillPath: skillPath);

  @override
  Future<List<EngineCronJob>> listCronJobs() async =>
      (await frb.listCronJobs()).map(_mapCronJob).toList(growable: false);

  @override
  Future<EngineCronJob> upsertCronJob(EngineCronJob job) async => _mapCronJob(
    await frb.upsertCronJob(
      job: frb.FfiCronJob(
        id: job.id,
        name: job.name,
        workspaceId: job.workspaceId,
        assistantId: job.assistantId,
        scheduleExpr: job.scheduleExpr,
        prompt: job.prompt,
        mode: job.mode,
        unattendedPolicy: job.unattendedPolicy,
        useWorktree: job.useWorktree,
        enabled: job.enabled,
        nextRunMs: job.nextRunMs,
        lastRunId: job.lastRunId,
        lastStatus: job.lastStatus,
      ),
    ),
  );

  @override
  Future<void> deleteCronJob(String jobId) => frb.deleteCronJob(jobId: jobId);

  @override
  Future<List<String>> getProviderApiKeys(String providerId) =>
      frb.getProviderApiKeys(providerId: providerId);

  @override
  Future<EngineModelCatalogInfo?> lookupModelCatalogInfo(
    String providerId,
    String modelId,
  ) async {
    final info = await frb.lookupModelCatalogInfo(
      providerId: providerId,
      modelId: modelId,
    );
    if (info == null) return null;
    return EngineModelCatalogInfo(
      contextWindow: info.contextWindow,
      maxOutputTokens: info.maxOutputTokens,
      inputPerMtokMicros: info.inputPerMtokMicros,
      outputPerMtokMicros: info.outputPerMtokMicros,
      cachedInputPerMtokMicros: info.cachedInputPerMtokMicros,
      cacheWritePerMtokMicros: info.cacheWritePerMtokMicros,
      cacheWrite1hPerMtokMicros: info.cacheWrite1HPerMtokMicros,
      reasoning: info.reasoning,
      effortLevels: info.effortLevels,
      writesText: info.writesText,
      aspectRatios: info.aspectRatios,
      resolutions: info.resolutions,
      durationsS: info.durationsS,
    );
  }

  @override
  Future<EngineNode> sendAndStreamReplyWithAttachments({
    required String threadId,
    String? parentId,
    required String userContent,
    required List<EngineAttachmentInput> attachments,
  }) async => _mapNode(
    await frb.sendAndStreamReplyWithAttachments(
      threadId: threadId,
      parentId: parentId,
      userContent: userContent,
      attachments: [
        for (final a in attachments)
          frb.FfiAttachmentInput(
            name: a.name,
            mimeType: a.mimeType,
            localPath: a.localPath,
          ),
      ],
    ),
  );

  @override
  Future<EngineNode> steerActiveRunNow({
    required String threadId,
    required String content,
  }) async => _mapNode(
    await frb.steerActiveRunNow(threadId: threadId, content: content),
  );

  @override
  @override
  Future<int> importThreadsJson(String rawJson) =>
      frb.importThreadsJson(rawJson: rawJson);

  @override
  Future<String> exportSettingsJson() => frb.exportSettingsJson();

  @override
  Future<EngineSettings> importSettingsJson(
    String rawJson, {
    bool allowLoosening = false,
  }) async => _mapSettings(
    await frb.importSettingsJson(
      rawJson: rawJson,
      allowLoosening: allowLoosening,
    ),
  );

  @override
  Future<List<EngineStorageFileEntry>> listStorageFiles() async {
    final items = await frb.listStorageFiles();
    return [
      for (final f in items)
        EngineStorageFileEntry(
          relPath: f.relPath,
          category: f.category,
          sizeBytes: f.sizeBytes.toInt(),
          modifiedMs: f.modifiedMs,
          deletable: f.deletable,
        ),
    ];
  }

  @override
  Future<bool> deleteStorageFile(String relPath) =>
      frb.deleteStorageFile(relPath: relPath);

  @override
  Future<int> cleanUnusedStorageFiles() async =>
      (await frb.cleanUnusedStorageFiles()).toInt();

  @override
  Stream<BistreEvent> subscribeEvents() => frb.subscribeEvents().map(_mapEvent);

  @override
  Future<void> shutdown() => frb.shutdownRuntime();
}
