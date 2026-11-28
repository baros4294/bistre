List<String> _decodeStringList(Object? raw) => raw is List<Object?>
    ? raw.whereType<String>().toList(growable: false)
    : const <String>[];

/// Character Card V3 / V2 record persisted in local SQLite (`character_cards`).
class EngineCharacterCard {
  const EngineCharacterCard({
    this.id = '',
    required this.name,
    this.nickname = '',
    this.specVersion = '3.0',
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.firstMessage = '',
    this.alternateGreetings = const <String>[],
    this.systemPrompt = '',
    this.postHistoryInstructions = '',
    this.creatorNotes = '',
    this.tags = const <String>[],
    this.avatarPath = '',
    this.extensionsJson = '{}',
    this.updatedAtMs = 0,
  });

  final String id;
  final String name;
  final String nickname;
  final String specVersion;
  final String description;
  final String personality;
  final String scenario;
  final String firstMessage;
  final List<String> alternateGreetings;
  final String systemPrompt;
  final String postHistoryInstructions;
  final String creatorNotes;
  final List<String> tags;
  final String avatarPath;
  final String extensionsJson;
  final int updatedAtMs;

  List<String> get allGreetings => <String>[
    if (firstMessage.trim().isNotEmpty) firstMessage,
    ...alternateGreetings.where((g) => g.trim().isNotEmpty),
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'nickname': nickname,
    'spec_version': specVersion,
    'description': description,
    'personality': personality,
    'scenario': scenario,
    'first_message': firstMessage,
    'alternate_greetings': alternateGreetings,
    'system_prompt': systemPrompt,
    'post_history_instructions': postHistoryInstructions,
    'creator_notes': creatorNotes,
    'tags': tags,
    'avatar_path': avatarPath,
    'extensions_json': extensionsJson,
    'updated_at_ms': updatedAtMs,
  };

  static EngineCharacterCard fromJson(Map<String, Object?> m) =>
      EngineCharacterCard(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        nickname: m['nickname'] as String? ?? '',
        specVersion: m['spec_version'] as String? ?? '3.0',
        description: m['description'] as String? ?? '',
        personality: m['personality'] as String? ?? '',
        scenario: m['scenario'] as String? ?? '',
        firstMessage: m['first_message'] as String? ?? '',
        alternateGreetings: _decodeStringList(m['alternate_greetings']),
        systemPrompt: m['system_prompt'] as String? ?? '',
        postHistoryInstructions:
            m['post_history_instructions'] as String? ?? '',
        creatorNotes: m['creator_notes'] as String? ?? '',
        tags: _decodeStringList(m['tags']),
        avatarPath: m['avatar_path'] as String? ?? '',
        extensionsJson: m['extensions_json'] as String? ?? '{}',
        updatedAtMs: (m['updated_at_ms'] as num?)?.toInt() ?? 0,
      );
}

/// User Persona record (`user_personas`) injected as `{{user}}` during roleplay or writing.
class EngineUserPersona {
  const EngineUserPersona({
    this.id = '',
    required this.name,
    this.description = '',
    this.avatarPath = '',
    this.isDefault = false,
    this.updatedAtMs = 0,
  });

  final String id;
  final String name;
  final String description;
  final String avatarPath;
  final bool isDefault;
  final int updatedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'description': description,
    'avatar_path': avatarPath,
    'is_default': isDefault,
    'updated_at_ms': updatedAtMs,
  };

  static EngineUserPersona fromJson(Map<String, Object?> m) =>
      EngineUserPersona(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        description: m['description'] as String? ?? '',
        avatarPath: m['avatar_path'] as String? ?? '',
        isDefault: m['is_default'] as bool? ?? false,
        updatedAtMs: (m['updated_at_ms'] as num?)?.toInt() ?? 0,
      );
}

/// Unified Story Bible (Codex) & Lorebook V3 entry (`story_entries`).
class EngineStoryEntry {
  const EngineStoryEntry({
    this.id = '',
    this.bookId = 'default_book',
    this.category = 'lore',
    required this.name,
    this.keys = const <String>[],
    this.secondaryKeys = const <String>[],
    this.selectiveLogic = 'and_any',
    this.content = '',
    this.insertionOrder = 100,
    this.priority = 10,
    this.position = 'after_char',
    this.depth = 4,
    this.role = 'system',
    this.constant = false,
    this.useRegex = false,
    this.caseSensitive = false,
    this.stickyTurns = 0,
    this.cooldownTurns = 0,
    this.delayTurns = 0,
    this.decorators = const <String>[],
    this.enabled = true,
    this.updatedAtMs = 0,
  });

  final String id;
  final String bookId;
  final String category;
  final String name;
  final List<String> keys;
  final List<String> secondaryKeys;
  final String selectiveLogic;
  final String content;
  final int insertionOrder;
  final int priority;
  final String position;
  final int depth;
  final String role;
  final bool constant;
  final bool useRegex;
  final bool caseSensitive;
  final int stickyTurns;
  final int cooldownTurns;
  final int delayTurns;
  final List<String> decorators;
  final bool enabled;
  final int updatedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'book_id': bookId,
    'category': category,
    'name': name,
    'keys': keys,
    'secondary_keys': secondaryKeys,
    'selective_logic': selectiveLogic,
    'content': content,
    'insertion_order': insertionOrder,
    'priority': priority,
    'position': position,
    'depth': depth,
    'role': role,
    'constant': constant,
    'use_regex': useRegex,
    'case_sensitive': caseSensitive,
    'sticky_turns': stickyTurns,
    'cooldown_turns': cooldownTurns,
    'delay_turns': delayTurns,
    'decorators': decorators,
    'enabled': enabled,
    'updated_at_ms': updatedAtMs,
  };

  static EngineStoryEntry fromJson(Map<String, Object?> m) => EngineStoryEntry(
    id: m['id'] as String? ?? '',
    bookId: m['book_id'] as String? ?? 'default_book',
    category: m['category'] as String? ?? 'lore',
    name: m['name'] as String? ?? '',
    keys: _decodeStringList(m['keys']),
    secondaryKeys: _decodeStringList(m['secondary_keys']),
    selectiveLogic: m['selective_logic'] as String? ?? 'and_any',
    content: m['content'] as String? ?? '',
    insertionOrder: (m['insertion_order'] as num?)?.toInt() ?? 100,
    priority: (m['priority'] as num?)?.toInt() ?? 10,
    position: m['position'] as String? ?? 'after_char',
    depth: (m['depth'] as num?)?.toInt() ?? 4,
    role: m['role'] as String? ?? 'system',
    constant: m['constant'] as bool? ?? false,
    useRegex: m['use_regex'] as bool? ?? false,
    caseSensitive: m['case_sensitive'] as bool? ?? false,
    stickyTurns: (m['sticky_turns'] as num?)?.toInt() ?? 0,
    cooldownTurns: (m['cooldown_turns'] as num?)?.toInt() ?? 0,
    delayTurns: (m['delay_turns'] as num?)?.toInt() ?? 0,
    decorators: _decodeStringList(m['decorators']),
    enabled: m['enabled'] as bool? ?? true,
    updatedAtMs: (m['updated_at_ms'] as num?)?.toInt() ?? 0,
  );
}

/// Chronological character/world progression gated strictly by `chapterOrder` (zero spoilers).
class EngineStoryProgression {
  const EngineStoryProgression({
    this.id = '',
    required this.entryId,
    required this.chapterOrder,
    this.sceneOrder = 0,
    required this.deltaText,
    this.createdAtMs = 0,
  });

  final String id;
  final String entryId;
  final int chapterOrder;
  final int sceneOrder;
  final String deltaText;
  final int createdAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'entry_id': entryId,
    'chapter_order': chapterOrder,
    'scene_order': sceneOrder,
    'delta_text': deltaText,
    'created_at_ms': createdAtMs,
  };

  static EngineStoryProgression fromJson(Map<String, Object?> m) =>
      EngineStoryProgression(
        id: m['id'] as String? ?? '',
        entryId: m['entry_id'] as String? ?? '',
        chapterOrder: (m['chapter_order'] as num?)?.toInt() ?? 1,
        sceneOrder: (m['scene_order'] as num?)?.toInt() ?? 0,
        deltaText: m['delta_text'] as String? ?? '',
        createdAtMs: (m['created_at_ms'] as num?)?.toInt() ?? 0,
      );
}

/// Long-form fiction Manuscript Chapter (`story_chapters`).
class EngineStoryChapter {
  const EngineStoryChapter({
    this.id = '',
    required this.threadId,
    this.orderIndex = 1,
    required this.title,
    this.summary = '',
    this.eraSummary = '',
    this.createdAtMs = 0,
  });

  final String id;
  final String threadId;
  final int orderIndex;
  final String title;
  final String summary;
  final String eraSummary;
  final int createdAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'thread_id': threadId,
    'order_index': orderIndex,
    'title': title,
    'summary': summary,
    'era_summary': eraSummary,
    'created_at_ms': createdAtMs,
  };

  static EngineStoryChapter fromJson(Map<String, Object?> m) =>
      EngineStoryChapter(
        id: m['id'] as String? ?? '',
        threadId: m['thread_id'] as String? ?? '',
        orderIndex: (m['order_index'] as num?)?.toInt() ?? 1,
        title: m['title'] as String? ?? '',
        summary: m['summary'] as String? ?? '',
        eraSummary: m['era_summary'] as String? ?? '',
        createdAtMs: (m['created_at_ms'] as num?)?.toInt() ?? 0,
      );
}

/// A chapter's era summary as written by the librarian, and the earlier facts it contradicts.
class EngineChapterSummary {
  const EngineChapterSummary({
    required this.eraSummary,
    this.contradictions = const <String>[],
  });

  final String eraSummary;
  final List<String> contradictions;
}

/// Long-form fiction Manuscript Scene (`story_scenes`) pairing Beats -> Prose.
class EngineStoryScene {
  const EngineStoryScene({
    this.id = '',
    required this.chapterId,
    this.orderIndex = 1,
    required this.title,
    this.beatsText = '',
    this.proseText = '',
    this.povCharacterId,
    this.wordCount = 0,
    this.updatedAtMs = 0,
  });

  final String id;
  final String chapterId;
  final int orderIndex;
  final String title;
  final String beatsText;
  final String proseText;
  final String? povCharacterId;
  final int wordCount;
  final int updatedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'chapter_id': chapterId,
    'order_index': orderIndex,
    'title': title,
    'beats_text': beatsText,
    'prose_text': proseText,
    'pov_character_id': povCharacterId,
    'word_count': wordCount,
    'updated_at_ms': updatedAtMs,
  };

  static EngineStoryScene fromJson(Map<String, Object?> m) => EngineStoryScene(
    id: m['id'] as String? ?? '',
    chapterId: m['chapter_id'] as String? ?? '',
    orderIndex: (m['order_index'] as num?)?.toInt() ?? 1,
    title: m['title'] as String? ?? '',
    beatsText: m['beats_text'] as String? ?? '',
    proseText: m['prose_text'] as String? ?? '',
    povCharacterId: m['pov_character_id'] as String?,
    wordCount: (m['word_count'] as num?)?.toInt() ?? 0,
    updatedAtMs: (m['updated_at_ms'] as num?)?.toInt() ?? 0,
  );
}

/// Creative samplers & anti-cliche phrase bias settings stored cleanly with integer milli-units.
class EngineCreativeSamplers {
  const EngineCreativeSamplers({
    this.minPMilli,
    this.topK,
    this.repetitionPenaltyMilli,
    this.dryMultiplierMilli,
    this.xtcProbabilityMilli,
    this.bannedPhrases = const <String>[],
  });

  final int? minPMilli;
  final int? topK;
  final int? repetitionPenaltyMilli;
  final int? dryMultiplierMilli;
  final int? xtcProbabilityMilli;
  final List<String> bannedPhrases;

  Map<String, Object?> toJson() => <String, Object?>{
    'min_p_milli': minPMilli,
    'top_k': topK,
    'repetition_penalty_milli': repetitionPenaltyMilli,
    'dry_multiplier_milli': dryMultiplierMilli,
    'xtc_probability_milli': xtcProbabilityMilli,
    'banned_phrases': bannedPhrases,
  };

  static EngineCreativeSamplers fromJson(Map<String, Object?> m) =>
      EngineCreativeSamplers(
        minPMilli: (m['min_p_milli'] as num?)?.toInt(),
        topK: (m['top_k'] as num?)?.toInt(),
        repetitionPenaltyMilli: (m['repetition_penalty_milli'] as num?)
            ?.toInt(),
        dryMultiplierMilli: (m['dry_multiplier_milli'] as num?)?.toInt(),
        xtcProbabilityMilli: (m['xtc_probability_milli'] as num?)?.toInt(),
        bannedPhrases: _decodeStringList(m['banned_phrases']),
      );
}

/// Per-thread Story & Roleplay state (`story_thread_state`).
class EngineStoryThreadState {
  const EngineStoryThreadState({
    this.threadId = '',
    this.activeCharacterIds = const <String>[],
    this.userPersonaId,
    this.activeBookIds = const <String>['default_book'],
    this.authorNote = '',
    this.authorNoteDepth = 4,
    this.storyMemory = '',
    this.groupTurnMode = 'natural',
    this.dialogueStyling = false,
    this.samplers = const EngineCreativeSamplers(),
    this.prewriterEnabled = false,
    this.librarianEnabled = false,
    this.currentChapterOrder = 1,
    this.updatedAtMs = 0,
  });

  final String threadId;
  final List<String> activeCharacterIds;
  final String? userPersonaId;
  final List<String> activeBookIds;
  final String authorNote;
  final int authorNoteDepth;
  final String storyMemory;
  final String groupTurnMode;
  final bool dialogueStyling;
  final EngineCreativeSamplers samplers;
  final bool prewriterEnabled;
  final bool librarianEnabled;
  final int currentChapterOrder;
  final int updatedAtMs;

  EngineStoryThreadState copyWith({
    String? threadId,
    List<String>? activeCharacterIds,
    String? userPersonaId,
    bool clearPersona = false,
    List<String>? activeBookIds,
    String? authorNote,
    int? authorNoteDepth,
    String? storyMemory,
    String? groupTurnMode,
    bool? dialogueStyling,
    EngineCreativeSamplers? samplers,
    bool? prewriterEnabled,
    bool? librarianEnabled,
    int? currentChapterOrder,
  }) => EngineStoryThreadState(
    threadId: threadId ?? this.threadId,
    activeCharacterIds: activeCharacterIds ?? this.activeCharacterIds,
    userPersonaId: clearPersona ? null : (userPersonaId ?? this.userPersonaId),
    activeBookIds: activeBookIds ?? this.activeBookIds,
    authorNote: authorNote ?? this.authorNote,
    authorNoteDepth: authorNoteDepth ?? this.authorNoteDepth,
    storyMemory: storyMemory ?? this.storyMemory,
    groupTurnMode: groupTurnMode ?? this.groupTurnMode,
    dialogueStyling: dialogueStyling ?? this.dialogueStyling,
    samplers: samplers ?? this.samplers,
    prewriterEnabled: prewriterEnabled ?? this.prewriterEnabled,
    librarianEnabled: librarianEnabled ?? this.librarianEnabled,
    currentChapterOrder: currentChapterOrder ?? this.currentChapterOrder,
    updatedAtMs: updatedAtMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'thread_id': threadId,
    'active_character_ids': activeCharacterIds,
    'user_persona_id': userPersonaId,
    'active_book_ids': activeBookIds,
    'author_note': authorNote,
    'author_note_depth': authorNoteDepth,
    'story_memory': storyMemory,
    'group_turn_mode': groupTurnMode,
    'dialogue_styling': dialogueStyling,
    'samplers': samplers.toJson(),
    'prewriter_enabled': prewriterEnabled,
    'librarian_enabled': librarianEnabled,
    'current_chapter_order': currentChapterOrder,
    'updated_at_ms': updatedAtMs,
  };

  static EngineStoryThreadState fromJson(Map<String, Object?> m) {
    final rawSamplers = m['samplers'];
    return EngineStoryThreadState(
      threadId: m['thread_id'] as String? ?? '',
      activeCharacterIds: _decodeStringList(m['active_character_ids']),
      userPersonaId: m['user_persona_id'] as String?,
      activeBookIds: _decodeStringList(m['active_book_ids']),
      authorNote: m['author_note'] as String? ?? '',
      authorNoteDepth: (m['author_note_depth'] as num?)?.toInt() ?? 4,
      storyMemory: m['story_memory'] as String? ?? '',
      groupTurnMode: m['group_turn_mode'] as String? ?? 'natural',
      dialogueStyling: m['dialogue_styling'] as bool? ?? false,
      samplers: rawSamplers is Map<String, Object?>
          ? EngineCreativeSamplers.fromJson(rawSamplers)
          : const EngineCreativeSamplers(),
      prewriterEnabled: m['prewriter_enabled'] as bool? ?? false,
      librarianEnabled: m['librarian_enabled'] as bool? ?? false,
      currentChapterOrder: (m['current_chapter_order'] as num?)?.toInt() ?? 1,
      updatedAtMs: (m['updated_at_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Safe linear-time Rust regex rule (`regex_rules`).
class EngineRegexRule {
  const EngineRegexRule({
    this.id = '',
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.scope = 'display_only',
    this.enabled = true,
    this.orderIndex = 0,
  });

  final String id;
  final String name;
  final String pattern;
  final String replacement;
  final String scope;
  final bool enabled;
  final int orderIndex;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'scope': scope,
    'enabled': enabled,
    'order_index': orderIndex,
  };

  static EngineRegexRule fromJson(Map<String, Object?> m) => EngineRegexRule(
    id: m['id'] as String? ?? '',
    name: m['name'] as String? ?? '',
    pattern: m['pattern'] as String? ?? '',
    replacement: m['replacement'] as String? ?? '',
    scope: m['scope'] as String? ?? 'display_only',
    enabled: m['enabled'] as bool? ?? true,
    orderIndex: (m['order_index'] as num?)?.toInt() ?? 0,
  );
}

/// Time Machine automatic version snapshot for Story Bible entities.
class EngineStorySnapshot {
  const EngineStorySnapshot({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.snapshotJson,
    required this.createdAtMs,
  });

  final String id;
  final String entityType;
  final String entityId;
  final String snapshotJson;
  final int createdAtMs;

  static EngineStorySnapshot fromJson(Map<String, Object?> m) =>
      EngineStorySnapshot(
        id: m['id'] as String? ?? '',
        entityType: m['entity_type'] as String? ?? '',
        entityId: m['entity_id'] as String? ?? '',
        snapshotJson: m['snapshot_json'] as String? ?? '{}',
        createdAtMs: (m['created_at_ms'] as num?)?.toInt() ?? 0,
      );
}

/// Single inspectable prompt block surfaced in the Live Prompt Inspector.
class EnginePromptBlock {
  const EnginePromptBlock({
    required this.id,
    required this.label,
    required this.role,
    required this.content,
    required this.estimatedTokens,
    required this.isStaticPrefix,
  });

  final String id;
  final String label;
  final String role;
  final String content;
  final int estimatedTokens;
  final bool isStaticPrefix;

  static EnginePromptBlock fromJson(Map<String, Object?> m) =>
      EnginePromptBlock(
        id: m['id'] as String? ?? '',
        label: m['label'] as String? ?? '',
        role: m['role'] as String? ?? 'system',
        content: m['content'] as String? ?? '',
        estimatedTokens: (m['estimated_tokens'] as num?)?.toInt() ?? 0,
        isStaticPrefix: m['is_static_prefix'] as bool? ?? false,
      );
}

/// Transparent Lorebook V3 activation trace item (fired vs skipped + exact reason).
class EngineLoreTraceItem {
  const EngineLoreTraceItem({
    required this.entryId,
    required this.name,
    required this.fired,
    required this.reason,
    required this.estimatedTokens,
  });

  final String entryId;
  final String name;
  final bool fired;
  final String reason;
  final int estimatedTokens;

  static EngineLoreTraceItem fromJson(Map<String, Object?> m) =>
      EngineLoreTraceItem(
        entryId: m['entry_id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        fired: m['fired'] as bool? ?? false,
        reason: m['reason'] as String? ?? '',
        estimatedTokens: (m['estimated_tokens'] as num?)?.toInt() ?? 0,
      );
}

/// Complete compiled prompt report including Cache Boundary index and Lorebook Trace.
class EnginePromptReport {
  const EnginePromptReport({
    this.blocks = const <EnginePromptBlock>[],
    this.cacheBoundaryIndex = 0,
    this.totalEstimatedTokens = 0,
    this.staticPrefixTokens = 0,
    this.loreTrace = const <EngineLoreTraceItem>[],
    this.loreTokensUsed = 0,
    this.loreTokenBudgetCap = 8000,
  });

  final List<EnginePromptBlock> blocks;
  final int cacheBoundaryIndex;
  final int totalEstimatedTokens;
  final int staticPrefixTokens;
  final List<EngineLoreTraceItem> loreTrace;
  final int loreTokensUsed;
  final int loreTokenBudgetCap;

  static EnginePromptReport fromJson(Map<String, Object?> m) {
    final rawBlocks = m['blocks'];
    final blocks = rawBlocks is List<Object?>
        ? rawBlocks
              .whereType<Map<String, Object?>>()
              .map(EnginePromptBlock.fromJson)
              .toList(growable: false)
        : const <EnginePromptBlock>[];
    final loreObj = m['lore_result'];
    var trace = const <EngineLoreTraceItem>[];
    var loreUsed = 0;
    var loreCap = 8000;
    if (loreObj is Map<String, Object?>) {
      final rawTrace = loreObj['trace'];
      if (rawTrace is List<Object?>) {
        trace = rawTrace
            .whereType<Map<String, Object?>>()
            .map(EngineLoreTraceItem.fromJson)
            .toList(growable: false);
      }
      loreUsed = (loreObj['total_tokens_used'] as num?)?.toInt() ?? 0;
      loreCap = (loreObj['token_budget_cap'] as num?)?.toInt() ?? 8000;
    }
    return EnginePromptReport(
      blocks: blocks,
      cacheBoundaryIndex: (m['cache_boundary_index'] as num?)?.toInt() ?? 0,
      totalEstimatedTokens: (m['total_estimated_tokens'] as num?)?.toInt() ?? 0,
      staticPrefixTokens: (m['static_prefix_tokens'] as num?)?.toInt() ?? 0,
      loreTrace: trace,
      loreTokensUsed: loreUsed,
      loreTokenBudgetCap: loreCap,
    );
  }
}
