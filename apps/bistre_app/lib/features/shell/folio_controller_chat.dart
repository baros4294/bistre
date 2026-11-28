part of 'folio_controller.dart';

/// The open chat's left-out messages and goal, and the side question shown beside it.
class _ChatActionState {
  Set<String> excluded = const <String>{};
  EngineThreadGoal? goal;

  /// The side question asked last, its answer (null while it is answered), and whether it
  /// is still being answered.
  String sideQuestion = '';
  String? sideAnswer;
  bool sideBusy = false;
}

/// Chat actions beside the runs: leaving messages out of the context, a reply edited as a
/// new version, side questions, summary and resume, the chat goal, and raw requests.
extension FolioChatActions on FolioController {
  /// Whether [nodeId] is left out of the chat's context.
  bool isExcluded(String nodeId) => _chatState.excluded.contains(nodeId);

  /// The open chat's goal, or null.
  EngineThreadGoal? get threadGoal => _chatState.goal;

  String get sideQuestion => _chatState.sideQuestion;
  String? get sideAnswer => _chatState.sideAnswer;

  /// Reloads the open chat's left-out messages and goal.
  Future<void> refreshChatActionState() async {
    final threadId = _activeThread?.id;
    if (threadId == null) return;
    try {
      final excluded = await _gateway.listExcludedNodes(threadId);
      final goal = await _gateway.getThreadGoal(threadId);
      if (_disposed || _activeThread?.id != threadId) return;
      _chatState
        ..excluded = excluded.toSet()
        ..goal = goal;
      _notify();
    } catch (e) {
      _noteNonFatal('chat_action_state', e);
    }
  }

  /// Leaves [nodeId] out of the chat's context, or brings it back.
  Future<void> toggleNodeExcluded(String nodeId) async {
    final threadId = _activeThread?.id;
    if (threadId == null) return;
    final leaveOut = !isExcluded(nodeId);
    try {
      final ids = await _gateway.setNodeExcluded(
        threadId: threadId,
        nodeId: nodeId,
        excluded: leaveOut,
      );
      if (_activeThread?.id != threadId) return;
      _chatState.excluded = ids.toSet();
      showToast(leaveOut ? L10nKey.toastLeftOut : L10nKey.toastBroughtBack);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// Saves [content] as a new version of the reply [nodeId] and shows it. Returns whether it
  /// was saved.
  Future<bool> editReplyAsNewVersion(String nodeId, String content) async {
    final active = _activeThread;
    if (active == null || content.trim().isEmpty) return false;
    try {
      final node = await _gateway.editReply(
        threadId: active.id,
        nodeId: nodeId,
        content: content,
      );
      await _reloadActiveNodes(active.id);
      final loaded = _nodes.where((n) => n.id == node.id).firstOrNull;
      if (loaded != null) {
        selectSiblingNodeById(_parentKeyOf(loaded), loaded.id);
      }
      showToast(L10nKey.toastVersionSaved);
      _notify();
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// `/btw`: answers [question] about the open chat beside it; nothing joins the chat.
  Future<void> askSideQuestion(String question) async {
    final threadId = _activeThread?.id;
    final q = question.trim();
    if (threadId == null || q.isEmpty || _chatState.sideBusy) return;
    _chatState
      ..sideQuestion = q
      ..sideAnswer = null
      ..sideBusy = true;
    _notify();
    try {
      final answer = await _gateway.askSideQuestion(
        threadId: threadId,
        question: q,
      );
      if (_activeThread?.id == threadId) _chatState.sideAnswer = answer;
      _walletSpendMicros = await _gateway.getWalletSpendMicros();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _chatState.sideQuestion = '';
    } finally {
      _chatState.sideBusy = false;
      _notify();
    }
  }

  /// Closes the side question.
  void dismissSideQuestion() {
    _chatState
      ..sideQuestion = ''
      ..sideAnswer = null;
    _notify();
  }

  /// `/summarize`: opens a new chat that starts from a summary of this one.
  Future<void> summarizeIntoNewChat() async {
    final active = _activeThread;
    if (active == null || visibleBranchNodes.isEmpty) return;
    showToast(L10nKey.toastSummarizing);
    try {
      final fresh = await _gateway.summarizeIntoNewChat(active.id);
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      await _activateThread(fresh);
      _walletSpendMicros = await _gateway.getWalletSpendMicros();
      showToast(L10nKey.toastResumedFromSummary, tone: ToastTone.ok);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// `/goal`: sets a new goal for the open chat; blank [objective] clears it.
  Future<void> setThreadGoal(String objective) async {
    final threadId = _activeThread?.id;
    if (threadId == null) return;
    try {
      final goal = await _gateway.setThreadGoal(
        threadId: threadId,
        objective: objective,
      );
      if (_activeThread?.id != threadId) return;
      _chatState.goal = goal;
      showToast(goal == null ? L10nKey.toastGoalCleared : L10nKey.toastGoalSet);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// The raw request and response of [node] while core keeps them, else null.
  Future<EngineRawExchange?> rawExchangeFor(EngineNode node) async {
    final requestId = node.usageMeta?.requestId ?? '';
    if (requestId.isEmpty) return null;
    try {
      return await _gateway.rawExchange(requestId);
    } catch (e) {
      _noteNonFatal('raw_exchange', e);
      return null;
    }
  }
}
