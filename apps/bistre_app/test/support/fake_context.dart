import 'package:bistre_app/bridge/bistre_engine.dart';

/// Test fake of core's context breakdown: ~4 characters per token over the leaf's ancestry
/// (core counts with BPE), a 128k window and its 15 % reserve.
EngineContextBreakdown estimateFakeBreakdown(
  List<EngineNode> nodes,
  String leafNodeId,
  String draft,
) {
  final byId = <String, EngineNode>{for (final n in nodes) n.id: n};
  var chars = 0;
  var turns = 0;
  var node = byId[leafNodeId];
  for (var hops = 0; node != null && hops <= nodes.length; hops++) {
    chars += node.content.length;
    turns++;
    final parent = node.parentId;
    node = parent == null ? null : byId[parent];
  }
  final history = (chars + 3) ~/ 4;
  final draftTokens = (draft.trim().length + 3) ~/ 4;
  return EngineContextBreakdown(
    categories: <EngineContextCategory>[
      EngineContextCategory(kind: 'messages', tokens: history, count: turns),
      if (draftTokens > 0)
        EngineContextCategory(kind: 'draft', tokens: draftTokens),
    ],
    totalSent: history + draftTokens,
    limitTokens: 128000,
    reserveTokens: 19200,
  );
}
