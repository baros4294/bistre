import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitType;

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
import '../chat/media_options_control.dart';
import '../chat/plain_preview.dart';
import '../chat/tool_timeline_view.dart';
import 'live_turn_notifier.dart';

part 'folio_controller_boot.dart';
part 'folio_controller_catalog.dart';
part 'folio_controller_chat.dart';
part 'folio_controller_extras.dart';
part 'folio_controller_library.dart';
part 'folio_controller_media.dart';
part 'folio_controller_navigation.dart';
part 'folio_controller_paging.dart';
part 'folio_controller_projects.dart';
part 'folio_controller_runs.dart';
part 'folio_controller_session.dart';
part 'folio_controller_shortcuts.dart';
part 'folio_controller_studio.dart';
part 'folio_controller_threads.dart';

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
  projects,
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

  /// What the next request sends for the visible branch, by category, from core. Only
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
    textSizePercent: _uiPrefs.textSizePercent,
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
    String? pendingCrashReport,
  }) : _gateway = gateway,
       _defaultThreadTitle = defaultThreadTitle,
       _defaultTitles = <String>{defaultThreadTitle},
       _onLocaleSynced = onLocaleSynced,
       _clock = clock,
       _pendingCrashReport = pendingCrashReport;

  String? _pendingCrashReport;

  /// Redacted local crash report captured from the previous session, if any.
  String? get pendingCrashReport => _pendingCrashReport;

  /// Sets or clears the pending local crash report shown in the next-launch banner.
  void setPendingCrashReport(String? report) {
    final clean = report?.trim();
    _pendingCrashReport = (clean == null || clean.isEmpty) ? null : clean;
    notifyListeners();
  }

  /// Dismisses the next-launch crash report banner.
  void dismissCrashReport() {
    if (_pendingCrashReport == null) return;
    _pendingCrashReport = null;
    notifyListeners();
  }

  /// Copies the redacted local crash report to the clipboard and clears the banner.
  Future<void> copyCrashReport() async {
    final report = _pendingCrashReport;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report));
    _pendingCrashReport = null;
    showToast(L10nKey.toastCopied);
    notifyListeners();
  }

  final BistreEngineGateway _gateway;

  /// Wall clock for date-relative UI (sidebar day groups); tests inject a fixed instant.
  final DateTime Function() _clock;

  /// The current local time from the injected clock.
  DateTime now() => _clock();
  String _defaultThreadTitle;

  /// Every default title this session has used, so a chat made before a language switch
  /// still counts as untitled.
  final Set<String> _defaultTitles;

  /// The "New chat" title in the current language; the app sets it again on every language
  /// change, so new chats are named in the language showing when they are made.
  set defaultThreadTitle(String title) {
    _defaultThreadTitle = title;
    if (_defaultTitles.length < 16) _defaultTitles.add(title);
  }

  /// Whether [title] is a default "New chat" title in any language used this session.
  bool isDefaultThreadTitle(String title) => _defaultTitles.contains(title);
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

  /// Whether the open chat has messages older than [_nodes] (see `FolioControllerPaging`).
  bool _hasEarlierNodes = false;
  bool _loadingEarlierNodes = false;

  /// Core's spend of a partly loaded chat; `null` when every message is loaded.
  int? _partialThreadSpendMicros;
  final Map<String, int> _selectedChildIndex = <String, int>{};

  // Streaming state driven by Rust 16ms coalesced DeltaBatch events. Text/thinking deltas
  // update ONLY the leaf `liveTurn` notifier (zero shell/sidebar rebuilds per delta).
  /// Live run per chat: thread id -> its streaming node id.
  final Map<String, String> _liveRuns = <String, String>{};

  /// Live text of chats replying in the background, shown when one is opened mid-reply.
  final Map<String, LiveTurn> _backgroundTurns = <String, LiveTurn>{};

  /// The message a search hit or a pinned reply asked to show; the feed scrolls to it.
  final ValueNotifier<String?> revealRequest = ValueNotifier<String?>(null);

  /// Chats whose reply finished while another chat was open.
  final Set<String> _unreadDone = <String>{};

  /// Tool rows per chat.
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

  /// The workspace's top-level entries for the `@` menu, read once per root, off the
  /// keystroke path: `(name, isFolder)`, at most [kMaxWorkspaceEntries].
  List<(String, bool)> _workspaceEntries = const <(String, bool)>[];
  String? _workspaceEntriesRoot;
  Future<void>? _workspaceEntriesLoading;
  int _workspaceEntryLoads = 0;
  EngineWorkspaceHooksStatus? _workspaceHooks;
  List<EngineGroundingSource> _threadGrounding =
      const <EngineGroundingSource>[];

  /// [_threadGrounding] grouped by reply, rebuilt with it: the feed asks per reply per build.
  Map<String, List<EngineGroundingSource>> _groundingByNode =
      const <String, List<EngineGroundingSource>>{};
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
  EngineInspectedRequest? _inspectedRequest;
  String? _inspectedRequestError;
  final Set<String> _autoTitledThreads = <String>{};
  final _ChatActionState _chatState = _ChatActionState();
  final _LibraryState _library = _LibraryState();
  int _historyMessageLimit = 0;
  bool _manuscriptViewActive = false;
  int _activeGreetingIndex = 0;

  // OTA Update state.
  EngineUpdateCheck? _updateCheck;
  bool _checkingUpdates = false;
  bool _stagingUpdate = false;
  bool _installingUpdate = false;
  ComposerAttachment? _playingAttachment;
  String? _pendingUpdateVersion;
  bool _updateBannerDismissed = false;
  String? _lastOtaDiagnostic;
  String? _lastOtaDetail;

  // Extended media, storage manager, hidden models, retry detail, TTS, and Live Voice state.
  String? _retryReasonDetail;

  /// Which automatic try the current wait follows, from the notice's `attempt=`.
  int? _backoffAttempt;
  final Map<String, Set<String>> _hiddenModelsByProvider =
      <String, Set<String>>{};
  List<EngineStorageFileEntry> _storageFiles = const <EngineStorageFileEntry>[];
  String? _speakingNodeId;
  bool _dictatingActive = false;
  String? _liveVoiceSessionId;
  String _liveVoiceState = 'idle';

  /// The diagnostic key of a failed live voice session, until it is dismissed.
  String? _liveVoiceError;
  String _liveVoiceTranscript = '';
  bool _liveVoiceTranscriptIsUser = false;

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
  List<EngineProject> _projects = const <EngineProject>[];
  String? _editingProjectId;
  String _branchRoot = '';
  bool _splitViewOpen = false;
  String? _splitSecondaryThreadId;

  /// The current toast; listened to only by the toast overlay.
  final ToastNotifier toast = ToastNotifier();

  // Draft & diagnostics.
  String _restoredDraft = '';
  int _draftEpoch = 0;
  ({int epoch, String text})? _draftInsert;

  /// Whether the composer draft is saved; only the composer's "Draft saved" label listens.
  final ValueNotifier<bool> draftSavedState = ValueNotifier<bool>(false);
  String? _lastDiagnosticKey;

  /// The provider's own words for the last error, from the diagnostic's `reason=` detail.
  String? _lastDiagnosticReason;
  Timer? _draftDebounce;

  /// The draft waiting in [_draftDebounce], saved at once on pause, dispose, or shutdown.
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
    readingWidthPx: _settings.readingWidthPx.toDouble().clamp(
      BistreSpacing.readingWidthMin,
      BistreSpacing.readingWidthMax,
    ),
    codeScale: _uiPrefs.codeTextPercent / 100.0,
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
  bool get installingUpdate => _installingUpdate;

  /// The downloaded, verified version Install update runs; null when none is staged.
  String? get pendingUpdateVersion => _pendingUpdateVersion;
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
      _partialThreadSpendMicros ??
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

  void clearDiagnostic() {
    if (_lastDiagnosticKey == null) return;
    _lastDiagnosticKey = null;
    _lastDiagnosticReason = null;
    notifyListeners();
  }

  /// What the provider itself said about the last error, when it said anything.
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
      final selected =
          (_selectedChildIndex[parentKey] ?? _defaultChildIndex(parentKey))
              .clamp(0, siblings.length - 1);
      final chosen = siblings[selected];
      if (!visited.add(chosen.id)) break;
      result.add(chosen);
      currentParent = chosen.id;
    }
    return result;
  }

  BranchSlotInfo? branchInfoFor(EngineNode node) {
    final parentKey = _parentKeyOf(node);
    // Siblings of the first loaded messages may be on an unloaded page.
    if (parentKey == '__root__' && _hasEarlierNodes) return null;
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

  /// The children-by-parent index of the open chat, built once per node list (the
  /// list is replaced, never changed in place), instead of once per message per build.
  List<EngineNode>? _branchIndexFor;
  Map<String, List<EngineNode>> _branchIndex =
      const <String, List<EngineNode>>{};
  int _branchIndexBuilds = 0;

  /// Interrupted runs whose notice the user closed this session.
  final Set<String> _dismissedInterruptions = <String>{};

  /// Ids of the loaded messages, built with the branch index.
  Set<String> _loadedIds = const <String>{};

  /// The first loaded ancestor of the newest message, built with the branch index.
  String? _newestBranchTopId;

  Map<String, List<EngineNode>> get _childrenByParent {
    if (!identical(_branchIndexFor, _nodes)) {
      _loadedIds = <String>{for (final n in _nodes) n.id};
      _branchIndex = _groupChildrenByParent(_nodes, _loadedIds);
      _newestBranchTopId = _topLoadedAncestor(_nodes.lastOrNull);
      _branchIndexFor = _nodes;
      _branchIndexBuilds++;
    }
    return _branchIndex;
  }

  /// How many times the branch index was built (tests check it is reused).
  @visibleForTesting
  int get debugBranchIndexBuilds => _branchIndexBuilds;

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
      _contextLimitModel == _contextLimitKey ? _contextLimit : null;
  int? _contextLimit;
  String _contextLimitModel = '';

  /// What the active model writes and its format choices; null while unknown.
  EngineModelCatalogInfo? get activeModelInfo {
    _ensureContextLimit();
    return _contextLimitModel == _contextLimitKey ? _modelInfo : null;
  }

  EngineModelCatalogInfo? _modelInfo;

  /// The picture and video format chosen in the composer (`settings.media_options`).
  MediaOptions get mediaOptions => _mediaOptions;
  MediaOptions _mediaOptions = const MediaOptions();

  /// The limit depends on who serves the model, so it is kept per provider and model.
  String get _contextLimitKey => '${activeProvider?.id ?? ''}\n$activeModelId';

  /// Looks up the active model's conversation limit and catalog facts once per model.
  void _ensureContextLimit() {
    final providerId = activeProvider?.id ?? '';
    final model = activeModelId;
    final key = _contextLimitKey;
    if (providerId.isEmpty || model.isEmpty || key == _contextLimitModel) {
      return;
    }
    _contextLimitModel = key;
    _contextLimit = null;
    _modelInfo = null;
    unawaited(
      _gateway
          .lookupModelCatalogInfo(providerId, model)
          .then((info) {
            if (_contextLimitModel != key) return;
            _modelInfo = info;
            notifyListeners();
          })
          .catchError((Object e) => _noteNonFatal('model_info', e)),
    );
    unawaited(
      _gateway
          .modelContextTokens(providerId, model)
          .then((limit) {
            if (_contextLimitModel != key) return;
            _contextLimit = limit;
            notifyListeners();
          })
          .catchError((Object e) => _noteNonFatal('context_limit', e)),
    );
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

  /// The chat being opened while its messages and draft load; sending waits for it.
  String? _switchingToThreadId;

  /// True while a chat switch is loading: the composer must not send yet.
  bool get isSwitchingThread => _switchingToThreadId != null;

  /// Latest settings change; an older save's response never overwrites a newer value.
  int _settingsSeq = 0;

  /// Quiet changes (sliders, toggles) are applied at once and saved after this pause, so a
  /// drag writes once instead of on every tick.
  static const Duration settingsSaveDebounce = Duration(milliseconds: 200);

  Timer? _settingsSaveTimer;
  EngineSettings? _pendingQuietSettings;

  bool _engineShutDown = false;

  /// Flushes pending work (deleted chats, window bounds, quiet settings) and shuts the engine
  /// down, which checkpoints the WAL and lets cancelled runs record their final state.
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
