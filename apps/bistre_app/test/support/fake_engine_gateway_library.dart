part of 'fake_engine_gateway.dart';

/// Library calls of [FakeEngineGateway]: a chat's files, Bistre's own skills, a drafted
/// message, a guided Regenerate, the chats zip, a PNG card, and erasing the data.
mixin _FakeLibrary implements BistreEngineGateway {
  Future<void> _record(String method, Map<String, Object?> args);

  /// The files [listChatFiles] returns per chat; tests seed them.
  final Map<String, List<EngineChatFile>> chatFiles =
      <String, List<EngineChatFile>>{};

  /// Bistre's skills as installed; tests seed or read them.
  final List<EngineSkillIndex> appSkills = <EngineSkillIndex>[];

  /// The message [draftNextMessage] drafts.
  String draftedMessage = 'Drafted message';

  bool _wipePending = false;

  /// The MCP servers with a token saved.
  final Set<String> mcpTokens = <String>{};

  @override
  Future<List<EngineChatFile>> listChatFiles(String threadId) async =>
      List<EngineChatFile>.unmodifiable(
        chatFiles[threadId] ?? const <EngineChatFile>[],
      );

  @override
  Future<List<EngineSkillIndex>> listAppSkills() async =>
      List<EngineSkillIndex>.unmodifiable(appSkills);

  @override
  Future<EngineSkillIndex> installSkill(String source) async {
    await _record('installSkill', <String, Object?>{'source': source});
    final name = source.split(RegExp(r'[\\/]')).last;
    final skill = EngineSkillIndex(
      name: name,
      description: '',
      path: 'skills/$name/SKILL.md',
    );
    appSkills
      ..removeWhere((s) => s.name == name)
      ..add(skill);
    return skill;
  }

  @override
  Future<EngineSkillIndex> saveReplyAsSkill({
    required String threadId,
    required String nodeId,
  }) async {
    await _record('saveReplyAsSkill', <String, Object?>{
      'threadId': threadId,
      'nodeId': nodeId,
    });
    final skill = EngineSkillIndex(
      name: 'saved-${appSkills.length + 1}',
      description: '',
      path: 'skills/saved-${appSkills.length + 1}/SKILL.md',
    );
    appSkills.add(skill);
    return skill;
  }

  @override
  Future<void> removeAppSkill(String skillPath) async {
    await _record('removeAppSkill', <String, Object?>{'skillPath': skillPath});
    appSkills.removeWhere((s) => s.path == skillPath);
  }

  /// The projects as saved; tests seed or read them.
  final List<EngineProject> projects = <EngineProject>[];

  /// The fake's chats, which a project move or delete rewrites.
  List<EngineThread> get chatThreads;

  @override
  Future<List<EngineProject>> listProjects() async =>
      List<EngineProject>.unmodifiable(projects);

  @override
  Future<EngineProject> saveProject(EngineProject project) async {
    await _record('saveProject', <String, Object?>{
      'id': project.id,
      'name': project.name,
      'folderPath': project.folderPath,
      'instructions': project.instructions,
    });
    final saved = project.id.isEmpty
        ? EngineProject(
            id: 'project-${projects.length + 1}',
            name: project.name.trim(),
            folderPath: project.folderPath.trim(),
            instructions: project.instructions.trim(),
          )
        : project;
    final at = projects.indexWhere((p) => p.id == saved.id);
    if (at < 0) {
      projects.add(saved);
    } else {
      projects[at] = saved;
    }
    return saved;
  }

  @override
  Future<void> deleteProject(String projectId) async {
    await _record('deleteProject', <String, Object?>{'projectId': projectId});
    projects.removeWhere((p) => p.id == projectId);
    final threads = chatThreads;
    for (var i = 0; i < threads.length; i++) {
      if (threads[i].workspaceId == projectId) {
        threads[i] = threads[i].withWorkspace('ws-default');
      }
    }
  }

  @override
  Future<void> moveThreadToProject(String threadId, String? projectId) async {
    await _record('moveThreadToProject', <String, Object?>{
      'threadId': threadId,
      'projectId': projectId,
    });
    final threads = chatThreads;
    final at = threads.indexWhere((t) => t.id == threadId);
    threads[at] = threads[at].withWorkspace(projectId ?? 'ws-default');
  }

  @override
  Future<String> draftNextMessage({
    required String threadId,
    required String note,
  }) async {
    await _record('draftNextMessage', <String, Object?>{
      'threadId': threadId,
      'note': note,
    });
    return draftedMessage;
  }

  @override
  Future<String> regenerateReplyGuided({
    required String threadId,
    required String userNodeId,
    required String guidance,
  }) async {
    await _record('regenerateReplyGuided', <String, Object?>{
      'threadId': threadId,
      'userNodeId': userNodeId,
      'guidance': guidance,
    });
    return 'run-guided';
  }

  @override
  Future<int> exportChatsZip(String destPath) async {
    await _record('exportChatsZip', <String, Object?>{'destPath': destPath});
    return 0;
  }

  @override
  Future<int> importChatsZip(String srcPath) async {
    await _record('importChatsZip', <String, Object?>{'srcPath': srcPath});
    return 1;
  }

  @override
  Future<void> exportCharacterCardPng({
    required String cardId,
    required String destPath,
  }) => _record('exportCharacterCardPng', <String, Object?>{
    'cardId': cardId,
    'destPath': destPath,
  });

  @override
  Future<void> requestDataWipe() async {
    await _record('requestDataWipe', const <String, Object?>{});
    _wipePending = true;
  }

  @override
  Future<bool> cancelDataWipe() async {
    await _record('cancelDataWipe', const <String, Object?>{});
    final was = _wipePending;
    _wipePending = false;
    return was;
  }

  @override
  Future<bool> dataWipePending() async => _wipePending;

  @override
  Future<void> setMcpToken({
    required String serverId,
    required String token,
  }) async {
    await _record('setMcpToken', <String, Object?>{'serverId': serverId});
    if (token.trim().isEmpty) {
      mcpTokens.remove(serverId);
    } else {
      mcpTokens.add(serverId);
    }
  }

  @override
  Future<bool> hasMcpToken(String serverId) async =>
      mcpTokens.contains(serverId);
}
