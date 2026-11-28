import 'dart:convert';

part 'engine_harness_models.dart';

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
    this.goalCheck = false,
    this.editedFrom = '',
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

  /// A work check core sent while the chat's goal was open (a user turn Bistre wrote).
  final bool goalCheck;

  /// The reply this version was edited from; empty for a written reply.
  final String editedFrom;

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
        goalCheck: decoded['goal_check'] as bool? ?? false,
        editedFrom: decoded['edited_from'] as String? ?? '',
      );
    } on FormatException {
      return null;
    }
  }
}

/// A chat's goal: open until the model calls `goal_complete` with what it did and checked.
class EngineThreadGoal {
  const EngineThreadGoal({
    required this.objective,
    required this.completed,
    this.summary = '',
  });

  final String objective;
  final bool completed;
  final String summary;
}

/// A recent reply's raw request body and response stream, kept in memory by core.
/// One file of a chat and the message it came with.
class EngineChatFile {
  const EngineChatFile({
    required this.nodeId,
    required this.fromUser,
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.blobRelPath,
    required this.createdAtMs,
  });

  final String nodeId;

  /// You sent it; otherwise a reply or a tool made it.
  final bool fromUser;
  final String name;
  final String mimeType;
  final int sizeBytes;
  final String blobRelPath;
  final int createdAtMs;

  /// The file as a message attachment (opens in the same preview).
  EngineNodeAttachment get attachment => EngineNodeAttachment(
    name: name,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    blobRelPath: blobRelPath,
  );
}

class EngineRawExchange {
  const EngineRawExchange({
    required this.url,
    required this.requestBody,
    required this.response,
    required this.truncated,
  });

  final String url;
  final String requestBody;
  final String response;

  /// Core kept only the first part of the request or the response.
  final bool truncated;
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
    this.autoCompactAtPercent = 85,
  });

  final String theme;
  final String layoutMode;
  final String locale;
  final String trustPreset;

  /// `null` explicitly represents Unlimited spending (no daily cap).
  final int? walletDailyCeilingMicros;
  final bool walletLocalFirst;
  final bool providerStatelessDefault;
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

  /// How full the context window may get (percent) before a run shortens the chat.
  final int autoCompactAtPercent;

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
    int? autoCompactAtPercent,
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
      autoCompactAtPercent: autoCompactAtPercent ?? this.autoCompactAtPercent,
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

  /// This chat moved to the project (or default workspace) [workspace].
  EngineThread withWorkspace(String workspace) => EngineThread(
    id: id,
    workspaceId: workspace,
    title: title,
    mode: mode,
    topic: topic,
    assistantId: assistantId,
    isPinned: isPinned,
    activeHeadNodeId: activeHeadNodeId,
    providerIdOverride: providerIdOverride,
    modelIdOverride: modelIdOverride,
    systemPromptOverride: systemPromptOverride,
    temperatureMilli: temperatureMilli,
    maxOutputTokens: maxOutputTokens,
    topPMilli: topPMilli,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs,
  );
}

/// A project: a named group of chats with a folder they work in and instructions every
/// reply in them reads. An empty [folderPath] keeps the app's open folders; an empty [id]
/// saves a new project.
class EngineProject {
  const EngineProject({
    this.id = '',
    required this.name,
    this.folderPath = '',
    this.instructions = '',
    this.createdAtMs = 0,
  });

  final String id;
  final String name;
  final String folderPath;
  final String instructions;
  final int createdAtMs;

  EngineProject copyWith({
    String? name,
    String? folderPath,
    String? instructions,
  }) => EngineProject(
    id: id,
    name: name ?? this.name,
    folderPath: folderPath ?? this.folderPath,
    instructions: instructions ?? this.instructions,
    createdAtMs: createdAtMs,
  );
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

  /// Files sent with this message, parsed once by core.
  final List<EngineNodeAttachment> attachments;

  /// Parsed once per node and cached (it was parsed on every access in every build).
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

/// One file sent with a message; [blobRelPath] is relative to the data directory.
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

final class HostActionRequestedEvent extends BistreEvent {
  const HostActionRequestedEvent({
    required this.requestId,
    required this.threadId,
    required this.runId,
    required this.actionJson,
  });

  final String requestId;
  final String threadId;
  final String runId;
  final String actionJson;
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
