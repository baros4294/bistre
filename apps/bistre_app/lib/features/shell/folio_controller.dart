import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app/app_appearance.dart';
import '../../app/shell_notifiers.dart';
import '../../bridge/bistre_engine.dart';
import '../../design/bistre_theme.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../../platform/font_manager.dart';
import '../../platform/host_memory.dart';
import '../../platform/power_guard_host.dart';
import '../chat/tool_timeline_view.dart';
import 'live_turn_notifier.dart';

part 'folio_controller_boot.dart';
part 'folio_controller_catalog.dart';
part 'folio_controller_extras.dart';
part 'folio_controller_media.dart';
part 'folio_controller_navigation.dart';
part 'folio_controller_runs.dart';
part 'folio_controller_threads.dart';
part 'folio_controller_studio.dart';

enum FolioLayoutMode { bubbles, openFolio }

enum SidebarTab { assistant, chat, pinned }

enum StudioTab { runs, files, story, prompt, sources }

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
  defaultModels,
  assistants,
  appearance,
  trust,
  agent,
  memory,
  worldBook,
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
    ShortcutActionSpec(
      id: 'stop_reply',
      labelKey: L10nKey.shortcutStopReply,
      defaultCombo: 'Ctrl+.',
    ),
  ];
}

/// First-load progress of the shell (see [FolioController.bootState]).
enum BootState { loading, ready, failed }

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
    // The root app rebuilds only when this value actually changes (ValueNotifier equality).
    appearance.value = _currentAppearance();
    _syncContextUsage();
    super.notifyListeners();
  }

  /// What the next request sends for the visible branch, by category, from core (A-SE). Only
  /// the composer's context ring listens.
  final ValueNotifier<EngineContextBreakdown> contextBreakdown =
      ValueNotifier<EngineContextBreakdown>(EngineContextBreakdown.empty);
  String? _contextUsageKey;
  int _contextUsageSeq = 0;

  /// Asks core again when the chat, the visible branch's newest node, or the context pin
  /// changed; an older answer never replaces a newer one.
  void _syncContextUsage() {
    final thread = _activeThread?.id;
    final leaf = visibleBranchNodes.lastOrNull?.id;
    final key = '$thread|$leaf|$_pinnedContextNodeId';
    if (key == _contextUsageKey) return;
    _contextUsageKey = key;
    final seq = ++_contextUsageSeq;
    if (thread == null || leaf == null) {
      contextBreakdown.value = EngineContextBreakdown.empty;
      return;
    }
    unawaited(
      _gateway
          .contextBreakdown(thread, leaf)
          .then(
            (usage) {
              if (seq != _contextUsageSeq || _disposed) return;
              contextBreakdown.value = usage;
            },
            onError: (Object e) {
              if (seq != _contextUsageSeq || _disposed) return;
              // Ask again on the next change instead of keeping a failed key.
              _contextUsageKey = null;
              _noteNonFatal('context_usage', e);
            },
          ),
    );
  }

  /// Theme and typography inputs for the root `WidgetsApp` (see [AppAppearance]).
  late final ValueNotifier<AppAppearance> appearance =
      ValueNotifier<AppAppearance>(_currentAppearance());

  AppAppearance _currentAppearance() => AppAppearance(
    isDark: isDark,
    themeId: _settings.theme,
    accentPreset: _settings.accentPreset,
    customAccentHex: _settings.customAccentHex,
    typography: resolvedTypography,
    reducedEffects: _lowMemoryMode,
    reduceMotion: _settings.reduceMotionOverride,
    syntaxThemeId: isDark
        ? _uiPrefs.codeSyntaxThemeDark
        : _uiPrefs.codeSyntaxThemeLight,
  );

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
    DateTime Function() clock = DateTime.now,
  }) : _gateway = gateway,
       _defaultThreadTitle = defaultThreadTitle,
       _onLocaleSynced = onLocaleSynced,
       _clock = clock;

  final BistreEngineGateway _gateway;

  /// Wall clock for date-relative UI (sidebar day groups); tests inject a fixed instant.
  final DateTime Function() _clock;

  /// The current local time from the injected clock.
  DateTime now() => _clock();
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
  /// Live run per chat: thread id -> its streaming node id (U11).
  final Map<String, String> _liveRuns = <String, String>{};

  /// Live text of chats replying in the background, shown when one is opened mid-reply.
  final Map<String, LiveTurn> _backgroundTurns = <String, LiveTurn>{};

  /// P23: the message a search hit or a pinned reply asked to show; the feed scrolls to it.
  final ValueNotifier<String?> revealRequest = ValueNotifier<String?>(null);

  /// Chats whose reply finished while another chat was open (U11).
  final Set<String> _unreadDone = <String>{};

  /// Tool rows per chat (U4, U9).
  final Map<String, List<ToolActivityEntry>> _toolActivitiesByThread =
      <String, List<ToolActivityEntry>>{};

  /// Leaf notifier read only by the streaming message widget.
  /// Paced unless low memory or Reduce motion (the OS setting is checked by the notifier).
  late final LiveTurnNotifier liveTurn = LiveTurnNotifier()
    ..shouldPace = () => !_lowMemoryMode && !_settings.reduceMotionOverride;

  // Low-memory hardware mode (< 4 GB RAM or Android isLowRamDevice).
  bool _lowMemoryMode = false;
  bool _disposed = false;

  // Backoff notice (`diag.run.backoff_waiting`) shown with an inline `Retry now`.
  DateTime? _backoffRetryAt;

  // Chats deleted within the last 8 s (still restorable with Undo).
  final Map<String, Timer> _pendingThreadDeletes = <String, Timer>{};

  // Durable runs, mid-stream steering queue, and OS sleep guard state.
  List<EngineAgentRun> _agentRuns = const <EngineAgentRun>[];
  List<EngineSteeringMessage> _pendingSteering =
      const <EngineSteeringMessage>[];
  EnginePowerGuardStatus _powerStatus = const EnginePowerGuardStatus();
  bool _studioPaneOpen = false;

  // Agent workspace binding, MCP servers, context compaction, pin, and tool timeline.
  String _workspaceRootPath = '';

  /// The workspace's top-level entries for the `@` menu (U19), read once per root, off the
  /// keystroke path: `(name, isFolder)`, at most [kMaxWorkspaceEntries].
  List<(String, bool)> _workspaceEntries = const <(String, bool)>[];
  String? _workspaceEntriesRoot;
  Future<void>? _workspaceEntriesLoading;
  int _workspaceEntryLoads = 0;
  EngineWorkspaceHooksStatus? _workspaceHooks;
  List<EngineGroundingSource> _threadGrounding =
      const <EngineGroundingSource>[];
  String _webSearchEndpoint = '';
  List<EngineMcpServerConfig> _mcpServers = const <EngineMcpServerConfig>[];
  String? _pinnedContextNodeId;
  List<EngineCheckpoint> _checkpoints = const <EngineCheckpoint>[];

  // Rich studio tabs, attachments, session tree, and provider overrides.
  StudioTab _studioTab = StudioTab.runs;
  bool _sessionTreeOpen = false;
  bool _sessionTreePromptsOnly = false;
  List<ComposerAttachment> _attachments = const <ComposerAttachment>[];

  // Cross-chat memory, progressive skills, and scheduled cron jobs.
  List<EngineMemoryEntry> _memoryEntries = const <EngineMemoryEntry>[];
  List<EngineSkillIndex> _discoveredSkills = const <EngineSkillIndex>[];
  List<EngineCronJob> _cronJobs = const <EngineCronJob>[];

  // Writing & Roleplay Studio (CCv3 cards, Personas, Lorebook V3, Manuscript, Prompt Inspector).
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
  bool _updateBannerDismissed = false;
  String? _lastOtaDiagnostic;
  String? _lastOtaDetail;

  // Extended media, storage manager, hidden models, retry detail, TTS, and Live Voice state.
  String? _retryReasonDetail;

  /// Which automatic try the current wait follows (P20), from the notice's `attempt=`.
  int? _backoffAttempt;
  final Map<String, Set<String>> _hiddenModelsByProvider =
      <String, Set<String>>{};
  List<EngineStorageFileEntry> _storageFiles = const <EngineStorageFileEntry>[];
  String? _speakingNodeId;
  bool _dictatingActive = false;
  String? _liveVoiceSessionId;
  String _liveVoiceState = 'idle';
  String? _liveVoiceError;
  String _liveVoiceTranscript = '';

  // Sidebar, Inspector, Search, Overlays & Toast.
  bool _sidebarOpen = true;
  bool _inspectorOpen = false;
  SidebarTab _sidebarTab = SidebarTab.chat;

  /// Sidebar filter text; only the sidebar's chat list listens.
  final ValueNotifier<String> sidebarFilterQuery = ValueNotifier<String>('');
  String _activeAssistantId = 'default_assistant';

  bool _searchPanelOpen = false;

  /// Search query, scope, and results; listened to only by the search bar and the feed.
  final SearchNotifier search = SearchNotifier();
  String? _quotedExcerpt;
  bool _settingsOpen = false;
  SettingsTab _settingsTab = SettingsTab.providers;
  String? _editingAssistantId;
  bool _commandPaletteOpen = false;
  bool _tabSwitcherOpen = false;
  bool _pinnedPanelOpen = false;
  String _replyPrefill = '';
  Set<String> _pinnedNodeIds = <String>{};
  int _threadExtrasVersion = 0;
  String _profileAvatarPath = '';
  int? _activeChatSpendLimitMicros;
  Map<String, String> _toolPermissions = <String, String>{};
  ComposerAttachment? _previewingAttachment;
  EngineNode? _inspectingTurnNode;
  String? _highlightedSettingKey;
  DefaultModelsConfig _defaultModels = const DefaultModelsConfig();
  UiDisplayPrefs _uiPrefs = const UiDisplayPrefs();
  List<String> _workspaceFolders = const <String>[];
  String _activeGitBranch = '';
  List<WorkspaceProject> _projects = const <WorkspaceProject>[];
  String? _activeProjectId;
  bool _splitViewOpen = false;
  String? _splitSecondaryThreadId;

  /// The current toast; listened to only by the toast overlay.
  final ToastNotifier toast = ToastNotifier();

  // Draft & diagnostics.
  String _restoredDraft = '';
  int _draftEpoch = 0;

  /// Whether the composer draft is saved; only the composer's "Draft saved" label listens.
  final ValueNotifier<bool> draftSavedState = ValueNotifier<bool>(false);
  String? _lastDiagnosticKey;

  /// The provider's own words for the last error (P4), from the diagnostic's `reason=` detail.
  String? _lastDiagnosticReason;
  Timer? _draftDebounce;

  /// The draft waiting in [_draftDebounce], saved at once on pause, dispose, or shutdown (P27).
  ({String threadId, String text})? _pendingDraft;
  StreamSubscription<BistreEvent>? _eventSub;

  EngineSettings get settings => _settings;

  bool get isDark =>
      BistreThemePreset.isDarkFor(_settings.theme, systemIsDark: _systemIsDark);

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
  bool get showUpdateBanner =>
      (_updateCheck?.updateAvailable ?? false) && !_updateBannerDismissed;

  void dismissUpdateBanner() {
    if (_updateBannerDismissed) return;
    _updateBannerDismissed = true;
    _notify();
  }

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

  bool get isStreaming {
    final active = _activeThread?.id;
    return active != null && _liveRuns.containsKey(active);
  }

  /// Whether [threadId] currently has a live streaming reply (`activeStreamsBySession`).
  bool isThreadStreaming(String threadId) => _liveRuns.containsKey(threadId);

  /// Count of background chats currently streaming other than the active chat.
  int get backgroundStreamingCount =>
      _liveRuns.keys.where((t) => t != _activeThread?.id).length;

  /// Total recorded cost in micro-USD for the active conversation (`SessionSpend.kt`).
  int get activeThreadSpendMicros =>
      _nodes.fold<int>(0, (sum, n) => sum + (n.usageMeta?.costMicros ?? 0));

  /// Whether any assistant reply in the active conversation had unknown pricing.
  bool get activeThreadHasUnknownCost => _nodes.any(
    (n) =>
        n.role == 'assistant' &&
        (n.usageMeta?.hasTokens ?? false) &&
        !(n.usageMeta?.costKnown ?? true),
  );

  bool get tabSwitcherOpen => _tabSwitcherOpen;
  bool get pinnedPanelOpen => _pinnedPanelOpen;
  String get replyPrefill => _replyPrefill;
  Set<String> get pinnedNodeIds => _pinnedNodeIds;
  String get profileAvatarPath => _profileAvatarPath;
  int? get activeChatSpendLimitMicros => _activeChatSpendLimitMicros;
  Map<String, String> get toolPermissions => _toolPermissions;
  ComposerAttachment? get previewingAttachment => _previewingAttachment;
  EngineNode? get inspectingTurnNode => _inspectingTurnNode;
  String? get highlightedSettingKey => _highlightedSettingKey;

  bool isNodePinned(String nodeId) => _pinnedNodeIds.contains(nodeId);

  List<EngineNode> get pinnedNodes => <EngineNode>[
    for (final n in _nodes)
      if (_pinnedNodeIds.contains(n.id)) n,
  ];

  bool get hasAnyActiveRun =>
      _liveRuns.isNotEmpty || _agentRuns.any((r) => r.isActive);
  int get activeRunCount => _agentRuns.where((r) => r.isActive).length;
  String get streamingBuffer => liveTurn.value?.text ?? '';
  String get streamingThinkingBuffer => liveTurn.value?.thinking ?? '';
  String? get streamingNodeId {
    final active = _activeThread?.id;
    return active == null ? null : _liveRuns[active];
  }

  List<EngineAgentRun> get agentRuns => _agentRuns;
  List<EngineSteeringMessage> get pendingSteering => _pendingSteering;
  EnginePowerGuardStatus get powerStatus => _powerStatus;
  bool get studioPaneOpen => _studioPaneOpen;

  bool get sidebarOpen => _sidebarOpen;
  bool get inspectorOpen => _inspectorOpen;
  SidebarTab get sidebarTab => _sidebarTab;
  String get sidebarFilter => sidebarFilterQuery.value;

  bool get searchPanelOpen => _searchPanelOpen;
  bool get searchAllThreads => search.allThreads;
  String get searchQuery => search.query;
  List<EngineSearchHit> get searchHits => search.hits;
  String? get quotedExcerpt => _quotedExcerpt;

  bool get settingsOpen => _settingsOpen;
  SettingsTab get settingsTab => _settingsTab;
  String? get editingAssistantId => _editingAssistantId;
  bool get commandPaletteOpen => _commandPaletteOpen;
  L10nKey? get toastKey => toast.value?.key;
  L10nKey? get toastActionKey => toast.value?.actionKey;
  VoidCallback? get toastAction => toast.value?.onAction;

  /// `true` on low-memory hardware: no overlay shadows, 30 fps streaming redraw.
  bool get lowMemoryMode => _lowMemoryMode;

  /// Applies low-memory mode (also used by tests and the gallery).
  void setLowMemoryMode(bool enabled) {
    _lowMemoryMode = enabled;
    liveTurn.minInterval = enabled ? kLowMemoryFrameInterval : Duration.zero;
    notifyListeners();
  }

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
    final threadId = _activeThread?.id;
    if (threadId == null || !_liveRuns.containsKey(threadId)) return;
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
  bool get draftSaved => draftSavedState.value;
  String? get lastDiagnosticKey => _lastDiagnosticKey;

  String? assistantNameFor(String assistantId) =>
      _assistants.where((a) => a.id == assistantId).firstOrNull?.name;

  static final RegExp _diagKeyPattern = RegExp(r'\bdiag\.[a-z0-9_.]+\b');

  static String extractDiagnosticKey(Object error) {
    final match = _diagKeyPattern.firstMatch(error.toString());
    return match?.group(0) ?? 'diag.internal.error';
  }

  static final RegExp _diagDetailPattern = RegExp(
    r'\bdiag\.[a-z0-9_.]+(?::|\s\()([A-Za-z0-9_.:-]+)',
  );

  /// The detail code after a diagnostic key (`diag.x:detail` or `diag.x (detail)`), if any.
  static String? extractDiagnosticDetail(Object error) =>
      _diagDetailPattern.firstMatch(error.toString())?.group(1);

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

  void clearDiagnostic() {
    if (_lastDiagnosticKey == null) return;
    _lastDiagnosticKey = null;
    _lastDiagnosticReason = null;
    notifyListeners();
  }

  /// What the provider itself said about the last error (P4), when it said anything.
  String? get lastDiagnosticReason =>
      _lastDiagnosticKey == null ? null : _lastDiagnosticReason;

  List<EngineThread> get filteredThreads {
    final q = sidebarFilterQuery.value.trim().toLowerCase();
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
    final childrenByParent = _childrenByParent;
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
    final siblings = _childrenByParent[parentKey];
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
    final siblings = _childrenByParent[parentKey];
    if (siblings == null || siblings.length <= 1) return;
    final current = _selectedChildIndex[parentKey] ?? (siblings.length - 1);
    final next = (current + delta).clamp(0, siblings.length - 1);
    _selectedChildIndex[parentKey] = next;
    notifyListeners();
  }

  /// Selects a specific sibling node under [parentKey] by its [nodeId] (e.g., 1-click undo after
  /// regenerating a reply while keeping the previous branch intact).
  void selectSiblingNodeById(String parentKey, String nodeId) {
    final siblings = _childrenByParent[parentKey];
    if (siblings == null) return;
    final idx = siblings.indexWhere((n) => n.id == nodeId);
    if (idx < 0) return;
    _selectedChildIndex[parentKey] = idx;
    notifyListeners();
  }

  /// U15: the children-by-parent index of the open chat, built once per node list (the
  /// list is replaced, never changed in place), instead of once per message per build.
  List<EngineNode>? _branchIndexFor;
  Map<String, List<EngineNode>> _branchIndex =
      const <String, List<EngineNode>>{};
  int _branchIndexBuilds = 0;

  Map<String, List<EngineNode>> get _childrenByParent {
    if (!identical(_branchIndexFor, _nodes)) {
      _branchIndex = _groupChildrenByParent(_nodes);
      _branchIndexFor = _nodes;
      _branchIndexBuilds++;
    }
    return _branchIndex;
  }

  /// How many times the branch index was built (tests check it is reused).
  @visibleForTesting
  int get debugBranchIndexBuilds => _branchIndexBuilds;

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

  BootState _bootState = BootState.loading;
  String? _bootDataDir;

  /// Event-stream re-subscriptions left before the failure is shown to the user.
  int _eventResubscribesLeft = _kMaxEventResubscribes;
  static const int _kMaxEventResubscribes = 3;

  /// Conversation limit of the active model (tokens), when a public model list reports it.
  /// [activeContextLimit], starting the lookup for a newly selected model.
  int? get activeContextLimitOrFetch {
    _ensureContextLimit();
    return activeContextLimit;
  }

  int? get activeContextLimit =>
      _contextLimitModel == activeModelId ? _contextLimit : null;
  int? _contextLimit;
  String _contextLimitModel = '';

  /// Looks up the active model's conversation limit once per model.
  void _ensureContextLimit() {
    final model = activeModelId;
    if (model.isEmpty || model == _contextLimitModel) return;
    _contextLimitModel = model;
    _contextLimit = null;
    unawaited(
      _gateway
          .modelContextTokens(model)
          .then((limit) {
            if (_contextLimitModel != model) return;
            _contextLimit = limit;
            notifyListeners();
          })
          .catchError((Object e) => _noteNonFatal('context_limit', e)),
    );
  }

  // --- Engine Event Bus ---

  void _handleEngineEvent(BistreEvent event) {
    switch (event) {
      case RunStartedEvent():
        if (event.threadId == _activeThread?.id) _backoffRetryAt = null;
        _onRunStarted(event.threadId, event.nodeId);
        unawaited(_syncAndroidService());
        unawaited(_refreshRunsAndPower());
        notifyListeners();
      case DeltaBatchEvent():
        // Leaf-only update: no notifyListeners() on the hot path.
        if (_backoffRetryAt != null && event.threadId == _activeThread?.id) {
          _backoffRetryAt = null;
          notifyListeners();
        }
        _onTextDelta(event.threadId, event.textDelta, event.nodeId);
      case ThinkingDeltaEvent():
        _onThinkingDelta(event.threadId, event.delta, event.nodeId);
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
            final siblings = _childrenByParent[parentKey];
            if (siblings != null && siblings.isNotEmpty) {
              _selectedChildIndex[parentKey] = siblings.length - 1;
            }
          }
          notifyListeners();
        }
      case RunFinishedEvent():
        _onRunFinished(
          event.threadId,
          event.nodeId,
          cancelled: event.cancelled,
        );
        if (event.threadId == _activeThread?.id) {
          unawaited(refreshThreadGrounding());
        }
        unawaited(_syncAndroidService());
        if (!event.cancelled && _uiPrefs.desktopNotifyOnComplete) {
          final finishedTitle =
              _threads
                  .where((t) => t.id == event.threadId)
                  .firstOrNull
                  ?.title ??
              _defaultThreadTitle;
          unawaited(() async {
            final focused = await BistreDesktopHost.isWindowFocused();
            if (!focused && !_disposed) {
              await BistreDesktopHost.showNotification(
                title: 'Bistre',
                body: finishedTitle,
                playSound: _uiPrefs.desktopNotifySound,
              );
            }
          }());
        }
        unawaited(_refreshAfterRun(event.threadId));
        notifyListeners();
      case DraftSavedEvent():
        // The save's own completion already set [draftSavedState]; the echo changes nothing,
        // so it must not rebuild the shell.
        break;
      case DiagnosticRaisedEvent():
        if (event.key == 'diag.run.backoff_waiting') {
          final raw = event.detailCode ?? '';
          final ms = int.tryParse(
            RegExp(r'retry_in_ms=(\d+)').firstMatch(raw)?.group(1) ?? '',
          );
          final reason = RegExp(r'reason=([^;]+)').firstMatch(raw)?.group(1);
          _backoffAttempt = int.tryParse(
            RegExp(r'(?:^|;)attempt=(\d+)').firstMatch(raw)?.group(1) ?? '',
          );
          _backoffRetryAt = ms == null
              ? null
              : DateTime.now().add(Duration(milliseconds: ms));
          // W8: only the reason's key is kept; the notice shows it in words (the raw
          // technical detail was shown verbatim).
          _retryReasonDetail = reason;
        } else {
          _lastDiagnosticKey = event.key;
          _lastDiagnosticReason = RegExp(r'(?:^|;)reason=([^;]+)')
              .firstMatch(event.detailCode ?? '')
              ?.group(1);
        }
        notifyListeners();
      case LiveVoiceStateEvent():
        _handleLiveVoiceStateEvent(event);
      case LiveVoiceTranscriptEvent():
        _handleLiveVoiceTranscriptEvent(event);
      case LiveVoiceAudioEvent():
        _handleLiveVoiceAudioEvent(event);
      case ToolApprovalRequestedEvent():
        // U4: recorded for its own chat, open or not; it waits there until answered.
        recordToolActivity(
          ToolActivityEntry(
            id: event.callId,
            toolName: event.toolName,
            summary: event.argumentsJson,
            status: 'awaiting_approval',
            riskTier: event.riskTier,
            outputText: event.argumentsJson,
            threadId: event.threadId,
            runId: event.runId,
          ),
        );
      case ToolExecutionUpdatedEvent():
        {
          recordToolActivity(
            ToolActivityEntry(
              id: event.callId,
              toolName: event.toolName,
              summary: event.summary,
              status: event.status,
              riskTier: event.riskTier,
              outputText: event.outputText,
              diffText: event.diffText,
              checkpointId: event.checkpointId,
              durationMs: event.durationMs,
              threadId: event.threadId,
              runId: event.runId,
            ),
          );
        }
      case LocalePackVerifiedEvent():
        notifyListeners();
      case EventsLaggedEvent():
        final threadId = _activeThread?.id;
        if (threadId != null) unawaited(_refreshAfterRun(threadId));
        unawaited(_reconcileLiveRuns());
      case UnknownEngineEvent():
        debugPrint('Ignoring unknown engine event kind: ${event.kind}');
    }
  }

  Future<void> _refreshAfterRun(String threadId) async {
    try {
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      if (_activeThread?.id == threadId) {
        final nodes = await _gateway.listNodes(threadId);
        // The user may have switched chats while the list loaded.
        if (_activeThread?.id == threadId) _nodes = nodes;
      }
      _walletSpendMicros = await _gateway.getWalletSpendMicros();
      _walletDailySpendMicros = await _gateway.getWalletDailySpendMicros();
      _health = await _gateway.getHealth();
      _storageStats = await _gateway.getStorageStats();
      _agentRuns = await _gateway.listAgentRuns(limit: 30);
      _powerStatus = await _gateway.powerGuardStatus();
      if (_activeThread?.id == threadId) {
        final steering = await _gateway.listPendingSteering(threadId);
        if (_activeThread?.id == threadId) _pendingSteering = steering;
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

  /// Bumped on every thread switch; async loads for an older switch are discarded so fast
  /// switching can never show one chat's messages under another chat.
  int _threadGeneration = 0;

  /// Latest search request; older responses are dropped.
  int _searchSeq = 0;

  /// Pause after the last search keystroke before querying.
  static const Duration searchDebounce = Duration(milliseconds: 150);

  /// Open chat tabs, most recently opened last (bounded to [_kMaxOpenTabs]).
  final List<String> _openTabIds = <String>[];
  static const int _kMaxOpenTabs = 8;

  /// The chat being opened while its messages and draft load; sending waits for it (U1).
  String? _switchingToThreadId;

  /// True while a chat switch is loading: the composer must not send yet.
  bool get isSwitchingThread => _switchingToThreadId != null;

  /// Whether async work started for [threadId] at [generation] may still change chat state:
  /// the same chat is open and no switch happened since (U2).
  bool _isStillOn(String threadId, int generation) =>
      !_disposed &&
      generation == _threadGeneration &&
      _activeThread?.id == threadId;

  /// Opens [thread]. Its messages, draft, pins and checkpoints load first and are committed
  /// together with the active chat, so nothing can act on a half-switched state (U1).
  Future<void> _activateThread(EngineThread thread) async {
    final generation = ++_threadGeneration;
    if (!_openTabIds.contains(thread.id)) {
      _openTabIds.add(thread.id);
      if (_openTabIds.length > _kMaxOpenTabs) _openTabIds.removeAt(0);
    }
    _switchingToThreadId = thread.id;
    try {
      await _loadAndCommitThread(thread, generation);
    } finally {
      if (generation == _threadGeneration) _switchingToThreadId = null;
    }
  }

  Future<void> _loadAndCommitThread(EngineThread thread, int generation) async {
    final nodes = await _gateway.listNodes(thread.id);
    final steering = await _gateway.listPendingSteering(thread.id);
    final pin = await _gateway.getContextStartPin(thread.id);
    final checkpoints = await _gateway.listCheckpoints(thread.id);
    final draft = await _gateway.loadDraft(thread.id);
    final query = search.query;
    final hits = query.isNotEmpty && !search.allThreads
        ? await _gateway.searchNodes(query, threadId: thread.id)
        : null;
    if (generation != _threadGeneration || _disposed) return;
    _swapLiveTurnFor(_activeThread?.id, thread.id);
    _unreadDone.remove(thread.id);
    _activeThread = thread;
    _activeAssistantId = thread.assistantId;
    _selectedChildIndex.clear();
    _quotedExcerpt = null;
    _nodes = nodes;
    _pendingSteering = steering;
    _pinnedContextNodeId = pin;
    _checkpoints = checkpoints;
    _activeGreetingIndex = 0;
    if (thread.mode == 'write') {
      unawaited(refreshStoryStudio());
    } else {
      _manuscriptViewActive = false;
    }
    _restoredDraft = draft ?? '';
    _draftEpoch++;
    draftSavedState.value = _restoredDraft.isNotEmpty;
    if (hits != null && search.query == query) search.update(hits: hits);
    unawaited(_loadThreadKvExtras(thread.id, generation));
    unawaited(refreshThreadGrounding());
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
        if (_activeThread?.id == updated.id) _activeThread = updated;
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
        if (_activeThread?.id == updated.id) _activeThread = updated;
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
      if (_activeThread?.id == updated.id) _activeThread = updated;
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

  /// Latest settings change; an older save's response never overwrites a newer value.
  int _settingsSeq = 0;

  /// Quiet changes (sliders, toggles) are applied at once and saved after this pause, so a
  /// drag writes once instead of on every tick.
  static const Duration settingsSaveDebounce = Duration(milliseconds: 200);

  Timer? _settingsSaveTimer;
  EngineSettings? _pendingQuietSettings;

  bool _engineShutDown = false;

  /// Flushes pending work (deleted chats, window bounds, quiet settings) and shuts the engine
  /// down, which checkpoints the WAL and lets cancelled runs record their final state (A-S11).
  /// Called once on app exit; later calls do nothing.
  Future<void> shutdownEngine() async {
    if (_engineShutDown) return;
    _engineShutDown = true;
    _settingsSaveTimer?.cancel();
    final unsaved = _pendingQuietSettings;
    _pendingQuietSettings = null;
    try {
      await flushPendingDraft();
      await flushPendingDeletes();
      await persistCurrentWindowBounds();
      if (unsaved != null) await _gateway.saveSettings(unsaved);
    } catch (e) {
      _noteNonFatal('shutdown_flush', e);
    }
    try {
      await _gateway.shutdown();
    } catch (e) {
      _noteNonFatal('engine_shutdown', e);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    revealRequest.dispose();
    unawaited(flushPendingDraft());
    _settingsSaveTimer?.cancel();
    final unsaved = _pendingQuietSettings;
    if (unsaved != null) unawaited(_gateway.saveSettings(unsaved));
    toast.dispose();
    search.dispose();
    sidebarFilterQuery.dispose();
    contextBreakdown.dispose();
    draftSavedState.dispose();
    // The user deleted these chats; closing the app inside the Undo window must not bring
    // them back.
    unawaited(flushPendingDeletes());
    liveTurn.dispose();
    appearance.dispose();
    unawaited(_eventSub?.cancel());
    super.dispose();
  }
}
