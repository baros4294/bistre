part of 'folio_controller.dart';

/// First load, engine-event subscription, and font hydration of [FolioController].
extension FolioBootActions on FolioController {
  /// Whether the first load finished; the shell shows a plain page until [BootState.ready]
  /// so defaults never flash, and a retry screen on [BootState.failed].
  BootState get bootState => _bootState;

  /// Retries a failed first load (the boot screen's "Try again").
  Future<void> retryBootstrap() async {
    final dir = _bootDataDir;
    if (dir == null) return;
    _bootState = BootState.loading;
    notifyListeners();
    await bootstrap(dir);
  }

  /// Subscribes to engine events first, so nothing that happens during startup is missed, and
  /// re-subscribes (bounded) if the stream errors or closes.
  void _subscribeEvents() {
    unawaited(_eventSub?.cancel());
    _eventSub = _gateway.subscribeEvents().listen(
      (event) {
        _eventResubscribesLeft = FolioController._kMaxEventResubscribes;
        _handleEngineEvent(event);
      },
      onError: _onEventStreamLost,
      onDone: () => _onEventStreamLost(null),
    );
  }

  void _onEventStreamLost(Object? error) {
    // A stream closed by our own shutdown is not a lost connection: never resubscribe.
    if (_disposed || _engineShutDown) return;
    if (_eventResubscribesLeft <= 0) {
      _lastDiagnosticKey = error == null
          ? 'diag.runtime.not_initialized'
          : FolioController.extractDiagnosticKey(error);
      notifyListeners();
      return;
    }
    final attempt =
        FolioController._kMaxEventResubscribes - _eventResubscribesLeft;
    _eventResubscribesLeft--;
    unawaited(
      Future<void>.delayed(Duration(milliseconds: 250 << attempt), () {
        if (!_disposed) _subscribeEvents();
      }),
    );
  }

  Future<void> bootstrap(String dataDir) async {
    _bootDataDir = dataDir;
    try {
      _health = await _gateway.init(dataDir);
      _subscribeEvents();
      // Fire-and-forget: platform probes must never block startup.
      unawaited(
        detectLowMemoryHost().then((low) {
          if (low && !_disposed) {
            setLowMemoryMode(true);
            PaintingBinding.instance.imageCache.maximumSizeBytes = 8 << 20;
            unawaited(configureGpuResourceCacheCap(lowMemory: true));
          }
        }),
      );
      // Parallel WAL reads cut 300-chat startup latency ~4-5x vs sequential FFI roundtrips.
      final (
        loadedSettings,
        loadedProviders,
        loadedAssistants,
        loadedThreads,
        rawUiPrefs,
      ) = await (
        _gateway.loadSettings(),
        _gateway.listProviders(),
        _gateway.listAssistants(),
        _gateway.listThreads(),
        _gateway.getKvMeta(kUiPrefsKvKey),
      ).wait;
      // Read before the first chat opens: it decides which chat that is.
      try {
        final uiPrefs = rawUiPrefs == null ? null : jsonDecode(rawUiPrefs);
        if (uiPrefs is Map<String, Object?>) {
          _uiPrefs = UiDisplayPrefs.fromJson(uiPrefs);
        }
      } on FormatException catch (e) {
        _noteNonFatal('ui_prefs_at_launch', e);
      }
      _settings = loadedSettings;
      _sidebarOpen = _settings.sidebarOpen;
      _onLocaleSynced?.call(_settings.locale);
      _providers = loadedProviders;
      _assistants = loadedAssistants;
      _threads = _withoutPendingDeletes(loadedThreads);

      final savedBounds = DesktopWindowBounds.tryParseJson(
        _settings.windowBoundsJson,
      );
      if (savedBounds != null) {
        unawaited(BistreDesktopHost.restoreWindowBounds(savedBounds));
      }

      // An empty last chat is reused rather than adding another empty one.
      final freshAtLaunch =
          _uiPrefs.newChatOnLaunch &&
          _threads.firstOrNull?.activeHeadNodeId != null;
      if (_threads.isEmpty || freshAtLaunch) {
        final created = await _gateway.createThread(
          _defaultThreadTitle,
          'chat',
          topic: 'general',
          assistantId: _assistants.isEmpty
              ? 'default_assistant'
              : _assistants.first.id,
        );
        _threads = <EngineThread>[created, ..._threads];
      }
      await _activateThread(_threads.first);

      // Mark ready immediately so the active chat paints without waiting for non-Frame-1
      // Settings/Studio/Storage metadata.
      _bootState = BootState.ready;
      notifyListeners();

      unawaited(_hydratePostBootMetadata());
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _bootState = BootState.failed;
      notifyListeners();
    }
  }

  /// Hydrates secondary metadata (wallet totals, storage stats, recent runs, power status,
  /// KV prefs, custom fonts) after first paint, notifying only if anything visible changed.
  Future<void> _hydratePostBootMetadata() async {
    try {
      final (spend, dailySpend, stats, runs, power) = await (
        _gateway.getWalletSpendMicros(),
        _gateway.getWalletDailySpendMicros(),
        _gateway.getStorageStats(),
        _gateway.listAgentRuns(limit: 30),
        _gateway.powerGuardStatus(),
      ).wait;
      if (_disposed) return;
      final changed =
          spend != _walletSpendMicros ||
          dailySpend != _walletDailySpendMicros ||
          runs.isNotEmpty;
      _walletSpendMicros = spend;
      _walletDailySpendMicros = dailySpend;
      _storageStats = stats;
      _agentRuns = runs;
      _powerStatus = power;
      await _restoreUnreadDone();
      await _loadAgentWorkspaceConfig();
      await _loadExtendedKvPrefs();
      unawaited(refreshLibrary());
      await _hydrateCustomFontsFromSettings();
      if (_settings.otaAutoCheck && !_disposed) {
        unawaited(checkForUpdates(background: true));
      }
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
      if (!_disposed && changed) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Bistre: post-boot metadata hydration skipped: $e');
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
}
