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

/// Stands in for core's built-in title prompt in widget tests.
const String kTestDefaultTitlePrompt =
    'Write a short title for this conversation.';

/// Test fixture mirroring core's `ProviderDialect` descriptors (`bistre-protocol`).
const List<EngineDialectDescriptor> kTestDialectDescriptors =
    <EngineDialectDescriptor>[
      EngineDialectDescriptor(
        id: 'openai',
        defaultBaseUrl: 'https://api.openai.com/v1',
        endpointPath: '/responses',
        requiresApiKey: true,
      ),
      EngineDialectDescriptor(
        id: 'google_gemini',
        defaultBaseUrl: 'https://generativelanguage.googleapis.com',
        endpointPath: '/v1beta/interactions',
        requiresApiKey: true,
      ),
      EngineDialectDescriptor(
        id: 'anthropic',
        defaultBaseUrl: 'https://api.anthropic.com/v1',
        endpointPath: '/messages',
        requiresApiKey: true,
      ),
      EngineDialectDescriptor(
        id: 'custom_openai',
        defaultBaseUrl: 'http://127.0.0.1:11434/v1',
        endpointPath: '/chat/completions',
        requiresApiKey: false,
      ),
    ];
