import 'dart:async';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import '../platform/vault_key_host.dart';
import 'api.dart' as frb;
import 'api/harness.dart' as frb;
import 'api/story.dart' as frb;
import 'engine_models.dart';
import 'engine_story_models.dart';
import 'frb_generated.dart';

export 'engine_models.dart';
export 'engine_story_models.dart';

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
  Future<EngineThread> createThread(
    String title,
    String mode, {
    String? topic,
    String? assistantId,
  });
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
  Future<EngineUpdateCheck> checkForUpdates({String? feedUrlOverride});
  Future<String> stageUpdate(EngineUpdateCheck check);
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

  /// Records the user's approval of one exact call; returns a one-use permit id.
  Future<String> approveToolCall({
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
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
  Future<EngineNode> compactThread({
    required String threadId,
    int keepRecentTurns = 4,
    String? customSummary,
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
  Future<List<EngineLocalServer>> discoverLocalServers();
  Future<EngineMcpDiscoveryReport> discoverMcpServer(
    EngineMcpServerConfig server,
  );
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
  Stream<BistreEvent> subscribeEvents();
  Future<void> shutdown();
}

/// Production FFI gateway backed by `flutter_rust_bridge 2.13` Native Assets.
class FrbBistreEngineGateway implements BistreEngineGateway {
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
  }) async => _mapThread(
    await frb.createThread(
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
      _mapSettings(
        await frb.saveSettings(
          settings: frb.FfiAppSettings(
            theme: settings.theme,
            layoutMode: settings.layoutMode,
            locale: settings.locale,
            trustPreset: settings.trustPreset,
            walletDailyCeilingMicros: settings.walletDailyCeilingMicros,
            walletLocalFirst: settings.walletLocalFirst,
            providerStatelessDefault: settings.providerStatelessDefault,
            fontScaleBps: settings.fontScaleBps,
            fontSizePx: settings.fontSizePx,
            lineHeightBps: settings.lineHeightBps,
            readingWidthPx: settings.readingWidthPx,
            proseFontFamily: settings.proseFontFamily,
            proseFontPath: settings.proseFontPath,
            monoFontFamily: settings.monoFontFamily,
            monoFontPath: settings.monoFontPath,
            accentPreset: settings.accentPreset,
            customAccentHex: settings.customAccentHex,
            sidebarOpen: settings.sidebarOpen,
            sendOnEnter: settings.sendOnEnter,
            reduceMotionOverride: settings.reduceMotionOverride,
            showTokenMetrics: settings.showTokenMetrics,
            activeProviderId: settings.activeProviderId,
            activeModelId: settings.activeModelId,
            otaFeedUrl: settings.otaFeedUrl,
            otaChannel: settings.otaChannel,
            otaAutoCheck: settings.otaAutoCheck,
            windowBoundsJson: settings.windowBoundsJson,
            customShortcutsJson: settings.customShortcutsJson,
            keepAwakeWhileRunning: settings.keepAwakeWhileRunning,
            windowsKeepAwakeOnBattery: settings.windowsKeepAwakeOnBattery,
            daemonKeepAliveWhenActive: settings.daemonKeepAliveWhenActive,
            unattendedPolicy: settings.unattendedPolicy,
            retryWatchdogMaxWaitSecs: settings.retryWatchdogMaxWaitSecs,
            reasoningEffort: settings.reasoningEffort,
            termuxBridgeEnabled: settings.termuxBridgeEnabled,
            codeWrapMode: settings.codeWrapMode,
          ),
        ),
      );

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
    final raw = await frb.listCheckpointsJson(threadId: threadId, limit: limit);
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) return const <EngineCheckpoint>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineCheckpoint.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EngineNode> compactThread({
    required String threadId,
    int keepRecentTurns = 4,
    String? customSummary,
  }) async => _mapNode(
    await frb.compactThread(
      threadId: threadId,
      keepRecentTurns: keepRecentTurns,
      customSummary: customSummary,
    ),
  );

  @override
  Future<void> undoCompaction({
    required String threadId,
    required String compactionNodeId,
  }) => frb.undoCompaction(
    threadId: threadId,
    compactionNodeId: compactionNodeId,
  );

  @override
  Future<String?> setContextStartPin({
    required String threadId,
    String? nodeId,
  }) => frb.setContextStartPin(threadId: threadId, nodeId: nodeId);

  @override
  Future<String?> getContextStartPin(String threadId) =>
      frb.getContextStartPin(threadId: threadId);

  @override
  Future<List<EngineLocalServer>> discoverLocalServers() async {
    final raw = await frb.discoverLocalServersJson();
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) return const <EngineLocalServer>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineLocalServer.fromJson)
        .toList(growable: false);
  }

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
    final raw = await frb.listMemoryEntriesJson(scope: scope);
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) return const <EngineMemoryEntry>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineMemoryEntry.fromJson)
        .toList(growable: false);
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
    final raw = await frb.upsertMemoryEntryJson(
      id: id,
      scope: scope,
      scopeId: scopeId,
      key: key,
      content: content,
      pinned: pinned,
    );
    return EngineMemoryEntry.fromJson(jsonDecode(raw) as Map<String, Object?>);
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
  Future<List<EngineCronJob>> listCronJobs() async {
    final raw = await frb.listCronJobsJson();
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) return const <EngineCronJob>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineCronJob.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EngineCronJob> upsertCronJob(EngineCronJob job) async {
    final raw = await frb.upsertCronJobJson(jobJson: jsonEncode(job.toJson()));
    return EngineCronJob.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<void> deleteCronJob(String jobId) => frb.deleteCronJob(jobId: jobId);

  @override
  Future<List<EngineCharacterCard>> listCharacterCards() async {
    final decoded = jsonDecode(await frb.listCharacterCardsJson());
    if (decoded is! List<Object?>) return const <EngineCharacterCard>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineCharacterCard.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EngineCharacterCard> upsertCharacterCard(
    EngineCharacterCard card,
  ) async {
    final raw = await frb.upsertCharacterCardJson(
      cardJson: jsonEncode(card.toJson()),
    );
    return EngineCharacterCard.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  @override
  Future<void> deleteCharacterCard(String cardId) =>
      frb.deleteCharacterCard(cardId: cardId);

  @override
  Future<EngineCharacterCard> importCharacterCardFile(String filePath) async {
    final raw = await frb.importCharacterCardFileJson(filePath: filePath);
    return EngineCharacterCard.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  @override
  Future<String> exportCharacterCardCcv3(String cardId) =>
      frb.exportCharacterCardCcv3(cardId: cardId);

  @override
  Future<List<EngineUserPersona>> listUserPersonas() async {
    final decoded = jsonDecode(await frb.listUserPersonasJson());
    if (decoded is! List<Object?>) return const <EngineUserPersona>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineUserPersona.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EngineUserPersona> upsertUserPersona(EngineUserPersona persona) async {
    final raw = await frb.upsertUserPersonaJson(
      personaJson: jsonEncode(persona.toJson()),
    );
    return EngineUserPersona.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<List<EngineStoryEntry>> listStoryEntries({String? bookId}) async {
    final decoded = jsonDecode(await frb.listStoryEntriesJson(bookId: bookId));
    if (decoded is! List<Object?>) return const <EngineStoryEntry>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStoryEntry.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EngineStoryEntry> upsertStoryEntry(EngineStoryEntry entry) async {
    final raw = await frb.upsertStoryEntryJson(
      entryJson: jsonEncode(entry.toJson()),
    );
    return EngineStoryEntry.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<void> deleteStoryEntry(String entryId) =>
      frb.deleteStoryEntry(entryId: entryId);

  @override
  Future<List<EngineStoryProgression>> listStoryProgressions({
    String? entryId,
  }) async {
    final decoded = jsonDecode(
      await frb.listStoryProgressionsJson(entryId: entryId),
    );
    if (decoded is! List<Object?>) return const <EngineStoryProgression>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStoryProgression.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EngineStoryProgression> addStoryProgression(
    EngineStoryProgression progression,
  ) async {
    final raw = await frb.addStoryProgressionJson(
      progJson: jsonEncode(progression.toJson()),
    );
    return EngineStoryProgression.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  @override
  Future<List<EngineStoryChapter>> listStoryChapters(String threadId) async {
    final decoded = jsonDecode(
      await frb.listStoryChaptersJson(threadId: threadId),
    );
    if (decoded is! List<Object?>) return const <EngineStoryChapter>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStoryChapter.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EngineStoryChapter> upsertStoryChapter(
    EngineStoryChapter chapter,
  ) async {
    final raw = await frb.upsertStoryChapterJson(
      chapterJson: jsonEncode(chapter.toJson()),
    );
    return EngineStoryChapter.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<List<EngineStoryScene>> listStoryScenes(String chapterId) async {
    final decoded = jsonDecode(
      await frb.listStoryScenesJson(chapterId: chapterId),
    );
    if (decoded is! List<Object?>) return const <EngineStoryScene>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStoryScene.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EngineStoryScene> upsertStoryScene(EngineStoryScene scene) async {
    final raw = await frb.upsertStorySceneJson(
      sceneJson: jsonEncode(scene.toJson()),
    );
    return EngineStoryScene.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<EngineStoryThreadState> loadStoryThreadState(String threadId) async {
    final raw = await frb.loadStoryThreadStateJson(threadId: threadId);
    return EngineStoryThreadState.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  @override
  Future<EngineStoryThreadState> saveStoryThreadState(
    EngineStoryThreadState state,
  ) async {
    final raw = await frb.saveStoryThreadStateJson(
      stateJson: jsonEncode(state.toJson()),
    );
    return EngineStoryThreadState.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  @override
  Future<List<EngineRegexRule>> listRegexRules() async {
    final decoded = jsonDecode(await frb.listRegexRulesJson());
    if (decoded is! List<Object?>) return const <EngineRegexRule>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineRegexRule.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EngineRegexRule> upsertRegexRule(EngineRegexRule rule) async {
    final raw = await frb.upsertRegexRuleJson(
      ruleJson: jsonEncode(rule.toJson()),
    );
    return EngineRegexRule.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Future<List<EngineStorySnapshot>> listStorySnapshots({
    required String entityType,
    required String entityId,
    int limit = 10,
  }) async {
    final decoded = jsonDecode(
      await frb.listStorySnapshotsJson(
        entityType: entityType,
        entityId: entityId,
        limit: limit,
      ),
    );
    if (decoded is! List<Object?>) return const <EngineStorySnapshot>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStorySnapshot.fromJson)
        .toList(growable: false);
  }

  @override
  Future<EnginePromptReport> inspectStoryPrompt({
    required String threadId,
    String? activeSceneBeats,
  }) async {
    final raw = await frb.inspectStoryPromptJson(
      threadId: threadId,
      activeSceneBeats: activeSceneBeats,
    );
    return EnginePromptReport.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  @override
  Stream<BistreEvent> subscribeEvents() => frb.subscribeEvents().map(_mapEvent);

  @override
  Future<void> shutdown() => frb.shutdownRuntime();

  static EngineHealth _mapHealth(frb.FfiHealthSnapshot h) => EngineHealth(
    coreVersion: h.coreVersion,
    schemaVersion: h.schemaVersion,
    walModeActive: h.walModeActive,
    threadCount: h.threadCount.toInt(),
    nodeCount: h.nodeCount.toInt(),
    activeRuns: h.activeRuns,
    statusKey: h.statusKey,
  );

  static EngineStorageStats _mapStorageStats(frb.FfiStorageStats s) =>
      EngineStorageStats(
        dataDir: s.dataDir,
        dbSizeBytes: s.dbSizeBytes.toInt(),
        coreVersion: s.coreVersion,
        schemaVersion: s.schemaVersion,
        walModeActive: s.walModeActive,
        threadCount: s.threadCount.toInt(),
        nodeCount: s.nodeCount.toInt(),
        activeRuns: s.activeRuns,
      );

  static EngineUpdateCheck _mapUpdateCheck(frb.FfiUpdateCheckResult u) =>
      EngineUpdateCheck(
        currentVersion: u.currentVersion,
        latestVersion: u.latestVersion,
        updateAvailable: u.updateAvailable,
        track: u.track,
        ownershipMode: u.ownershipMode,
        signatureVerified: u.signatureVerified,
        activeRunsBlocking: u.activeRunsBlocking,
        releaseNotes: u.releaseNotes,
        downloadUrl: u.downloadUrl,
        sha256Hex: u.sha256Hex,
        downloadSizeBytes: u.downloadSizeBytes.toInt(),
        checkedAtMs: u.checkedAtMs.toInt(),
      );

  static EngineProvider _mapProvider(frb.FfiProviderProfile p) =>
      EngineProvider(
        id: p.id,
        name: p.name,
        dialect: p.dialect,
        baseUrl: p.baseUrl,
        defaultModel: p.defaultModel,
        keyHint: p.keyHint,
        hasApiKey: p.hasApiKey,
        isEnabled: p.isEnabled,
        isBuiltin: p.isBuiltin,
        useServerStateCache: p.useServerStateCache,
        iconSlug: p.iconSlug,
        customIconPath: p.customIconPath,
        createdAtMs: p.createdAtMs.toInt(),
        updatedAtMs: p.updatedAtMs.toInt(),
      );

  static EngineAssistant _mapAssistant(frb.FfiAssistantRecord a) =>
      EngineAssistant(
        id: a.id,
        name: a.name,
        roleSubtitle: a.roleSubtitle,
        systemPrompt: a.systemPrompt,
        defaultMode: a.defaultMode,
        badgeCode: a.badgeCode,
        iconSlug: a.iconSlug,
        defaultProviderId: a.defaultProviderId,
        defaultModelId: a.defaultModelId,
        temperatureMilli: a.temperatureMilli,
        maxOutputTokens: a.maxOutputTokens,
        topPMilli: a.topPMilli,
        isBuiltin: a.isBuiltin,
        createdAtMs: a.createdAtMs.toInt(),
      );

  static EngineSettings _mapSettings(frb.FfiAppSettings s) => EngineSettings(
    theme: s.theme,
    layoutMode: s.layoutMode,
    locale: s.locale,
    trustPreset: s.trustPreset,
    walletDailyCeilingMicros: s.walletDailyCeilingMicros?.toInt(),
    walletLocalFirst: s.walletLocalFirst,
    providerStatelessDefault: s.providerStatelessDefault,
    fontScaleBps: s.fontScaleBps,
    fontSizePx: s.fontSizePx,
    lineHeightBps: s.lineHeightBps,
    readingWidthPx: s.readingWidthPx,
    proseFontFamily: s.proseFontFamily,
    proseFontPath: s.proseFontPath,
    monoFontFamily: s.monoFontFamily,
    monoFontPath: s.monoFontPath,
    accentPreset: s.accentPreset,
    customAccentHex: s.customAccentHex,
    sidebarOpen: s.sidebarOpen,
    sendOnEnter: s.sendOnEnter,
    reduceMotionOverride: s.reduceMotionOverride,
    showTokenMetrics: s.showTokenMetrics,
    activeProviderId: s.activeProviderId,
    activeModelId: s.activeModelId,
    otaFeedUrl: s.otaFeedUrl,
    otaChannel: s.otaChannel,
    otaAutoCheck: s.otaAutoCheck,
    windowBoundsJson: s.windowBoundsJson,
    customShortcutsJson: s.customShortcutsJson,
    keepAwakeWhileRunning: s.keepAwakeWhileRunning,
    windowsKeepAwakeOnBattery: s.windowsKeepAwakeOnBattery,
    daemonKeepAliveWhenActive: s.daemonKeepAliveWhenActive,
    unattendedPolicy: s.unattendedPolicy,
    retryWatchdogMaxWaitSecs: s.retryWatchdogMaxWaitSecs,
    reasoningEffort: s.reasoningEffort,
    termuxBridgeEnabled: s.termuxBridgeEnabled,
    codeWrapMode: s.codeWrapMode,
  );

  static EngineAgentRun _mapAgentRun(frb.FfiAgentRunRecord r) => EngineAgentRun(
    id: r.id,
    threadId: r.threadId,
    parentRunId: r.parentRunId,
    rootNodeId: r.rootNodeId,
    mode: r.mode,
    status: r.status,
    stepIndex: r.stepIndex,
    maxSteps: r.maxSteps,
    unattendedPolicy: r.unattendedPolicy,
    worktreePath: r.worktreePath,
    retryAfterMs: r.retryAfterMs?.toInt(),
    lastHeartbeatMs: r.lastHeartbeatMs.toInt(),
    costMicros: r.costMicros.toInt(),
    errorKey: r.errorKey,
    createdAtMs: r.createdAtMs.toInt(),
    updatedAtMs: r.updatedAtMs.toInt(),
  );

  static EngineSteeringMessage _mapSteering(frb.FfiSteeringMessage m) =>
      EngineSteeringMessage(
        id: m.id,
        threadId: m.threadId,
        runId: m.runId,
        content: m.content,
        status: m.status,
        createdAtMs: m.createdAtMs.toInt(),
      );

  static EnginePowerGuardStatus _mapPowerStatus(frb.FfiPowerGuardStatus p) =>
      EnginePowerGuardStatus(
        platform: p.platform,
        keepAwakeActive: p.keepAwakeActive,
        batteryOverrideActive: p.batteryOverrideActive,
        daemonConnected: p.daemonConnected,
        onAcPower: p.onAcPower,
        sleepPreventedReason: p.sleepPreventedReason,
        androidFgsActive: p.androidFgsActive,
        androidBatteryUnrestricted: p.androidBatteryUnrestricted,
        activeRunCount: p.activeRunCount,
      );

  static EngineThread _mapThread(frb.FfiThreadSummary t) => EngineThread(
    id: t.id,
    workspaceId: t.workspaceId,
    title: t.title,
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
    createdAtMs: t.createdAtMs.toInt(),
    updatedAtMs: t.updatedAtMs.toInt(),
  );

  static EngineNode _mapNode(frb.FfiNodeRecord n) => EngineNode(
    id: n.id,
    threadId: n.threadId,
    parentId: n.parentId,
    role: n.role,
    content: n.content,
    providerMetaJson: n.providerMetaJson,
    createdAtMs: n.createdAtMs.toInt(),
  );

  static EngineSearchHit _mapHit(frb.FfiSearchHit h) => EngineSearchHit(
    nodeId: h.nodeId,
    threadId: h.threadId,
    role: h.role,
    snippet: h.snippet,
    createdAtMs: h.createdAtMs.toInt(),
  );

  static BistreEvent _mapEvent(frb.FfiEngineEvent e) => switch (e.kind) {
    'run_started' => RunStartedEvent(
      threadId: e.threadId ?? '',
      nodeId: e.nodeId ?? '',
    ),
    'delta_batch' => DeltaBatchEvent(
      threadId: e.threadId ?? '',
      nodeId: e.nodeId ?? '',
      textDelta: e.textDelta ?? '',
    ),
    'thinking_delta' => ThinkingDeltaEvent(
      threadId: e.threadId ?? '',
      nodeId: e.nodeId ?? '',
      delta: e.textDelta ?? '',
    ),
    'run_finished' => RunFinishedEvent(
      threadId: e.threadId ?? '',
      nodeId: e.nodeId ?? '',
      cancelled: e.cancelled ?? false,
    ),
    'run_state_changed' => RunStateChangedEvent(
      threadId: e.threadId ?? '',
      payloadJson: e.payloadJson ?? '{}',
    ),
    'run_step_updated' => RunStepUpdatedEvent(
      payloadJson: e.payloadJson ?? '{}',
    ),
    'steering_queue_changed' => SteeringQueueChangedEvent(
      threadId: e.threadId ?? '',
      pendingCount: _parsePendingCount(e.payloadJson),
    ),
    'power_status_changed' => PowerStatusChangedEvent(
      payloadJson: e.payloadJson ?? '{}',
    ),
    'node_committed' when e.node != null => NodeCommittedEvent(
      _mapNode(e.node!),
    ),
    'draft_saved' => DraftSavedEvent(
      threadId: e.threadId ?? '',
      updatedAtMs: e.updatedAtMs?.toInt() ?? 0,
    ),
    'locale_pack_verified' => LocalePackVerifiedEvent(
      packId: e.packId ?? '',
      semver: e.semver ?? '',
    ),
    'events_lagged' => const EventsLaggedEvent(),
    'diagnostic_raised' => DiagnosticRaisedEvent(
      key: e.diagnosticKey ?? 'diag.internal.error',
      detailCode: e.detailCode,
    ),
    _ => UnknownEngineEvent(e.kind),
  };

  static int _parsePendingCount(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return (decoded['pending_count'] as num?)?.toInt() ?? 0;
      }
    } on FormatException {
      // Ignore malformed count payload.
    }
    return 0;
  }
}
