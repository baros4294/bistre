part of 'folio_controller.dart';

/// The `kv_meta` key prefix of an assistant's opening message (core `GREETING_KEY_PREFIX`).
const String kGreetingKvPrefix = 'assistant_greeting:';

/// The `kv_meta` key of the saved system-prompt presets (a JSON list of `{name, text}`).
const String kPromptPresetsKvKey = 'settings.prompt_presets';

/// Most system-prompt presets kept.
const int kMaxPromptPresets = 50;

/// Longest preset name, in characters (taken from the prompt's first line).
const int kPromptPresetNameChars = 40;

/// A saved system prompt, named by its first line.
class PromptPreset {
  const PromptPreset({required this.name, required this.text});

  final String name;
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'text': text,
  };
}

/// The open chat's files, Bistre's own skills, the saved prompts, and a pending erase.
class _LibraryState {
  String filesThreadId = '';
  List<EngineChatFile> chatFiles = const <EngineChatFile>[];
  List<EngineSkillIndex> appSkills = const <EngineSkillIndex>[];
  List<PromptPreset> presets = const <PromptPreset>[];
  bool wipePending = false;
  bool installingSkill = false;
}

/// Library calls: a chat's files, Bistre's own skills, a drafted message, a guided
/// Regenerate, the chats zip, a PNG card, an assistant's opening message, saved prompts, and
/// erasing everything on this device.
extension FolioLibrary on FolioController {
  /// The open chat's files, newest first (loaded by [refreshChatFiles]).
  List<EngineChatFile> get chatFiles =>
      _library.filesThreadId == _activeThread?.id
      ? _library.chatFiles
      : const <EngineChatFile>[];

  List<EngineSkillIndex> get appSkills => _library.appSkills;
  bool get installingSkill => _library.installingSkill;
  List<PromptPreset> get promptPresets => _library.presets;
  bool get dataWipePending => _library.wipePending;

  Future<void> refreshChatFiles() async {
    final threadId = _activeThread?.id;
    if (threadId == null) return;
    try {
      final files = await _gateway.listChatFiles(threadId);
      if (_disposed || _activeThread?.id != threadId) return;
      _library
        ..filesThreadId = threadId
        ..chatFiles = files;
      _notify();
    } catch (e) {
      _noteNonFatal('chat_files', e);
    }
  }

  Future<void> refreshLibrary() async {
    try {
      _library
        ..appSkills = await _gateway.listAppSkills()
        ..wipePending = await _gateway.dataWipePending();
      final raw = await _gateway.getKvMeta(kPromptPresetsKvKey);
      _library.presets = _parsePresets(raw);
      _notify();
    } catch (e) {
      _noteNonFatal('library_refresh', e);
    }
  }

  List<PromptPreset> _parsePresets(String? raw) {
    if (raw == null || raw.isEmpty) return const <PromptPreset>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <PromptPreset>[];
      return <PromptPreset>[
        for (final item in decoded.take(kMaxPromptPresets))
          if (item case {'name': final String name, 'text': final String text})
            PromptPreset(name: name, text: text),
      ];
    } on FormatException catch (e) {
      _noteNonFatal('prompt_presets_parse', e);
      return const <PromptPreset>[];
    }
  }

  /// Installs a skill from a GitHub link or a folder, `SKILL.md`, or zip path.
  Future<bool> installSkill(String source) async {
    final clean = source.trim();
    if (clean.isEmpty || _library.installingSkill) return false;
    _library.installingSkill = true;
    _notify();
    try {
      await _gateway.installSkill(clean);
      _library.appSkills = await _gateway.listAppSkills();
      showToast(L10nKey.toastSkillInstalled, tone: ToastTone.ok);
      return true;
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      return false;
    } finally {
      _library.installingSkill = false;
      _notify();
    }
  }

  /// Saves the reply [node] as a new skill named by its chat.
  Future<void> saveReplyAsSkill(EngineNode node) async {
    final threadId = _activeThread?.id;
    if (threadId == null) return;
    try {
      await _gateway.saveReplyAsSkill(threadId: threadId, nodeId: node.id);
      _library.appSkills = await _gateway.listAppSkills();
      showToast(L10nKey.toastSkillSaved, tone: ToastTone.ok);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> removeAppSkill(EngineSkillIndex skill) async {
    try {
      await _gateway.removeAppSkill(skill.path);
      _library.appSkills = await _gateway.listAppSkills();
      showToast(L10nKey.toastDeleted);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// `/draft`: the user's next message drafted by the chat's model, or null when it failed
  /// (the reason shows as the chat's notice).
  Future<String?> draftNextMessage(String note) async {
    final threadId = _activeThread?.id;
    if (threadId == null) return null;
    try {
      final text = await _gateway.draftNextMessage(
        threadId: threadId,
        note: note.trim(),
      );
      _walletSpendMicros = await _gateway.getWalletSpendMicros();
      _notify();
      return text;
    } catch (e) {
      _fail(e);
      return null;
    }
  }

  /// `/guide`: regenerates the chat's last reply following [direction].
  Future<void> guideLastReply(String direction) async {
    final last = visibleBranchNodes.lastOrNull;
    if (last == null || last.role != 'assistant' || isStreaming) return;
    await regenerateFromAssistantNode(last, guidance: direction.trim());
  }

  /// Writes every chat with its files to a zip at [destPath].
  Future<void> exportChatsZip(String destPath) async {
    try {
      await _gateway.exportChatsZip(destPath);
      showToast(L10nKey.toastExported);
    } catch (e) {
      _fail(e);
    }
  }

  /// Imports the chats (and, from a zip, their files) at [srcPath].
  Future<void> importChatsZip(String srcPath) async {
    try {
      await _gateway.importChatsZip(srcPath);
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      _storageStats = await _gateway.getStorageStats();
      showToast(L10nKey.toastImported);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// Saves the character card [cardId] as a PNG card at [destPath].
  Future<void> exportCharacterCardPng(String cardId, String destPath) async {
    try {
      await _gateway.exportCharacterCardPng(cardId: cardId, destPath: destPath);
      showToast(L10nKey.toastExported);
    } catch (e) {
      _fail(e);
    }
  }

  /// Marks everything on this device for erasing at the next start.
  Future<void> requestDataWipe() async {
    try {
      await _gateway.requestDataWipe();
      _library.wipePending = await _gateway.dataWipePending();
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> cancelDataWipe() async {
    try {
      await _gateway.cancelDataWipe();
      _library.wipePending = await _gateway.dataWipePending();
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// Whether the MCP server [serverId] has a token saved (false when the vault cannot say).
  Future<bool> hasMcpToken(String serverId) async {
    try {
      return await _gateway.hasMcpToken(serverId);
    } catch (e) {
      _noteNonFatal('mcp_token_load', e);
      return false;
    }
  }

  /// Saves [token] as the MCP server's token; blank removes it. Returns whether it was saved.
  Future<bool> setMcpToken(String serverId, String token) async {
    try {
      await _gateway.setMcpToken(serverId: serverId, token: token.trim());
      showToast(L10nKey.toastSettingsSaved, tone: ToastTone.ok);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// The opening message of [assistantId]'s new chats ('' for none).
  Future<String> assistantGreeting(String assistantId) async {
    try {
      return await _gateway.getKvMeta('$kGreetingKvPrefix$assistantId') ?? '';
    } catch (e) {
      _noteNonFatal('assistant_greeting_load', e);
      return '';
    }
  }

  /// Saves [text] as [assistantId]'s opening message; blank (which core skips) removes it.
  Future<void> setAssistantGreeting(String assistantId, String text) async {
    try {
      await _gateway.setKvMeta('$kGreetingKvPrefix$assistantId', text.trim());
    } catch (e) {
      _fail(e);
    }
  }

  /// Saves [text] as a preset named by its first line; a preset of that name is replaced.
  Future<void> savePromptPreset(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final firstLine = clean.split('\n').first.trim();
    final name = firstLine.characters.take(kPromptPresetNameChars).toString();
    final next = <PromptPreset>[
      PromptPreset(name: name, text: clean),
      for (final p in _library.presets)
        if (p.name != name) p,
    ].take(kMaxPromptPresets).toList();
    await _savePresets(next);
    showToast(L10nKey.toastPresetSaved);
  }

  Future<void> deletePromptPreset(PromptPreset preset) =>
      _savePresets(<PromptPreset>[
        for (final p in _library.presets)
          if (p.name != preset.name) p,
      ]);

  Future<void> _savePresets(List<PromptPreset> next) async {
    _library.presets = List<PromptPreset>.unmodifiable(next);
    _notify();
    try {
      await _gateway.setKvMeta(
        kPromptPresetsKvKey,
        jsonEncode(<Object?>[for (final p in next) p.toJson()]),
      );
    } catch (e) {
      _fail(e);
    }
  }
}
