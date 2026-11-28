part of 'bistre_engine.dart';

/// Library calls of [FrbBistreEngineGateway]: a chat's files, Bistre's own skills, a drafted
/// message, a guided Regenerate, the chats zip, a PNG character card, and erasing the data.
mixin _FrbLibraryMixin {
  Future<List<EngineChatFile>> listChatFiles(String threadId) async => [
    for (final f in await frb.listChatFiles(threadId: threadId))
      EngineChatFile(
        nodeId: f.nodeId,
        fromUser: f.fromUser,
        name: f.name,
        mimeType: f.mimeType,
        sizeBytes: f.sizeBytes.toInt(),
        blobRelPath: f.blobRelPath,
        createdAtMs: f.createdAtMs,
      ),
  ];

  Future<List<EngineSkillIndex>> listAppSkills() async => [
    for (final s in await frb.listAppSkills()) _mapSkill(s),
  ];

  Future<EngineSkillIndex> installSkill(String source) async =>
      _mapSkill(await frb.installSkill(source: source));

  Future<EngineSkillIndex> saveReplyAsSkill({
    required String threadId,
    required String nodeId,
  }) async =>
      _mapSkill(await frb.saveReplyAsSkill(threadId: threadId, nodeId: nodeId));

  Future<void> removeAppSkill(String skillPath) =>
      frb.removeAppSkill(skillPath: skillPath);

  Future<String> draftNextMessage({
    required String threadId,
    required String note,
  }) => frb.draftNextMessage(threadId: threadId, note: note);

  Future<List<EngineProject>> listProjects() async => [
    for (final p in await frb.listProjects()) _mapProject(p),
  ];

  Future<EngineProject> saveProject(EngineProject project) async => _mapProject(
    await frb.saveProject(
      project: frb.FfiProject(
        id: project.id,
        name: project.name,
        folderPath: project.folderPath,
        instructions: project.instructions,
        createdAtMs: project.createdAtMs,
      ),
    ),
  );

  Future<void> deleteProject(String projectId) =>
      frb.deleteProject(projectId: projectId);

  Future<void> moveThreadToProject(String threadId, String? projectId) =>
      frb.moveThreadToProject(threadId: threadId, projectId: projectId);

  Future<String> regenerateReplyGuided({
    required String threadId,
    required String userNodeId,
    required String guidance,
  }) => frb.regenerateReplyGuided(
    threadId: threadId,
    userNodeId: userNodeId,
    guidance: guidance,
  );

  Future<int> exportChatsZip(String destPath) =>
      frb.exportChatsZip(destPath: destPath);

  Future<int> importChatsZip(String srcPath) =>
      frb.importChatsZip(srcPath: srcPath);

  Future<void> exportCharacterCardPng({
    required String cardId,
    required String destPath,
  }) => frb.exportCharacterCardPng(cardId: cardId, destPath: destPath);

  Future<void> setMcpToken({required String serverId, required String token}) =>
      frb.setMcpToken(serverId: serverId, token: token);

  Future<bool> hasMcpToken(String serverId) =>
      frb.hasMcpToken(serverId: serverId);

  Future<void> requestDataWipe() => frb.requestDataWipe();

  Future<bool> cancelDataWipe() => frb.cancelDataWipe();

  Future<bool> dataWipePending() => frb.dataWipePending();
}

EngineProject _mapProject(frb.FfiProject p) => EngineProject(
  id: p.id,
  name: p.name,
  folderPath: p.folderPath,
  instructions: p.instructions,
  createdAtMs: p.createdAtMs,
);

EngineSkillIndex _mapSkill(frb.FfiSkill s) =>
    EngineSkillIndex(name: s.name, description: s.description, path: s.path);
