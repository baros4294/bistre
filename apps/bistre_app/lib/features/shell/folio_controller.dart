import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_theme.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../../platform/font_manager.dart';
import '../../platform/host_memory.dart';
import '../../platform/power_guard_host.dart';
import '../chat/tool_timeline_view.dart';
import 'live_turn_notifier.dart';

part 'folio_controller_catalog.dart';
part 'folio_controller_threads.dart';
part 'folio_controller_studio.dart';

enum FolioLayoutMode { bubbles, openFolio }

enum SidebarTab { assistant, chat, pinned }

enum StudioTab { runs, files, story, prompt }

/// Attached file or inline file-range reference held in the composer prior to send.
class ComposerAttachment {
  const ComposerAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.path,
    this.sizeBytes = 0,
    this.isImage = false,
    this.inlineReference = '',
  });

  final String id;
  final String name;
  final String mimeType;
  final String path;
  final int sizeBytes;
  final bool isImage;
  final String inlineReference;
}

enum SettingsTab {
  providers,
  assistants,
  appearance,
  trust,
  agent,
  memory,
  updates,
  language,
  shortcuts,
}

/// Sibling branch coordinates for a DAG node (e.g. `1 / 2`).
class BranchSlotInfo {
  const BranchSlotInfo({
    required this.parentKey,
    required this.index,
    required this.total,
  });

  final String parentKey;
  final int index;
  final int total;
}

/// Canonical keyboard shortcut action identifiers and default combos.
class ShortcutActionSpec {
  const ShortcutActionSpec({
    required this.id,
    required this.labelKey,
    required this.defaultCombo,
  });

  final String id;
  final L10nKey labelKey;
  final String defaultCombo;

  static const List<ShortcutActionSpec> defaults = <ShortcutActionSpec>[
    ShortcutActionSpec(
      id: 'palette',
      labelKey: L10nKey.shortcutPalette,
      defaultCombo: 'Ctrl+K',
    ),
    ShortcutActionSpec(
      id: 'new_chat',
      labelKey: L10nKey.shortcutNewFolio,
      defaultCombo: 'Ctrl+N',
    ),
    ShortcutActionSpec(
      id: 'sidebar',
      labelKey: L10nKey.shortcutSidebar,
      defaultCombo: 'Ctrl+B',
    ),
    ShortcutActionSpec(
      id: 'settings',
      labelKey: L10nKey.shortcutSettings,
      defaultCombo: 'Ctrl+,',
    ),
    ShortcutActionSpec(
      id: 'search',
      labelKey: L10nKey.shortcutSearch,
      defaultCombo: 'Ctrl+Shift+F',
    ),
    ShortcutActionSpec(
      id: 'theme',
      labelKey: L10nKey.shortcutTheme,
      defaultCombo: 'Ctrl+Shift+L',
    ),
    ShortcutActionSpec(
      id: 'layout',
      labelKey: L10nKey.shortcutLayout,
      defaultCombo: 'Ctrl+Shift+M',
    ),
    ShortcutActionSpec(
      id: 'shortcuts',
      labelKey: L10nKey.shortcutShortcuts,
      defaultCombo: 'Ctrl+/',
    ),
    ShortcutActionSpec(
      id: 'jump_prompt',
      labelKey: L10nKey.shortcutJumpPrompt,
      defaultCombo: 'Ctrl+Alt+G',
    ),
  ];
}

/// Pure `ChangeNotifier` state coordinator for Bistre's native desktop & mobile UI.
/// All persistence, OS secret vault operations, HTTP streaming, FTS5 search, OTA,
/// and settings delegate strictly to `BistreEngineGateway`.
class FolioController extends ChangeNotifier {
  /// Notifies listeners on behalf of the extension parts of this library.
  void _notify() => notifyListeners();

  /// Async work (FFI calls, font discovery) can finish after the shell is gone; a late
  /// notification must not touch a disposed notifier.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  /// Background refresh failures never interrupt the user; they are logged with their
  /// diagnostic key instead of being swallowed.
  void _noteNonFatal(String where, Object error) {
    debugPrint('[bistre] non-fatal $where: ${extractDiagnosticKey(error)}');
  }

  FolioController({
    required BistreEngineGateway gateway,
    required String defaultThreadTitle,
    void Function(String locale)? onLocaleSynced,
    this.isDevEnvironment = false,
  }) : _gateway = gateway,
       _defaultThreadTitle = defaultThreadTitle,
       _onLocaleSynced = onLocaleSynced;

  final BistreEngineGateway _gateway;
  final String _defaultThreadTitle;
  final void Function(String locale)? _onLocaleSynced;
  final bool isDevEnvironment;

  EngineSettings _settings = const EngineSettings();
  EngineHealth? _health;
  EngineStorageStats? _storageStats;
  int _walletSpendMicros = 0;
  int _walletDailySpendMicros = 0;
  bool _systemIsDark = false;

  // Local typography runtime font handles.
  String _loadedProseFontFamily = BistreTypography.fontProse;
  String _loadedMonoFontFamily = BistreTypography.fontMono;
  List<LocalFontEntry> _systemFonts = const <LocalFontEntry>[];
  bool _loadingSystemFonts = false;

  // Providers, models, assistants, threads, DAG nodes.
  List<EngineProvider> _providers = const <EngineProvider>[];
  final Map<String, List<EngineProviderModel>> _modelsByProvider =
      <String, List<EngineProviderModel>>{};
  String? _loadingModelsProviderId;
  List<EngineAssistant> _assistants = const <EngineAssistant>[];
  List<EngineThread> _threads = const <EngineThread>[];
  EngineThread? _activeThread;
  List<EngineNode> _nodes = const <EngineNode>[];
  final Map<String, int> _selectedChildIndex = <String, int>{};

  // Streaming state driven by Rust 16ms coalesced DeltaBatch events. Text/thinking deltas
  // update ONLY the leaf `liveTurn` notifier (zero shell/sidebar rebuilds per delta).
  String? _streamingThreadId;
  String? _streamingNodeId;

  /// Leaf notifier read only by the streaming message widget.
  final LiveTurnNotifier liveTurn = LiveTurnNotifier();

  // Low-memory hardware mode (< 4 GB RAM or Android isLowRamDevice).
  bool _lowMemoryMode = false;
  bool _disposed = false;

  // Backoff notice (`diag.run.backoff_waiting`) shown with an inline `Retry now`.
  DateTime? _backoffRetryAt;

  // Chats deleted within the last 8 s (still restorable with Undo).
  final Map<String, Timer> _pendingThreadDeletes = <String, Timer>{};

  // Wave A durable runs, mid-stream steering queue, and OS sleep guard state.
  List<EngineAgentRun> _agentRuns = const <EngineAgentRun>[];
  List<EngineSteeringMessage> _pendingSteering =
      const <EngineSteeringMessage>[];
  EnginePowerGuardStatus _powerStatus = const EnginePowerGuardStatus();
  bool _studioPaneOpen = false;

  // Wave B workspace binding, MCP servers, context compaction, pin, and tool timeline.
  String _workspaceRootPath = '';
  String _webSearchEndpoint = '';
  List<EngineMcpServerConfig> _mcpServers = const <EngineMcpServerConfig>[];
  String? _pinnedContextNodeId;
  List<ToolActivityEntry> _toolActivities = const <ToolActivityEntry>[];
  List<EngineCheckpoint> _checkpoints = const <EngineCheckpoint>[];
  List<EngineLocalServer> _discoveredLocalServers = const <EngineLocalServer>[];

  // Wave C rich studio tabs, attachments, session tree, and provider overrides.
  StudioTab _studioTab = StudioTab.runs;
  bool _sessionTreeOpen = false;
  bool _sessionTreePromptsOnly = false;
  List<ComposerAttachment> _attachments = const <ComposerAttachment>[];
  bool _detectingLocalServers = false;

  // Wave D cross-chat memory, progressive skills, and scheduled cron jobs.
  List<EngineMemoryEntry> _memoryEntries = const <EngineMemoryEntry>[];
  List<EngineSkillIndex> _discoveredSkills = const <EngineSkillIndex>[];
  List<EngineCronJob> _cronJobs = const <EngineCronJob>[];

  // Wave E Writing & Roleplay Studio (CCv3 cards, Personas, Lorebook V3, Manuscript, Prompt Inspector).
  List<EngineCharacterCard> _characterCards = const <EngineCharacterCard>[];
  List<EngineUserPersona> _userPersonas = const <EngineUserPersona>[];
  List<EngineStoryEntry> _storyEntries = const <EngineStoryEntry>[];
  List<EngineStoryProgression> _storyProgressions =
      const <EngineStoryProgression>[];
  List<EngineStoryChapter> _storyChapters = const <EngineStoryChapter>[];
  final Map<String, List<EngineStoryScene>> _storyScenesByChapter =
      <String, List<EngineStoryScene>>{};
  String? _selectedChapterId;
  String? _selectedSceneId;
  EngineStoryThreadState _storyState = const EngineStoryThreadState();
  List<EngineRegexRule> _regexRules = const <EngineRegexRule>[];
  EnginePromptReport _promptReport = const EnginePromptReport();
  bool _manuscriptViewActive = false;
  int _activeGreetingIndex = 0;

  // OTA Update state.
  EngineUpdateCheck? _updateCheck;
  bool _checkingUpdates = false;
  bool _stagingUpdate = false;
  String? _stagedUpdatePath;

  // Sidebar, Inspector, Search, Overlays & Toast.
  bool _sidebarOpen = true;
  bool _inspectorOpen = false;
  SidebarTab _sidebarTab = SidebarTab.chat;
  String _sidebarFilter = '';
  String _activeAssistantId = 'default_assistant';

  bool _searchPanelOpen = false;
  bool _searchAllThreads = false;
  String _searchQuery = '';
  List<EngineSearchHit> _searchHits = const <EngineSearchHit>[];
  String? _quotedExcerpt;
  bool _settingsOpen = false;
  SettingsTab _settingsTab = SettingsTab.providers;
  String? _editingAssistantId;
  bool _commandPaletteOpen = false;
  L10nKey? _toastKey;
  L10nKey? _toastActionKey;
  VoidCallback? _toastAction;
  Timer? _toastTimer;

  // Draft & diagnostics.
  String _restoredDraft = '';
  int _draftEpoch = 0;
  bool _draftSaved = false;
  String? _lastDiagnosticKey;
  Timer? _draftDebounce;
  StreamSubscription<BistreEvent>? _eventSub;

  EngineSettings get settings => _settings;

  bool get isDark {
    if (_settings.theme == 'night') return true;
    if (_settings.theme == 'day') return false;
    return _systemIsDark;
  }

  FolioLayoutMode get layoutMode => _settings.layoutMode == 'bubbles'
      ? FolioLayoutMode.bubbles
      : FolioLayoutMode.openFolio;

  BistreTypographyConfig get resolvedTypography => BistreTypographyConfig(
    proseFontFamily: _loadedProseFontFamily,
    monoFontFamily: _loadedMonoFontFamily,
    baseFontSizePx: _settings.fontSizePx.clamp(12, 28).toDouble(),
    lineHeightFactor: (_settings.lineHeightBps.clamp(13000, 20000)) / 10000.0,
    readingWidthPx: _settings.readingWidthPx.clamp(600, 1120).toDouble(),
  );

  List<LocalFontEntry> get systemFonts => _systemFonts;
  bool get loadingSystemFonts => _loadingSystemFonts;

  bool get reduceMotionOverride => _settings.reduceMotionOverride;
  bool get sendOnEnter => _settings.sendOnEnter;
  bool get showTokenMetrics => _settings.showTokenMetrics;

  EngineHealth? get health => _health;
  EngineStorageStats? get storageStats => _storageStats;
  int get walletSpendMicros => _walletSpendMicros;
  int get walletDailySpendMicros => _walletDailySpendMicros;
  List<EngineProvider> get providers => _providers;
  String? get loadingModelsProviderId => _loadingModelsProviderId;

  EngineUpdateCheck? get updateCheck => _updateCheck;
  bool get checkingUpdates => _checkingUpdates;
  bool get stagingUpdate => _stagingUpdate;
  String? get stagedUpdatePath => _stagedUpdatePath;

  List<EngineProviderModel> modelsForProvider(String providerId) =>
      _modelsByProvider[providerId] ?? const <EngineProviderModel>[];

  int get readyProviderCount => _providers.where((p) => p.isReady).length;
  bool get hasConfiguredProvider => readyProviderCount > 0;

  EngineProvider? get activeProvider {
    final overrideId = _activeThread?.providerIdOverride;
    if (overrideId != null && overrideId.isNotEmpty) {
      for (final p in _providers) {
        if (p.id == overrideId) return p;
      }
    }
    final asstProviderId = activeAssistant?.defaultProviderId ?? '';
    if (asstProviderId.isNotEmpty) {
      for (final p in _providers) {
        if (p.id == asstProviderId && p.isEnabled) return p;
      }
    }
    if (_settings.activeProviderId.isNotEmpty) {
      for (final p in _providers) {
        if (p.id == _settings.activeProviderId) return p;
      }
    }
    for (final p in _providers) {
      if (p.isReady) return p;
    }
    return null;
  }

  String get activeModelId {
    final overrideModel = _activeThread?.modelIdOverride;
    if (overrideModel != null && overrideModel.isNotEmpty) {
      return overrideModel;
    }
    final asstModel = activeAssistant?.defaultModelId ?? '';
    if (asstModel.isNotEmpty) return asstModel;
    if (_settings.activeModelId.isNotEmpty) {
      return _settings.activeModelId;
    }
    return activeProvider?.defaultModel ?? '';
  }

  /// Compact display string for the active provider + model (empty if unconfigured).
  String get activeProviderModelDisplay {
    final p = activeProvider;
    if (p == null || !p.isReady) return '';
    final m = activeModelId;
    if (m.isEmpty) return p.name;
    return m;
  }

  List<EngineAssistant> get assistants => _assistants;
  List<EngineThread> get threads => _threads;
  EngineThread? get activeThread => _activeThread;
  List<EngineNode> get nodes => _nodes;
  String get activeAssistantId =>
      _activeThread?.assistantId ?? _activeAssistantId;

  EngineAssistant? get activeAssistant {
    final target = activeAssistantId;
    for (final a in _assistants) {
      if (a.id == target) return a;
    }
    return _assistants.isEmpty ? null : _assistants.first;
  }

  bool get isStreaming =>
      _streamingThreadId != null && _streamingThreadId == _activeThread?.id;
  bool get hasAnyActiveRun =>
      _streamingThreadId != null || _agentRuns.any((r) => r.isActive);
  int get activeRunCount => _agentRuns.where((r) => r.isActive).length;
  String get streamingBuffer => liveTurn.value?.text ?? '';
  String get streamingThinkingBuffer => liveTurn.value?.thinking ?? '';
  String? get streamingNodeId => _streamingNodeId;
  List<EngineAgentRun> get agentRuns => _agentRuns;
  List<EngineSteeringMessage> get pendingSteering => _pendingSteering;
  EnginePowerGuardStatus get powerStatus => _powerStatus;
  bool get studioPaneOpen => _studioPaneOpen;

  bool get sidebarOpen => _sidebarOpen;
  bool get inspectorOpen => _inspectorOpen;
  SidebarTab get sidebarTab => _sidebarTab;
  String get sidebarFilter => _sidebarFilter;

  bool get searchPanelOpen => _searchPanelOpen;
  bool get searchAllThreads => _searchAllThreads;
  String get searchQuery => _searchQuery;
  List<EngineSearchHit> get searchHits => _searchHits;
  String? get quotedExcerpt => _quotedExcerpt;

  bool get settingsOpen => _settingsOpen;
  SettingsTab get settingsTab => _settingsTab;
  String? get editingAssistantId => _editingAssistantId;
  bool get commandPaletteOpen => _commandPaletteOpen;
  L10nKey? get toastKey => _toastKey;
  L10nKey? get toastActionKey => _toastActionKey;
  VoidCallback? get toastAction => _toastAction;

  /// `true` on low-memory hardware: no overlay shadows, 30 fps streaming redraw.
  bool get lowMemoryMode => _lowMemoryMode;

  /// Applies low-memory mode (also used by tests and the gallery).
  void setLowMemoryMode(bool enabled) {
    _lowMemoryMode = enabled;
    liveTurn.minInterval = enabled ? kLowMemoryFrameInterval : Duration.zero;
    notifyListeners();
  }

  /// Text the composer's conversation-limit gauge counts (visible branch of the active chat).
  String get contextGaugeText =>
      visibleBranchNodes.map((n) => n.content).join('\n');

  /// When the current run's automatic retry fires (null when not backing off).
  DateTime? get backoffRetryAt => _backoffRetryAt;

  /// Effective code-fence wrapping for a viewport `width` (`auto` wraps below 640 px).
  bool codeWrapFor(double width) => switch (_settings.codeWrapMode) {
    'on' => true,
    'off' => false,
    _ => width < 640,
  };

  Future<void> setCodeWrapMode(String mode) async {
    await updateSettings(_settings.copyWith(codeWrapMode: mode));
  }

  /// Ends the backoff wait immediately (`Retry now`).
  Future<void> retryNow() async {
    final threadId = _streamingThreadId;
    if (threadId == null) return;
    _backoffRetryAt = null;
    notifyListeners();
    try {
      await _gateway.retryRunNow(threadId);
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  String get restoredDraft => _restoredDraft;
  int get draftEpoch => _draftEpoch;
  bool get draftSaved => _draftSaved;
  String? get lastDiagnosticKey => _lastDiagnosticKey;

  String? assistantNameFor(String assistantId) =>
      _assistants.where((a) => a.id == assistantId).firstOrNull?.name;

  static final RegExp _diagKeyPattern = RegExp(r'\bdiag\.[a-z0-9_.]+\b');

  static String extractDiagnosticKey(Object error) {
    final match = _diagKeyPattern.firstMatch(error.toString());
    return match?.group(0) ?? 'diag.internal.error';
  }

  /// Formats integer micro-USD (`1 USD = 1_000_000`) deterministically with zero floats.
  static String formatMicrosUsd(int micros, {bool showSubCent = false}) {
    final negative = micros < 0;
    final abs = micros.abs();
    final dollars = abs ~/ 1000000;
    if (showSubCent && abs > 0 && abs < 10000) {
      final frac4 = (abs ~/ 100).toString().padLeft(4, '0');
      return '${negative ? '-' : ''}\$$dollars.$frac4';
    }
    final cents = (abs % 1000000) ~/ 10000;
    final centsStr = cents.toString().padLeft(2, '0');
    return '${negative ? '-' : ''}\$$dollars.$centsStr';
  }

  /// Parses user USD text (e.g. `"12.50"` or `"$0.75"`) into exact integer micro-USD (zero floats).
  static int? parseUsdToMicros(String raw) {
    final cleaned = raw.trim().replaceAll(r'$', '').replaceAll(',', '');
    if (cleaned.isEmpty) return null;
    final parts = cleaned.split('.');
    if (parts.length > 2) return null;
    final whole = int.tryParse(parts[0].isEmpty ? '0' : parts[0]);
    if (whole == null || whole < 0) return null;
    var fracMicros = 0;
    if (parts.length == 2 && parts[1].isNotEmpty) {
      final padded = parts[1].padRight(6, '0').substring(0, 6);
      final parsedFrac = int.tryParse(padded);
      if (parsedFrac == null || parsedFrac < 0) return null;
      fracMicros = parsedFrac;
    }
    return whole * 1000000 + fracMicros;
  }

  /// Formats bytes cleanly into KB / MB without floating-point money ambiguity.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Map<String, String> get shortcutBindings {
    final result = <String, String>{
      for (final spec in ShortcutActionSpec.defaults)
        spec.id: spec.defaultCombo,
    };
    final raw = _settings.customShortcutsJson.trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          for (final kv in decoded.entries) {
            if (kv.value is String && (kv.value! as String).trim().isNotEmpty) {
              result[kv.key] = (kv.value! as String).trim();
            }
          }
        }
      } on FormatException {
        // Fallback safely to defaults.
      }
    }
    return result;
  }

  String shortcutFor(String actionId) =>
      shortcutBindings[actionId] ??
      ShortcutActionSpec.defaults
          .where((s) => s.id == actionId)
          .firstOrNull
          ?.defaultCombo ??
      '';

  Future<void> setShortcutBinding(String actionId, String combo) async {
    final next = Map<String, String>.from(shortcutBindings);
    next[actionId] = combo;
    await updateSettings(
      _settings.copyWith(customShortcutsJson: jsonEncode(next)),
    );
  }

  Future<void> resetShortcuts() async {
    await updateSettings(_settings.copyWith(customShortcutsJson: ''));
  }

  void setSystemBrightness(bool isDark) {
    if (_systemIsDark == isDark) return;
    _systemIsDark = isDark;
    if (_settings.theme == 'system') {
      notifyListeners();
    }
  }

  void clearDiagnostic() {
    if (_lastDiagnosticKey == null) return;
    _lastDiagnosticKey = null;
    notifyListeners();
  }

  List<EngineThread> get filteredThreads {
    final q = _sidebarFilter.trim().toLowerCase();
    return _threads
        .where((t) {
          if (q.isEmpty) return true;
          return t.title.toLowerCase().contains(q) ||
              t.topic.toLowerCase().contains(q);
        })
        .toList(growable: false);
  }

  List<EngineThread> get pinnedThreads =>
      filteredThreads.where((t) => t.isPinned).toList(growable: false);

  /// Walks the active thread's canonical SQLite DAG following the user's selected
  /// sibling branch at every fork point (defaulting to the newest sibling).
  List<EngineNode> get visibleBranchNodes {
    if (_nodes.isEmpty) return const <EngineNode>[];
    final childrenByParent = _groupChildrenByParent(_nodes);
    final result = <EngineNode>[];
    String? currentParent;
    final visited = <String>{};

    while (true) {
      final parentKey = currentParent ?? '__root__';
      final siblings = childrenByParent[parentKey];
      if (siblings == null || siblings.isEmpty) break;
      final selected = (_selectedChildIndex[parentKey] ?? (siblings.length - 1))
          .clamp(0, siblings.length - 1);
      final chosen = siblings[selected];
      if (!visited.add(chosen.id)) break;
      result.add(chosen);
      currentParent = chosen.id;
    }
    return result;
  }

  BranchSlotInfo? branchInfoFor(EngineNode node) {
    final parentKey = node.parentId ?? '__root__';
    final siblings = _groupChildrenByParent(_nodes)[parentKey];
    if (siblings == null || siblings.length <= 1) return null;
    final idx = siblings.indexWhere((n) => n.id == node.id);
    if (idx < 0) return null;
    return BranchSlotInfo(
      parentKey: parentKey,
      index: idx,
      total: siblings.length,
    );
  }

  void selectSiblingBranch(String parentKey, int delta) {
    final siblings = _groupChildrenByParent(_nodes)[parentKey];
    if (siblings == null || siblings.length <= 1) return;
    final current = _selectedChildIndex[parentKey] ?? (siblings.length - 1);
    final next = (current + delta).clamp(0, siblings.length - 1);
    _selectedChildIndex[parentKey] = next;
    notifyListeners();
  }

  static Map<String, List<EngineNode>> _groupChildrenByParent(
    List<EngineNode> allNodes,
  ) {
    final map = <String, List<EngineNode>>{};
    for (final node in allNodes) {
      final key = node.parentId ?? '__root__';
      map.putIfAbsent(key, () => <EngineNode>[]).add(node);
    }
    return map;
  }

  Future<void> bootstrap(String dataDir) async {
    try {
      _health = await _gateway.init(dataDir);
      // Fire-and-forget: platform probes must never block startup.
      unawaited(
        detectLowMemoryHost().then((low) {
          if (low && !_disposed) setLowMemoryMode(true);
        }),
      );
      _settings = await _gateway.loadSettings();
      _sidebarOpen = _settings.sidebarOpen;
      _onLocaleSynced?.call(_settings.locale);

      await _hydrateCustomFontsFromSettings();
      final savedBounds = DesktopWindowBounds.tryParseJson(
        _settings.windowBoundsJson,
      );
      if (savedBounds != null) {
        unawaited(BistreDesktopHost.restoreWindowBounds(savedBounds));
      }

      _providers = await _gateway.listProviders();
      _assistants = await _gateway.listAssistants();
      _walletSpendMicros = await _gateway.getWalletSpendMicros();
      _walletDailySpendMicros = await _gateway.getWalletDailySpendMicros();
      _storageStats = await _gateway.getStorageStats();
      _threads = _withoutPendingDeletes(await _gateway.listThreads());

      if (_threads.isEmpty) {
        final created = await _gateway.createThread(
          _defaultThreadTitle,
          'chat',
          topic: 'general',
          assistantId: _assistants.isEmpty
              ? 'default_assistant'
              : _assistants.first.id,
        );
        _threads = <EngineThread>[created];
      }
      await _activateThread(_threads.first);
      _health = await _gateway.getHealth();
      _storageStats = await _gateway.getStorageStats();
      _agentRuns = await _gateway.listAgentRuns(limit: 30);
      _powerStatus = await _gateway.powerGuardStatus();
      await _loadAgentWorkspaceConfig();
      if (BistrePowerGuardHost.isAndroid) {
        final androidState = await BistrePowerGuardHost.getAndroidPowerState();
        _powerStatus = await _gateway.setAndroidPowerState(
          fgsActive: androidState.fgsActive,
          batteryUnrestricted: androidState.batteryUnrestricted,
        );
        BistrePowerGuardHost.attachPowerEventListener((eventKind) {
          unawaited(_gateway.notifyPowerEvent(eventKind));
        });
      }

      unawaited(_eventSub?.cancel());
      _eventSub = _gateway.subscribeEvents().listen(_handleEngineEvent);
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  Future<void> _hydrateCustomFontsFromSettings() async {
    if (_settings.proseFontPath.isNotEmpty) {
      final loaded = await BistreFontManager.loadFontFromFile(
        _settings.proseFontPath,
        preferredFamily: _settings.proseFontFamily,
      );
      _loadedProseFontFamily = loaded ?? BistreTypography.fontProse;
    } else if (_settings.proseFontFamily.isNotEmpty) {
      _loadedProseFontFamily = _settings.proseFontFamily;
    } else {
      _loadedProseFontFamily = BistreTypography.fontProse;
    }

    if (_settings.monoFontPath.isNotEmpty) {
      final loaded = await BistreFontManager.loadFontFromFile(
        _settings.monoFontPath,
        preferredFamily: _settings.monoFontFamily,
      );
      _loadedMonoFontFamily = loaded ?? BistreTypography.fontMono;
    } else if (_settings.monoFontFamily.isNotEmpty) {
      _loadedMonoFontFamily = _settings.monoFontFamily;
    } else {
      _loadedMonoFontFamily = BistreTypography.fontMono;
    }
  }

  Future<void> ensureSystemFontsLoaded() async {
    if (_systemFonts.isNotEmpty || _loadingSystemFonts) return;
    _loadingSystemFonts = true;
    notifyListeners();
    _systemFonts = await BistreFontManager.discoverSystemFonts();
    _loadingSystemFonts = false;
    notifyListeners();
  }

  Future<bool> applyLocalProseFont({
    required String familyLabel,
    required String filePath,
  }) async {
    final loaded = await BistreFontManager.loadFontFromFile(
      filePath,
      preferredFamily: familyLabel,
    );
    if (loaded == null) return false;
    _loadedProseFontFamily = loaded;
    await updateSettings(
      _settings.copyWith(proseFontFamily: familyLabel, proseFontPath: filePath),
      quiet: true,
    );
    showToast(L10nKey.toastFontLoaded);
    return true;
  }

  Future<bool> applyLocalMonoFont({
    required String familyLabel,
    required String filePath,
  }) async {
    final loaded = await BistreFontManager.loadFontFromFile(
      filePath,
      preferredFamily: familyLabel,
    );
    if (loaded == null) return false;
    _loadedMonoFontFamily = loaded;
    await updateSettings(
      _settings.copyWith(monoFontFamily: familyLabel, monoFontPath: filePath),
      quiet: true,
    );
    showToast(L10nKey.toastFontLoaded);
    return true;
  }

  Future<void> resetProseFont() async {
    _loadedProseFontFamily = BistreTypography.fontProse;
    await updateSettings(
      _settings.copyWith(proseFontFamily: '', proseFontPath: ''),
      quiet: true,
    );
    showToast(L10nKey.toastSettingsSaved);
  }

  Future<void> resetMonoFont() async {
    _loadedMonoFontFamily = BistreTypography.fontMono;
    await updateSettings(
      _settings.copyWith(monoFontFamily: '', monoFontPath: ''),
      quiet: true,
    );
    showToast(L10nKey.toastSettingsSaved);
  }

  Future<void> persistCurrentWindowBounds() async {
    final bounds = await BistreDesktopHost.readWindowBounds();
    if (bounds == null) return;
    final encoded = bounds.toJsonString();
    if (encoded == _settings.windowBoundsJson) return;
    try {
      _settings = await _gateway.saveSettings(
        _settings.copyWith(windowBoundsJson: encoded),
      );
    } catch (e) {
      _noteNonFatal('window_bounds_save', e);
    }
  }

  // --- Engine Event Bus ---

  void _handleEngineEvent(BistreEvent event) {
    switch (event) {
      case RunStartedEvent():
        _streamingThreadId = event.threadId;
        _streamingNodeId = event.nodeId;
        _backoffRetryAt = null;
        liveTurn.start(event.threadId, event.nodeId);
        if (BistrePowerGuardHost.isAndroid && _settings.keepAwakeWhileRunning) {
          unawaited(_syncAndroidFgs(active: true));
        }
        unawaited(_refreshRunsAndPower());
        notifyListeners();
      case DeltaBatchEvent():
        // Leaf-only update: no notifyListeners() on the hot path.
        if (_backoffRetryAt != null) {
          _backoffRetryAt = null;
          notifyListeners();
        }
        liveTurn.appendText(event.threadId, event.textDelta);
      case ThinkingDeltaEvent():
        liveTurn.appendThinking(event.threadId, event.delta);
      case RunStateChangedEvent():
        unawaited(_refreshRunsAndPower());
      case RunStepUpdatedEvent():
        unawaited(_refreshRunsAndPower());
      case SteeringQueueChangedEvent():
        if (_activeThread?.id == event.threadId) {
          unawaited(_refreshPendingSteering(event.threadId));
        }
      case PowerStatusChangedEvent():
        unawaited(_refreshRunsAndPower());
      case NodeCommittedEvent():
        if (_activeThread?.id == event.node.threadId) {
          final exists = _nodes.any((n) => n.id == event.node.id);
          if (!exists) {
            _nodes = <EngineNode>[..._nodes, event.node];
            final parentKey = event.node.parentId ?? '__root__';
            final siblings = _groupChildrenByParent(_nodes)[parentKey];
            if (siblings != null && siblings.isNotEmpty) {
              _selectedChildIndex[parentKey] = siblings.length - 1;
            }
          }
          notifyListeners();
        }
      case RunFinishedEvent():
        if (_streamingThreadId == event.threadId) {
          _streamingThreadId = null;
          _streamingNodeId = null;
          _backoffRetryAt = null;
          liveTurn.clear();
        }
        if (BistrePowerGuardHost.isAndroid) {
          unawaited(_syncAndroidFgs(active: false));
        }
        unawaited(_refreshAfterRun(event.threadId));
        notifyListeners();
      case DraftSavedEvent():
        if (_activeThread?.id == event.threadId) {
          notifyListeners();
        }
      case DiagnosticRaisedEvent():
        if (event.key == 'diag.run.backoff_waiting') {
          final ms = int.tryParse(
            RegExp(r'retry_in_ms=(\d+)')
                    .firstMatch(event.detailCode ?? '')
                    ?.group(1) ??
                '',
          );
          _backoffRetryAt = ms == null
              ? null
              : DateTime.now().add(Duration(milliseconds: ms));
        } else {
          _lastDiagnosticKey = event.key;
        }
        notifyListeners();
      case LocalePackVerifiedEvent():
        notifyListeners();
    }
  }

  Future<void> _refreshAfterRun(String threadId) async {
    try {
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      if (_activeThread?.id == threadId) {
        _nodes = await _gateway.listNodes(threadId);
      }
      _walletSpendMicros = await _gateway.getWalletSpendMicros();
      _walletDailySpendMicros = await _gateway.getWalletDailySpendMicros();
      _health = await _gateway.getHealth();
      _storageStats = await _gateway.getStorageStats();
      _agentRuns = await _gateway.listAgentRuns(limit: 30);
      _powerStatus = await _gateway.powerGuardStatus();
      if (_activeThread?.id == threadId) {
        _pendingSteering = await _gateway.listPendingSteering(threadId);
      }
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  Future<void> _refreshRunsAndPower() async {
    try {
      _agentRuns = await _gateway.listAgentRuns(limit: 30);
      _powerStatus = await _gateway.powerGuardStatus();
      notifyListeners();
    } catch (e) {
      _noteNonFatal('runs_power_refresh', e);
    }
  }

  Future<void> _refreshPendingSteering(String threadId) async {
    try {
      _pendingSteering = await _gateway.listPendingSteering(threadId);
      notifyListeners();
    } catch (e) {
      _noteNonFatal('steering_refresh', e);
    }
  }

  Future<void> _syncAndroidFgs({required bool active}) async {
    final state = active
        ? await BistrePowerGuardHost.startAndroidAgentService(
            activeCount: activeRunCount > 0 ? activeRunCount : 1,
            summary: _activeThread?.title ?? _defaultThreadTitle,
          )
        : await BistrePowerGuardHost.stopAndroidAgentService();
    try {
      _powerStatus = await _gateway.setAndroidPowerState(
        fgsActive: state.fgsActive,
        batteryUnrestricted: state.batteryUnrestricted,
      );
      notifyListeners();
    } catch (e) {
      _noteNonFatal('android_fgs_sync', e);
    }
  }

  Future<void> requestAndroidBatteryUnrestricted() async {
    final state =
        await BistrePowerGuardHost.requestIgnoreBatteryOptimizations();
    try {
      _powerStatus = await _gateway.setAndroidPowerState(
        fgsActive: state.fgsActive,
        batteryUnrestricted: state.batteryUnrestricted,
      );
      notifyListeners();
    } catch (e) {
      _noteNonFatal('android_battery_state', e);
    }
  }

  Future<bool> enqueueSteeringMessage(String rawText) async {
    final clean = rawText.trim();
    final active = _activeThread;
    if (clean.isEmpty || active == null) return false;
    try {
      await _gateway.enqueueSteering(threadId: active.id, content: clean);
      _pendingSteering = await _gateway.listPendingSteering(active.id);
      showToast(L10nKey.toastSteeringQueued);
      notifyListeners();
      return true;
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
      return false;
    }
  }

  Future<void> removeSteeringMessage(String steeringId) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      await _gateway.deleteSteering(steeringId);
      _pendingSteering = await _gateway.listPendingSteering(active.id);
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  Future<void> resolveIndeterminateRun(
    String runId, {
    required bool confirmCompleted,
  }) async {
    try {
      await _gateway.resolveIndeterminateRun(
        runId: runId,
        confirmCompleted: confirmCompleted,
      );
      await _refreshRunsAndPower();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  Future<void> _activateThread(EngineThread thread) async {
    _activeThread = thread;
    _activeAssistantId = thread.assistantId;
    _selectedChildIndex.clear();
    _quotedExcerpt = null;
    _nodes = await _gateway.listNodes(thread.id);
    _pendingSteering = await _gateway.listPendingSteering(thread.id);
    _pinnedContextNodeId = await _gateway.getContextStartPin(thread.id);
    _checkpoints = await _gateway.listCheckpoints(thread.id);
    _activeGreetingIndex = 0;
    if (thread.mode == 'write') {
      unawaited(refreshStoryStudio());
    } else {
      _manuscriptViewActive = false;
    }
    final draft = await _gateway.loadDraft(thread.id);
    _restoredDraft = draft ?? '';
    _draftEpoch++;
    _draftSaved = _restoredDraft.isNotEmpty;
    if (_searchQuery.isNotEmpty && !_searchAllThreads) {
      _searchHits = await _gateway.searchNodes(
        _searchQuery,
        threadId: thread.id,
      );
    }
  }

  Future<void> selectThread(String threadId) async {
    final target = _threads.where((t) => t.id == threadId).firstOrNull;
    if (target == null) return;
    try {
      await _activateThread(target);
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  Future<void> createNewFolio({String? title, String? assistantId}) async {
    try {
      final resolvedAssistantId = assistantId ?? activeAssistantId;
      final resolvedTitle = (title != null && title.trim().isNotEmpty)
          ? title.trim()
          : _defaultThreadTitle;
      final created = await _gateway.createThread(
        resolvedTitle,
        'chat',
        topic: 'general',
        assistantId: resolvedAssistantId,
      );
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      await _activateThread(created);
      _health = await _gateway.getHealth();
      _storageStats = await _gateway.getStorageStats();
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  Future<void> togglePinThread(String threadId) async {
    final target = _threads.where((t) => t.id == threadId).firstOrNull;
    if (target == null) return;
    try {
      final nextPinned = !target.isPinned;
      final updated = await _gateway.updateThread(
        threadId: threadId,
        isPinned: nextPinned,
      );
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      if (_activeThread?.id == threadId) {
        _activeThread = updated;
      }
      showToast(nextPinned ? L10nKey.toastPinned : L10nKey.toastUnpinned);
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  Future<void> renameThread(String threadId, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return;
    try {
      final updated = await _gateway.updateThread(
        threadId: threadId,
        title: trimmed,
      );
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      if (_activeThread?.id == threadId) {
        _activeThread = updated;
      }
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  Future<void> updateActiveThreadOverrides({
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
    final active = _activeThread;
    if (active == null) return;
    try {
      final updated = await _gateway.updateThread(
        threadId: active.id,
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
      );
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      _activeThread = updated;
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  Future<void> resetActiveThreadOverrides() => updateActiveThreadOverrides(
    clearProviderOverride: true,
    clearModelOverride: true,
    clearSystemPromptOverride: true,
    clearTemperature: true,
    clearMaxOutputTokens: true,
    clearTopP: true,
  );

  // --- Navigation & Layout Controls ---

  void toggleSidebar() {
    _sidebarOpen = !_sidebarOpen;
    unawaited(
      updateSettings(
        _settings.copyWith(sidebarOpen: _sidebarOpen),
        quiet: true,
      ),
    );
    notifyListeners();
  }

  void toggleInspector() {
    _inspectorOpen = !_inspectorOpen;
    if (_inspectorOpen) {
      _studioPaneOpen = false;
    }
    notifyListeners();
  }

  void toggleStudioPane() {
    _studioPaneOpen = !_studioPaneOpen;
    if (_studioPaneOpen) {
      _inspectorOpen = false;
      unawaited(_refreshRunsAndPower());
    }
    notifyListeners();
  }

  void setSidebarTab(SidebarTab tab) {
    if (_sidebarTab == tab) return;
    _sidebarTab = tab;
    notifyListeners();
  }

  void setSidebarFilter(String query) {
    _sidebarFilter = query;
    notifyListeners();
  }

  void toggleSearchPanel() {
    _searchPanelOpen = !_searchPanelOpen;
    if (!_searchPanelOpen) {
      _searchQuery = '';
      _searchHits = const <EngineSearchHit>[];
    }
    notifyListeners();
  }

  void setSearchAllThreads(bool allThreads) {
    _searchAllThreads = allThreads;
    if (_searchQuery.isNotEmpty) {
      unawaited(updateSearch(_searchQuery));
    } else {
      notifyListeners();
    }
  }

  void openSettings([SettingsTab tab = SettingsTab.providers]) {
    _commandPaletteOpen = false;
    _settingsTab = tab;
    _settingsOpen = true;
    if (tab == SettingsTab.appearance) {
      unawaited(ensureSystemFontsLoaded());
    }
    notifyListeners();
  }

  void openAssistantEditor([String? assistantId]) {
    _editingAssistantId = assistantId;
    openSettings(SettingsTab.assistants);
  }

  void closeSettings() {
    if (!_settingsOpen) return;
    _settingsOpen = false;
    notifyListeners();
  }

  void setSettingsTab(SettingsTab tab) {
    _settingsTab = tab;
    if (tab == SettingsTab.appearance) {
      unawaited(ensureSystemFontsLoaded());
    }
    notifyListeners();
  }

  void toggleCommandPalette() {
    _commandPaletteOpen = !_commandPaletteOpen;
    notifyListeners();
  }

  void closeCommandPalette() {
    if (!_commandPaletteOpen) return;
    _commandPaletteOpen = false;
    notifyListeners();
  }

  void handleEscape() {
    if (_sessionTreeOpen) {
      closeSessionTree();
      return;
    }
    if (_commandPaletteOpen) {
      closeCommandPalette();
      return;
    }
    if (_settingsOpen) {
      closeSettings();
      return;
    }
    if (isStreaming) {
      unawaited(cancelStreaming());
      return;
    }
    if (_quotedExcerpt != null) {
      clearQuote();
      return;
    }
    if (_searchPanelOpen) {
      toggleSearchPanel();
      return;
    }
    if (_inspectorOpen) {
      toggleInspector();
      return;
    }
    if (_studioPaneOpen) {
      toggleStudioPane();
    }
  }

  void replyToPassage(String content) {
    final compact = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    _quotedExcerpt = compact.length > 96
        ? '${compact.substring(0, 96)}...'
        : compact;
    notifyListeners();
  }

  void clearQuote() {
    _quotedExcerpt = null;
    notifyListeners();
  }

  Future<void> copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    showToast(L10nKey.toastCopied);
  }

  void showToast(
    L10nKey key, {
    L10nKey? actionKey,
    VoidCallback? onAction,
    Duration duration = const Duration(milliseconds: 2200),
  }) {
    _toastTimer?.cancel();
    _toastKey = key;
    _toastActionKey = actionKey;
    _toastAction = onAction;
    notifyListeners();
    _toastTimer = Timer(duration, dismissToast);
  }

  void dismissToast() {
    _toastTimer?.cancel();
    _toastKey = null;
    _toastActionKey = null;
    _toastAction = null;
    notifyListeners();
  }

  Future<void> updateSettings(EngineSettings next, {bool quiet = false}) async {
    _settings = next;
    _sidebarOpen = next.sidebarOpen;
    _onLocaleSynced?.call(next.locale);
    notifyListeners();
    try {
      _settings = await _gateway.saveSettings(next);
      if (!quiet) {
        showToast(L10nKey.toastSettingsSaved);
      }
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = extractDiagnosticKey(e);
      notifyListeners();
    }
  }

  void toggleTheme() {
    final nextTheme = isDark ? 'day' : 'night';
    unawaited(
      updateSettings(_settings.copyWith(theme: nextTheme), quiet: true),
    );
  }

  void toggleLayoutMode() {
    unawaited(
      updateSettings(
        _settings.copyWith(
          layoutMode: layoutMode == FolioLayoutMode.openFolio
              ? 'bubbles'
              : 'open_folio',
        ),
        quiet: true,
      ),
    );
  }

  void syncLocale(String locale) {
    unawaited(updateSettings(_settings.copyWith(locale: locale), quiet: true));
  }

  @override
  void dispose() {
    _disposed = true;
    _draftDebounce?.cancel();
    _toastTimer?.cancel();
    for (final timer in _pendingThreadDeletes.values) {
      timer.cancel();
    }
    _pendingThreadDeletes.clear();
    liveTurn.dispose();
    unawaited(_eventSub?.cancel());
    super.dispose();
  }
}
