part of 'folio_controller.dart';

/// Persisted Default Models configuration (`kv_meta` key: `settings.default_models`).
@immutable
class DefaultModelsConfig {
  const DefaultModelsConfig({
    this.globalProviderId = '',
    this.globalModelId = '',
    this.titleFollowGlobal = true,
    this.titleProviderId = '',
    this.titleModelId = '',
    this.titlePromptTemplate = defaultTitlePrompt,
    this.summaryFollowGlobal = true,
    this.summaryProviderId = '',
    this.summaryModelId = '',
    this.translationFollowGlobal = true,
    this.translationProviderId = '',
    this.translationModelId = '',
    this.translationTargetLanguage = 'English',
  });

  static const String defaultTitlePrompt =
      'Generate a concise, natural 3 to 6 word title summarizing this conversation. Return ONLY the title text without quotes or trailing punctuation.';

  final String globalProviderId;
  final String globalModelId;
  final bool titleFollowGlobal;
  final String titleProviderId;
  final String titleModelId;
  final String titlePromptTemplate;
  final bool summaryFollowGlobal;
  final String summaryProviderId;
  final String summaryModelId;
  final bool translationFollowGlobal;
  final String translationProviderId;
  final String translationModelId;
  final String translationTargetLanguage;

  DefaultModelsConfig copyWith({
    String? globalProviderId,
    String? globalModelId,
    bool? titleFollowGlobal,
    String? titleProviderId,
    String? titleModelId,
    String? titlePromptTemplate,
    bool? summaryFollowGlobal,
    String? summaryProviderId,
    String? summaryModelId,
    bool? translationFollowGlobal,
    String? translationProviderId,
    String? translationModelId,
    String? translationTargetLanguage,
  }) => DefaultModelsConfig(
    globalProviderId: globalProviderId ?? this.globalProviderId,
    globalModelId: globalModelId ?? this.globalModelId,
    titleFollowGlobal: titleFollowGlobal ?? this.titleFollowGlobal,
    titleProviderId: titleProviderId ?? this.titleProviderId,
    titleModelId: titleModelId ?? this.titleModelId,
    titlePromptTemplate: titlePromptTemplate ?? this.titlePromptTemplate,
    summaryFollowGlobal: summaryFollowGlobal ?? this.summaryFollowGlobal,
    summaryProviderId: summaryProviderId ?? this.summaryProviderId,
    summaryModelId: summaryModelId ?? this.summaryModelId,
    translationFollowGlobal:
        translationFollowGlobal ?? this.translationFollowGlobal,
    translationProviderId: translationProviderId ?? this.translationProviderId,
    translationModelId: translationModelId ?? this.translationModelId,
    translationTargetLanguage:
        translationTargetLanguage ?? this.translationTargetLanguage,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'globalProviderId': globalProviderId,
    'globalModelId': globalModelId,
    'titleFollowGlobal': titleFollowGlobal,
    'titleProviderId': titleProviderId,
    'titleModelId': titleModelId,
    'titlePromptTemplate': titlePromptTemplate,
    'summaryFollowGlobal': summaryFollowGlobal,
    'summaryProviderId': summaryProviderId,
    'summaryModelId': summaryModelId,
    'translationFollowGlobal': translationFollowGlobal,
    'translationProviderId': translationProviderId,
    'translationModelId': translationModelId,
    'translationTargetLanguage': translationTargetLanguage,
  };

  static DefaultModelsConfig fromJson(Map<String, Object?> m) =>
      DefaultModelsConfig(
        globalProviderId: m['globalProviderId'] as String? ?? '',
        globalModelId: m['globalModelId'] as String? ?? '',
        titleFollowGlobal: m['titleFollowGlobal'] as bool? ?? true,
        titleProviderId: m['titleProviderId'] as String? ?? '',
        titleModelId: m['titleModelId'] as String? ?? '',
        titlePromptTemplate:
            m['titlePromptTemplate'] as String? ?? defaultTitlePrompt,
        summaryFollowGlobal: m['summaryFollowGlobal'] as bool? ?? true,
        summaryProviderId: m['summaryProviderId'] as String? ?? '',
        summaryModelId: m['summaryModelId'] as String? ?? '',
        translationFollowGlobal: m['translationFollowGlobal'] as bool? ?? true,
        translationProviderId: m['translationProviderId'] as String? ?? '',
        translationModelId: m['translationModelId'] as String? ?? '',
        translationTargetLanguage:
            m['translationTargetLanguage'] as String? ?? 'English',
      );
}

/// Extended Preferences & Desktop App configuration (`kv_meta` key: `settings.ui_prefs`).
@immutable
class UiDisplayPrefs {
  const UiDisplayPrefs({
    this.messageNavVisibility = 'while_scrolling',
    this.showUserAvatar = true,
    this.showUserName = true,
    this.showUserTimestamp = true,
    this.showModelIcon = true,
    this.showModelName = true,
    this.showProviderAfterModel = true,
    this.showThinkingCards = true,
    this.showToolCards = true,
    this.showFilesBelowReplies = true,
    this.renderUserMarkdown = true,
    this.renderMathFormulas = true,
    this.autoCollapseCodeBlocks = false,
    this.autoCollapseThinking = true,
    this.collapseLongMessages = false,
    this.confirmBeforeDeletingChat = false,
    this.confirmBeforeRegenerating = false,
    this.showChatListDates = true,
    this.codeSyntaxThemeLight = 'sepia_warm',
    this.codeSyntaxThemeDark = 'espresso_amber',
    this.desktopNotifyOnComplete = true,
    this.desktopNotifySound = false,
    this.runOnStartup = false,
    this.systemTrayEnabled = false,
    this.quickEntryShortcut = 'Alt+Space',
    this.computerUseEnabled = false,
  });

  final String messageNavVisibility; // always | while_scrolling | hidden
  final bool showUserAvatar;
  final bool showUserName;
  final bool showUserTimestamp;
  final bool showModelIcon;
  final bool showModelName;
  final bool showProviderAfterModel;
  final bool showThinkingCards;
  final bool showToolCards;
  final bool showFilesBelowReplies;
  final bool renderUserMarkdown;
  final bool renderMathFormulas;
  final bool autoCollapseCodeBlocks;
  final bool autoCollapseThinking;
  final bool collapseLongMessages;
  final bool confirmBeforeDeletingChat;
  final bool confirmBeforeRegenerating;
  final bool showChatListDates;
  final String codeSyntaxThemeLight;
  final String codeSyntaxThemeDark;
  final bool desktopNotifyOnComplete;
  final bool desktopNotifySound;
  final bool runOnStartup;
  final bool systemTrayEnabled;
  final String quickEntryShortcut;
  final bool computerUseEnabled;

  UiDisplayPrefs copyWith({
    String? messageNavVisibility,
    bool? showUserAvatar,
    bool? showUserName,
    bool? showUserTimestamp,
    bool? showModelIcon,
    bool? showModelName,
    bool? showProviderAfterModel,
    bool? showThinkingCards,
    bool? showToolCards,
    bool? showFilesBelowReplies,
    bool? renderUserMarkdown,
    bool? renderMathFormulas,
    bool? autoCollapseCodeBlocks,
    bool? autoCollapseThinking,
    bool? collapseLongMessages,
    bool? confirmBeforeDeletingChat,
    bool? confirmBeforeRegenerating,
    bool? showChatListDates,
    String? codeSyntaxThemeLight,
    String? codeSyntaxThemeDark,
    bool? desktopNotifyOnComplete,
    bool? desktopNotifySound,
    bool? runOnStartup,
    bool? systemTrayEnabled,
    String? quickEntryShortcut,
    bool? computerUseEnabled,
  }) => UiDisplayPrefs(
    messageNavVisibility: messageNavVisibility ?? this.messageNavVisibility,
    showUserAvatar: showUserAvatar ?? this.showUserAvatar,
    showUserName: showUserName ?? this.showUserName,
    showUserTimestamp: showUserTimestamp ?? this.showUserTimestamp,
    showModelIcon: showModelIcon ?? this.showModelIcon,
    showModelName: showModelName ?? this.showModelName,
    showProviderAfterModel:
        showProviderAfterModel ?? this.showProviderAfterModel,
    showThinkingCards: showThinkingCards ?? this.showThinkingCards,
    showToolCards: showToolCards ?? this.showToolCards,
    showFilesBelowReplies: showFilesBelowReplies ?? this.showFilesBelowReplies,
    renderUserMarkdown: renderUserMarkdown ?? this.renderUserMarkdown,
    renderMathFormulas: renderMathFormulas ?? this.renderMathFormulas,
    autoCollapseCodeBlocks:
        autoCollapseCodeBlocks ?? this.autoCollapseCodeBlocks,
    autoCollapseThinking: autoCollapseThinking ?? this.autoCollapseThinking,
    collapseLongMessages: collapseLongMessages ?? this.collapseLongMessages,
    confirmBeforeDeletingChat:
        confirmBeforeDeletingChat ?? this.confirmBeforeDeletingChat,
    confirmBeforeRegenerating:
        confirmBeforeRegenerating ?? this.confirmBeforeRegenerating,
    showChatListDates: showChatListDates ?? this.showChatListDates,
    codeSyntaxThemeLight: codeSyntaxThemeLight ?? this.codeSyntaxThemeLight,
    codeSyntaxThemeDark: codeSyntaxThemeDark ?? this.codeSyntaxThemeDark,
    desktopNotifyOnComplete:
        desktopNotifyOnComplete ?? this.desktopNotifyOnComplete,
    desktopNotifySound: desktopNotifySound ?? this.desktopNotifySound,
    runOnStartup: runOnStartup ?? this.runOnStartup,
    systemTrayEnabled: systemTrayEnabled ?? this.systemTrayEnabled,
    quickEntryShortcut: quickEntryShortcut ?? this.quickEntryShortcut,
    computerUseEnabled: computerUseEnabled ?? this.computerUseEnabled,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'messageNavVisibility': messageNavVisibility,
    'showUserAvatar': showUserAvatar,
    'showUserName': showUserName,
    'showUserTimestamp': showUserTimestamp,
    'showModelIcon': showModelIcon,
    'showModelName': showModelName,
    'showProviderAfterModel': showProviderAfterModel,
    'showThinkingCards': showThinkingCards,
    'showToolCards': showToolCards,
    'showFilesBelowReplies': showFilesBelowReplies,
    'renderUserMarkdown': renderUserMarkdown,
    'renderMathFormulas': renderMathFormulas,
    'autoCollapseCodeBlocks': autoCollapseCodeBlocks,
    'autoCollapseThinking': autoCollapseThinking,
    'collapseLongMessages': collapseLongMessages,
    'confirmBeforeDeletingChat': confirmBeforeDeletingChat,
    'confirmBeforeRegenerating': confirmBeforeRegenerating,
    'showChatListDates': showChatListDates,
    'codeSyntaxThemeLight': codeSyntaxThemeLight,
    'codeSyntaxThemeDark': codeSyntaxThemeDark,
    'desktopNotifyOnComplete': desktopNotifyOnComplete,
    'desktopNotifySound': desktopNotifySound,
    'runOnStartup': runOnStartup,
    'systemTrayEnabled': systemTrayEnabled,
    'quickEntryShortcut': quickEntryShortcut,
    'computerUseEnabled': computerUseEnabled,
  };

  static UiDisplayPrefs fromJson(Map<String, Object?> m) => UiDisplayPrefs(
    messageNavVisibility:
        m['messageNavVisibility'] as String? ?? 'while_scrolling',
    showUserAvatar: m['showUserAvatar'] as bool? ?? true,
    showUserName: m['showUserName'] as bool? ?? true,
    showUserTimestamp: m['showUserTimestamp'] as bool? ?? true,
    showModelIcon: m['showModelIcon'] as bool? ?? true,
    showModelName: m['showModelName'] as bool? ?? true,
    showProviderAfterModel: m['showProviderAfterModel'] as bool? ?? true,
    showThinkingCards: m['showThinkingCards'] as bool? ?? true,
    showToolCards: m['showToolCards'] as bool? ?? true,
    showFilesBelowReplies: m['showFilesBelowReplies'] as bool? ?? true,
    renderUserMarkdown: m['renderUserMarkdown'] as bool? ?? true,
    renderMathFormulas: m['renderMathFormulas'] as bool? ?? true,
    autoCollapseCodeBlocks: m['autoCollapseCodeBlocks'] as bool? ?? false,
    autoCollapseThinking: m['autoCollapseThinking'] as bool? ?? true,
    collapseLongMessages: m['collapseLongMessages'] as bool? ?? false,
    confirmBeforeDeletingChat: m['confirmBeforeDeletingChat'] as bool? ?? false,
    confirmBeforeRegenerating: m['confirmBeforeRegenerating'] as bool? ?? false,
    showChatListDates: m['showChatListDates'] as bool? ?? true,
    codeSyntaxThemeLight: m['codeSyntaxThemeLight'] as String? ?? 'sepia_warm',
    codeSyntaxThemeDark:
        m['codeSyntaxThemeDark'] as String? ?? 'espresso_amber',
    desktopNotifyOnComplete: m['desktopNotifyOnComplete'] as bool? ?? true,
    desktopNotifySound: m['desktopNotifySound'] as bool? ?? false,
    runOnStartup: m['runOnStartup'] as bool? ?? false,
    systemTrayEnabled: m['systemTrayEnabled'] as bool? ?? false,
    quickEntryShortcut: m['quickEntryShortcut'] as String? ?? 'Alt+Space',
    computerUseEnabled: m['computerUseEnabled'] as bool? ?? false,
  );
}

/// Per-model limits & USD/1M pricing overrides configured in Providers → Model Settings.
@immutable
class ModelConfigOverride {
  const ModelConfigOverride({
    this.contextLimit = 128000,
    this.maxOutputTokens = 8192,
    this.inputPerMillion = '',
    this.outputPerMillion = '',
    this.cacheReadPerMillion = '',
    this.cacheWritePerMillion = '',
    this.cacheWriteLongPerMillion = '',
    this.reasoningPerMillion = '',
  });

  final int contextLimit;
  final int maxOutputTokens;
  final String inputPerMillion;
  final String outputPerMillion;
  final String cacheReadPerMillion;
  final String cacheWritePerMillion;
  final String cacheWriteLongPerMillion;
  final String reasoningPerMillion;

  Map<String, Object?> toJson() => <String, Object?>{
    'contextLimit': contextLimit,
    'maxOutputTokens': maxOutputTokens,
    'inputPerMillion': inputPerMillion,
    'outputPerMillion': outputPerMillion,
    'cacheReadPerMillion': cacheReadPerMillion,
    'cacheWritePerMillion': cacheWritePerMillion,
    'cacheWriteLongPerMillion': cacheWriteLongPerMillion,
    'reasoningPerMillion': reasoningPerMillion,
  };

  static ModelConfigOverride fromJson(Map<String, Object?> m) =>
      ModelConfigOverride(
        contextLimit: (m['contextLimit'] as num?)?.toInt() ?? 128000,
        maxOutputTokens: (m['maxOutputTokens'] as num?)?.toInt() ?? 8192,
        inputPerMillion: m['inputPerMillion'] as String? ?? '',
        outputPerMillion: m['outputPerMillion'] as String? ?? '',
        cacheReadPerMillion: m['cacheReadPerMillion'] as String? ?? '',
        cacheWritePerMillion: m['cacheWritePerMillion'] as String? ?? '',
        cacheWriteLongPerMillion:
            m['cacheWriteLongPerMillion'] as String? ?? '',
        reasoningPerMillion: m['reasoningPerMillion'] as String? ?? '',
      );
}

/// Per-provider Advanced sub-page configuration (`kv_meta` key: `provider.adv:<id>`).
@immutable
class ProviderAdvancedConfig {
  const ProviderAdvancedConfig({
    this.customDialect = 'openai_chat',
    this.endpointPathOverride = '',
    this.authHeaderMode = 'native',
    this.autoFetchModels = true,
    this.storeServerSide = false,
    this.useStatefulChaining = false,
    this.useBackgroundPolling = true,
    this.useLegacyFallback = true,
    this.defaultThinkingEffort = 'default',
    this.modelOverrides = const <String, ModelConfigOverride>{},
  });

  final String customDialect;
  final String endpointPathOverride;
  final String authHeaderMode;
  final bool autoFetchModels;
  final bool storeServerSide;
  final bool useStatefulChaining;
  final bool useBackgroundPolling;
  final bool useLegacyFallback;
  final String defaultThinkingEffort;
  final Map<String, ModelConfigOverride> modelOverrides;

  ProviderAdvancedConfig copyWith({
    String? customDialect,
    String? endpointPathOverride,
    String? authHeaderMode,
    bool? autoFetchModels,
    bool? storeServerSide,
    bool? useStatefulChaining,
    bool? useBackgroundPolling,
    bool? useLegacyFallback,
    String? defaultThinkingEffort,
    Map<String, ModelConfigOverride>? modelOverrides,
  }) => ProviderAdvancedConfig(
    customDialect: customDialect ?? this.customDialect,
    endpointPathOverride: endpointPathOverride ?? this.endpointPathOverride,
    authHeaderMode: authHeaderMode ?? this.authHeaderMode,
    autoFetchModels: autoFetchModels ?? this.autoFetchModels,
    storeServerSide: storeServerSide ?? this.storeServerSide,
    useStatefulChaining: useStatefulChaining ?? this.useStatefulChaining,
    useBackgroundPolling: useBackgroundPolling ?? this.useBackgroundPolling,
    useLegacyFallback: useLegacyFallback ?? this.useLegacyFallback,
    defaultThinkingEffort: defaultThinkingEffort ?? this.defaultThinkingEffort,
    modelOverrides: modelOverrides ?? this.modelOverrides,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'customDialect': customDialect,
    'endpointPathOverride': endpointPathOverride,
    'authHeaderMode': authHeaderMode,
    'autoFetchModels': autoFetchModels,
    'storeServerSide': storeServerSide,
    'useStatefulChaining': useStatefulChaining,
    'useBackgroundPolling': useBackgroundPolling,
    'useLegacyFallback': useLegacyFallback,
    'defaultThinkingEffort': defaultThinkingEffort,
    'modelOverrides': <String, Object?>{
      for (final e in modelOverrides.entries) e.key: e.value.toJson(),
    },
  };

  static ProviderAdvancedConfig fromJson(Map<String, Object?> m) {
    final rawModels = m['modelOverrides'];
    final models = <String, ModelConfigOverride>{};
    if (rawModels is Map<String, Object?>) {
      for (final e in rawModels.entries) {
        if (e.value is Map<String, Object?>) {
          models[e.key] = ModelConfigOverride.fromJson(
            e.value! as Map<String, Object?>,
          );
        }
      }
    }
    return ProviderAdvancedConfig(
      customDialect: m['customDialect'] as String? ?? 'openai_chat',
      endpointPathOverride: m['endpointPathOverride'] as String? ?? '',
      authHeaderMode: m['authHeaderMode'] as String? ?? 'native',
      autoFetchModels: m['autoFetchModels'] as bool? ?? true,
      storeServerSide: m['storeServerSide'] as bool? ?? false,
      useStatefulChaining: m['useStatefulChaining'] as bool? ?? false,
      useBackgroundPolling: m['useBackgroundPolling'] as bool? ?? true,
      useLegacyFallback: m['useLegacyFallback'] as bool? ?? true,
      defaultThinkingEffort: m['defaultThinkingEffort'] as String? ?? 'default',
      modelOverrides: models,
    );
  }
}

/// Named workspace project grouping shared folders, instructions, and chats.
@immutable
class WorkspaceProject {
  const WorkspaceProject({
    required this.id,
    required this.name,
    this.folderPath = '',
    this.instructions = '',
  });

  final String id;
  final String name;
  final String folderPath;
  final String instructions;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'folderPath': folderPath,
    'instructions': instructions,
  };

  static WorkspaceProject fromJson(Map<String, Object?> m) => WorkspaceProject(
    id: m['id'] as String? ?? '',
    name: m['name'] as String? ?? '',
    folderPath: m['folderPath'] as String? ?? '',
    instructions: m['instructions'] as String? ?? '',
  );
}

extension FolioExtrasActions on FolioController {
  /// The workspace's `.bistre/hooks.json` and whether it is approved; `null` when none.
  EngineWorkspaceHooksStatus? get workspaceHooks => _workspaceHooks;

  /// The URLs a provider is called at (P8), for the settings preview.
  EngineResolvedEndpoint resolveProviderEndpoint(
    String dialect,
    String baseUrl,
  ) => _gateway.resolveProviderEndpoint(dialect, baseUrl);

  /// Core's descriptor for an API format id (P7); `null` for an unknown id.
  EngineDialectDescriptor? dialectDescriptor(String dialect) {
    return _gateway
        .dialectDescriptors()
        .where((d) => d.id == dialect)
        .firstOrNull;
  }

  /// Web sources of the open chat's replies (B2), oldest first.
  List<EngineGroundingSource> get threadGrounding => _threadGrounding;

  /// The sources one reply used.
  List<EngineGroundingSource> groundingFor(String nodeId) =>
      _threadGrounding.where((s) => s.nodeId == nodeId).toList(growable: false);

  /// Reloads the open chat's sources; a reply for a chat that is no longer open is dropped.
  Future<void> refreshThreadGrounding() async {
    final threadId = _activeThread?.id;
    if (threadId == null) return;
    try {
      final sources = await _gateway.listThreadGrounding(threadId);
      if (_disposed || _activeThread?.id != threadId) return;
      _threadGrounding = sources;
      _notify();
    } catch (e) {
      _noteNonFatal('thread_grounding', e);
    }
  }

  /// Reloads the hooks of the current workspace folder (A-S5).
  Future<void> refreshWorkspaceHooks() async {
    final root = _workspaceRootPath;
    if (root.isEmpty) {
      if (_workspaceHooks == null) return;
      _workspaceHooks = null;
      _notify();
      return;
    }
    try {
      _workspaceHooks = await _gateway.workspaceHooksStatus(root);
    } catch (e) {
      _workspaceHooks = null;
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
    }
    _notify();
  }

  /// Approves the hooks file exactly as shown; a file changed meanwhile is refused by core.
  Future<void> approveWorkspaceHooks() async {
    final status = _workspaceHooks;
    final root = _workspaceRootPath;
    if (status == null || root.isEmpty) return;
    try {
      await _gateway.approveWorkspaceHooks(root, status.digest);
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
    }
    await refreshWorkspaceHooks();
  }

  DefaultModelsConfig get defaultModels => _defaultModels;
  UiDisplayPrefs get uiPrefs => _uiPrefs;
  String get messageNavVisibility => _uiPrefs.messageNavVisibility;
  List<String> get workspaceFolders => _workspaceFolders;
  String get activeGitBranch => _activeGitBranch;
  List<WorkspaceProject> get projects => _projects;
  String? get activeProjectId => _activeProjectId;
  bool get splitViewOpen => _splitViewOpen;
  String? get splitSecondaryThreadId => _splitSecondaryThreadId;

  Future<void> _loadExtendedKvPrefs() async {
    try {
      final rawDm = await _gateway.getKvMeta('settings.default_models');
      if (rawDm != null && rawDm.trim().isNotEmpty) {
        final decoded = jsonDecode(rawDm);
        if (decoded is Map<String, Object?>) {
          _defaultModels = DefaultModelsConfig.fromJson(decoded);
        }
      }
      final rawUi = await _gateway.getKvMeta('settings.ui_prefs');
      if (rawUi != null && rawUi.trim().isNotEmpty) {
        final decoded = jsonDecode(rawUi);
        if (decoded is Map<String, Object?>) {
          _uiPrefs = UiDisplayPrefs.fromJson(decoded);
        }
      }
      final rawFolders = await _gateway.getKvMeta('agent.workspace_folders');
      if (rawFolders != null && rawFolders.trim().isNotEmpty) {
        final decoded = jsonDecode(rawFolders);
        if (decoded is List<Object?>) {
          _workspaceFolders = decoded
              .whereType<String>()
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
      } else if (_workspaceRootPath.isNotEmpty) {
        _workspaceFolders = <String>[_workspaceRootPath];
      }
      final rawProjects = await _gateway.getKvMeta('projects.list');
      if (rawProjects != null && rawProjects.trim().isNotEmpty) {
        final decoded = jsonDecode(rawProjects);
        if (decoded is List<Object?>) {
          _projects = decoded
              .whereType<Map<String, Object?>>()
              .map(WorkspaceProject.fromJson)
              .where((p) => p.id.isNotEmpty && p.name.isNotEmpty)
              .toList();
        }
      }
      unawaited(_refreshGitBranch());
    } catch (e) {
      _noteNonFatal('load_extended_prefs', e);
    }
  }

  Future<void> saveDefaultModels(DefaultModelsConfig next) async {
    _defaultModels = next;
    _notify();
    try {
      await _gateway.setKvMeta(
        'settings.default_models',
        jsonEncode(next.toJson()),
      );
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _noteNonFatal('save_default_models', e);
    }
  }

  Future<void> saveUiPrefs(UiDisplayPrefs next, {bool quiet = false}) async {
    _uiPrefs = next;
    _notify();
    try {
      await _gateway.setKvMeta('settings.ui_prefs', jsonEncode(next.toJson()));
      if (!quiet) showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _noteNonFatal('save_ui_prefs', e);
    }
  }

  Future<ProviderAdvancedConfig> loadProviderAdvanced(String providerId) async {
    try {
      final raw = await _gateway.getKvMeta('provider.adv:$providerId');
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) {
          return ProviderAdvancedConfig.fromJson(decoded);
        }
      }
    } catch (e) {
      _noteNonFatal('load_provider_adv', e);
    }
    return const ProviderAdvancedConfig();
  }

  Future<void> saveProviderAdvanced(
    String providerId,
    ProviderAdvancedConfig cfg,
  ) async {
    try {
      await _gateway.setKvMeta(
        'provider.adv:$providerId',
        jsonEncode(cfg.toJson()),
      );
      await saveProviderConfig(
        providerId: providerId,
        useServerStateCache: cfg.storeServerSide,
      );
    } catch (e) {
      _noteNonFatal('save_provider_adv', e);
    }
  }

  /// Tests a provider connection live and shows a centered floating pill toast with timing & count.
  Future<void> testProviderConnection(String providerId) async {
    final sw = Stopwatch()..start();
    await fetchModelsForProvider(providerId);
    sw.stop();
    final models = modelsForProvider(providerId);
    if (_lastDiagnosticKey == null) {
      final secs = (sw.elapsedMilliseconds / 1000.0).toStringAsFixed(1);
      showToast(
        L10nKey.toastProviderConnectionOk,
        args: <String, Object?>{'seconds': secs, 'count': models.length},
        tone: ToastTone.ok,
      );
    } else {
      // P8: name the URL that was tried; the typed reason shows with the provider.
      final p = providers.where((x) => x.id == providerId).firstOrNull;
      final url = p == null
          ? ''
          : _gateway.resolveProviderEndpoint(p.dialect, p.baseUrl).modelsUrl;
      showToast(
        L10nKey.toastProviderConnectionFailed,
        args: <String, Object?>{'url': url},
        tone: ToastTone.error,
        duration: const Duration(seconds: 6),
      );
    }
  }

  Future<void> addWorkspaceFolder(String path) async {
    final clean = path.trim();
    if (clean.isEmpty) return;
    if (!_workspaceFolders.contains(clean)) {
      _workspaceFolders = <String>[..._workspaceFolders, clean];
    }
    await _gateway.setKvMeta(
      'agent.workspace_folders',
      jsonEncode(_workspaceFolders),
    );
    await setWorkspaceRootPath(_workspaceFolders.first);
    unawaited(_refreshGitBranch());
  }

  Future<void> removeWorkspaceFolder(String path) async {
    _workspaceFolders = _workspaceFolders.where((f) => f != path).toList();
    await _gateway.setKvMeta(
      'agent.workspace_folders',
      jsonEncode(_workspaceFolders),
    );
    await setWorkspaceRootPath(
      _workspaceFolders.isEmpty ? '' : _workspaceFolders.first,
    );
    unawaited(_refreshGitBranch());
  }

  Future<void> clearWorkspaceFolders() async {
    _workspaceFolders = const <String>[];
    _activeGitBranch = '';
    await _gateway.setKvMeta('agent.workspace_folders', '[]');
    await setWorkspaceRootPath('');
  }

  Future<void> _refreshGitBranch() async {
    final root = _workspaceRootPath.trim();
    if (root.isEmpty || !BistreDesktopHost.isSafeLocalFolder(root)) {
      if (_activeGitBranch.isNotEmpty) {
        _activeGitBranch = '';
        _notify();
      }
      return;
    }
    try {
      final headFile = File('$root/.git/HEAD');
      if (!headFile.existsSync()) {
        _activeGitBranch = '';
        _notify();
        return;
      }
      final raw = headFile.readAsStringSync().trim();
      const prefix = 'ref: refs/heads/';
      _activeGitBranch = raw.startsWith(prefix)
          ? raw.substring(prefix.length).trim()
          : (raw.length > 8 ? raw.substring(0, 8) : raw);
      _notify();
    } on FileSystemException {
      _activeGitBranch = '';
    }
  }

  /// Imports MCP servers from a standard `.mcp.json` / `mcp.json` file (`enabled: false` default).
  Future<int> importMcpJsonFile(String filePath) async {
    try {
      final raw = await File(filePath).readAsString();
      final decoded = jsonDecode(raw);
      final imported = <EngineMcpServerConfig>[];
      void parseEntry(String name, Map<String, Object?> obj) {
        final url = (obj['url'] as String? ?? '').trim();
        final cmd = Platform.isAndroid
            ? ''
            : (obj['command'] as String? ?? '').trim();
        final rawArgs = obj['args'];
        final argStr = rawArgs is List<Object?>
            ? rawArgs.whereType<String>().join(' ')
            : '';
        final fullCmd = argStr.isNotEmpty && cmd.isNotEmpty
            ? '$cmd $argStr'
            : cmd;
        if (url.isEmpty && fullCmd.isEmpty) return;
        imported.add(
          EngineMcpServerConfig(
            id: 'mcp_imp_${DateTime.now().microsecondsSinceEpoch}_${imported.length}',
            name: name.trim().isEmpty ? 'Imported MCP' : name.trim(),
            transport: url.isNotEmpty ? 'http' : 'stdio',
            url: url,
            command: fullCmd,
            enabled: false,
          ),
        );
      }

      if (decoded is Map<String, Object?>) {
        final servers = decoded['mcpServers'] ?? decoded['servers'];
        if (servers is Map<String, Object?>) {
          for (final e in servers.entries) {
            if (e.value is Map<String, Object?>) {
              parseEntry(e.key, e.value! as Map<String, Object?>);
            }
          }
        }
      } else if (decoded is List<Object?>) {
        for (final item in decoded.whereType<Map<String, Object?>>()) {
          parseEntry(item['name'] as String? ?? '', item);
        }
      }
      for (final srv in imported) {
        await addMcpServer(srv);
      }
      if (imported.isNotEmpty) {
        showToast(L10nKey.toastSettingsSaved, tone: ToastTone.ok);
      }
      return imported.length;
    } catch (e) {
      _noteNonFatal('mcp_import', e);
      return 0;
    }
  }

  /// Creates or updates a Workspace Project grouping shared folders & instructions.
  Future<void> saveProject(WorkspaceProject project) async {
    final next = <WorkspaceProject>[
      for (final p in _projects)
        if (p.id != project.id) p,
      project,
    ];
    _projects = next;
    _notify();
    await _gateway.setKvMeta(
      'projects.list',
      jsonEncode(next.map((p) => p.toJson()).toList()),
    );
    showToast(L10nKey.toastSettingsSaved);
  }

  Future<void> deleteProject(String projectId) async {
    _projects = _projects.where((p) => p.id != projectId).toList();
    if (_activeProjectId == projectId) _activeProjectId = null;
    _notify();
    await _gateway.setKvMeta(
      'projects.list',
      jsonEncode(_projects.map((p) => p.toJson()).toList()),
    );
    showToast(L10nKey.toastDeleted);
  }

  void selectProject(String? projectId) {
    _activeProjectId = projectId;
    final proj = _projects.where((p) => p.id == projectId).firstOrNull;
    if (proj != null && proj.folderPath.isNotEmpty) {
      unawaited(addWorkspaceFolder(proj.folderPath));
    }
    _notify();
  }

  Future<List<EngineNode>> loadThreadPreviewNodes(String threadId) async {
    try {
      return await _gateway.listNodes(threadId);
    } catch (e) {
      _noteNonFatal('split_preview_nodes', e);
      return const <EngineNode>[];
    }
  }

  void toggleSplitView({String? secondaryThreadId}) {
    if (_splitViewOpen && secondaryThreadId == null) {
      _splitViewOpen = false;
      _splitSecondaryThreadId = null;
    } else {
      _splitViewOpen = true;
      _splitSecondaryThreadId =
          secondaryThreadId ??
          _threads.where((t) => t.id != _activeThread?.id).firstOrNull?.id ??
          _activeThread?.id;
    }
    _notify();
  }
}
