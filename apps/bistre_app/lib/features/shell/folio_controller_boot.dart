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
    if (_disposed) return;
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
            unawaited(configureGpuResourceCacheCap(lowMemory: true));
          }
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

      _bootState = BootState.ready;
      notifyListeners();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _bootState = BootState.failed;
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
}
