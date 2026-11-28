part of 'bistre_engine.dart';

// FRB DTO -> app model mapping for [FrbBistreEngineGateway], one function per record type.

EngineHealth _mapHealth(frb.FfiHealthSnapshot h) => EngineHealth(
  coreVersion: h.coreVersion,
  schemaVersion: h.schemaVersion,
  walModeActive: h.walModeActive,
  threadCount: h.threadCount.toInt(),
  nodeCount: h.nodeCount.toInt(),
  activeRuns: h.activeRuns,
  statusKey: h.statusKey,
);

EngineStorageStats _mapStorageStats(frb.FfiStorageStats s) =>
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

EngineUpdateCheck _mapUpdateCheck(frb.FfiUpdateCheckResult u) =>
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

EngineProvider _mapProvider(frb.FfiProviderProfile p) => EngineProvider(
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
  isLocal: p.isLocal,
);

EngineAssistant _mapAssistant(frb.FfiAssistantRecord a) => EngineAssistant(
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

EngineSettings _mapSettings(frb.FfiAppSettings s) => EngineSettings(
  theme: s.theme,
  layoutMode: s.layoutMode,
  locale: s.locale,
  trustPreset: s.trustPreset,
  walletDailyCeilingMicros: s.walletDailyCeilingMicros?.toInt(),
  walletLocalFirst: s.walletLocalFirst,
  providerStatelessDefault: s.providerStatelessDefault,
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
  pricingAutoRefresh: s.pricingAutoRefresh,
  userDisplayName: s.userDisplayName,
  autoCompactAtPercent: s.autoCompactAtPercent,
);

EngineAgentRun _mapAgentRun(frb.FfiAgentRunRecord r) => EngineAgentRun(
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

EngineSteeringMessage _mapSteering(frb.FfiSteeringMessage m) =>
    EngineSteeringMessage(
      id: m.id,
      threadId: m.threadId,
      runId: m.runId,
      content: m.content,
      status: m.status,
      createdAtMs: m.createdAtMs.toInt(),
    );

EnginePowerGuardStatus _mapPowerStatus(frb.FfiPowerGuardStatus p) =>
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

EngineThread _mapThread(frb.FfiThreadSummary t) => EngineThread(
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

EngineNode _mapNode(frb.FfiNodeRecord n) => EngineNode(
  id: n.id,
  threadId: n.threadId,
  parentId: n.parentId,
  role: n.role,
  content: n.content,
  providerMetaJson: n.providerMetaJson,
  createdAtMs: n.createdAtMs.toInt(),
  attachments: <EngineNodeAttachment>[
    for (final a in n.attachments)
      EngineNodeAttachment(
        name: a.name,
        mimeType: a.mimeType,
        sizeBytes: a.sizeBytes.toInt(),
        blobRelPath: a.blobRelPath,
      ),
  ],
);

EngineSearchHit _mapHit(frb.FfiSearchHit h) => EngineSearchHit(
  nodeId: h.nodeId,
  threadId: h.threadId,
  role: h.role,
  snippet: h.snippet,
  createdAtMs: h.createdAtMs.toInt(),
);

BistreEvent _mapEvent(frb.FfiEngineEvent e) => switch (e.kind) {
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
  'run_step_updated' => RunStepUpdatedEvent(payloadJson: e.payloadJson ?? '{}'),
  'steering_queue_changed' => SteeringQueueChangedEvent(
    threadId: e.threadId ?? '',
    pendingCount: _parsePendingCount(e.payloadJson),
  ),
  'power_status_changed' => PowerStatusChangedEvent(
    payloadJson: e.payloadJson ?? '{}',
  ),
  'node_committed' when e.node != null => NodeCommittedEvent(_mapNode(e.node!)),
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
  'live_voice_state' => _mapLiveVoiceState(e.payloadJson),
  'live_voice_transcript' => _mapLiveVoiceTranscript(e.payloadJson),
  'live_voice_audio' => _mapLiveVoiceAudio(e.payloadJson),
  'host_action_requested' => _mapHostActionRequested(e.payloadJson),
  'tool_approval_requested' => _mapToolApprovalRequested(e.payloadJson),
  'tool_execution_updated' => _mapToolExecutionUpdated(e.payloadJson),
  _ => UnknownEngineEvent(e.kind),
};

BistreEvent _mapToolApprovalRequested(String? raw) {
  final m = _decodeMap(raw);
  return ToolApprovalRequestedEvent(
    threadId: m['thread_id'] as String? ?? '',
    runId: m['run_id'] as String? ?? '',
    callId: m['call_id'] as String? ?? '',
    toolName: m['tool_name'] as String? ?? '',
    argumentsJson: m['arguments_json'] as String? ?? '{}',
    riskTier: m['risk_tier'] as String? ?? 'tier2_external_side_effect',
  );
}

BistreEvent _mapToolExecutionUpdated(String? raw) {
  final m = _decodeMap(raw);
  return ToolExecutionUpdatedEvent(
    threadId: m['thread_id'] as String? ?? '',
    runId: m['run_id'] as String? ?? '',
    callId: m['call_id'] as String? ?? '',
    toolName: m['tool_name'] as String? ?? '',
    riskTier: m['risk_tier'] as String? ?? 'tier0_read_only',
    status: m['status'] as String? ?? 'running',
    summary: m['summary'] as String? ?? '',
    outputText: m['output_text'] as String? ?? '',
    diffText: m['diff_text'] as String?,
    checkpointId: m['checkpoint_id'] as String?,
    durationMs: (m['duration_ms'] as num?)?.toInt() ?? 0,
  );
}

BistreEvent _mapLiveVoiceState(String? raw) {
  final m = _decodeMap(raw);
  return LiveVoiceStateEvent(
    sessionId: m['session_id'] as String? ?? '',
    state: m['state'] as String? ?? 'closed',
    detail: m['detail'] as String?,
  );
}

BistreEvent _mapLiveVoiceTranscript(String? raw) {
  final m = _decodeMap(raw);
  return LiveVoiceTranscriptEvent(
    sessionId: m['session_id'] as String? ?? '',
    role: m['role'] as String? ?? 'assistant',
    text: m['text'] as String? ?? '',
    isFinal: m['is_final'] as bool? ?? false,
  );
}

BistreEvent _mapLiveVoiceAudio(String? raw) {
  final m = _decodeMap(raw);
  return LiveVoiceAudioEvent(
    sessionId: m['session_id'] as String? ?? '',
    wavBase64: m['wav_base64'] as String? ?? '',
  );
}

BistreEvent _mapHostActionRequested(String? raw) {
  final m = _decodeMap(raw);
  return HostActionRequestedEvent(
    requestId: m['request_id'] as String? ?? '',
    threadId: m['thread_id'] as String? ?? '',
    runId: m['run_id'] as String? ?? '',
    actionJson: m['action_json'] as String? ?? '{}',
  );
}

Map<String, Object?> _decodeMap(String? raw) {
  if (raw == null || raw.isEmpty) return const <String, Object?>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // Ignore malformed payload.
  }
  return const <String, Object?>{};
}

int _parsePendingCount(String? raw) {
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

EngineMemoryEntry _mapMemoryEntry(frb.FfiMemoryEntry m) => EngineMemoryEntry(
  id: m.id,
  scope: m.scope,
  scopeId: m.scopeId,
  key: m.key,
  content: m.content,
  pinned: m.pinned,
  updatedAtMs: m.updatedAtMs,
);

EngineCronJob _mapCronJob(frb.FfiCronJob j) => EngineCronJob(
  id: j.id,
  name: j.name,
  workspaceId: j.workspaceId,
  assistantId: j.assistantId,
  scheduleExpr: j.scheduleExpr,
  prompt: j.prompt,
  mode: j.mode,
  unattendedPolicy: j.unattendedPolicy,
  useWorktree: j.useWorktree,
  enabled: j.enabled,
  nextRunMs: j.nextRunMs,
  lastRunId: j.lastRunId,
  lastStatus: j.lastStatus,
);

EngineWorkspaceHooksStatus _mapWorkspaceHooks(frb.FfiWorkspaceHooksStatus s) =>
    EngineWorkspaceHooksStatus(
      hooks: s.hooks
          .map(
            (h) => EngineWorkspaceHook(
              event: h.event,
              command: h.command,
              toolFilter: h.toolFilter,
            ),
          )
          .toList(growable: false),
      digest: s.digest,
      approved: s.approved,
    );

/// App settings -> FFI DTO for `saveSettings`.
frb.FfiAppSettings _toFfiSettings(EngineSettings settings) =>
    frb.FfiAppSettings(
      theme: settings.theme,
      layoutMode: settings.layoutMode,
      locale: settings.locale,
      trustPreset: settings.trustPreset,
      walletDailyCeilingMicros: settings.walletDailyCeilingMicros,
      walletLocalFirst: settings.walletLocalFirst,
      providerStatelessDefault: settings.providerStatelessDefault,
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
      pricingAutoRefresh: settings.pricingAutoRefresh,
      userDisplayName: settings.userDisplayName,
      autoCompactAtPercent: settings.autoCompactAtPercent,
    );

EngineGroundingSource _mapGroundingSource(frb.FfiGroundingSource r) =>
    EngineGroundingSource(
      nodeId: r.nodeId,
      url: r.url,
      title: r.title,
      citedText: r.citedText,
    );

int _clampInt(BigInt n) =>
    n > BigInt.from(0x7fffffffffffffff) ? 0x7fffffffffffffff : n.toInt();

EngineContextBreakdown _mapContextBreakdown(frb.FfiContextBreakdown b) =>
    EngineContextBreakdown(
      categories: b.categories
          .map(
            (c) => EngineContextCategory(
              kind: c.kind,
              tokens: _clampInt(c.tokens),
              count: c.count,
              sent: c.sent,
            ),
          )
          .toList(growable: false),
      totalSent: _clampInt(b.totalSent),
      limitTokens: b.limitTokens == null ? null : _clampInt(b.limitTokens!),
      reserveTokens: _clampInt(b.reserveTokens),
      mcp: b.mcp
          .map(
            (srv) => EngineMcpServerUsage(
              serverId: srv.serverId,
              label: srv.label,
              tools: srv.tools
                  .map(
                    (t) => EngineMcpToolUsage(
                      name: t.name,
                      tokens: _clampInt(t.tokens),
                      deferred: t.deferred_,
                    ),
                  )
                  .toList(growable: false),
            ),
          )
          .toList(growable: false),
      mcpTruncated: b.mcpTruncated,
    );

mixin _FrbUtilityAndVoiceMixin {
  Future<EngineNode> compactThread({
    required String threadId,
    int keepRecentTurns = 4,
    String? customSummary,
    String? instructions,
  }) async => _mapNode(
    await frb.compactThread(
      threadId: threadId,
      keepRecentTurns: keepRecentTurns,
      customSummary: customSummary,
      instructions: instructions,
    ),
  );

  Future<EngineNode> rewriteCompactionSummary({
    required String threadId,
    required String nodeId,
    required String content,
  }) async => _mapNode(
    await frb.rewriteCompactionSummary(
      threadId: threadId,
      nodeId: nodeId,
      content: content,
    ),
  );

  Future<void> undoCompaction({
    required String threadId,
    required String compactionNodeId,
  }) => frb.undoCompaction(
    threadId: threadId,
    compactionNodeId: compactionNodeId,
  );

  Future<List<int>> synthesizeSpeech({
    required String providerId,
    required String modelId,
    required String text,
    String? voice,
  }) => frb.synthesizeSpeech(
    providerId: providerId,
    modelId: modelId,
    text: text,
    voice: voice,
  );

  Future<String> startLiveVoiceSession({
    required String providerId,
    required String modelId,
    required String voice,
    required String systemPrompt,
  }) => frb.startLiveVoiceSession(
    providerId: providerId,
    modelId: modelId,
    voice: voice,
    systemPrompt: systemPrompt,
  );

  Future<void> sendLiveVoicePcmChunk({
    required String sessionId,
    required String pcmBase64,
  }) => frb.sendLiveVoicePcmChunk(sessionId: sessionId, pcmBase64: pcmBase64);

  Future<void> sendLiveVoiceText({
    required String sessionId,
    required String text,
  }) => frb.sendLiveVoiceText(sessionId: sessionId, text: text);

  Future<void> stopLiveVoiceSession(String sessionId) =>
      frb.stopLiveVoiceSession(sessionId: sessionId);

  Future<EngineThread> generateThreadTitle(String threadId) async =>
      _mapThread(await frb.generateThreadTitle(threadId: threadId));

  Future<EngineNode> translateNode({
    required String threadId,
    required String nodeId,
    String? targetLanguage,
  }) async => _mapNode(
    await frb.translateNode(
      threadId: threadId,
      nodeId: nodeId,
      targetLanguage: targetLanguage,
    ),
  );

  Future<String> reinstallUpdate(EngineUpdateCheck check) =>
      frb.reinstallUpdate(
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

  Future<bool> respondHostAction({
    required String requestId,
    required bool ok,
    required String outputText,
    String? imageBase64,
  }) => frb.respondHostAction(
    requestId: requestId,
    ok: ok,
    outputText: outputText,
    imageBase64: imageBase64,
  );

  Future<EngineInspectedRequest> inspectNextRequest({
    required String threadId,
    required String draft,
  }) async {
    final req = await frb.inspectNextRequest(threadId: threadId, draft: draft);
    return EngineInspectedRequest(
      method: req.method,
      url: req.url,
      dialect: req.dialect,
      model: req.model,
      headers: req.headers,
      bodyJson: req.bodyJson,
    );
  }

  Future<String> exportProviderShareCode({
    required String providerId,
    bool includeApiKey = false,
  }) => frb.exportProviderShareCode(
    providerId: providerId,
    includeApiKey: includeApiKey,
  );

  Future<EngineProvider> importProviderShareCode(String code) async =>
      _mapProvider(await frb.importProviderShareCode(code: code));

  Future<List<EngineNode>> listNodesWindow({
    required String threadId,
    String? beforeNodeId,
    required int limit,
  }) async => (await frb.listNodesWindow(
    threadId: threadId,
    beforeNodeId: beforeNodeId,
    limit: limit,
  )).map(_mapNode).toList(growable: false);

  Future<int> getThreadSpendMicros(String threadId) async =>
      (await frb.getThreadSpendMicros(threadId: threadId)).toInt();

  Future<int> threadHistoryRev(String threadId) async =>
      (await frb.threadHistoryRev(threadId: threadId)).toInt();

  Future<List<EnginePurposeUsage>> getWalletUsageByPurpose(
    DateTime since,
  ) async {
    final rows = await frb.getWalletUsageByPurpose(
      sinceUnixMs: since.millisecondsSinceEpoch,
    );
    return [
      for (final r in rows)
        EnginePurposeUsage(
          // Core names only known purposes; anything else is a broken bridge, not data.
          purpose: EngineSpendPurpose.values.byName(r.purpose),
          requests: r.requests.toInt(),
          costMicros: r.costMicros,
        ),
    ];
  }

  Future<EngineMcpRegistryPage> searchMcpRegistry(
    String query, {
    String? cursor,
  }) async => EngineMcpRegistryPage.fromJson(
    jsonDecode(await frb.searchMcpRegistryJson(query: query, cursor: cursor))
        as Map<String, Object?>,
  );
}
