part of 'fake_engine_gateway.dart';

/// Chat actions of [FakeEngineGateway]: left-out messages, edited reply versions, side
/// questions, summary and resume, the chat goal, and raw requests (split by responsibility).
mixin _FakeChatActions implements BistreEngineGateway {
  List<EngineNode> get _nodes;
  Future<void> _record(String method, Map<String, Object?> args);

  final Map<String, List<String>> _excluded = <String, List<String>>{};
  final Map<String, EngineThreadGoal> _goals = <String, EngineThreadGoal>{};

  /// Raw exchanges by request id, as core keeps them; tests seed them.
  final Map<String, EngineRawExchange> rawExchanges =
      <String, EngineRawExchange>{};

  /// The answer [askSideQuestion] gives.
  String sideAnswer = 'Side answer';

  @override
  Future<List<String>> setNodeExcluded({
    required String threadId,
    required String nodeId,
    required bool excluded,
  }) async {
    await _record('setNodeExcluded', <String, Object?>{
      'threadId': threadId,
      'nodeId': nodeId,
      'excluded': excluded,
    });
    final ids = (_excluded[threadId] ?? const <String>[])
        .where((id) => id != nodeId)
        .toList();
    if (excluded) ids.add(nodeId);
    _excluded[threadId] = ids;
    return List<String>.unmodifiable(ids);
  }

  @override
  Future<List<String>> listExcludedNodes(String threadId) async =>
      List<String>.unmodifiable(_excluded[threadId] ?? const <String>[]);

  @override
  Future<EngineNode> editReply({
    required String threadId,
    required String nodeId,
    required String content,
  }) async {
    await _record('editReply', <String, Object?>{
      'threadId': threadId,
      'nodeId': nodeId,
      'content': content,
    });
    final source = _nodes.firstWhere((n) => n.id == nodeId);
    final node = EngineNode(
      id: 'edit-${_nodes.length}',
      threadId: threadId,
      parentId: source.parentId,
      role: 'assistant',
      content: content.trim(),
      providerMetaJson: jsonEncode(<String, Object?>{'edited_from': nodeId}),
      createdAtMs: source.createdAtMs + 1,
    );
    _nodes.add(node);
    return node;
  }

  @override
  Future<String> askSideQuestion({
    required String threadId,
    required String question,
  }) async {
    await _record('askSideQuestion', <String, Object?>{
      'threadId': threadId,
      'question': question,
    });
    return sideAnswer;
  }

  @override
  Future<EngineThread> summarizeIntoNewChat(String threadId) async {
    await _record('summarizeIntoNewChat', <String, Object?>{
      'threadId': threadId,
    });
    final source = (await listThreads()).firstWhere((t) => t.id == threadId);
    final fresh = await createThread(
      source.title,
      source.mode,
      assistantId: source.assistantId,
    );
    _nodes.add(
      EngineNode(
        id: 'resume-${_nodes.length}',
        threadId: fresh.id,
        role: 'compaction_summary',
        content: 'Summary of the chat',
        providerMetaJson: '{"compaction":true}',
        createdAtMs: fresh.createdAtMs,
      ),
    );
    return fresh;
  }

  @override
  Future<EngineThreadGoal?> getThreadGoal(String threadId) async =>
      _goals[threadId];

  @override
  Future<EngineThreadGoal?> setThreadGoal({
    required String threadId,
    required String objective,
  }) async {
    await _record('setThreadGoal', <String, Object?>{
      'threadId': threadId,
      'objective': objective,
    });
    final clean = objective.trim();
    if (clean.isEmpty) {
      _goals.remove(threadId);
      return null;
    }
    return _goals[threadId] = EngineThreadGoal(
      objective: clean,
      completed: false,
    );
  }

  /// Closes the chat's goal as `goal_complete` would.
  void completeGoal(String threadId, String summary) {
    final open = _goals[threadId];
    if (open == null) return;
    _goals[threadId] = EngineThreadGoal(
      objective: open.objective,
      completed: true,
      summary: summary,
    );
  }

  @override
  Future<EngineRawExchange?> rawExchange(String requestId) async =>
      rawExchanges[requestId];
}
