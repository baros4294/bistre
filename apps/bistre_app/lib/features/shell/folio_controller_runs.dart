part of 'folio_controller.dart';

/// What a chat's run is doing, as the sidebar shows it (U11, Kelivo #1538).
enum ThreadRunState { idle, running, awaitingApproval, doneUnread, failed }

/// What the Android foreground service should do (P13, P15).
@immutable
class AndroidServicePlan {
  const AndroidServicePlan({
    required this.run,
    required this.activeCount,
    required this.holdLocks,
  });

  final bool run;
  final int activeCount;

  /// Whether the wake and Wi-Fi locks are held: not while every run waits for the user.
  final bool holdLocks;

  @override
  bool operator ==(Object other) =>
      other is AndroidServicePlan &&
      other.run == run &&
      other.activeCount == activeCount &&
      other.holdLocks == holdLocks;

  @override
  int get hashCode => Object.hash(run, activeCount, holdLocks);
}

/// P13: the service follows the number of live runs (it stopped when any run finished);
/// P15: while every live run waits for an approval it keeps no wake lock.
AndroidServicePlan androidServicePlan({
  required int liveRuns,
  required int waitingForApproval,
  required bool keepAwake,
}) => AndroidServicePlan(
  run: keepAwake && liveRuns > 0,
  activeCount: liveRuns,
  holdLocks: keepAwake && liveRuns > waitingForApproval,
);

/// Most workspace entries the `@` menu lists (U19).
const int kMaxWorkspaceEntries = 12;

/// Longest tool output a timeline row keeps (U9); the full output stays in the chat history.
const int kMaxToolActivityOutputChars = 16 * 1024;

/// Most tool rows kept per chat (U9).
const int kMaxToolActivitiesPerThread = 200;

/// Live runs per chat (U11): any number of chats may reply at once, each with its own Stop,
/// live text, tool rows and approvals; nothing is keyed to "the" streaming chat.
extension FolioRunState on FolioController {
  /// The state the sidebar shows for [threadId].
  ThreadRunState threadRunState(String threadId) {
    if (_liveRuns.containsKey(threadId)) {
      final waiting =
          (_toolActivitiesByThread[threadId] ?? const <ToolActivityEntry>[])
              .any((e) => e.status == 'awaiting_approval') ||
          _latestRunOf(threadId)?.status == 'waiting_approval';
      return waiting ? ThreadRunState.awaitingApproval : ThreadRunState.running;
    }
    if (_unreadDone.contains(threadId)) {
      return _latestRunOf(threadId)?.status == 'failed'
          ? ThreadRunState.failed
          : ThreadRunState.doneUnread;
    }
    return ThreadRunState.idle;
  }

  EngineAgentRun? _latestRunOf(String threadId) {
    EngineAgentRun? latest;
    for (final run in _agentRuns) {
      if (run.threadId != threadId) continue;
      if (latest == null || run.updatedAtMs > latest.updatedAtMs) latest = run;
    }
    return latest;
  }

  void _onRunStarted(String threadId, String nodeId) {
    final isNewRun = !_liveRuns.containsKey(threadId);
    _liveRuns[threadId] = nodeId;
    _unreadDone.remove(threadId);
    if (isNewRun) {
      // U9: a new run starts with no rows from earlier runs (steps of one run keep theirs).
      _toolActivitiesByThread.remove(threadId);
    }
    if (threadId == _activeThread?.id) {
      liveTurn.start(threadId, nodeId);
    } else {
      _backgroundTurns[threadId] = LiveTurn(threadId: threadId, nodeId: nodeId);
    }
  }

  void _onTextDelta(String threadId, String delta, String nodeId) {
    if (liveTurn.value?.threadId == threadId) {
      liveTurn.appendText(threadId, delta, nodeId: nodeId);
      return;
    }
    final turn = _backgroundTurns[threadId];
    if (turn == null || (nodeId.isNotEmpty && turn.nodeId != nodeId)) return;
    _backgroundTurns[threadId] = turn.copyWith(text: '${turn.text}$delta');
  }

  void _onThinkingDelta(String threadId, String delta, String nodeId) {
    if (liveTurn.value?.threadId == threadId) {
      liveTurn.appendThinking(threadId, delta, nodeId: nodeId);
      return;
    }
    final turn = _backgroundTurns[threadId];
    if (turn == null || (nodeId.isNotEmpty && turn.nodeId != nodeId)) return;
    _backgroundTurns[threadId] = turn.copyWith(
      thinking: '${turn.thinking}$delta',
    );
  }

  /// Returns whether [threadId]'s live run ended with this event.
  bool _onRunFinished(
    String threadId,
    String nodeId, {
    required bool cancelled,
  }) {
    final live = _liveRuns[threadId];
    if (live == null || (nodeId.isNotEmpty && live != nodeId)) return false;
    _endLiveRun(threadId);
    if (threadId != _activeThread?.id && !cancelled) _unreadDone.add(threadId);
    return true;
  }

  void _endLiveRun(String threadId) {
    _liveRuns.remove(threadId);
    _backgroundTurns.remove(threadId);
    if (liveTurn.value?.threadId == threadId) liveTurn.clear();
    if (threadId == _activeThread?.id) {
      _backoffRetryAt = null;
      _retryReasonDetail = null;
    }
  }

  /// U10: a chat whose `RunFinished` was lost (lagged events) is checked against core's run
  /// list; one with no active run there stops showing Stop and "Replying".
  Future<void> _reconcileLiveRuns() async {
    if (_liveRuns.isEmpty) return;
    try {
      _agentRuns = await _gateway.listAgentRuns(limit: 30);
    } catch (e) {
      _noteNonFatal('runs_reconcile', e);
      return;
    }
    final stale = <String>[
      for (final threadId in _liveRuns.keys)
        if (!_agentRuns.any((r) => r.threadId == threadId && r.isActive))
          threadId,
    ];
    for (final threadId in stale) {
      _endLiveRun(threadId);
    }
    if (stale.isNotEmpty) _notify();
  }

  /// P19: the app came back to the foreground.
  Future<void> onAppResumed() async {
    try {
      await _gateway.notifyPowerEvent('app_resumed');
    } catch (e) {
      _noteNonFatal('app_resumed', e);
    }
    await _reconcileLiveRuns();
  }

  /// Moves the live text between the leaf notifier and the background buffers when the open
  /// chat changes, so a chat opened mid-reply shows its text so far.
  void _swapLiveTurnFor(String? previousThreadId, String nextThreadId) {
    final current = liveTurn.value;
    if (previousThreadId != null &&
        current != null &&
        current.threadId == previousThreadId &&
        _liveRuns.containsKey(previousThreadId)) {
      _backgroundTurns[previousThreadId] = current;
    }
    final nodeId = _liveRuns[nextThreadId];
    if (nodeId == null) {
      if (current != null && current.threadId != nextThreadId) liveTurn.clear();
      return;
    }
    final stored = _backgroundTurns.remove(nextThreadId);
    liveTurn
      ..start(nextThreadId, nodeId)
      ..seed(text: stored?.text ?? '', thinking: stored?.thinking ?? '');
  }

  /// Records a tool row for its own chat (U4: a background chat's approval waits there).
  void _recordToolActivityFor(ToolActivityEntry entry) {
    final capped = entry.outputText.length > kMaxToolActivityOutputChars
        ? entry.copyWithOutput(
            entry.outputText.substring(0, kMaxToolActivityOutputChars),
          )
        : entry;
    final list = List<ToolActivityEntry>.of(
      _toolActivitiesByThread[entry.threadId] ?? const <ToolActivityEntry>[],
    );
    final idx = list.indexWhere(
      (e) => e.id == capped.id && e.runId == capped.runId,
    );
    if (idx >= 0) {
      list[idx] = capped;
    } else {
      list.add(capped);
      if (list.length > kMaxToolActivitiesPerThread) list.removeAt(0);
    }
    _toolActivitiesByThread[entry.threadId] = list;
    _notify();
    // P15: a run that starts or stops waiting for an approval changes whether locks are held.
    if (entry.status == 'awaiting_approval' || idx >= 0) {
      unawaited(_syncAndroidService());
    }
  }

  /// P23: opens [threadId] at [nodeId]: selects the branch that holds the message, then asks
  /// the feed to scroll it into view.
  Future<void> revealNode(String threadId, String nodeId) async {
    if (_activeThread?.id != threadId) await selectThread(threadId);
    if (_activeThread?.id != threadId) return;
    final byId = <String, EngineNode>{for (final n in _nodes) n.id: n};
    final grouped = _childrenByParent;
    final seen = <String>{};
    var current = byId[nodeId];
    if (current == null) return;
    while (current != null && seen.add(current.id)) {
      final key = current.parentId ?? '__root__';
      final idx = (grouped[key] ?? const <EngineNode>[]).indexWhere(
        (n) => n.id == current!.id,
      );
      if (idx >= 0) _selectedChildIndex[key] = idx;
      final parentId = current.parentId;
      current = parentId == null ? null : byId[parentId];
    }
    _notify();
    revealRequest
      ..value = null
      ..value = nodeId;
  }

  /// Brings the Android service in line with the live runs (P13, P15).
  Future<void> _syncAndroidService() async {
    if (!BistrePowerGuardHost.isAndroid) return;
    final waiting = _liveRuns.keys
        .where((t) => threadRunState(t) == ThreadRunState.awaitingApproval)
        .length;
    final plan = androidServicePlan(
      liveRuns: _liveRuns.length,
      waitingForApproval: waiting,
      keepAwake: _settings.keepAwakeWhileRunning,
    );
    final state = plan.run
        ? await BistrePowerGuardHost.startAndroidAgentService(
            activeCount: plan.activeCount,
            holdLocks: plan.holdLocks,
            summary: _activeThread?.title ?? _defaultThreadTitle,
          )
        : await BistrePowerGuardHost.stopAndroidAgentService();
    try {
      _powerStatus = await _gateway.setAndroidPowerState(
        fgsActive: state.fgsActive,
        batteryUnrestricted: state.batteryUnrestricted,
      );
      _notify();
    } catch (e) {
      _noteNonFatal('android_fgs_sync', e);
    }
  }
}
