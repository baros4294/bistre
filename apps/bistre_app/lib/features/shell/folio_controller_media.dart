part of 'folio_controller.dart';

/// Multi-key vault management, hidden model filters, live catalog fill, export/import,
/// storage file manager, immediate steering, OS dictation, Live TTS, and Live Voice sessions.
extension FolioControllerMedia on FolioController {
  /// The last update error (A-W 7c): shown only in Updates, never in the chat composer.
  String? get lastOtaDiagnostic => _lastOtaDiagnostic;
  String? get lastOtaDetail => _lastOtaDetail;
  String? get retryReasonDetail => _retryReasonDetail;

  /// Which automatic try the current wait follows (P20); `null` when core did not say.
  int? get backoffAttempt => _backoffAttempt;
  List<EngineStorageFileEntry> get storageFiles => _storageFiles;
  String? get speakingNodeId => _speakingNodeId;
  bool get dictatingActive => _dictatingActive;
  bool get liveVoiceActive => _liveVoiceSessionId != null;
  String? get liveVoiceSessionId => _liveVoiceSessionId;
  String get liveVoiceState => _liveVoiceState;
  String? get liveVoiceError => _liveVoiceError;
  String get liveVoiceTranscript => _liveVoiceTranscript;

  // --- Multi-key Vault Reveal & Management (#4) ---

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

  // --- Per-Model Hidden/Deleted Filter (#6) ---

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

  // --- Live Catalog Lookup (#12) ---

  Future<EngineModelCatalogInfo?> lookupModelCatalogInfo(String modelId) async {
    try {
      var info = await _gateway.lookupModelCatalogInfo(modelId);
      if (info == null) {
        await _gateway.refreshPrices();
        info = await _gateway.lookupModelCatalogInfo(modelId);
      }
      return info;
    } catch (e) {
      _noteNonFatal('lookup_model_catalog_info', e);
      return null;
    }
  }

  // --- Export / Import & Storage File Manager (#17) ---

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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
    }
  }

  Future<bool> exportAllThreadsToFile(String filePath) async {
    try {
      final jsonText = await _gateway.exportAllThreadsJson();
      await File(filePath).writeAsString(jsonText);
      showToast(L10nKey.toastExported);
      return true;
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
    }
  }

  Future<bool> importSettingsFromFile(String filePath) async {
    final String raw;
    try {
      raw = await File(filePath).readAsString();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
    }
    return importSettingsJson(raw);
  }

  /// Imports settings JSON. A file that would loosen trust or the spending limit is not
  /// applied; a toast explains it and offers "Import anyway" (A-S3).
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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<int> cleanUnusedStorageFiles() async {
    try {
      final freed = await _gateway.cleanUnusedStorageFiles();
      await refreshStorageFiles();
      showToast(L10nKey.toastStorageCleaned);
      return freed;
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return 0;
    }
  }

  // --- Immediate Steer Now (#19) ---

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
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
    }
  }

  Future<void> promoteQueuedSteeringNow(EngineSteeringMessage item) async {
    await removeSteeringMessage(item.id);
    await steerActiveRunNow(item.content);
  }

  // --- OS Dictation Mic (#22) ---

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
      final provider = activeProvider;
      final model = activeModelId.toLowerCase();
      final isTtsModel = model.contains('tts') || model.contains('audio');
      if (provider != null && isTtsModel) {
        final wavBytes = await _gateway.synthesizeSpeech(
          providerId: provider.id,
          modelId: activeModelId,
          text: clean,
        );
        if (wavBytes.isNotEmpty) {
          await BistreDesktopHost.playWavBytes(wavBytes);
          return;
        }
      }
      // Fallback to OS native speech synthesis when active model is text-only.
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
        voice: provider.dialect == 'google_gemini' ? 'Kore' : 'alloy',
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
      await BistreDesktopHost.startMicCapture();
      _notify();
    } catch (e) {
      _liveVoiceSessionId = null;
      _liveVoiceState = 'error';
      _liveVoiceError = e.toString();
      _notify();
    }
  }

  Future<void> stopLiveVoice() async {
    final sid = _liveVoiceSessionId;
    _liveVoiceSessionId = null;
    _liveVoiceState = 'idle';
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
      _liveVoiceError = event.detail ?? 'Live voice connection failed';
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
    final prefix = event.role == 'user' ? 'You: ' : 'AI: ';
    if (event.isFinal || _liveVoiceTranscript.length > 600) {
      _liveVoiceTranscript = '$prefix${event.text}';
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
}
