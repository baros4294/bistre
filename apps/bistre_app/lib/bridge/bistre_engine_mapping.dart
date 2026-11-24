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
  pricingAutoRefresh: s.pricingAutoRefresh,
  userDisplayName: s.userDisplayName,
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
  _ => UnknownEngineEvent(e.kind),
};

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
