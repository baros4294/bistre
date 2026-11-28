part of 'bistre_engine.dart';

/// Chat action calls of [FrbBistreEngineGateway]: left-out messages, edited reply versions,
/// side questions, summary and resume, the chat goal, and a reply's raw request.
mixin _FrbChatActionsMixin {
  Future<List<String>> setNodeExcluded({
    required String threadId,
    required String nodeId,
    required bool excluded,
  }) => frb.setNodeExcluded(
    threadId: threadId,
    nodeId: nodeId,
    excluded: excluded,
  );

  Future<List<String>> listExcludedNodes(String threadId) =>
      frb.listExcludedNodes(threadId: threadId);

  Future<EngineNode> editReply({
    required String threadId,
    required String nodeId,
    required String content,
  }) async => _mapNode(
    await frb.editReply(threadId: threadId, nodeId: nodeId, content: content),
  );

  Future<String> askSideQuestion({
    required String threadId,
    required String question,
  }) => frb.askSideQuestion(threadId: threadId, question: question);

  Future<EngineThread> summarizeIntoNewChat(String threadId) async =>
      _mapThread(await frb.summarizeIntoNewChat(threadId: threadId));

  Future<EngineThreadGoal?> getThreadGoal(String threadId) async =>
      _mapGoal(await frb.getThreadGoal(threadId: threadId));

  Future<EngineThreadGoal?> setThreadGoal({
    required String threadId,
    required String objective,
  }) async => _mapGoal(
    await frb.setThreadGoal(threadId: threadId, objective: objective),
  );

  Future<EngineRawExchange?> rawExchange(String requestId) async {
    final raw = await frb.rawExchange(requestId: requestId);
    if (raw == null) return null;
    return EngineRawExchange(
      url: raw.url,
      requestBody: raw.requestBody,
      response: raw.response,
      truncated: raw.truncated,
    );
  }
}

EngineThreadGoal? _mapGoal(frb.FfiThreadGoal? g) => g == null
    ? null
    : EngineThreadGoal(
        objective: g.objective,
        completed: g.completed,
        summary: g.summary,
      );
