part of 'folio_controller.dart';

/// Studio, memory, skills, automation, and writing/roleplay actions of [FolioController].
extension FolioStudioActions on FolioController {
  // --- Studio Tabs, Session Tree, Multimodal Attachments & Provider QoL ---

  StudioTab get studioTab => _studioTab;

  bool get sessionTreeOpen => _sessionTreeOpen;

  bool get sessionTreePromptsOnly => _sessionTreePromptsOnly;

  List<ComposerAttachment> get attachments => _attachments;

  List<EngineNode> get allThreadNodes => _nodes;

  void setStudioTab(StudioTab tab) {
    if (_studioPaneOpen && _studioTab == tab) return;
    _studioTab = tab;
    _studioPaneOpen = true;
    _inspectorOpen = false;
    if (tab == StudioTab.story || tab == StudioTab.prompt) {
      unawaited(refreshStoryStudio());
    }
    _notify();
  }

  void openSessionTree({bool onlyUserPrompts = false}) {
    _sessionTreeOpen = true;
    _sessionTreePromptsOnly = onlyUserPrompts;
    _commandPaletteOpen = false;
    _notify();
  }

  void closeSessionTree() {
    if (!_sessionTreeOpen) return;
    _sessionTreeOpen = false;
    _notify();
  }

  /// Selects every ancestor branch index needed so `targetNodeId` appears on the active visible branch.
  void focusBranchNode(String targetNodeId) {
    final byId = <String, EngineNode>{for (final n in _nodes) n.id: n};
    final grouped = _childrenByParent;
    var cursor = byId[targetNodeId];
    var guard = 0;
    while (cursor != null && guard < _nodes.length + 1) {
      guard++;
      final parentKey = cursor.parentId ?? '__root__';
      final siblings = grouped[parentKey];
      if (siblings != null) {
        final idx = siblings.indexWhere((s) => s.id == cursor!.id);
        if (idx >= 0) {
          _selectedChildIndex[parentKey] = idx;
        }
      }
      cursor = cursor.parentId != null ? byId[cursor.parentId!] : null;
    }
    _notify();
  }

  /// Attaches a file to the composer, enforcing a max of 4 image attachments per recall window.
  void addAttachment(ComposerAttachment item) {
    final currentImages = _attachments.where((a) => a.isImage).length;
    if (item.isImage && currentImages >= 4) {
      final oldestImageIdx = _attachments.indexWhere((a) => a.isImage);
      final trimmed = List<ComposerAttachment>.of(_attachments);
      if (oldestImageIdx >= 0) trimmed.removeAt(oldestImageIdx);
      trimmed.add(item);
      _attachments = trimmed;
    } else {
      _attachments = <ComposerAttachment>[..._attachments, item];
    }
    _notify();
  }

  void removeAttachment(String id) {
    _attachments = _attachments
        .where((a) => a.id != id)
        .toList(growable: false);
    _notify();
  }

  void attachInlineFileComment(String filePath, String lineRange) {
    final ref = '@$filePath:$lineRange';
    addAttachment(
      ComposerAttachment(
        id: 'ref_${DateTime.now().millisecondsSinceEpoch}',
        name: ref,
        mimeType: 'text/plain',
        path: filePath,
        inlineReference: ref,
      ),
    );
  }

  Future<void> pickComposerAttachment({
    required String title,
    required String filterLabel,
  }) async {
    final path = await BistreDesktopHost.pickLocalFile(
      title: title,
      filterLabel: filterLabel,
      filterSpec:
          '*.png;*.jpg;*.jpeg;*.webp;*.gif;*.pdf;*.docx;*.doc;*.dotx;*.odt;'
          '*.xlsx;*.xls;*.ods;*.pptx;*.ppt;*.odp;*.mp3;*.wav;*.ogg;*.m4a;'
          '*.flac;*.mp4;*.webm;*.txt;*.md;*.csv;*.tsv;*.json;*.xml;*.yaml;'
          '*.yml;*.rs;*.dart;*.py;*.js;*.ts',
    );
    if (path == null || path.trim().isEmpty) return;
    final clean = path.trim();
    final name = clean.split(RegExp(r'[/\\]')).last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final isImg =
        ext == 'png' ||
        ext == 'jpg' ||
        ext == 'jpeg' ||
        ext == 'webp' ||
        ext == 'gif';
    final mime = switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'pdf' => 'application/pdf',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'dotx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.template',
      'doc' => 'application/msword',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'xls' => 'application/vnd.ms-excel',
      'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'ppt' => 'application/vnd.ms-powerpoint',
      'odt' => 'application/vnd.oasis.opendocument.text',
      'ods' => 'application/vnd.oasis.opendocument.spreadsheet',
      'odp' => 'application/vnd.oasis.opendocument.presentation',
      'mp3' => 'audio/mpeg',
      'wav' => 'audio/wav',
      'ogg' => 'audio/ogg',
      'm4a' => 'audio/mp4',
      'flac' => 'audio/flac',
      'mp4' => 'video/mp4',
      'webm' => 'video/webm',
      'csv' => 'text/csv',
      'tsv' => 'text/tab-separated-values',
      'json' => 'application/json',
      'xml' => 'application/xml',
      _ => 'text/plain',
    };
    int size = 0;
    try {
      size = File(clean).lengthSync();
    } catch (e) {
      _noteNonFatal('attachment_size', e);
    }
    addAttachment(
      ComposerAttachment(
        id: 'att_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        mimeType: mime,
        path: clean,
        sizeBytes: size,
        isImage: isImg,
      ),
    );
  }

  Future<(String, String)> loadProviderOverrides(String providerId) async {
    try {
      final raw = await _gateway.getKvMeta('provider.overrides:$providerId');
      if (raw == null || raw.trim().isEmpty) return ('', '');
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return (
          decoded['headers_json'] as String? ?? '',
          decoded['body_json'] as String? ?? '',
        );
      }
    } catch (e) {
      _noteNonFatal('provider_overrides_load', e);
    }
    return ('', '');
  }

  Future<void> saveProviderOverrides({
    required String providerId,
    required String headersJson,
    required String bodyJson,
  }) async {
    try {
      // Rust validates both fields and binds the headers to the provider's origin (A-S8).
      await _gateway.saveProviderOverrides(
        providerId: providerId,
        headersJson: headersJson,
        bodyJson: bodyJson,
      );
      showToast(L10nKey.toastSettingsSaved);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  /// Exports a strictly non-secret provider profile JSON string (API key never included).
  String exportProviderShareJson(EngineProvider provider) =>
      jsonEncode(<String, Object?>{
        'format': 'bistre_provider_v1',
        'name': provider.name,
        'dialect': provider.dialect,
        'base_url': provider.baseUrl,
        'default_model': provider.defaultModel,
        'icon_slug': provider.iconSlug,
      });

  // --- Memory, Progressive Skills & Scheduled Automations ---

  List<EngineMemoryEntry> get memoryEntries => _memoryEntries;

  List<EngineSkillIndex> get discoveredSkills => _discoveredSkills;

  List<EngineCronJob> get cronJobs => _cronJobs;

  Future<void> refreshMemorySkillsAndCron() async {
    try {
      _memoryEntries = await _gateway.listMemoryEntries();
      _cronJobs = await _gateway.listCronJobs();
      if (_workspaceRootPath.isNotEmpty) {
        _discoveredSkills = await _gateway.discoverWorkspaceSkills(
          _workspaceRootPath,
        );
      } else {
        _discoveredSkills = const <EngineSkillIndex>[];
      }
      _notify();
    } catch (e) {
      _noteNonFatal('memory_cron_skills_refresh', e);
    }
  }

  Future<void> addMemoryEntry({
    required String content,
    String scope = 'global',
  }) async {
    final clean = content.trim();
    if (clean.isEmpty) return;
    try {
      await _gateway.upsertMemoryEntry(
        scope: scope,
        scopeId: 'default',
        key: 'note_${DateTime.now().millisecondsSinceEpoch}',
        content: clean,
      );
      _memoryEntries = await _gateway.listMemoryEntries();
      showToast(L10nKey.toastSettingsSaved);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> toggleMemoryPinned(EngineMemoryEntry entry) async {
    try {
      await _gateway.upsertMemoryEntry(
        id: entry.id,
        scope: entry.scope,
        scopeId: entry.scopeId,
        key: entry.key,
        content: entry.content,
        pinned: !entry.pinned,
      );
      _memoryEntries = await _gateway.listMemoryEntries();
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> deleteMemoryEntry(String entryId) async {
    try {
      await _gateway.deleteMemoryEntry(entryId);
      _memoryEntries = await _gateway.listMemoryEntries();
      showToast(L10nKey.toastDeleted);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<String> loadSkillBody(String skillPath) async {
    if (_workspaceRootPath.isEmpty) return '';
    try {
      return await _gateway.loadSkillBody(_workspaceRootPath, skillPath);
    } catch (_) {
      return '';
    }
  }

  Future<void> createCronJob({
    required String name,
    required String scheduleExpr,
    required String prompt,
  }) async {
    try {
      await _gateway.upsertCronJob(
        EngineCronJob(
          name: name.trim(),
          scheduleExpr: scheduleExpr.trim(),
          prompt: prompt.trim(),
          assistantId: activeAssistantId,
          unattendedPolicy: _settings.unattendedPolicy,
        ),
      );
      _cronJobs = await _gateway.listCronJobs();
      showToast(L10nKey.toastSettingsSaved);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> toggleCronJobEnabled(EngineCronJob job, bool enabled) async {
    try {
      await _gateway.upsertCronJob(
        EngineCronJob(
          id: job.id,
          name: job.name,
          workspaceId: job.workspaceId,
          assistantId: job.assistantId,
          scheduleExpr: job.scheduleExpr,
          prompt: job.prompt,
          mode: job.mode,
          unattendedPolicy: job.unattendedPolicy,
          useWorktree: job.useWorktree,
          enabled: enabled,
          nextRunMs: job.nextRunMs,
          lastRunId: job.lastRunId,
          lastStatus: job.lastStatus,
        ),
      );
      _cronJobs = await _gateway.listCronJobs();
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> deleteCronJob(String jobId) async {
    try {
      await _gateway.deleteCronJob(jobId);
      _cronJobs = await _gateway.listCronJobs();
      showToast(L10nKey.toastDeleted);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  void recordToolActivity(ToolActivityEntry entry) =>
      _recordToolActivityFor(entry);

  /// Answers the paused call [callId] with `approve_once`, `approve_for_thread`, `deny`, or
  /// `stop`, addressed to the exact chat and run that asked (never the active chat).
  Future<void> respondToolApproval(String callId, String decision) async {
    final rows = toolActivities;
    final idx = rows.indexWhere((e) => e.id == callId);
    if (idx < 0) return;
    final entry = rows[idx];
    if (entry.threadId.isEmpty || entry.runId.isEmpty) return;
    try {
      await _gateway.respondToolApproval(
        threadId: entry.threadId,
        runId: entry.runId,
        callId: callId,
        decision: decision,
      );
      final refused = decision == 'deny' || decision == 'stop';
      recordToolActivity(entry.withStatus(refused ? 'failed' : 'running'));
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }
  // --- Writing & Roleplay Studio State & Actions ---

  List<EngineCharacterCard> get characterCards => _characterCards;

  List<EngineUserPersona> get userPersonas => _userPersonas;

  List<EngineStoryEntry> get storyEntries => _storyEntries;

  List<EngineStoryProgression> get storyProgressions => _storyProgressions;

  List<EngineStoryChapter> get storyChapters => _storyChapters;

  String? get selectedChapterId => _selectedChapterId;

  String? get selectedSceneId => _selectedSceneId;

  EngineStoryThreadState get storyState => _storyState;

  List<EngineRegexRule> get regexRules => _regexRules;

  EnginePromptReport get promptReport => _promptReport;

  bool get manuscriptViewActive => _manuscriptViewActive;

  int get activeGreetingIndex => _activeGreetingIndex;

  List<EngineStoryScene> scenesForChapter(String chapterId) =>
      _storyScenesByChapter[chapterId] ?? const <EngineStoryScene>[];

  EngineStoryChapter? get activeChapter {
    if (_storyChapters.isEmpty) return null;
    if (_selectedChapterId != null) {
      final found = _storyChapters
          .where((c) => c.id == _selectedChapterId)
          .firstOrNull;
      if (found != null) return found;
    }
    return _storyChapters.first;
  }

  EngineStoryScene? get activeScene {
    final ch = activeChapter;
    if (ch == null) return null;
    final scenes = scenesForChapter(ch.id);
    if (scenes.isEmpty) return null;
    if (_selectedSceneId != null) {
      final found = scenes.where((s) => s.id == _selectedSceneId).firstOrNull;
      if (found != null) return found;
    }
    return scenes.first;
  }

  List<EngineCharacterCard> get activeThreadCharacters {
    if (_storyState.activeCharacterIds.isEmpty) {
      return _characterCards.isEmpty
          ? const <EngineCharacterCard>[]
          : <EngineCharacterCard>[_characterCards.first];
    }
    return _characterCards
        .where((c) => _storyState.activeCharacterIds.contains(c.id))
        .toList(growable: false);
  }

  void toggleManuscriptView(bool active) {
    if (_manuscriptViewActive == active) return;
    _manuscriptViewActive = active;
    if (active) {
      unawaited(refreshStoryStudio());
    }
    _notify();
  }

  void cycleAltGreeting(int delta) {
    final primary = activeThreadCharacters.firstOrNull;
    if (primary == null) return;
    final greetings = primary.allGreetings;
    if (greetings.isEmpty) return;
    _activeGreetingIndex = (_activeGreetingIndex + delta) % greetings.length;
    if (_activeGreetingIndex < 0) _activeGreetingIndex += greetings.length;
    _notify();
  }

  Future<void> applyActiveGreetingToThread() async {
    final active = _activeThread;
    final primary = activeThreadCharacters.firstOrNull;
    if (active == null || primary == null) return;
    final greetings = primary.allGreetings;
    if (greetings.isEmpty) return;
    final idx = _activeGreetingIndex.clamp(0, greetings.length - 1);
    try {
      await _gateway.appendNode(
        threadId: active.id,
        role: 'assistant',
        content: greetings[idx],
      );
      final reloaded = await _gateway.listNodes(active.id);
      // U2: write only into the chat that is still open.
      if (_activeThread?.id == active.id) _nodes = reloaded;
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> refreshStoryStudio() async {
    final active = _activeThread;
    try {
      _characterCards = await _gateway.listCharacterCards();
      _userPersonas = await _gateway.listUserPersonas();
      _storyEntries = await _gateway.listStoryEntries();
      _storyProgressions = await _gateway.listStoryProgressions();
      _regexRules = await _gateway.listRegexRules();
      if (active != null) {
        _storyState = await _gateway.loadStoryThreadState(active.id);
        _storyChapters = await _gateway.listStoryChapters(active.id);
        _storyScenesByChapter.clear();
        for (final ch in _storyChapters) {
          _storyScenesByChapter[ch.id] = await _gateway.listStoryScenes(ch.id);
        }
        if (_selectedChapterId == null && _storyChapters.isNotEmpty) {
          _selectedChapterId = _storyChapters.first.id;
        }
        final ch = activeChapter;
        if (ch != null) {
          final scenes = scenesForChapter(ch.id);
          if (_selectedSceneId == null && scenes.isNotEmpty) {
            _selectedSceneId = scenes.first.id;
          }
        }
        _promptReport = await _gateway.inspectStoryPrompt(
          threadId: active.id,
          activeSceneBeats: activeScene?.beatsText,
        );
      }
      _notify();
    } catch (e) {
      _noteNonFatal('story_workspace_load', e);
    }
  }

  Future<void> refreshPromptInspector({String? activeSceneBeats}) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      _promptReport = await _gateway.inspectStoryPrompt(
        threadId: active.id,
        activeSceneBeats: activeSceneBeats ?? activeScene?.beatsText,
      );
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> saveCharacterCard(EngineCharacterCard card) async {
    try {
      await _gateway.upsertCharacterCard(card);
      await refreshStoryStudio();
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> deleteCharacterCard(String cardId) async {
    try {
      await _gateway.deleteCharacterCard(cardId);
      await refreshStoryStudio();
      showToast(L10nKey.toastDeleted);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> importCharacterCardFromFile({
    required String title,
    required String filterLabel,
  }) async {
    final path = await BistreDesktopHost.pickLocalFile(
      title: title,
      filterLabel: filterLabel,
      filterSpec: '*.png;*.json;*.charx',
    );
    if (path == null || path.trim().isEmpty) return;
    try {
      await _gateway.importCharacterCardFile(path.trim());
      await refreshStoryStudio();
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> exportCharacterCardToClipboard(String cardId) async {
    try {
      final jsonText = await _gateway.exportCharacterCardCcv3(cardId);
      await Clipboard.setData(ClipboardData(text: jsonText));
      showToast(L10nKey.toastExported);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> restoreLatestCharacterSnapshot(String cardId) async {
    try {
      final snaps = await _gateway.listStorySnapshots(
        entityType: 'character_card',
        entityId: cardId,
      );
      // Index 0 is the current save; index 1 (if present) is the previous revision.
      final target = snaps.length >= 2 ? snaps[1] : snaps.firstOrNull;
      if (target == null) return;
      final decoded = jsonDecode(target.snapshotJson);
      if (decoded is Map<String, Object?>) {
        await _gateway.upsertCharacterCard(
          EngineCharacterCard.fromJson(decoded),
        );
        await refreshStoryStudio();
        showToast(L10nKey.toolRewoundToast);
      }
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> toggleActiveCharacterInThread(String cardId) async {
    final active = _activeThread;
    if (active == null) return;
    final ids = List<String>.of(_storyState.activeCharacterIds);
    if (ids.contains(cardId)) {
      ids.remove(cardId);
    } else {
      ids.add(cardId);
    }
    await saveStoryThreadState(
      _storyState.copyWith(threadId: active.id, activeCharacterIds: ids),
    );
  }

  Future<void> saveUserPersona(EngineUserPersona persona) async {
    try {
      final saved = await _gateway.upsertUserPersona(persona);
      final active = _activeThread;
      if (active != null && _storyState.userPersonaId == null) {
        await _gateway.saveStoryThreadState(
          _storyState.copyWith(threadId: active.id, userPersonaId: saved.id),
        );
      }
      await refreshStoryStudio();
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> saveStoryEntry(EngineStoryEntry entry) async {
    try {
      await _gateway.upsertStoryEntry(entry);
      await refreshStoryStudio();
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> deleteStoryEntry(String entryId) async {
    try {
      await _gateway.deleteStoryEntry(entryId);
      await refreshStoryStudio();
      showToast(L10nKey.toastDeleted);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> addStoryProgression({
    required String entryId,
    required int chapterOrder,
    required String deltaText,
  }) async {
    final clean = deltaText.trim();
    if (clean.isEmpty) return;
    try {
      await _gateway.addStoryProgression(
        EngineStoryProgression(
          entryId: entryId,
          chapterOrder: chapterOrder,
          deltaText: clean,
        ),
      );
      await refreshStoryStudio();
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> saveStoryThreadState(EngineStoryThreadState next) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      _storyState = await _gateway.saveStoryThreadState(
        next.copyWith(threadId: active.id),
      );
      await refreshPromptInspector();
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> addStoryChapter(String title) async {
    final active = _activeThread;
    if (active == null || title.trim().isEmpty) return;
    try {
      final created = await _gateway.upsertStoryChapter(
        EngineStoryChapter(
          threadId: active.id,
          orderIndex: _storyChapters.length + 1,
          title: title.trim(),
        ),
      );
      _selectedChapterId = created.id;
      await refreshStoryStudio();
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  void selectChapter(String chapterId) {
    _selectedChapterId = chapterId;
    final scenes = scenesForChapter(chapterId);
    _selectedSceneId = scenes.isNotEmpty ? scenes.first.id : null;
    final ch = activeChapter;
    if (ch != null && _storyState.currentChapterOrder != ch.orderIndex) {
      unawaited(
        saveStoryThreadState(
          _storyState.copyWith(currentChapterOrder: ch.orderIndex),
        ),
      );
    }
    _notify();
  }

  Future<void> addStoryScene(String chapterId, String title) async {
    if (title.trim().isEmpty) return;
    try {
      final existing = scenesForChapter(chapterId);
      final created = await _gateway.upsertStoryScene(
        EngineStoryScene(
          chapterId: chapterId,
          orderIndex: existing.length + 1,
          title: title.trim(),
        ),
      );
      _selectedChapterId = chapterId;
      _selectedSceneId = created.id;
      await refreshStoryStudio();
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  void selectScene(String sceneId) {
    _selectedSceneId = sceneId;
    unawaited(refreshPromptInspector());
    _notify();
  }

  Future<void> saveStoryScene(EngineStoryScene scene) async {
    try {
      await _gateway.upsertStoryScene(scene);
      await refreshStoryStudio();
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  /// Sends `request` (the UI's localized prose-from-beats message) when the scene has beats.
  Future<void> generateProseFromBeats(
    EngineStoryScene scene, {
    required String request,
  }) async {
    if (scene.beatsText.trim().isEmpty) return;
    _manuscriptViewActive = false;
    _notify();
    await submitPassage(request);
  }

  /// Sends `request` (the UI's localized rewrite/expand/shorten/polish message) for `excerpt`.
  Future<void> runLaserRewrite({
    required String excerpt,
    required String request,
  }) async {
    if (excerpt.trim().isEmpty) return;
    _manuscriptViewActive = false;
    _notify();
    await submitPassage(request);
  }

  /// Sends the UI's localized "continue the story" message.
  Future<void> triggerStoryContinue({required String request}) =>
      submitPassage(request);

  /// Name of the chat's user persona, or `null` when none is chosen.
  String? get activePersonaName => _userPersonas
      .where((p) => p.id == _storyState.userPersonaId)
      .firstOrNull
      ?.name;

  /// Sends the UI's localized "draft my persona's next reply" message.
  Future<void> triggerStoryImpersonate({required String request}) =>
      submitPassage(request);

  Future<void> saveRegexRule(EngineRegexRule rule) async {
    try {
      await _gateway.upsertRegexRule(rule);
      await refreshStoryStudio();
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }
}
