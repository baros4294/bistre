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
    this.costMicros = 0,
    this.costKnown = true,
    this.cancelled = false,
    this.thinkingText = '',
    this.thinkingDurationMs = 0,
    this.compactedCount = 0,
  });

  final String providerId;
  final String providerName;
  final String iconSlug;
  final String modelId;
  final int inputTokens;
  final int outputTokens;
  final int costMicros;

  /// `false` when the model has no published price (`cost_known` in Rust): the reply counts as
  /// `$0` toward the spending limit and the UI shows the quiet breakdown popup instead of a price.
  final bool costKnown;
  final bool cancelled;
  final String thinkingText;
  final int thinkingDurationMs;
  final int compactedCount;

  bool get hasTokens => inputTokens > 0 || outputTokens > 0;
  bool get hasThinking => thinkingText.trim().isNotEmpty;

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
        costMicros: (decoded['cost_micros'] as num?)?.toInt() ?? 0,
        costKnown: decoded['cost_known'] as bool? ?? true,
        cancelled: decoded['cancelled'] as bool? ?? false,
        thinkingText: decoded['thinking_text'] as String? ?? '',
        thinkingDurationMs:
            (decoded['thinking_duration_ms'] as num?)?.toInt() ?? 0,
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
  });

  final String id;
  final String name;
  final String dialect;
  final String baseUrl;
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
    this.accentPreset = 'wax',
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
    this.reasoningEffort = 'medium',
    this.termuxBridgeEnabled = false,
    this.codeWrapMode = 'auto',
    this.pricingAutoRefresh = true,
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
  });

  final String id;
  final String threadId;
  final String? parentId;
  final String role;
  final String content;
  final String? providerMetaJson;
  final int createdAtMs;

  NodeUsageMeta? get usageMeta => NodeUsageMeta.tryParse(providerMetaJson);
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

/// Auto-discovered local loopback inference server (`$0` priority).
class EngineLocalServer {
  const EngineLocalServer({
    required this.kind,
    required this.name,
    required this.baseUrl,
    this.models = const <String>[],
  });

  final String kind;
  final String name;
  final String baseUrl;
  final List<String> models;

  static EngineLocalServer fromJson(Map<String, Object?> m) {
    final raw = m['models'];
    final models = raw is List<Object?>
        ? raw.whereType<String>().toList(growable: false)
        : const <String>[];
    return EngineLocalServer(
      kind: m['kind'] as String? ?? '',
      name: m['name'] as String? ?? '',
      baseUrl: m['base_url'] as String? ?? '',
      models: models,
    );
  }
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
