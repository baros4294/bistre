part of 'folio_controller.dart';

/// Multi-key vault management, hidden model filters, live catalog fill, export/import,
/// storage file manager, immediate steering, OS dictation, Live TTS, and Live Voice sessions.
extension FolioControllerMedia on FolioController {
  /// The last update error: shown only in Updates, never in the chat composer.
  String? get lastOtaDiagnostic => _lastOtaDiagnostic;
  String? get lastOtaDetail => _lastOtaDetail;
  String? get retryReasonDetail => _retryReasonDetail;

  /// Which automatic try the current wait follows; `null` when core did not say.
  int? get backoffAttempt => _backoffAttempt;
  List<EngineStorageFileEntry> get storageFiles => _storageFiles;
  String? get speakingNodeId => _speakingNodeId;
  bool get dictatingActive => _dictatingActive;
  bool get liveVoiceActive => _liveVoiceSessionId != null;
  String? get liveVoiceSessionId => _liveVoiceSessionId;
  String get liveVoiceState => _liveVoiceState;
  String? get liveVoiceError => _liveVoiceError;
  String get liveVoiceTranscript => _liveVoiceTranscript;

  /// Whether the transcript line is the user's words (else the model's).
  bool get liveVoiceTranscriptIsUser => _liveVoiceTranscriptIsUser;

  // --- Multi-key Vault Reveal & Management ---

  Future<List<String>> loadProviderApiKeys(String providerId) async {
    try {
      return await _gateway.getProviderApiKeys(providerId);
    } catch (e) {
      _noteNonFatal('load_provider_api_keys', e);
      return const <String>[];
    }
  }

  Future<bool> addProviderApiKey(String providerId, String rawInput) async {
    final clean = rawInput.trim();
    if (clean.isEmpty) return false;
    final existing = await loadProviderApiKeys(providerId);
    final merged = <String>[
      ...existing,
      for (final part in clean.split(RegExp(r'[\s,;]+')))
        if (part.trim().isNotEmpty && !existing.contains(part.trim()))
          part.trim(),
    ];
    if (merged.isEmpty) return false;
    return saveProviderApiKey(providerId, merged.join('\n'));
  }

  Future<bool> removeProviderApiKeyAt(String providerId, int index) async {
    final existing = List<String>.of(await loadProviderApiKeys(providerId));
    if (index < 0 || index >= existing.length) return false;
    existing.removeAt(index);
    if (existing.isEmpty) {
      await clearProviderApiKey(providerId);
      return true;
    }
    return saveProviderApiKey(providerId, existing.join('\n'));
  }

  Future<bool> promoteProviderApiKey(String providerId, int index) async {
    final existing = List<String>.of(await loadProviderApiKeys(providerId));
    if (index <= 0 || index >= existing.length) return false;
    final promoted = existing.removeAt(index);
    existing.insert(0, promoted);
    return saveProviderApiKey(providerId, existing.join('\n'));
  }

  // --- Per-Model Hidden/Deleted Filter ---

  Set<String> hiddenModelIdsFor(String providerId) =>
      _hiddenModelsByProvider[providerId] ?? const <String>{};

  Future<void> ensureHiddenModelsLoaded(String providerId) async {
    if (_hiddenModelsByProvider.containsKey(providerId)) return;
    try {
      final raw = await _gateway.getKvMeta(
        'provider.hidden_models:$providerId',
      );
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List<Object?>) {
          _hiddenModelsByProvider[providerId] = decoded
              .whereType<String>()
              .toSet();
          _notify();
          return;
        }
      }
    } catch (e) {
      _noteNonFatal('hidden_models_load', e);
    }
    _hiddenModelsByProvider[providerId] = <String>{};
  }

  Future<void> hideModelForProvider(String providerId, String modelId) async {
    await ensureHiddenModelsLoaded(providerId);
    final next = Set<String>.of(
      _hiddenModelsByProvider[providerId] ?? const <String>{},
    )..add(modelId);
    _hiddenModelsByProvider[providerId] = next;
    try {
      await _gateway.setKvMeta(
        'provider.hidden_models:$providerId',
        jsonEncode(next.toList()),
      );
    } catch (e) {
      _noteNonFatal('hidden_models_save', e);
    }
    _notify();
  }

  Future<void> restoreHiddenModelsForProvider(String providerId) async {
    _hiddenModelsByProvider[providerId] = <String>{};
    try {
      await _gateway.setKvMeta('provider.hidden_models:$providerId', '[]');
    } catch (e) {
      _noteNonFatal('hidden_models_restore', e);
    }
    _notify();
  }

  // --- Live Catalog Lookup ---

  Future<EngineModelCatalogInfo?> lookupModelCatalogInfo(
    String providerId,
    String modelId,
  ) async {
    try {
      var info = await _gateway.lookupModelCatalogInfo(providerId, modelId);
      if (info == null) {
        await _gateway.refreshPrices();
        info = await _gateway.lookupModelCatalogInfo(providerId, modelId);
      }
      return info;
    } catch (e) {
      _noteNonFatal('lookup_model_catalog_info', e);
      return null;
    }
  }

  // --- Export / Import & Storage File Manager ---

  Future<bool> exportCurrentThreadToFile(
    String filePath, {
    required String format,
  }) async {
    final active = _activeThread;
    if (active == null) return false;
    try {
      final text = await _gateway.exportThread(
        threadId: active.id,
        format: format,
      );
      await File(filePath).writeAsString(text);
      showToast(L10nKey.toastExported);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  Future<int> importThreadsFromFile(String filePath) async {
    try {
      final raw = await File(filePath).readAsString();
      final count = await _gateway.importThreadsJson(raw);
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      _health = await _gateway.getHealth();
      _storageStats = await _gateway.getStorageStats();
      showToast(L10nKey.toastImported);
      _notify();
      return count;
    } catch (e) {
      _fail(e);
      return 0;
    }
  }

  Future<bool> exportSettingsToFile(String filePath) async {
    try {
      final jsonText = await _gateway.exportSettingsJson();
      await File(filePath).writeAsString(jsonText);
      showToast(L10nKey.toastExported);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  Future<bool> importSettingsFromFile(String filePath) async {
    final String raw;
    try {
      raw = await File(filePath).readAsString();
    } catch (e) {
      _fail(e);
      return false;
    }
    return importSettingsJson(raw);
  }

  /// Imports settings JSON. A file that would loosen trust or the spending limit is not
  /// applied; a toast explains it and offers "Import anyway".
  Future<bool> importSettingsJson(
    String raw, {
    bool allowLoosening = false,
  }) async {
    try {
      _settings = await _gateway.importSettingsJson(
        raw,
        allowLoosening: allowLoosening,
      );
      _onLocaleSynced?.call(_settings.locale);
      showToast(L10nKey.toastImported);
      _notify();
      return true;
    } catch (e) {
      final key = FolioController.extractDiagnosticKey(e);
      if (key == 'diag.import.loosens_safety' && !allowLoosening) {
        showToast(
          L10nKey.diagImportLoosensSafety,
          actionKey: L10nKey.settingsImportAnyway,
          duration: const Duration(seconds: 12),
          onAction: () {
            dismissToast();
            unawaited(importSettingsJson(raw, allowLoosening: true));
          },
        );
        return false;
      }
      _lastDiagnosticKey = key;
      _notify();
      return false;
    }
  }

  /// Settled spend per purpose over the last [days] days; `null` when it could not be read
  /// (logged with its diagnostic key).
  Future<List<EnginePurposeUsage>?> loadUsageByPurpose({int days = 30}) async {
    try {
      return await _gateway.getWalletUsageByPurpose(
        _clock().subtract(Duration(days: days)),
      );
    } catch (e) {
      _noteNonFatal('wallet_usage_by_purpose', e);
      return null;
    }
  }

  Future<void> refreshStorageFiles() async {
    try {
      _storageFiles = await _gateway.listStorageFiles();
      _storageStats = await _gateway.getStorageStats();
      _notify();
    } catch (e) {
      _noteNonFatal('list_storage_files', e);
    }
  }

  Future<void> deleteStorageFile(String relPath) async {
    try {
      await _gateway.deleteStorageFile(relPath);
      await refreshStorageFiles();
    } catch (e) {
      _fail(e);
    }
  }

  Future<int> cleanUnusedStorageFiles() async {
    try {
      final freed = await _gateway.cleanUnusedStorageFiles();
      await refreshStorageFiles();
      showToast(L10nKey.toastStorageCleaned);
      return freed;
    } catch (e) {
      _fail(e);
      return 0;
    }
  }

  // --- Immediate Steer Now ---

  Future<bool> steerActiveRunNow(String text) async {
    final active = _activeThread;
    final clean = text.trim();
    if (active == null || clean.isEmpty) return false;
    try {
      _lastDiagnosticKey = null;
      final committed = await _gateway.steerActiveRunNow(
        threadId: active.id,
        content: clean,
      );
      if (!_nodes.any((n) => n.id == committed.id)) {
        _nodes = <EngineNode>[..._nodes, committed];
      }
      _notify();
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  Future<void> promoteQueuedSteeringNow(EngineSteeringMessage item) async {
    await removeSteeringMessage(item.id);
    await steerActiveRunNow(item.content);
  }

  // --- OS Dictation Mic ---

  Future<String?> dictateVoiceOnce() async {
    if (_dictatingActive) {
      await BistreDesktopHost.stopVoiceDictation();
      _dictatingActive = false;
      _notify();
      return null;
    }
    _dictatingActive = true;
    _notify();
    try {
      final text = await BistreDesktopHost.dictateVoiceOnce();
      return text?.trim().isNotEmpty == true ? text!.trim() : null;
    } finally {
      _dictatingActive = false;
      _notify();
    }
  }

  // --- Live TTS Playback & Live Voice Audio-to-Audio Pill ---

  Future<void> speakAssistantMessage(String nodeId, String text) async {
    if (_speakingNodeId == nodeId) {
      await stopSpeaking();
      return;
    }
    await stopSpeaking();
    final clean = text.trim();
    if (clean.isEmpty) return;
    _speakingNodeId = nodeId;
    _notify();
    try {
      // Settings > Default models names the speech model; without one the system voice reads.
      final speech = readAloudModel;
      if (speech != null) {
        final wavBytes = await _gateway.synthesizeSpeech(
          providerId: speech.provider.id,
          modelId: speech.modelId,
          text: clean,
        );
        if (wavBytes.isNotEmpty) {
          await BistreDesktopHost.playWavBytes(wavBytes);
          return;
        }
      }
      await BistreDesktopHost.speakTextAloud(clean);
    } catch (e) {
      _noteNonFatal('speak_assistant_message', e);
      await BistreDesktopHost.speakTextAloud(clean);
    } finally {
      if (_speakingNodeId == nodeId) {
        _speakingNodeId = null;
        _notify();
      }
    }
  }

  Future<void> stopSpeaking() async {
    _speakingNodeId = null;
    await BistreDesktopHost.stopAudioPlayback();
    _notify();
  }

  Future<void> toggleLiveVoiceSession() async {
    if (_liveVoiceSessionId != null) {
      await stopLiveVoice();
      return;
    }
    final provider = activeProvider;
    final model = activeModelId.trim();
    if (provider == null || model.isEmpty) {
      _lastDiagnosticKey = 'diag.provider.not_configured';
      _notify();
      return;
    }
    _liveVoiceError = null;
    _liveVoiceTranscript = '';
    _liveVoiceState = 'connecting';
    _notify();
    try {
      final assistant = activeAssistant;
      final sysPrompt =
          _activeThread?.systemPromptOverride ?? assistant?.systemPrompt ?? '';
      final sid = await _gateway.startLiveVoiceSession(
        providerId: provider.id,
        modelId: model,
        // Core picks the provider's default voice.
        voice: '',
        systemPrompt: sysPrompt,
      );
      _liveVoiceSessionId = sid;
      BistreDesktopHost.attachMicPcmListener((pcmBase64) {
        final activeSid = _liveVoiceSessionId;
        if (activeSid != null) {
          unawaited(
            _gateway.sendLiveVoicePcmChunk(
              sessionId: activeSid,
              pcmBase64: pcmBase64,
            ),
          );
        }
      });
      if (!await BistreDesktopHost.startMicCapture()) {
        await stopLiveVoice();
        _liveVoiceError = 'diag.voice.mic_unavailable';
      }
      _notify();
    } catch (e) {
      _liveVoiceSessionId = null;
      _liveVoiceState = 'error';
      _liveVoiceError = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> stopLiveVoice() async {
    final sid = _liveVoiceSessionId;
    _liveVoiceSessionId = null;
    _liveVoiceState = 'idle';
    // Ending also dismisses a failed session's notice.
    _liveVoiceError = null;
    BistreDesktopHost.detachMicPcmListener();
    await BistreDesktopHost.stopMicCapture();
    await BistreDesktopHost.stopAudioPlayback();
    if (sid != null) {
      try {
        await _gateway.stopLiveVoiceSession(sid);
      } catch (e) {
        _noteNonFatal('stop_live_voice', e);
      }
    }
    _notify();
  }

  void _handleLiveVoiceStateEvent(LiveVoiceStateEvent event) {
    if (_liveVoiceSessionId != null && event.sessionId != _liveVoiceSessionId) {
      return;
    }
    _liveVoiceState = event.state;
    if (event.state == 'error') {
      _liveVoiceError = FolioController.extractDiagnosticKey(
        event.detail ?? '',
      );
      _liveVoiceSessionId = null;
      BistreDesktopHost.detachMicPcmListener();
      unawaited(BistreDesktopHost.stopMicCapture());
    } else if (event.state == 'closed') {
      _liveVoiceSessionId = null;
      BistreDesktopHost.detachMicPcmListener();
      unawaited(BistreDesktopHost.stopMicCapture());
    }
    _notify();
  }

  void _handleLiveVoiceTranscriptEvent(LiveVoiceTranscriptEvent event) {
    if (event.sessionId != _liveVoiceSessionId) return;
    final isUser = event.role == 'user';
    if (event.isFinal ||
        isUser != _liveVoiceTranscriptIsUser ||
        _liveVoiceTranscript.length > 600) {
      _liveVoiceTranscript = event.text;
      _liveVoiceTranscriptIsUser = isUser;
    } else {
      _liveVoiceTranscript = '$_liveVoiceTranscript${event.text}';
    }
    _notify();
  }

  void _handleLiveVoiceAudioEvent(LiveVoiceAudioEvent event) {
    if (event.sessionId != _liveVoiceSessionId) return;
    try {
      final wavBytes = base64Decode(event.wavBase64);
      if (wavBytes.isNotEmpty) {
        unawaited(BistreDesktopHost.playWavBytes(wavBytes));
      }
    } on FormatException {
      // Ignore malformed audio chunk.
    }
  }

  Future<void> _handleHostActionRequested(
    HostActionRequestedEvent event,
  ) async {
    if (event.requestId.isEmpty) return;
    Map<String, Object?> parsed;
    try {
      final decoded = jsonDecode(event.actionJson);
      parsed = decoded is Map<String, Object?>
          ? decoded
          : const <String, Object?>{};
    } on FormatException {
      await _gateway.respondHostAction(
        requestId: event.requestId,
        ok: false,
        outputText: 'Malformed host action payload.',
      );
      return;
    }
    final res = await BistreDesktopHost.runComputerUseAction(parsed);
    await _gateway.respondHostAction(
      requestId: event.requestId,
      ok: res['ok'] as bool? ?? false,
      outputText: res['outputText'] as String? ?? '',
      imageBase64: res['imageBase64'] as String?,
    );
  }
}
