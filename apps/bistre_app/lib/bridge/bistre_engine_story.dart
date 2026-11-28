part of 'bistre_engine.dart';

/// Story Studio calls of [FrbBistreEngineGateway]: character cards, personas, the story
/// bible, chapters, scenes, regex rules, snapshots, and the prompt report.
mixin _FrbStoryMixin {
  Future<List<EngineCharacterCard>> listCharacterCards() async {
    final decoded = jsonDecode(await frb.listCharacterCardsJson());
    if (decoded is! List<Object?>) return const <EngineCharacterCard>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineCharacterCard.fromJson)
        .toList(growable: false);
  }

  Future<EngineCharacterCard> upsertCharacterCard(
    EngineCharacterCard card,
  ) async {
    final raw = await frb.upsertCharacterCardJson(
      cardJson: jsonEncode(card.toJson()),
    );
    return EngineCharacterCard.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  Future<void> deleteCharacterCard(String cardId) =>
      frb.deleteCharacterCard(cardId: cardId);

  Future<EngineCharacterCard> importCharacterCardFile(String filePath) async {
    final raw = await frb.importCharacterCardFileJson(filePath: filePath);
    return EngineCharacterCard.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  Future<String> exportCharacterCardCcv3(String cardId) =>
      frb.exportCharacterCardCcv3(cardId: cardId);

  Future<List<EngineUserPersona>> listUserPersonas() async {
    final decoded = jsonDecode(await frb.listUserPersonasJson());
    if (decoded is! List<Object?>) return const <EngineUserPersona>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineUserPersona.fromJson)
        .toList(growable: false);
  }

  Future<EngineUserPersona> upsertUserPersona(EngineUserPersona persona) async {
    final raw = await frb.upsertUserPersonaJson(
      personaJson: jsonEncode(persona.toJson()),
    );
    return EngineUserPersona.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<List<EngineStoryEntry>> listStoryEntries({String? bookId}) async {
    final decoded = jsonDecode(await frb.listStoryEntriesJson(bookId: bookId));
    if (decoded is! List<Object?>) return const <EngineStoryEntry>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStoryEntry.fromJson)
        .toList(growable: false);
  }

  Future<EngineStoryEntry> upsertStoryEntry(EngineStoryEntry entry) async {
    final raw = await frb.upsertStoryEntryJson(
      entryJson: jsonEncode(entry.toJson()),
    );
    return EngineStoryEntry.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<void> deleteStoryEntry(String entryId) =>
      frb.deleteStoryEntry(entryId: entryId);

  Future<List<EngineStoryProgression>> listStoryProgressions({
    String? entryId,
  }) async {
    final decoded = jsonDecode(
      await frb.listStoryProgressionsJson(entryId: entryId),
    );
    if (decoded is! List<Object?>) return const <EngineStoryProgression>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStoryProgression.fromJson)
        .toList(growable: false);
  }

  Future<EngineStoryProgression> addStoryProgression(
    EngineStoryProgression progression,
  ) async {
    final raw = await frb.addStoryProgressionJson(
      progJson: jsonEncode(progression.toJson()),
    );
    return EngineStoryProgression.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  Future<List<EngineStoryChapter>> listStoryChapters(String threadId) async {
    final decoded = jsonDecode(
      await frb.listStoryChaptersJson(threadId: threadId),
    );
    if (decoded is! List<Object?>) return const <EngineStoryChapter>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStoryChapter.fromJson)
        .toList(growable: false);
  }

  Future<EngineStoryChapter> upsertStoryChapter(
    EngineStoryChapter chapter,
  ) async {
    final raw = await frb.upsertStoryChapterJson(
      chapterJson: jsonEncode(chapter.toJson()),
    );
    return EngineStoryChapter.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<List<EngineStoryScene>> listStoryScenes(String chapterId) async {
    final decoded = jsonDecode(
      await frb.listStoryScenesJson(chapterId: chapterId),
    );
    if (decoded is! List<Object?>) return const <EngineStoryScene>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStoryScene.fromJson)
        .toList(growable: false);
  }

  Future<EngineStoryScene> upsertStoryScene(EngineStoryScene scene) async {
    final raw = await frb.upsertStorySceneJson(
      sceneJson: jsonEncode(scene.toJson()),
    );
    return EngineStoryScene.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<EngineStoryThreadState> loadStoryThreadState(String threadId) async {
    final raw = await frb.loadStoryThreadStateJson(threadId: threadId);
    return EngineStoryThreadState.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  Future<EngineStoryThreadState> saveStoryThreadState(
    EngineStoryThreadState state,
  ) async {
    final raw = await frb.saveStoryThreadStateJson(
      stateJson: jsonEncode(state.toJson()),
    );
    return EngineStoryThreadState.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
  }

  Future<List<EngineRegexRule>> listRegexRules() async {
    final decoded = jsonDecode(await frb.listRegexRulesJson());
    if (decoded is! List<Object?>) return const <EngineRegexRule>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineRegexRule.fromJson)
        .toList(growable: false);
  }

  Future<EngineRegexRule> upsertRegexRule(EngineRegexRule rule) async {
    final raw = await frb.upsertRegexRuleJson(
      ruleJson: jsonEncode(rule.toJson()),
    );
    return EngineRegexRule.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<List<EngineStorySnapshot>> listStorySnapshots({
    required String entityType,
    required String entityId,
    int limit = 10,
  }) async {
    final decoded = jsonDecode(
      await frb.listStorySnapshotsJson(
        entityType: entityType,
        entityId: entityId,
        limit: limit,
      ),
    );
    if (decoded is! List<Object?>) return const <EngineStorySnapshot>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(EngineStorySnapshot.fromJson)
        .toList(growable: false);
  }

  Future<EnginePromptReport> inspectStoryPrompt({
    required String threadId,
    String? activeSceneBeats,
  }) async {
    final raw = await frb.inspectStoryPromptJson(
      threadId: threadId,
      activeSceneBeats: activeSceneBeats,
    );
    return EnginePromptReport.fromJson(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<String> rewritePassage({
    required String threadId,
    required String mode,
    required String excerpt,
    required String context,
  }) => frb.rewritePassage(
    threadId: threadId,
    mode: mode,
    excerpt: excerpt,
    context: context,
  );

  Future<String> planScene({
    required String threadId,
    required String title,
    required String beats,
  }) => frb.planScene(threadId: threadId, title: title, beats: beats);

  Future<EngineChapterSummary> summarizeChapter({
    required String threadId,
    required String chapterId,
  }) async {
    final s = await frb.summarizeChapter(
      threadId: threadId,
      chapterId: chapterId,
    );
    return EngineChapterSummary(
      eraSummary: s.eraSummary,
      contradictions: s.contradictions,
    );
  }
}
