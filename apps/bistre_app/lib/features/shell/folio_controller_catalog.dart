part of 'folio_controller.dart';

/// Provider, OTA/storage, and assistant actions of [FolioController].
extension FolioCatalogActions on FolioController {
  // --- Providers CRUD (all providers freely editable & deletable) ---

  Future<EngineProvider?> createProvider({
    required String name,
    required String dialect,
    required String baseUrl,
    required String defaultModel,
    required String iconSlug,
    String customIconPath = '',
    String? apiKey,
  }) async {
    if (name.trim().isEmpty || baseUrl.trim().isEmpty) return null;
    try {
      final created = await _gateway.createProvider(
        name: name.trim(),
        dialect: dialect,
        baseUrl: baseUrl.trim(),
        defaultModel: defaultModel.trim(),
        iconSlug: iconSlug.trim(),
        customIconPath: customIconPath.trim(),
        apiKey: apiKey != null && apiKey.trim().isNotEmpty
            ? apiKey.trim()
            : null,
      );
      _providers = await _gateway.listProviders();
      _settings = await _gateway.loadSettings();
      _lastDiagnosticKey = null;
      showToast(L10nKey.toastProviderAdded);
      _notify();
      return created;
    } catch (e) {
      _fail(e);
      return null;
    }
  }

  /// Copies [provider]'s share code; core leaves the key out unless [includeApiKey].
  Future<void> copyProviderShareCode(
    EngineProvider provider, {
    bool includeApiKey = false,
  }) async {
    try {
      await copyText(
        await _gateway.exportProviderShareCode(
          providerId: provider.id,
          includeApiKey: includeApiKey,
        ),
      );
    } catch (e) {
      _fail(e);
    }
  }

  /// Adds a provider from a share code; `null` when core cannot read the code.
  Future<EngineProvider?> importProviderShareCode(String code) async {
    if (code.trim().isEmpty) return null;
    try {
      final created = await _gateway.importProviderShareCode(code.trim());
      _providers = await _gateway.listProviders();
      _lastDiagnosticKey = null;
      showToast(L10nKey.toastProviderAdded);
      _notify();
      return created;
    } catch (e) {
      _fail(e);
      return null;
    }
  }

  Future<EngineProvider?> createCustomProvider({
    required String name,
    required String baseUrl,
    required String defaultModel,
    String? apiKey,
  }) => createProvider(
    name: name,
    dialect: 'custom_openai',
    baseUrl: baseUrl,
    defaultModel: defaultModel,
    iconSlug: 'server',
    apiKey: apiKey,
  );

  Future<bool> saveProviderApiKey(String providerId, String rawKey) async {
    if (rawKey.trim().isEmpty) return false;
    try {
      await _gateway.setProviderApiKey(
        providerId: providerId,
        apiKey: rawKey.trim(),
      );
      _providers = await _gateway.listProviders();
      _settings = await _gateway.loadSettings();
      _lastDiagnosticKey = null;
      showToast(L10nKey.toastKeySaved);
      _notify();
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  Future<void> clearProviderApiKey(String providerId) async {
    try {
      await _gateway.clearProviderApiKey(providerId);
      _providers = await _gateway.listProviders();
      _modelsByProvider.remove(providerId);
      showToast(L10nKey.toastKeyRemoved);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  Future<bool> saveProviderConfig({
    required String providerId,
    String? name,
    String? baseUrl,
    String? defaultModel,
    bool? isEnabled,
    bool? useServerStateCache,
    String? iconSlug,
    String? customIconPath,
    bool activate = false,
  }) async {
    try {
      final updated = await _gateway.updateProvider(
        providerId: providerId,
        name: name,
        baseUrl: baseUrl,
        defaultModel: defaultModel,
        isEnabled: isEnabled,
        useServerStateCache: useServerStateCache,
        iconSlug: iconSlug,
        customIconPath: customIconPath,
      );
      _providers = await _gateway.listProviders();
      if (activate || _settings.activeProviderId == providerId) {
        final nextModel = updated.defaultModel.isNotEmpty
            ? updated.defaultModel
            : _settings.activeModelId;
        _settings = await _gateway.saveSettings(
          _settings.copyWith(
            activeProviderId: providerId,
            activeModelId: nextModel,
          ),
        );
      }
      _lastDiagnosticKey = null;
      showToast(L10nKey.toastSettingsSaved);
      _notify();
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// [forOpenChat]: picked in the chat's model picker, so it becomes that chat's own model
  /// (Settings > Default models is the default for other chats).
  Future<void> setActiveProviderAndModel(
    String providerId,
    String modelId, {
    bool forOpenChat = false,
  }) async {
    try {
      final cleanModel = modelId.trim();
      if (cleanModel.isNotEmpty) {
        await _gateway.updateProvider(
          providerId: providerId,
          defaultModel: cleanModel,
        );
        _providers = await _gateway.listProviders();
      }
      _settings = await _gateway.saveSettings(
        _settings.copyWith(
          activeProviderId: providerId,
          activeModelId: cleanModel,
        ),
      );
      // If the active thread or its assistant overrides provider/model, update the thread
      // override so choosing a model in the top Model Picker always takes effect immediately.
      final active = _activeThread;
      final assistant = activeAssistant;
      final hasOverride =
          active != null &&
          (forOpenChat ||
              (active.providerIdOverride?.trim().isNotEmpty ?? false) ||
              (active.modelIdOverride?.trim().isNotEmpty ?? false) ||
              (assistant?.defaultProviderId.trim().isNotEmpty ?? false) ||
              (assistant?.defaultModelId.trim().isNotEmpty ?? false));
      if (hasOverride) {
        final updated = await _gateway.updateThread(
          threadId: active.id,
          providerIdOverride: providerId,
          modelIdOverride: cleanModel,
        );
        if (_activeThread?.id == updated.id) _activeThread = updated;
        _threads = _threads
            .map((t) => t.id == updated.id ? updated : t)
            .toList(growable: false);
      }
      _lastDiagnosticKey = null;
      showToast(L10nKey.toastSettingsSaved);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> deleteProvider(String providerId) async {
    try {
      await _gateway.deleteProvider(providerId);
      _providers = await _gateway.listProviders();
      _settings = await _gateway.loadSettings();
      _modelsByProvider.remove(providerId);
      showToast(L10nKey.toastProviderDeleted);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  Future<int?> fetchModelsForProvider(String providerId) async {
    _loadingModelsProviderId = providerId;
    _lastDiagnosticKey = null;
    _notify();
    try {
      final list = await _gateway.fetchProviderModels(providerId);
      _modelsByProvider[providerId] = list;
      _loadingModelsProviderId = null;
      _notify();
      return list.length;
    } catch (e) {
      _loadingModelsProviderId = null;
      _fail(e);
      return null;
    }
  }

  // --- OTA Updates & Storage Management ---

  bool get showUpdateBanner =>
      (_updateCheck?.updateAvailable ?? false) && !_updateBannerDismissed;

  void dismissUpdateBanner() {
    if (_updateBannerDismissed) return;
    _updateBannerDismissed = true;
    _notify();
  }

  Future<void> checkForUpdates({
    String? feedUrlOverride,
    bool background = false,
  }) async {
    if (_checkingUpdates) return;
    _checkingUpdates = true;
    if (!background) {
      _lastOtaDiagnostic = null;
      _lastOtaDetail = null;
    }
    _notify();
    try {
      _updateCheck = await _gateway.checkForUpdates(
        feedUrlOverride: feedUrlOverride,
      );
      _checkingUpdates = false;
      _notify();
    } catch (e) {
      _checkingUpdates = false;
      if (!background) {
        _lastOtaDiagnostic = FolioController.extractDiagnosticKey(e);
        _lastOtaDetail = FolioController.extractDiagnosticDetail(e);
      }
      _notify();
    }
  }

  Future<void> stageAvailableUpdate() => _stageUpdateImpl(reinstall: false);

  Future<void> reinstallCurrentVersion() => _stageUpdateImpl(reinstall: true);

  Future<void> _stageUpdateImpl({required bool reinstall}) async {
    final check = _updateCheck;
    if (check == null || _stagingUpdate) return;
    _stagingUpdate = true;
    _lastOtaDiagnostic = null;
    _lastOtaDetail = null;
    _notify();
    try {
      if (reinstall) {
        await _gateway.reinstallUpdate(check);
      } else {
        await _gateway.stageUpdate(check);
      }
      _pendingUpdateVersion = check.latestVersion;
      _stagingUpdate = false;
      showToast(L10nKey.toastUpdateStaged);
      _notify();
    } catch (e) {
      // The reason goes to Updates; the banner's download gets a way there.
      _stagingUpdate = false;
      _lastOtaDiagnostic = FolioController.extractDiagnosticKey(e);
      _lastOtaDetail = FolioController.extractDiagnosticDetail(e);
      showToast(
        L10nKey.toastUpdateStageFailed,
        tone: ToastTone.error,
        actionKey: L10nKey.settingsOtaOpenUpdates,
        onAction: () => openSettings(SettingsTab.updates),
        duration: const Duration(seconds: 6),
      );
      _notify();
    }
  }

  /// Loads the staged update left from an earlier session, so Install update survives a
  /// restart.
  Future<void> _loadPendingUpdate() async {
    try {
      _pendingUpdateVersion = await _gateway.pendingUpdateVersion();
    } catch (e) {
      _lastOtaDiagnostic = FolioController.extractDiagnosticKey(e);
      _lastOtaDetail = FolioController.extractDiagnosticDetail(e);
    }
    _notify();
  }

  /// Runs the staged update. Desktop: core started the installer, so Bistre quits through
  /// the normal close path and the installer reopens it. Android: the system installer
  /// opens and asks the user to confirm.
  Future<void> installUpdate() async {
    if (_installingUpdate || _pendingUpdateVersion == null) return;
    _installingUpdate = true;
    _lastOtaDiagnostic = null;
    _lastOtaDetail = null;
    _notify();
    try {
      final apk = await _gateway.installStagedUpdate();
      if (apk.isEmpty) {
        _pendingUpdateVersion = null;
        await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
      } else if (!await BistreDesktopHost.installUpdate(apk)) {
        throw Exception('diag.ota.install_failed');
      }
    } catch (e) {
      _lastOtaDiagnostic = FolioController.extractDiagnosticKey(e);
      _lastOtaDetail = FolioController.extractDiagnosticDetail(e);
    }
    _installingUpdate = false;
    _notify();
  }

  /// Whether [attachment] is audio or video on a desktop, which the file manager opens.
  /// Desktop only: the system file manager shows where a stored file lives.
  bool canOpenFolderOf(ComposerAttachment attachment) =>
      attachment.path.isNotEmpty && (Platform.isWindows || Platform.isLinux);

  /// Opens the folder holding [attachment] in the system file manager.
  Future<void> openFolderOf(ComposerAttachment attachment) =>
      BistreDesktopHost.openFolder(File(attachment.path).parent.path);

  /// Whether [attachment] can go to its default app (never an executable or a script).
  bool canOpenInAppOf(ComposerAttachment attachment) =>
      BistreDesktopHost.canOpenFiles &&
      attachment.path.isNotEmpty &&
      !BistreDesktopHost.blockedOpenExtensions.contains(
        _extensionOf(attachment.name),
      );

  Future<void> openInAppOf(ComposerAttachment attachment) async {
    if (!await BistreDesktopHost.openFile(attachment.path)) {
      showToast(L10nKey.viewerOpenFailed, tone: ToastTone.error);
    }
  }

  bool canSaveCopyOf(ComposerAttachment attachment) =>
      BistreDesktopHost.canSaveFiles && attachment.path.isNotEmpty;

  /// A picture Flutter can decode (never SVG) on a platform with a picture clipboard.
  bool canCopyPictureOf(ComposerAttachment attachment) =>
      BistreDesktopHost.canCopyPictures &&
      attachment.path.isNotEmpty &&
      attachment.mimeType.startsWith('image/') &&
      attachment.mimeType != 'image/svg+xml';

  Future<void> copyPictureOf(ComposerAttachment attachment) async {
    var copied = false;
    try {
      copied = await BistreDesktopHost.copyPicture(attachment.path);
    } on Exception catch (e) {
      // A file that is unreadable or not a picture Flutter decodes.
      _noteNonFatal('copy_picture', e);
    }
    if (copied) {
      showToast(L10nKey.toastCopied, tone: ToastTone.ok);
    } else {
      showToast(L10nKey.viewerCopyFailed, tone: ToastTone.error);
    }
  }

  Future<void> saveCopyOf(ComposerAttachment attachment, String title) async {
    final ext = _extensionOf(attachment.name);
    final dest = await BistreDesktopHost.saveLocalFile(
      title: title,
      defaultName: attachment.name,
      filterLabel: ext.isEmpty ? attachment.name : ext.toUpperCase(),
      filterSpec: ext.isEmpty ? '*.*' : '*.$ext',
    );
    if (dest == null || dest.isEmpty) return;
    try {
      await File(attachment.path).copy(dest);
      showToast(L10nKey.viewerSaved, tone: ToastTone.ok);
    } on FileSystemException catch (e) {
      _noteNonFatal('save_copy', e);
      showToast(L10nKey.diagStorageIoError, tone: ToastTone.error);
    }
  }

  /// A sound or video plays in the app on Windows, Linux, and Android.
  bool canPlayOf(ComposerAttachment attachment) =>
      (Platform.isWindows || Platform.isAndroid || Platform.isLinux) &&
      attachment.path.isNotEmpty &&
      (attachment.mimeType.startsWith('audio/') ||
          attachment.mimeType.startsWith('video/'));

  /// Plays [attachment] in Bistre's player: a sound in the background, a video in its own
  /// window. A file the platform's player cannot take opens in its default app instead,
  /// also when it fails after starting ([onMediaPlaybackFailed]).
  Future<void> playOf(ComposerAttachment attachment) async {
    _playingAttachment = attachment;
    final started = await BistreDesktopHost.playMediaFile(
      path: attachment.path,
      title: attachment.name,
      video: attachment.mimeType.startsWith('video/'),
    );
    if (!started) await openInAppOf(attachment);
  }

  /// The host could not decode the file it started: open it in its default app.
  void onMediaPlaybackFailed() {
    final attachment = _playingAttachment;
    _playingAttachment = null;
    if (attachment != null) unawaited(openInAppOf(attachment));
  }

  Future<void> stopPlayback() => BistreDesktopHost.stopAudioPlayback();

  Future<void> openDataFolder() async {
    final dir = _storageStats?.dataDir ?? '';
    if (dir.isNotEmpty) {
      await BistreDesktopHost.openFolder(dir);
    }
  }

  Future<bool> backupDatabaseTo(String destPath) async {
    try {
      await _gateway.backupDatabase(destPath);
      showToast(L10nKey.toastBackupSaved);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// Saves one code block to a file (native save dialog on desktop; on Android it is copied).
  Future<void> saveCodeBlock(
    String code,
    String language, {
    required String saveTitle,
  }) async {
    final lang = language.trim().toLowerCase();
    final ext = RegExp(r'^[a-z0-9]{1,8}$').hasMatch(lang) ? lang : 'txt';
    if (!BistreDesktopHost.canSaveFiles) {
      await copyText(code);
      return;
    }
    final path = await BistreDesktopHost.saveLocalFile(
      title: saveTitle,
      defaultName: 'snippet.$ext',
      filterLabel: saveTitle,
      filterSpec: '*.$ext',
    );
    if (path == null) return;
    try {
      await File(path).writeAsString(code, flush: true);
      showToast(L10nKey.toastSettingsSaved);
    } on FileSystemException catch (e) {
      _noteNonFatal('save_code_block', e);
    }
  }

  Future<String?> exportActiveThread(String format) async {
    final tid = _activeThread?.id;
    if (tid == null) return null;
    try {
      final content = await _gateway.exportThread(
        threadId: tid,
        format: format,
      );
      return content;
    } catch (e) {
      _fail(e);
      return null;
    }
  }

  Future<void> exportActiveThreadToFileOrClipboard(
    String format, {
    required String saveTitle,
  }) async {
    final content = await exportActiveThread(format);
    if (content == null) return;
    final ext = format == 'json' ? 'json' : 'md';
    final safeTitle = (_activeThread?.title ?? 'bistre-chat')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\- ]'), '')
        .trim()
        .replaceAll(' ', '-');
    final defaultName = '${safeTitle.isEmpty ? 'bistre-chat' : safeTitle}.$ext';

    final chosen = await BistreDesktopHost.saveLocalFile(
      title: saveTitle,
      defaultName: defaultName,
      filterLabel: format == 'json' ? 'JSON' : 'Markdown',
      filterSpec: '*.$ext',
    );
    if (chosen != null && chosen.isNotEmpty) {
      try {
        await File(chosen).writeAsString(content);
        showToast(L10nKey.toastExported);
        return;
      } on FileSystemException {
        _lastDiagnosticKey = 'diag.export.failed';
        _notify();
        return;
      }
    }
    // Fallback on non-Windows / headless tests: copy cleanly to clipboard.
    await Clipboard.setData(ClipboardData(text: content));
    showToast(L10nKey.toastExported);
  }

  // --- Assistants CRUD (zero hardcoded mode presets) ---

  Future<void> selectAssistant(String assistantId) async {
    _activeAssistantId = assistantId;
    final assistant = _assistants.where((a) => a.id == assistantId).firstOrNull;
    final active = _activeThread;
    if (_uiPrefs.newChatOnAssistantSwitch &&
        assistant != null &&
        active != null &&
        active.assistantId != assistantId &&
        visibleBranchNodes.isNotEmpty) {
      await createNewFolio(assistantId: assistantId);
      return;
    }
    if (active != null && assistant != null) {
      try {
        final updated = await _gateway.updateThread(
          threadId: active.id,
          assistantId: assistant.id,
        );
        _threads = _withoutPendingDeletes(await _gateway.listThreads());
        if (_activeThread?.id == updated.id) _activeThread = updated;
      } catch (e) {
        _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      }
    }
    _notify();
  }

  Future<bool> createCustomAssistant({
    required String name,
    required String roleSubtitle,
    required String systemPrompt,
    String iconSlug = '',
    String defaultProviderId = '',
    String defaultModelId = '',
    int? temperatureMilli,
    int? maxOutputTokens,
    int? topPMilli,
  }) async {
    if (name.trim().isEmpty) return false;
    try {
      final created = await _gateway.createAssistant(
        name: name.trim(),
        roleSubtitle: roleSubtitle.trim(),
        systemPrompt: systemPrompt.trim(),
        defaultMode: 'chat',
        badgeCode: '',
      );
      if (iconSlug.isNotEmpty ||
          defaultProviderId.isNotEmpty ||
          defaultModelId.isNotEmpty ||
          temperatureMilli != null ||
          maxOutputTokens != null ||
          topPMilli != null) {
        await _gateway.updateAssistant(
          assistantId: created.id,
          iconSlug: iconSlug,
          defaultProviderId: defaultProviderId,
          defaultModelId: defaultModelId,
          temperatureMilli: temperatureMilli,
          maxOutputTokens: maxOutputTokens,
          topPMilli: topPMilli,
        );
      }
      _assistants = await _gateway.listAssistants();
      await selectAssistant(created.id);
      showToast(L10nKey.toastAssistantCreated);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  Future<bool> updateAssistant({
    required String assistantId,
    required String name,
    required String roleSubtitle,
    required String systemPrompt,
    String? iconSlug,
    String? defaultProviderId,
    String? defaultModelId,
    int? temperatureMilli,
    bool clearTemperature = false,
    int? maxOutputTokens,
    bool clearMaxOutputTokens = false,
    int? topPMilli,
    bool clearTopP = false,
  }) async {
    if (name.trim().isEmpty) return false;
    try {
      await _gateway.updateAssistant(
        assistantId: assistantId,
        name: name.trim(),
        roleSubtitle: roleSubtitle.trim(),
        systemPrompt: systemPrompt.trim(),
        iconSlug: iconSlug,
        defaultProviderId: defaultProviderId,
        defaultModelId: defaultModelId,
        temperatureMilli: temperatureMilli,
        clearTemperature: clearTemperature,
        maxOutputTokens: maxOutputTokens,
        clearMaxOutputTokens: clearMaxOutputTokens,
        topPMilli: topPMilli,
        clearTopP: clearTopP,
      );
      _assistants = await _gateway.listAssistants();
      showToast(L10nKey.toastAssistantUpdated);
      _notify();
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// Copies the assistant [assistantId] under [name] with its prompt and defaults.
  Future<bool> duplicateAssistant(String assistantId, String name) async {
    final source = _assistants.where((a) => a.id == assistantId).firstOrNull;
    if (source == null) return false;
    return createCustomAssistant(
      name: name,
      roleSubtitle: source.roleSubtitle,
      systemPrompt: source.systemPrompt,
      iconSlug: source.iconSlug,
      defaultProviderId: source.defaultProviderId,
      defaultModelId: source.defaultModelId,
      temperatureMilli: source.temperatureMilli,
      maxOutputTokens: source.maxOutputTokens,
      topPMilli: source.topPMilli,
    );
  }

  Future<bool> deleteAssistant(String assistantId) async {
    if (_assistants.length <= 1) return false;
    try {
      await _gateway.deleteAssistant(assistantId);
      _assistants = await _gateway.listAssistants();
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      if (_activeAssistantId == assistantId && _assistants.isNotEmpty) {
        _activeAssistantId = _assistants.first.id;
      }
      if (_activeThread != null) {
        final refreshed = _threads
            .where((t) => t.id == _activeThread!.id)
            .firstOrNull;
        if (refreshed != null) _activeThread = refreshed;
      }
      showToast(L10nKey.toastAssistantDeleted);
      _notify();
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// Deletes a chat after an 8 s Undo window (`docs/design/design.md` §1.1: Undo instead of asking).
  Future<void> deleteThread(String threadId) async {
    _pendingThreadDeletes.remove(threadId)?.cancel();
    // Register pending delete and close its tab BEFORE awaiting `createNewFolio()` so
    // `listThreads()` never resurrects the deleted thread into `_threads` or `openTabs`.
    _pendingThreadDeletes[threadId] = Timer(
      const Duration(seconds: 8),
      () => unawaited(_commitThreadDelete(threadId)),
    );
    // A deleted chat stops spending now, not when the Undo window ends; Undo restores the
    // chat and its messages, not the stopped reply.
    unawaited(_cancelRunOf(threadId));
    _openTabIds.remove(threadId);
    final remaining = _threads.where((t) => t.id != threadId).toList();
    _threads = remaining;
    if (_activeThread?.id == threadId) {
      if (remaining.isNotEmpty && !_uiPrefs.newChatAfterDelete) {
        await _activateThread(remaining.first);
      } else {
        // Deleting the last chat must not leave it on screen.
        await createNewFolio();
      }
    }
    showToast(
      L10nKey.toastDeleted,
      actionKey: L10nKey.toastUndo,
      onAction: () => unawaited(undoDeleteThread(threadId)),
      duration: const Duration(seconds: 8),
    );
    _notify();
  }

  Future<void> _cancelRunOf(String threadId) async {
    try {
      await _gateway.cancelActiveRun(threadId);
    } catch (e) {
      _noteNonFatal('delete_cancel_run', e);
    }
  }

  /// Permanently deletes all chats and opens a fresh empty chat with 1 clean tab.
  Future<void> clearAllThreads() async {
    final ids = <String>{
      for (final t in _threads) t.id,
      ..._pendingThreadDeletes.keys,
    };
    for (final id in _pendingThreadDeletes.keys.toList()) {
      _pendingThreadDeletes.remove(id)?.cancel();
    }
    _openTabIds.clear();
    _threads = const <EngineThread>[];
    _activeThread = null;
    _nodes = const <EngineNode>[];
    liveTurn.clear();
    for (final id in ids) {
      try {
        await _gateway.cancelActiveRun(id);
      } catch (e) {
        _noteNonFatal('clear_all_cancel', e);
      }
      try {
        await _gateway.deleteThread(id);
      } catch (e) {
        _noteNonFatal('clear_all_delete', e);
      }
    }
    await createNewFolio();
    try {
      _health = await _gateway.getHealth();
      _storageStats = await _gateway.getStorageStats();
    } catch (e) {
      _noteNonFatal('clear_all_stats', e);
    }
    showToast(L10nKey.toastChatsCleared);
    _notify();
  }

  List<EngineThread> _withoutPendingDeletes(List<EngineThread> threads) =>
      _pendingThreadDeletes.isEmpty
      ? threads
      : threads.where((t) => !_pendingThreadDeletes.containsKey(t.id)).toList();

  /// Restores a chat deleted less than 8 s ago.
  Future<void> undoDeleteThread(String threadId) async {
    final timer = _pendingThreadDeletes.remove(threadId);
    if (timer == null) return;
    timer.cancel();
    dismissToast();
    try {
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      showToast(L10nKey.toastRestored);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
    }
    _notify();
  }

  /// Commits every chat still inside its Undo window (app pause, close, or dispose).
  Future<void> flushPendingDeletes() async {
    final ids = _pendingThreadDeletes.keys.toList();
    for (final id in ids) {
      _pendingThreadDeletes.remove(id)?.cancel();
      try {
        await _gateway.deleteThread(id);
      } catch (e) {
        _noteNonFatal('flush_pending_delete', e);
      }
    }
  }

  Future<void> _commitThreadDelete(String threadId) async {
    _pendingThreadDeletes.remove(threadId);
    try {
      await _gateway.deleteThread(threadId);
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      if (_threads.isEmpty) {
        await createNewFolio();
      } else if (_activeThread?.id == threadId) {
        await _activateThread(_threads.first);
      }
      _health = await _gateway.getHealth();
      _storageStats = await _gateway.getStorageStats();
      _notify();
    } catch (e) {
      _fail(e);
    }
  }
}

/// Lowercase extension of a file name, without the dot ('' when there is none).
String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
}
