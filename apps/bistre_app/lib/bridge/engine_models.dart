import 'dart:convert';

/// Parsed token usage, thinking trace, & model attribution metadata stored on assistant DAG nodes.
class NodeUsageMeta {
  const NodeUsageMeta({
    this.providerId = '',
    this.providerName = '',
    this.iconSlug = '',
    this.modelId = '',
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.cacheCreationInputTokens = 0,
    this.reasoningTokens = 0,
    this.firstTokenMs = 0,
    this.costMicros = 0,
    this.costKnown = true,
    this.cancelled = false,
    this.thinkingText = '',
    this.thinkingDurationMs = 0,
    this.elapsedMs = 0,
    this.requestId = '',
    this.compactedCount = 0,
  });

  final String providerId;
  final String providerName;
  final String iconSlug;
  final String modelId;
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int cacheCreationInputTokens;
  final int reasoningTokens;
  final int firstTokenMs;
  final int costMicros;

  /// `false` when the model has no published price (`cost_known` in Rust): the reply counts as
  /// `$0` toward the spending limit and the UI shows the quiet breakdown popup instead of a price.
  final bool costKnown;
  final bool cancelled;
  final String thinkingText;
  final int thinkingDurationMs;
  final int elapsedMs;
  final String requestId;
  final int compactedCount;

  bool get hasTokens => inputTokens > 0 || outputTokens > 0;
  bool get hasThinking => thinkingText.trim().isNotEmpty;
  double? get tokensPerSecond => elapsedMs > 0 && outputTokens > 0
      ? outputTokens / (elapsedMs / 1000.0)
      : null;

  static NodeUsageMeta? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      return NodeUsageMeta(
        providerId: decoded['provider_id'] as String? ?? '',
        providerName: decoded['provider_name'] as String? ?? '',
        iconSlug: decoded['icon_slug'] as String? ?? '',
        modelId: decoded['model_id'] as String? ?? '',
        inputTokens: (decoded['input_tokens'] as num?)?.toInt() ?? 0,
        outputTokens: (decoded['output_tokens'] as num?)?.toInt() ?? 0,
        cachedInputTokens:
            (decoded['cached_input_tokens'] as num?)?.toInt() ?? 0,
        cacheCreationInputTokens:
            (decoded['cache_creation_input_tokens'] as num?)?.toInt() ?? 0,
        reasoningTokens: (decoded['reasoning_tokens'] as num?)?.toInt() ?? 0,
        firstTokenMs: (decoded['first_token_ms'] as num?)?.toInt() ?? 0,
        costMicros: (decoded['cost_micros'] as num?)?.toInt() ?? 0,
        costKnown: decoded['cost_known'] as bool? ?? true,
        cancelled: decoded['cancelled'] as bool? ?? false,
        thinkingText: decoded['thinking_text'] as String? ?? '',
        thinkingDurationMs:
            (decoded['thinking_duration_ms'] as num?)?.toInt() ?? 0,
        elapsedMs: (decoded['elapsed_ms'] as num?)?.toInt() ?? 0,
        requestId: decoded['request_id'] as String? ?? '',
        compactedCount: (decoded['compacted_count'] as num?)?.toInt() ?? 0,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Immutable health snapshot returned from Rust `bistre-core`.
class EngineHealth {
  const EngineHealth({
    required this.coreVersion,
    required this.schemaVersion,
    required this.walModeActive,
    required this.threadCount,
    required this.nodeCount,
    required this.activeRuns,
    required this.statusKey,
  });

  final String coreVersion;
  final int schemaVersion;
  final bool walModeActive;
  final int threadCount;
  final int nodeCount;
  final int activeRuns;
  final String statusKey;
}

/// Detailed local storage and WAL runtime diagnostics.
class EngineStorageStats {
  const EngineStorageStats({
    required this.dataDir,
    required this.dbSizeBytes,
    required this.coreVersion,
    required this.schemaVersion,
    required this.walModeActive,
    required this.threadCount,
    required this.nodeCount,
    required this.activeRuns,
  });

  final String dataDir;
  final int dbSizeBytes;
  final String coreVersion;
  final int schemaVersion;
  final bool walModeActive;
  final int threadCount;
  final int nodeCount;
  final int activeRuns;
}

/// Zero-telemetry signed Track-A / Track-B OTA check result.
class EngineUpdateCheck {
  const EngineUpdateCheck({
    required this.currentVersion,
    required this.latestVersion,
    required this.updateAvailable,
    required this.track,
    required this.ownershipMode,
    required this.signatureVerified,
    required this.activeRunsBlocking,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.sha256Hex,
    required this.downloadSizeBytes,
    required this.checkedAtMs,
  });

  final String currentVersion;
  final String latestVersion;
  final bool updateAvailable;
  final String track;
  final String ownershipMode;
  final bool signatureVerified;
  final bool activeRunsBlocking;
  final String releaseNotes;
  final String downloadUrl;
  final String sha256Hex;
  final int downloadSizeBytes;
  final int checkedAtMs;
}

/// Immutable provider profile mirrored from Rust SQLite + `SecretVault` key presence.
/// Raw API keys are never transmitted back to Flutter.
class EngineProvider {
  const EngineProvider({
    required this.id,
    required this.name,
    required this.dialect,
    required this.baseUrl,
    required this.defaultModel,
    required this.keyHint,
    required this.hasApiKey,
    required this.isEnabled,
    required this.isBuiltin,
    required this.useServerStateCache,
    this.iconSlug = '',
    this.customIconPath = '',
    required this.createdAtMs,
    required this.updatedAtMs,
    this.isLocal = false,
  });

  final String id;
  final String name;
  final String dialect;
  final String baseUrl;

  /// The model runs on this device (core decides by parsed host); the picker badges it.
  final bool isLocal;
  final String defaultModel;
  final String keyHint;
  final bool hasApiKey;
  final bool isEnabled;
  final bool isBuiltin;
  final bool useServerStateCache;
  final String iconSlug;
  final String customIconPath;
  final int createdAtMs;
  final int updatedAtMs;

  bool get isReady => isEnabled && (dialect == 'custom_openai' || hasApiKey);
}

/// Live model discovered from a provider's `/models` endpoint.
class EngineProviderModel {
  const EngineProviderModel({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

/// Immutable assistant persona mirrored from Rust SQLite.
class EngineAssistant {
  const EngineAssistant({
    required this.id,
    required this.name,
    required this.roleSubtitle,
    required this.systemPrompt,
    required this.defaultMode,
    required this.badgeCode,
    this.iconSlug = '',
    this.defaultProviderId = '',
    this.defaultModelId = '',
    this.temperatureMilli,
    this.maxOutputTokens,
    this.topPMilli,
    required this.isBuiltin,
    required this.createdAtMs,
  });

  final String id;
  final String name;
  final String roleSubtitle;
  final String systemPrompt;
  final String defaultMode;
  final String badgeCode;
  final String iconSlug;
  final String defaultProviderId;
  final String defaultModelId;
  final int? temperatureMilli;
  final int? maxOutputTokens;
  final int? topPMilli;
  final bool isBuiltin;
  final int createdAtMs;
}

/// Immutable user preferences, typography, personalization, OTA, and Wallet Shield settings.
class EngineSettings {
  const EngineSettings({
    this.theme = 'system',
    this.layoutMode = 'bubbles',
    this.locale = 'en',
    this.trustPreset = 'guided_craft',
    this.walletDailyCeilingMicros = 5000000,
    this.walletLocalFirst = true,
    this.providerStatelessDefault = true,
    this.fontScaleBps = 10000,
    this.fontSizePx = 15,
    this.lineHeightBps = 16000,
    this.readingWidthPx = 760,
    this.proseFontFamily = '',
    this.proseFontPath = '',
    this.monoFontFamily = '',
    this.monoFontPath = '',
    this.accentPreset = 'brass',
    this.customAccentHex = '',
    this.sidebarOpen = true,
    this.sendOnEnter = true,
    this.reduceMotionOverride = false,
    this.showTokenMetrics = true,
    this.activeProviderId = '',
    this.activeModelId = '',
    this.otaFeedUrl = 'https://github.com/baros4294/bistre/releases/latest/download/manifest.json',
    this.otaChannel = 'stable',
    this.otaAutoCheck = true,
    this.windowBoundsJson = '',
    this.customShortcutsJson = '',
    this.keepAwakeWhileRunning = true,
    this.windowsKeepAwakeOnBattery = false,
    this.daemonKeepAliveWhenActive = true,
    this.unattendedPolicy = 'pause_and_notify',
    this.retryWatchdogMaxWaitSecs = 1800,
    this.reasoningEffort = 'default',
    this.termuxBridgeEnabled = false,
    this.codeWrapMode = 'auto',
    this.pricingAutoRefresh = true,
    this.userDisplayName = '',
  });

  final String theme;
  final String layoutMode;
  final String locale;
  final String trustPreset;

  /// `null` explicitly represents Unlimited spending (no daily cap).
  final int? walletDailyCeilingMicros;
  final bool walletLocalFirst;
  final bool providerStatelessDefault;
  final int fontScaleBps;
  final int fontSizePx;
  final int lineHeightBps;
  final int readingWidthPx;
  final String proseFontFamily;
  final String proseFontPath;
  final String monoFontFamily;
  final String monoFontPath;
  final String accentPreset;
  final String customAccentHex;
  final bool sidebarOpen;
  final bool sendOnEnter;
  final bool reduceMotionOverride;
  final bool showTokenMetrics;
  final String activeProviderId;
  final String activeModelId;
  final String otaFeedUrl;
  final String otaChannel;
  final bool otaAutoCheck;
  final String windowBoundsJson;
  final String customShortcutsJson;
  final bool keepAwakeWhileRunning;
  final bool windowsKeepAwakeOnBattery;
  final bool daemonKeepAliveWhenActive;
  final String unattendedPolicy;
  final int retryWatchdogMaxWaitSecs;
  final String reasoningEffort;
  final bool termuxBridgeEnabled;

  /// Code-fence wrapping: `auto` (soft-wrap below 640 px), `on`, or `off`.
  final String codeWrapMode;

  /// Refresh public model prices automatically (at most once a day).
  final bool pricingAutoRefresh;

  /// Your name: shown on your messages and told to the model in chats without a persona.
  final String userDisplayName;

  bool get isWalletUnlimited => walletDailyCeilingMicros == null;

  EngineSettings copyWith({
    String? theme,
    String? layoutMode,
    String? locale,
    String? trustPreset,
    int? walletDailyCeilingMicros,
    bool setWalletUnlimited = false,
    bool? walletLocalFirst,
    bool? providerStatelessDefault,
    int? fontScaleBps,
    int? fontSizePx,
    int? lineHeightBps,
    int? readingWidthPx,
    String? proseFontFamily,
    String? proseFontPath,
    String? monoFontFamily,
    String? monoFontPath,
    String? accentPreset,
    String? customAccentHex,
    bool? sidebarOpen,
    bool? sendOnEnter,
    bool? reduceMotionOverride,
    bool? showTokenMetrics,
    String? activeProviderId,
    String? activeModelId,
    String? otaFeedUrl,
    String? otaChannel,
    bool? otaAutoCheck,
    String? windowBoundsJson,
    String? customShortcutsJson,
    bool? keepAwakeWhileRunning,
    bool? windowsKeepAwakeOnBattery,
    bool? daemonKeepAliveWhenActive,
    String? unattendedPolicy,
    int? retryWatchdogMaxWaitSecs,
    String? reasoningEffort,
    bool? termuxBridgeEnabled,
    String? codeWrapMode,
    bool? pricingAutoRefresh,
    String? userDisplayName,
  }) {
    return EngineSettings(
      theme: theme ?? this.theme,
      layoutMode: layoutMode ?? this.layoutMode,
      locale: locale ?? this.locale,
      trustPreset: trustPreset ?? this.trustPreset,
      walletDailyCeilingMicros: setWalletUnlimited
          ? null
          : (walletDailyCeilingMicros ?? this.walletDailyCeilingMicros),
      walletLocalFirst: walletLocalFirst ?? this.walletLocalFirst,
      providerStatelessDefault:
          providerStatelessDefault ?? this.providerStatelessDefault,
      fontScaleBps: fontScaleBps ?? this.fontScaleBps,
      fontSizePx: fontSizePx ?? this.fontSizePx,
      lineHeightBps: lineHeightBps ?? this.lineHeightBps,
      readingWidthPx: readingWidthPx ?? this.readingWidthPx,
      proseFontFamily: proseFontFamily ?? this.proseFontFamily,
      proseFontPath: proseFontPath ?? this.proseFontPath,
      monoFontFamily: monoFontFamily ?? this.monoFontFamily,
      monoFontPath: monoFontPath ?? this.monoFontPath,
      accentPreset: accentPreset ?? this.accentPreset,
      customAccentHex: customAccentHex ?? this.customAccentHex,
      sidebarOpen: sidebarOpen ?? this.sidebarOpen,
      sendOnEnter: sendOnEnter ?? this.sendOnEnter,
      reduceMotionOverride: reduceMotionOverride ?? this.reduceMotionOverride,
      showTokenMetrics: showTokenMetrics ?? this.showTokenMetrics,
      activeProviderId: activeProviderId ?? this.activeProviderId,
      activeModelId: activeModelId ?? this.activeModelId,
      otaFeedUrl: otaFeedUrl ?? this.otaFeedUrl,
      otaChannel: otaChannel ?? this.otaChannel,
      otaAutoCheck: otaAutoCheck ?? this.otaAutoCheck,
      windowBoundsJson: windowBoundsJson ?? this.windowBoundsJson,
      customShortcutsJson: customShortcutsJson ?? this.customShortcutsJson,
      keepAwakeWhileRunning:
          keepAwakeWhileRunning ?? this.keepAwakeWhileRunning,
      windowsKeepAwakeOnBattery:
          windowsKeepAwakeOnBattery ?? this.windowsKeepAwakeOnBattery,
      daemonKeepAliveWhenActive:
          daemonKeepAliveWhenActive ?? this.daemonKeepAliveWhenActive,
      unattendedPolicy: unattendedPolicy ?? this.unattendedPolicy,
      retryWatchdogMaxWaitSecs:
          retryWatchdogMaxWaitSecs ?? this.retryWatchdogMaxWaitSecs,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      termuxBridgeEnabled: termuxBridgeEnabled ?? this.termuxBridgeEnabled,
      codeWrapMode: codeWrapMode ?? this.codeWrapMode,
      pricingAutoRefresh: pricingAutoRefresh ?? this.pricingAutoRefresh,
      userDisplayName: userDisplayName ?? this.userDisplayName,
    );
  }
}

/// Immutable thread summary mirrored from Rust SQLite.
class EngineThread {
  const EngineThread({
    required this.id,
    required this.workspaceId,
    required this.title,
    required this.mode,
    this.topic = 'general',
    this.assistantId = 'default_assistant',
    this.isPinned = false,
    this.activeHeadNodeId,
    this.providerIdOverride,
    this.modelIdOverride,
    this.systemPromptOverride,
    this.temperatureMilli,
    this.maxOutputTokens,
    this.topPMilli,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String workspaceId;
  final String title;
  final String mode;
  final String topic;
  final String assistantId;
  final bool isPinned;
  final String? activeHeadNodeId;
  final String? providerIdOverride;
  final String? modelIdOverride;
  final String? systemPromptOverride;
  final int? temperatureMilli;
  final int? maxOutputTokens;
  final int? topPMilli;
  final int createdAtMs;
  final int updatedAtMs;

  bool get hasAnyOverride =>
      providerIdOverride != null ||
      modelIdOverride != null ||
      systemPromptOverride != null ||
      temperatureMilli != null ||
      maxOutputTokens != null ||
      topPMilli != null;
}

/// Immutable canonical DAG node mirrored from Rust SQLite.
class EngineNode {
  const EngineNode({
    required this.id,
    required this.threadId,
    this.parentId,
    required this.role,
    required this.content,
    this.providerMetaJson,
    required this.createdAtMs,
    this.attachments = const <EngineNodeAttachment>[],
  });

  final String id;
  final String threadId;
  final String? parentId;
  final String role;
  final String content;
  final String? providerMetaJson;
  final int createdAtMs;

  /// Files sent with this message (P1), parsed once by core.
  final List<EngineNodeAttachment> attachments;

  /// Parsed once per node and cached (R39: it was parsed on every access in every build).
  NodeUsageMeta? get usageMeta {
    final cached = _usageCache[this];
    if (cached != null) return cached.meta;
    final meta = NodeUsageMeta.tryParse(providerMetaJson);
    _usageCache[this] = _UsageBox(meta);
    return meta;
  }

  static final Expando<_UsageBox> _usageCache = Expando<_UsageBox>('usageMeta');
}

/// Holds a parsed [NodeUsageMeta] (which may be null) for [EngineNode]'s cache.
class _UsageBox {
  const _UsageBox(this.meta);
  final NodeUsageMeta? meta;
}

/// One file sent with a message (P1); [blobRelPath] is relative to the data directory.
class EngineNodeAttachment {
  const EngineNodeAttachment({
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.blobRelPath,
  });

  final String name;
  final String mimeType;
  final int sizeBytes;
  final String blobRelPath;
}

/// Immutable FTS5 search hit mirrored from Rust SQLite.
class EngineSearchHit {
  const EngineSearchHit({
    required this.nodeId,
    required this.threadId,
    required this.role,
    required this.snippet,
    required this.createdAtMs,
  });

  final String nodeId;
  final String threadId;
  final String role;
  final String snippet;
  final int createdAtMs;
}

/// Durable SQLite-journaled long-horizon agent run mirrored from Rust.
class EngineAgentRun {
  const EngineAgentRun({
    required this.id,
    required this.threadId,
    this.parentRunId,
    this.rootNodeId,
    required this.mode,
    required this.status,
    required this.stepIndex,
    required this.maxSteps,
    required this.unattendedPolicy,
    this.worktreePath,
    this.retryAfterMs,
    required this.lastHeartbeatMs,
    required this.costMicros,
    this.errorKey,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String threadId;
  final String? parentRunId;
  final String? rootNodeId;
  final String mode;
  final String status;
  final int stepIndex;
  final int maxSteps;
  final String unattendedPolicy;
  final String? worktreePath;
  final int? retryAfterMs;
  final int lastHeartbeatMs;
  final int costMicros;
  final String? errorKey;
  final int createdAtMs;
  final int updatedAtMs;

  bool get isActive =>
      status == 'running' ||
      status == 'waiting_approval' ||
      status == 'backoff_wait' ||
      status == 'sleep_paused';

  bool get isIndeterminateHalt => status == 'indeterminate_halt';
}

/// Queued mid-stream user steering message injected cleanly at the next step boundary.
class EngineSteeringMessage {
  const EngineSteeringMessage({
    required this.id,
    required this.threadId,
    this.runId,
    required this.content,
    required this.status,
    required this.createdAtMs,
  });

  final String id;
  final String threadId;
  final String? runId;
  final String content;
  final String status;
  final int createdAtMs;
}

/// Live OS sleep-guard, daemon connection, and Android FGS status snapshot.
class EnginePowerGuardStatus {
  const EnginePowerGuardStatus({
    this.platform = 'windows',
    this.keepAwakeActive = false,
    this.batteryOverrideActive = false,
    this.daemonConnected = false,
    this.onAcPower = true,
    this.sleepPreventedReason = '',
    this.androidFgsActive = false,
    this.androidBatteryUnrestricted = false,
    this.activeRunCount = 0,
  });

  final String platform;
  final bool keepAwakeActive;
  final bool batteryOverrideActive;
  final bool daemonConnected;
  final bool onAcPower;
  final String sleepPreventedReason;
  final bool androidFgsActive;
  final bool androidBatteryUnrestricted;
  final int activeRunCount;
}

/// Exhaustive Dart 3 sealed event hierarchy decoded from flattened FRB DTOs.
sealed class BistreEvent {
  const BistreEvent();
}

final class RunStartedEvent extends BistreEvent {
  const RunStartedEvent({required this.threadId, required this.nodeId});
  final String threadId;
  final String nodeId;
}

final class DeltaBatchEvent extends BistreEvent {
  const DeltaBatchEvent({
    required this.threadId,
    required this.nodeId,
    required this.textDelta,
  });

  final String threadId;
  final String nodeId;
  final String textDelta;
}

final class ThinkingDeltaEvent extends BistreEvent {
  const ThinkingDeltaEvent({
    required this.threadId,
    required this.nodeId,
    required this.delta,
  });

  final String threadId;
  final String nodeId;
  final String delta;
}

final class RunFinishedEvent extends BistreEvent {
  const RunFinishedEvent({
    required this.threadId,
    required this.nodeId,
    required this.cancelled,
  });

  final String threadId;
  final String nodeId;
  final bool cancelled;
}

final class RunStateChangedEvent extends BistreEvent {
  const RunStateChangedEvent({
    required this.threadId,
    required this.payloadJson,
  });
  final String threadId;
  final String payloadJson;
}

final class RunStepUpdatedEvent extends BistreEvent {
  const RunStepUpdatedEvent({required this.payloadJson});
  final String payloadJson;
}

final class SteeringQueueChangedEvent extends BistreEvent {
  const SteeringQueueChangedEvent({
    required this.threadId,
    required this.pendingCount,
  });

  final String threadId;
  final int pendingCount;
}

final class PowerStatusChangedEvent extends BistreEvent {
  const PowerStatusChangedEvent({required this.payloadJson});
  final String payloadJson;
}

final class NodeCommittedEvent extends BistreEvent {
  const NodeCommittedEvent(this.node);
  final EngineNode node;
}

/// The core dropped events because the UI fell behind; reload state from storage.
final class EventsLaggedEvent extends BistreEvent {
  const EventsLaggedEvent();
}

/// An event kind this build does not know (a newer core); ignored, never an error.
final class LiveVoiceStateEvent extends BistreEvent {
  const LiveVoiceStateEvent({
    required this.sessionId,
    required this.state,
    this.detail,
  });

  final String sessionId;
  final String state;
  final String? detail;
}

final class LiveVoiceTranscriptEvent extends BistreEvent {
  const LiveVoiceTranscriptEvent({
    required this.sessionId,
    required this.role,
    required this.text,
    required this.isFinal,
  });

  final String sessionId;
  final String role;
  final String text;
  final bool isFinal;
}

final class LiveVoiceAudioEvent extends BistreEvent {
  const LiveVoiceAudioEvent({required this.sessionId, required this.wavBase64});

  final String sessionId;
  final String wavBase64;
}

final class ToolApprovalRequestedEvent extends BistreEvent {
  const ToolApprovalRequestedEvent({
    required this.threadId,
    required this.runId,
    required this.callId,
    required this.toolName,
    required this.argumentsJson,
    required this.riskTier,
  });

  final String threadId;
  final String runId;
  final String callId;
  final String toolName;
  final String argumentsJson;
  final String riskTier;
}

final class ToolExecutionUpdatedEvent extends BistreEvent {
  const ToolExecutionUpdatedEvent({
    required this.threadId,
    required this.runId,
    required this.callId,
    required this.toolName,
    required this.riskTier,
    required this.status,
    required this.summary,
    required this.outputText,
    this.diffText,
    this.checkpointId,
    this.durationMs = 0,
  });

  final String threadId;
  final String runId;
  final String callId;
  final String toolName;
  final String riskTier;
  final String status;
  final String summary;
  final String outputText;
  final String? diffText;
  final String? checkpointId;
  final int durationMs;
}

final class UnknownEngineEvent extends BistreEvent {
  const UnknownEngineEvent(this.kind);
  final String kind;
}

final class DraftSavedEvent extends BistreEvent {
  const DraftSavedEvent({required this.threadId, required this.updatedAtMs});
  final String threadId;
  final int updatedAtMs;
}

final class DiagnosticRaisedEvent extends BistreEvent {
  const DiagnosticRaisedEvent({required this.key, this.detailCode});
  final String key;
  final String? detailCode;
}

final class LocalePackVerifiedEvent extends BistreEvent {
  const LocalePackVerifiedEvent({required this.packId, required this.semver});
  final String packId;
  final String semver;
}

/// Result of executing a built-in workspace or web tool in Rust `bistre-core`.
class EngineToolOutput {
  const EngineToolOutput({
    required this.toolName,
    required this.riskTier,
    required this.ok,
    required this.summary,
    required this.outputText,
    this.diffText,
    this.checkpointId,
    this.durationMs = 0,
  });

  final String toolName;
  final String riskTier;
  final bool ok;
  final String summary;
  final String outputText;
  final String? diffText;
  final String? checkpointId;
  final int durationMs;

  static EngineToolOutput fromJson(Map<String, Object?> m) => EngineToolOutput(
    toolName: m['tool_name'] as String? ?? '',
    riskTier: m['risk_tier'] as String? ?? 'tier0_read_only',
    ok: m['ok'] as bool? ?? false,
    summary: m['summary'] as String? ?? '',
    outputText: m['output_text'] as String? ?? '',
    diffText: m['diff_text'] as String?,
    checkpointId: m['checkpoint_id'] as String?,
    durationMs: (m['duration_ms'] as num?)?.toInt() ?? 0,
  );
}

/// Pre-image workspace file edit checkpoint persisted in SQLite for 1-click Rewind.
class EngineCheckpoint {
  const EngineCheckpoint({
    required this.id,
    required this.threadId,
    required this.filePath,
    required this.preHashBlake3,
    required this.postHashBlake3,
    required this.createdAtMs,
  });

  final String id;
  final String threadId;
  final String filePath;
  final String preHashBlake3;
  final String postHashBlake3;
  final int createdAtMs;
}

/// Configured MCP server entry (`stdio` or Streamable `http`).
class EngineMcpServerConfig {
  const EngineMcpServerConfig({
    required this.id,
    required this.name,
    required this.transport,
    this.command = '',
    this.args = const <String>[],
    this.url = '',
    this.enabled = true,
  });

  final String id;
  final String name;
  final String transport;
  final String command;
  final List<String> args;
  final String url;
  final bool enabled;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'transport': transport,
    'command': command,
    'args': args,
    'url': url,
    'enabled': enabled,
  };

  static EngineMcpServerConfig fromJson(Map<String, Object?> m) {
    final rawArgs = m['args'];
    return EngineMcpServerConfig(
      id: m['id'] as String? ?? '',
      name: m['name'] as String? ?? '',
      transport: m['transport'] as String? ?? 'http',
      command: m['command'] as String? ?? '',
      args: rawArgs is List<Object?>
          ? rawArgs.whereType<String>().toList(growable: false)
          : const <String>[],
      url: m['url'] as String? ?? '',
      enabled: m['enabled'] as bool? ?? true,
    );
  }
}

/// MCP discovery result detailing negotiated protocol (`2026-07-28` vs `2025-11-25`) and tool names.
class EngineMcpDiscoveryReport {
  const EngineMcpDiscoveryReport({
    required this.negotiatedProtocol,
    this.toolNames = const <String>[],
  });

  final String negotiatedProtocol;
  final List<String> toolNames;

  static EngineMcpDiscoveryReport fromJson(Map<String, Object?> m) {
    final rawTools = m['tools'];
    final names = <String>[];
    if (rawTools is List<Object?>) {
      for (final item in rawTools) {
        if (item is Map<String, Object?> && item['name'] is String) {
          names.add(item['name']! as String);
        }
      }
    }
    return EngineMcpDiscoveryReport(
      negotiatedProtocol: m['negotiated_protocol'] as String? ?? '',
      toolNames: names,
    );
  }
}

/// Persistent cross-chat / workspace memory item backed by SQLite `memory_entries`.
class EngineMemoryEntry {
  const EngineMemoryEntry({
    required this.id,
    required this.scope,
    required this.scopeId,
    required this.key,
    required this.content,
    this.pinned = false,
    this.updatedAtMs = 0,
  });

  final String id;
  final String scope;
  final String scopeId;
  final String key;
  final String content;
  final bool pinned;
  final int updatedAtMs;
}

/// Progressive-disclosure `SKILL.md` frontmatter index entry.
class EngineSkillIndex {
  const EngineSkillIndex({
    required this.name,
    required this.description,
    required this.path,
  });

  final String name;
  final String description;
  final String path;

  static EngineSkillIndex fromJson(Map<String, Object?> m) => EngineSkillIndex(
    name: m['name'] as String? ?? '',
    description: m['description'] as String? ?? '',
    path: m['path'] as String? ?? '',
  );
}

/// Scheduled background cron/timer automation job backed by SQLite `cron_jobs`.
class EngineCronJob {
  const EngineCronJob({
    this.id = '',
    required this.name,
    this.workspaceId = 'default',
    this.assistantId = 'default_assistant',
    required this.scheduleExpr,
    required this.prompt,
    this.mode = 'chat',
    this.unattendedPolicy = 'pause_and_notify',
    this.useWorktree = false,
    this.enabled = true,
    this.nextRunMs = 0,
    this.lastRunId,
    this.lastStatus = 'idle',
  });

  final String id;
  final String name;
  final String workspaceId;
  final String assistantId;
  final String scheduleExpr;
  final String prompt;
  final String mode;
  final String unattendedPolicy;
  final bool useWorktree;
  final bool enabled;
  final int nextRunMs;
  final String? lastRunId;
  final String lastStatus;
}

/// Live catalog metadata returned for a single model (`Fill from catalog`).
class EngineModelCatalogInfo {
  const EngineModelCatalogInfo({
    this.contextWindow,
    this.maxOutputTokens,
    this.inputPerMtokMicros,
    this.outputPerMtokMicros,
    this.cachedInputPerMtokMicros,
    this.reasoning,
  });

  final int? contextWindow;
  final int? maxOutputTokens;
  final int? inputPerMtokMicros;
  final int? outputPerMtokMicros;
  final int? cachedInputPerMtokMicros;
  final bool? reasoning;
}

/// User-selected file attachment passed from Flutter composer into Rust core.
class EngineAttachmentInput {
  const EngineAttachmentInput({
    required this.name,
    required this.mimeType,
    required this.localPath,
  });

  final String name;
  final String mimeType;
  final String localPath;
}

/// File entry reported by the Storage & File Manager inside Bistre's data directory.
class EngineStorageFileEntry {
  const EngineStorageFileEntry({
    required this.relPath,
    required this.category,
    required this.sizeBytes,
    required this.modifiedMs,
    required this.deletable,
  });

  final String relPath;
  final String category;
  final int sizeBytes;
  final int modifiedMs;
  final bool deletable;
}

/// One hook from the workspace's `.bistre/hooks.json`, shown for review.
class EngineWorkspaceHook {
  const EngineWorkspaceHook({
    required this.event,
    required this.command,
    this.toolFilter,
  });

  /// `pre_tool_use`, `post_tool_use`, `run_finished`, or `run_failed`.
  final String event;
  final String command;
  final String? toolFilter;
}

/// The workspace's hooks file and whether the user approved exactly this file (by digest).
class EngineWorkspaceHooksStatus {
  const EngineWorkspaceHooksStatus({
    required this.hooks,
    required this.digest,
    required this.approved,
  });

  final List<EngineWorkspaceHook> hooks;
  final String digest;
  final bool approved;
}

/// One web page a reply used (B2); parsed and bounded in core, `http(s)` only.
class EngineGroundingSource {
  const EngineGroundingSource({
    required this.nodeId,
    required this.url,
    required this.title,
    this.citedText,
  });

  final String nodeId;
  final String url;
  final String title;
  final String? citedText;

  /// The site's host name, shown under the title.
  String get host => Uri.tryParse(url)?.host ?? url;
}

/// What core knows about one API format (P7): its default server URL and chat endpoint.
class EngineDialectDescriptor {
  const EngineDialectDescriptor({
    required this.id,
    required this.defaultBaseUrl,
    required this.endpointPath,
    required this.requiresApiKey,
  });

  final String id;
  final String defaultBaseUrl;
  final String endpointPath;
  final bool requiresApiKey;
}

/// The exact URLs core calls a provider at (P8), shown in settings and connection tests.
class EngineResolvedEndpoint {
  const EngineResolvedEndpoint({
    required this.chatUrl,
    required this.modelsUrl,
  });

  final String chatUrl;
  final String modelsUrl;
}

/// One row of the context breakdown (A-SE). [kind] is a fixed id from core
/// (`messages`, `built_in_tools`, `mcp_tools`, `system_prompt`, `workspace_instructions`,
/// `story`, `attachments`, `draft`, `deferred_mcp_tools`); the app maps it to its own words.
class EngineContextCategory {
  const EngineContextCategory({
    required this.kind,
    required this.tokens,
    this.count,
    this.sent = true,
  });

  final String kind;
  final int tokens;
  final int? count;
  final bool sent;

  @override
  bool operator ==(Object other) =>
      other is EngineContextCategory &&
      other.kind == kind &&
      other.tokens == tokens &&
      other.count == count &&
      other.sent == sent;

  @override
  int get hashCode => Object.hash(kind, tokens, count, sent);
}

/// One MCP tool's schema size in the breakdown.
class EngineMcpToolUsage {
  const EngineMcpToolUsage({
    required this.name,
    required this.tokens,
    required this.deferred,
  });

  final String name;
  final int tokens;
  final bool deferred;
}

/// One MCP server and its tools in the breakdown.
class EngineMcpServerUsage {
  const EngineMcpServerUsage({
    required this.serverId,
    required this.label,
    required this.tools,
  });

  final String serverId;
  final String label;
  final List<EngineMcpToolUsage> tools;

  int get tokens => tools.fold(0, (sum, t) => sum + t.tokens);
}

/// What fills the next request, from core (A-SE): rows, the window, and the kept-free
/// reserve. Core owns every number.
class EngineContextBreakdown {
  const EngineContextBreakdown({
    this.categories = const <EngineContextCategory>[],
    this.totalSent = 0,
    this.limitTokens,
    this.reserveTokens = 0,
    this.mcp = const <EngineMcpServerUsage>[],
    this.mcpTruncated = false,
  });

  static const EngineContextBreakdown empty = EngineContextBreakdown();

  final List<EngineContextCategory> categories;
  final int totalSent;
  final int? limitTokens;
  final int reserveTokens;
  final List<EngineMcpServerUsage> mcp;
  final bool mcpTruncated;

  int tokensOf(String kind) =>
      categories.where((c) => c.kind == kind).firstOrNull?.tokens ?? 0;

  int? countOf(String kind) =>
      categories.where((c) => c.kind == kind).firstOrNull?.count;

  @override
  bool operator ==(Object other) =>
      other is EngineContextBreakdown &&
      other.totalSent == totalSent &&
      other.limitTokens == limitTokens &&
      other.reserveTokens == reserveTokens &&
      other.mcpTruncated == mcpTruncated &&
      other.mcp.length == mcp.length &&
      _listEquals(other.categories, categories);

  @override
  int get hashCode => Object.hash(
    totalSent,
    limitTokens,
    reserveTokens,
    mcpTruncated,
    mcp.length,
    Object.hashAll(categories),
  );

  static bool _listEquals(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
