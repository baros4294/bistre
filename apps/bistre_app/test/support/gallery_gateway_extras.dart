/// Request inspection, provider share codes, use per purpose, compaction, and windowed
/// history of the gallery gateway (split out of `gallery_harness.dart`).
library;

import 'package:bistre_app/bridge/bistre_engine.dart';

mixin GalleryGatewayExtras implements BistreEngineGateway {
  @override
  Future<List<String>> setNodeExcluded({
    required String threadId,
    required String nodeId,
    required bool excluded,
  }) async => excluded ? <String>[nodeId] : const <String>[];

  @override
  Future<List<String>> listExcludedNodes(String threadId) async =>
      const <String>[];

  @override
  Future<EngineNode> editReply({
    required String threadId,
    required String nodeId,
    required String content,
  }) async => EngineNode(
    id: '$nodeId-edit',
    threadId: threadId,
    role: 'assistant',
    content: content,
    createdAtMs: 1700000008000,
  );

  @override
  Future<String> askSideQuestion({
    required String threadId,
    required String question,
  }) async => 'Answer';

  @override
  Future<EngineThread> summarizeIntoNewChat(String threadId) async =>
      (await listThreads()).first;

  @override
  Future<EngineThreadGoal?> getThreadGoal(String threadId) async => null;

  @override
  Future<EngineThreadGoal?> setThreadGoal({
    required String threadId,
    required String objective,
  }) async => objective.trim().isEmpty
      ? null
      : EngineThreadGoal(objective: objective.trim(), completed: false);

  @override
  Future<EngineRawExchange?> rawExchange(String requestId) async => null;

  @override
  Future<List<EngineChatFile>> listChatFiles(String threadId) async =>
      const <EngineChatFile>[];

  @override
  Future<List<EngineSkillIndex>> listAppSkills() async =>
      const <EngineSkillIndex>[];

  @override
  Future<EngineSkillIndex> installSkill(String source) async =>
      EngineSkillIndex(name: source, description: '', path: source);

  @override
  Future<EngineSkillIndex> saveReplyAsSkill({
    required String threadId,
    required String nodeId,
  }) async => const EngineSkillIndex(name: 'saved', description: '', path: '');

  @override
  Future<void> removeAppSkill(String skillPath) async {}

  /// Projects the sidebar and Settings > Projects show; empty unless a scene seeds one.
  final List<EngineProject> projects = <EngineProject>[];

  @override
  Future<List<EngineProject>> listProjects() async =>
      List<EngineProject>.of(projects);

  @override
  Future<EngineProject> saveProject(EngineProject project) async => project;

  @override
  Future<void> deleteProject(String projectId) async {}

  @override
  Future<String> draftNextMessage({
    required String threadId,
    required String note,
  }) async => 'Draft';

  @override
  Future<String> regenerateReplyGuided({
    required String threadId,
    required String userNodeId,
    required String guidance,
  }) async => 'run';

  @override
  Future<int> exportChatsZip(String destPath) async => 0;

  @override
  Future<int> importChatsZip(String srcPath) async => 0;

  @override
  Future<void> exportCharacterCardPng({
    required String cardId,
    required String destPath,
  }) async {}

  @override
  Future<void> requestDataWipe() async {}

  @override
  Future<bool> cancelDataWipe() async => false;

  @override
  Future<bool> dataWipePending() async => false;

  @override
  Future<void> setMcpToken({
    required String serverId,
    required String token,
  }) async {}

  @override
  Future<bool> hasMcpToken(String serverId) async => false;

  @override
  Future<EngineNode> compactThread({
    required String threadId,
    int keepRecentTurns = 4,
    String? customSummary,
    String? instructions,
  }) async => EngineNode(
    id: 'compact-1',
    threadId: threadId,
    role: 'compaction_summary',
    content: customSummary ?? 'Summary',
    createdAtMs: 1700000007000,
  );

  @override
  Future<EngineNode> rewriteCompactionSummary({
    required String threadId,
    required String nodeId,
    required String content,
  }) async => EngineNode(
    id: nodeId,
    threadId: threadId,
    role: 'compaction_summary',
    content: content,
    createdAtMs: 1700000007000,
  );

  @override
  Future<void> undoCompaction({
    required String threadId,
    required String compactionNodeId,
  }) async {}

  @override
  Future<EngineMcpRegistryPage> searchMcpRegistry(
    String query, {
    String? cursor,
  }) async => const EngineMcpRegistryPage(
    entries: <EngineMcpRegistryEntry>[
      EngineMcpRegistryEntry(
        name: 'io.github.acme/notes',
        description: 'Read and write notes in your notebook.',
        version: '1.2.0',
        server: EngineMcpServerConfig(
          id: 'mcp_gallery_notes',
          name: 'notes',
          transport: 'http',
          url: 'https://notes.acme.example/mcp',
          enabled: false,
        ),
      ),
      EngineMcpRegistryEntry(
        name: 'io.github.acme/files',
        description: 'Files on this computer, through a local helper program.',
        version: '0.3.1',
        server: EngineMcpServerConfig(
          id: 'mcp_gallery_files',
          name: 'files',
          transport: 'stdio',
          command: 'npx',
          args: <String>['-y', '@acme/files-mcp@0.3.1'],
          enabled: false,
        ),
      ),
    ],
  );

  @override
  Future<EngineInspectedRequest> inspectNextRequest({
    required String threadId,
    required String draft,
  }) async => const EngineInspectedRequest(
    method: 'POST',
    url: 'https://api.openai.com/v1/responses',
    dialect: 'openai',
    model: 'gpt-4.1',
    headers: <(String, String)>[('content-type', 'application/json')],
    bodyJson: '{"model":"gpt-4.1","store":false}',
  );

  static const String _shareCode = 'ai-provider:v1:eyJuYW1lIjoiT3BlbkFJIn0';

  @override
  Future<String> exportProviderShareCode({
    required String providerId,
    bool includeApiKey = false,
  }) async => _shareCode;

  /// Only the code [exportProviderShareCode] gives is read; anything else fails like core.
  @override
  Future<EngineProvider> importProviderShareCode(String code) async {
    if (code.trim() != _shareCode) {
      throw StateError('diag.validation.invalid_input');
    }
    return (await listProviders()).first;
  }

  @override
  Future<List<EngineNode>> listNodesWindow({
    required String threadId,
    String? beforeNodeId,
    required int limit,
  }) async {
    final thread = await listNodes(threadId);
    final end = beforeNodeId == null
        ? thread.length
        : thread.indexWhere((n) => n.id == beforeNodeId);
    final cap = limit.clamp(1, 500);
    return thread.sublist(end > cap ? end - cap : 0, end < 0 ? 0 : end);
  }

  @override
  Future<int> getThreadSpendMicros(String threadId) async => 0;

  @override
  Future<int> threadHistoryRev(String threadId) async =>
      (await listNodes(threadId)).length;

  @override
  Future<List<EnginePurposeUsage>> getWalletUsageByPurpose(
    DateTime since,
  ) async => const <EnginePurposeUsage>[
    EnginePurposeUsage(
      purpose: EngineSpendPurpose.chat,
      requests: 214,
      costMicros: 18420000,
    ),
    EnginePurposeUsage(
      purpose: EngineSpendPurpose.title,
      requests: 31,
      costMicros: 12000,
    ),
    EnginePurposeUsage(
      purpose: EngineSpendPurpose.translation,
      requests: 1,
      costMicros: 3000,
    ),
  ];
}
