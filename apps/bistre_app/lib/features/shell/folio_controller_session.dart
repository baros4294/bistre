part of 'folio_controller.dart';

/// Engine events, run refreshes, steering, chat switching, and per-chat overrides of
/// [FolioController].
extension FolioSessionActions on FolioController {
  /// A user action failed: [error]'s diagnostic key becomes the notice.
  void _fail(Object error) {
    _lastDiagnosticKey = FolioController.extractDiagnosticKey(error);
    _notify();
  }

  // --- Engine Event Bus ---

  void _handleEngineEvent(BistreEvent event) {
    switch (event) {
      case RunStartedEvent():
        if (event.threadId == _activeThread?.id) _backoffRetryAt = null;
        _onRunStarted(event.threadId, event.nodeId);
        unawaited(_syncAndroidService());
        unawaited(_refreshRunsAndPower());
        _notify();
      case DeltaBatchEvent():
        // Leaf-only update: no notifyListeners() on the hot path.
        if (_backoffRetryAt != null && event.threadId == _activeThread?.id) {
          _backoffRetryAt = null;
          _notify();
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
        _onStepCommitted(event.node);
        if (_activeThread?.id == event.node.threadId) {
          final exists = _nodes.any((n) => n.id == event.node.id);
          if (!exists) {
            _nodes = <EngineNode>[..._nodes, event.node];
            final parentKey = _parentKeyOf(event.node);
            final siblings = _childrenByParent[parentKey];
            if (siblings != null && siblings.isNotEmpty) {
              _selectedChildIndex[parentKey] = siblings.length - 1;
            }
          }
          _notify();
        }
      case RunFinishedEvent():
        _onRunFinished(
          event.threadId,
          event.nodeId,
          cancelled: event.cancelled,
        );
        if (event.threadId == _activeThread?.id) {
          unawaited(refreshThreadGrounding());
          // `goal_complete` may have closed the goal; the reply may have made files.
          unawaited(refreshChatActionState());
          unawaited(refreshChatFiles());
        }
        if (!event.cancelled && _autoTitledThreads.remove(event.threadId)) {
          unawaited(regenerateThreadTitle(event.threadId, quiet: true));
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
        _notify();
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
          // Only the reason's key is kept; the notice shows it in words (the raw
          // technical detail was shown verbatim).
          _retryReasonDetail = reason;
        } else {
          _lastDiagnosticKey = event.key;
          _lastDiagnosticReason = RegExp(r'(?:^|;)reason=([^;]+)')
              .firstMatch(event.detailCode ?? '')
              ?.group(1);
        }
        _notify();
      case LiveVoiceStateEvent():
        _handleLiveVoiceStateEvent(event);
      case LiveVoiceTranscriptEvent():
        _handleLiveVoiceTranscriptEvent(event);
      case LiveVoiceAudioEvent():
        _handleLiveVoiceAudioEvent(event);
      case HostActionRequestedEvent():
        unawaited(_handleHostActionRequested(event));
      case ToolApprovalRequestedEvent():
        // Recorded for its own chat, open or not; it waits there until answered.
        recordToolActivity(
          ToolActivityEntry(
            id: event.callId,
            toolName: event.toolName,
            // The tool and what it acts on, like every other tool row; the full
            // arguments stay in the expanded detail.
            summary: approvalSummary(event.toolName, event.argumentsJson),
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
        _notify();
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
      final active = _activeThread?.id == threadId;
      final (
        threads,
        spend,
        dailySpend,
        health,
        stats,
        runs,
        power,
        steering,
        _,
      ) = await (
        _gateway.listThreads(),
        _gateway.getWalletSpendMicros(),
        _gateway.getWalletDailySpendMicros(),
        _gateway.getHealth(),
        _gateway.getStorageStats(),
        _gateway.listAgentRuns(limit: 30),
        _gateway.powerGuardStatus(),
        active
            ? _gateway.listPendingSteering(threadId)
            : Future<List<EngineSteeringMessage>?>.value(),
        active ? _reloadActiveNodes(threadId) : Future<void>.value(),
      ).wait;
      _threads = _withoutPendingDeletes(threads);
      _walletSpendMicros = spend;
      _walletDailySpendMicros = dailySpend;
      _health = health;
      _storageStats = stats;
      _agentRuns = runs;
      _powerStatus = power;
      // The user may have switched chats while these loaded.
      if (steering != null && _activeThread?.id == threadId) {
        _pendingSteering = steering;
      }
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _refreshRunsAndPower() async {
    try {
      _agentRuns = await _gateway.listAgentRuns(limit: 30);
      _powerStatus = await _gateway.powerGuardStatus();
      _notify();
    } catch (e) {
      _noteNonFatal('runs_power_refresh', e);
    }
  }

  Future<void> _refreshPendingSteering(String threadId) async {
    try {
      _pendingSteering = await _gateway.listPendingSteering(threadId);
      _notify();
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
      _notify();
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
      _notify();
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  Future<void> removeSteeringMessage(String steeringId) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      await _gateway.deleteSteering(steeringId);
      _pendingSteering = await _gateway.listPendingSteering(active.id);
      _notify();
    } catch (e) {
      _fail(e);
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
      _fail(e);
    }
  }

  /// Whether async work started for [threadId] at [generation] may still change chat state:
  /// the same chat is open and no switch happened since.
  bool _isStillOn(String threadId, int generation) =>
      !_disposed &&
      generation == _threadGeneration &&
      _activeThread?.id == threadId;

  /// Opens [thread]. Its messages, draft, pins and checkpoints load first and are committed
  /// together with the active chat, so nothing can act on a half-switched state.
  Future<void> _activateThread(EngineThread thread) async {
    final generation = ++_threadGeneration;
    if (!_openTabIds.contains(thread.id)) {
      _openTabIds.add(thread.id);
      if (_openTabIds.length > FolioController._kMaxOpenTabs)
        _openTabIds.removeAt(0);
    }
    _switchingToThreadId = thread.id;
    try {
      await _loadAndCommitThread(thread, generation);
      if (generation == _threadGeneration) _syncChatFolder();
    } finally {
      if (generation == _threadGeneration) _switchingToThreadId = null;
    }
  }

  Future<void> _loadAndCommitThread(EngineThread thread, int generation) async {
    final query = search.query;
    final (page, steering, pin, checkpoints, draft, hits) = await (
      _loadNodes(thread.id),
      _gateway.listPendingSteering(thread.id),
      _gateway.getContextStartPin(thread.id),
      _gateway.listCheckpoints(thread.id),
      _gateway.loadDraft(thread.id),
      query.isNotEmpty && !search.allThreads
          ? _gateway.searchNodes(query, threadId: thread.id)
          : Future<List<EngineSearchHit>?>.value(),
    ).wait;
    final spend = page.earlier
        ? await _gateway.getThreadSpendMicros(thread.id)
        : null;
    if (generation != _threadGeneration || _disposed) return;
    _swapLiveTurnFor(_activeThread?.id, thread.id);
    _unreadDone.remove(thread.id);
    unawaited(_markThreadViewed(thread.id));
    _activeThread = thread;
    _activeAssistantId = thread.assistantId;
    _selectedChildIndex.clear();
    _quotedExcerpt = null;
    _nodes = page.nodes;
    _hasEarlierNodes = page.earlier;
    _partialThreadSpendMicros = spend;
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
    _chatState
      ..excluded = const <String>{}
      ..goal = null
      ..sideQuestion = ''
      ..sideAnswer = null;
    unawaited(_loadThreadKvExtras(thread.id, generation));
    unawaited(refreshThreadGrounding());
    unawaited(refreshChatActionState());
    unawaited(refreshChatFiles());
  }

  Future<void> selectThread(String threadId) async {
    final target = _threads.where((t) => t.id == threadId).firstOrNull;
    if (target == null) return;
    try {
      await _activateThread(target);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// Starts a chat (in [projectId] when given) and opens it.
  Future<void> createNewFolio({
    String? title,
    String? assistantId,
    String? projectId,
  }) async {
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
        projectId: projectId,
      );
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      await _activateThread(created);
      _health = await _gateway.getHealth();
      _storageStats = await _gateway.getStorageStats();
      _notify();
    } catch (e) {
      _fail(e);
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
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> renameThread(String threadId, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return;
    _autoTitledThreads.remove(threadId);
    try {
      final updated = await _gateway.updateThread(
        threadId: threadId,
        title: trimmed,
      );
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      if (_activeThread?.id == threadId) {
        if (_activeThread?.id == updated.id) _activeThread = updated;
      }
      _notify();
    } catch (e) {
      _fail(e);
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
      _notify();
    } catch (e) {
      _fail(e);
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
}
