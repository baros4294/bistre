part of 'folio_controller.dart';

/// Appearance, fonts, shortcuts, settings persistence, tabs, and navigation actions
/// of [FolioController].
extension FolioNavigationAndSettingsActions on FolioController {
  // --- Fonts, Pricing & Window Bounds ---

  Future<void> ensureSystemFontsLoaded() async {
    if (_systemFonts.isNotEmpty || _loadingSystemFonts) return;
    _loadingSystemFonts = true;
    _notify();
    _systemFonts = await BistreFontManager.discoverSystemFonts();
    _loadingSystemFonts = false;
    _notify();
  }

  /// Starts a public price-list refresh now (Settings -> Safety & Budget).
  Future<void> refreshPrices() async {
    try {
      await _gateway.refreshPrices();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
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

  // --- Shortcuts ---

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
      _notify();
    }
  }

  // --- Open Chat Tabs ---

  /// Open chats as tabs (Parchment v2.6.0), skipping deleted ones.
  List<EngineThread> get openTabs => <EngineThread>[
    for (final id in _openTabIds)
      if (_threads.where((t) => t.id == id).firstOrNull case final t?) t,
  ];

  /// Closes a tab; closing the current one switches to its neighbour.
  Future<void> closeTab(String threadId) async {
    final index = _openTabIds.indexOf(threadId);
    if (index < 0) return;
    _openTabIds.removeAt(index);
    if (_activeThread?.id == threadId && _openTabIds.isNotEmpty) {
      await selectThread(_openTabIds[index.clamp(0, _openTabIds.length - 1)]);
      return;
    }
    _notify();
  }

  /// Cycles through open tabs (`Ctrl+Tab` / `Ctrl+Shift+Tab`, `ParchmentApp.kt` L432-L440).
  Future<void> cycleTab(int delta) async {
    final tabs = openTabs;
    if (tabs.length < 2) return;
    final activeId = _activeThread?.id;
    final here = tabs.indexWhere((t) => t.id == activeId);
    final start = here < 0 ? 0 : here;
    final next = (start + delta) % tabs.length;
    final wrapped = next < 0 ? next + tabs.length : next;
    await selectThread(tabs[wrapped].id);
  }

  void openTabSwitcher() {
    if (_tabSwitcherOpen) return;
    _tabSwitcherOpen = true;
    _commandPaletteOpen = false;
    _notify();
  }

  void closeTabSwitcher() {
    if (!_tabSwitcherOpen) return;
    _tabSwitcherOpen = false;
    _notify();
  }

  void toggleTabSwitcher() {
    if (_tabSwitcherOpen) {
      closeTabSwitcher();
    } else {
      openTabSwitcher();
    }
  }

  // --- Navigation & Layout Controls ---

  void toggleSidebar() {
    _sidebarOpen = !_sidebarOpen;
    unawaited(
      updateSettings(
        _settings.copyWith(sidebarOpen: _sidebarOpen),
        quiet: true,
      ),
    );
    _notify();
  }

  void toggleInspector() {
    _inspectorOpen = !_inspectorOpen;
    if (_inspectorOpen) {
      _studioPaneOpen = false;
    }
    _notify();
  }

  void toggleStudioPane() {
    _studioPaneOpen = !_studioPaneOpen;
    if (_studioPaneOpen) {
      _inspectorOpen = false;
      unawaited(_refreshRunsAndPower());
    }
    _notify();
  }

  void setSidebarTab(SidebarTab tab) {
    if (_sidebarTab == tab) return;
    _sidebarTab = tab;
    _notify();
  }

  void setSidebarFilter(String query) {
    sidebarFilterQuery.value = query;
  }

  void toggleSearchPanel() {
    _searchPanelOpen = !_searchPanelOpen;
    if (!_searchPanelOpen) search.clear();
    _notify();
  }

  void setSearchAllThreads(bool allThreads) {
    search.update(allThreads: allThreads);
    if (search.query.isNotEmpty) unawaited(updateSearch(search.query));
  }

  void openSettings([SettingsTab tab = SettingsTab.providers]) {
    _commandPaletteOpen = false;
    _settingsTab = tab;
    _settingsOpen = true;
    if (tab == SettingsTab.appearance) {
      unawaited(ensureSystemFontsLoaded());
    }
    _notify();
  }

  void openAssistantEditor([String? assistantId]) {
    _editingAssistantId = assistantId;
    openSettings(SettingsTab.assistants);
  }

  void closeSettings() {
    if (!_settingsOpen) return;
    _settingsOpen = false;
    _notify();
  }

  void setSettingsTab(SettingsTab tab) {
    _settingsTab = tab;
    if (tab == SettingsTab.appearance) {
      unawaited(ensureSystemFontsLoaded());
    }
    _notify();
  }

  void toggleCommandPalette() {
    _commandPaletteOpen = !_commandPaletteOpen;
    _notify();
  }

  void closeCommandPalette() {
    if (!_commandPaletteOpen) return;
    _commandPaletteOpen = false;
    _notify();
  }

  void handleEscape() {
    if (_tabSwitcherOpen) {
      closeTabSwitcher();
      return;
    }
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
    _notify();
  }

  void clearQuote() {
    _quotedExcerpt = null;
    _notify();
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
    if (_disposed) return;
    toast.show(
      ToastMessage(key, actionKey: actionKey, onAction: onAction),
      duration,
    );
  }

  void dismissToast() {
    if (_disposed) return;
    toast.dismiss();
  }

  // --- Settings Persistence ---

  /// Applies [next] at once. Quiet changes (sliders, toggles) are saved after
  /// [FolioController.settingsSaveDebounce] so a drag writes once; other changes
  /// save immediately.
  Future<void> updateSettings(EngineSettings next, {bool quiet = false}) async {
    final seq = ++_settingsSeq;
    _settings = next;
    _sidebarOpen = next.sidebarOpen;
    _onLocaleSynced?.call(next.locale);
    _notify();
    _settingsSaveTimer?.cancel();
    if (quiet) {
      _pendingQuietSettings = next;
      _settingsSaveTimer = Timer(FolioController.settingsSaveDebounce, () {
        _pendingQuietSettings = null;
        unawaited(_persistSettings(seq, next, quiet: true));
      });
      return;
    }
    _pendingQuietSettings = null;
    await _persistSettings(seq, next, quiet: false);
  }

  Future<void> _persistSettings(
    int seq,
    EngineSettings next, {
    required bool quiet,
  }) async {
    try {
      final saved = await _gateway.saveSettings(next);
      // An older save's response never overwrites a newer value.
      if (seq != _settingsSeq) return;
      _settings = saved;
      if (!quiet) {
        showToast(L10nKey.toastSettingsSaved);
      }
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
}
