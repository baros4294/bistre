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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
    }
  }

  Future<void> setActiveProviderAndModel(
    String providerId,
    String modelId,
  ) async {
    try {
      if (modelId.trim().isNotEmpty) {
        await _gateway.updateProvider(
          providerId: providerId,
          defaultModel: modelId.trim(),
        );
        _providers = await _gateway.listProviders();
      }
      _settings = await _gateway.saveSettings(
        _settings.copyWith(
          activeProviderId: providerId,
          activeModelId: modelId.trim(),
        ),
      );
      _lastDiagnosticKey = null;
      showToast(L10nKey.toastSettingsSaved);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return null;
    }
  }

  // --- OTA Updates & Storage Management ---

  Future<void> checkForUpdates({String? feedUrlOverride}) async {
    if (_checkingUpdates) return;
    _checkingUpdates = true;
    _lastDiagnosticKey = null;
    _notify();
    try {
      _updateCheck = await _gateway.checkForUpdates(
        feedUrlOverride: feedUrlOverride,
      );
      _checkingUpdates = false;
      _notify();
    } catch (e) {
      _checkingUpdates = false;
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> stageAvailableUpdate() async {
    final check = _updateCheck;
    if (check == null || _stagingUpdate) return;
    _stagingUpdate = true;
    _lastDiagnosticKey = null;
    _notify();
    try {
      _stagedUpdatePath = await _gateway.stageUpdate(check);
      _stagingUpdate = false;
      showToast(L10nKey.toastUpdateStaged);
      _notify();
    } catch (e) {
      _stagingUpdate = false;
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
    if (active != null && assistant != null) {
      try {
        final updated = await _gateway.updateThread(
          threadId: active.id,
          assistantId: assistant.id,
        );
        _threads = _withoutPendingDeletes(await _gateway.listThreads());
        _activeThread = updated;
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
    }
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
    }
  }

  /// Deletes a chat after an 8 s Undo window (`docs/design/DESIGN.md` §1.1: Undo instead of asking).
  Future<void> deleteThread(String threadId) async {
    _pendingThreadDeletes.remove(threadId)?.cancel();
    final remaining = _threads.where((t) => t.id != threadId).toList();
    _threads = remaining;
    if (_activeThread?.id == threadId && remaining.isNotEmpty) {
      await _activateThread(remaining.first);
    }
    _pendingThreadDeletes[threadId] = Timer(
      const Duration(seconds: 8),
      () => unawaited(_commitThreadDelete(threadId)),
    );
    showToast(
      L10nKey.toastDeleted,
      actionKey: L10nKey.toastUndo,
      onAction: () => unawaited(undoDeleteThread(threadId)),
      duration: const Duration(seconds: 8),
    );
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }
}
