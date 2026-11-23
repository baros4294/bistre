import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

const String _kCardFilterSpecLabel = 'CCv3 PNG / JSON / .charx';
const String _kDefaultPersonaName = 'Traveler';
const String _kScopeDisplay = 'display_only';
const String _kScopePrompt = 'prompt_outgoing';
const String _kScopeIncoming = 'incoming_commit';
const String _kCategoryLore = 'lore';
const String _kCategoryCharacter = 'character';
const String _kCategoryLocation = 'location';

String _chapterTag(int chapterOrder) => 'Ch $chapterOrder';
String _depthTag(int depth) => '@D$depth';
String _keysSummary(List<String> keys) => keys.join(', ');

/// Unified Story Bible, Character Cards (CCv3/V2 PNG/JSON/.charx), User Personas,
/// Lorebook V3 + Chronological Progressions, Author's Note, Story Memory, and
/// Safe Linear-Time Regex Rules mounted inside the Studio Pane `[Story]` tab.
class StoryBiblePanel extends StatefulWidget {
  const StoryBiblePanel({super.key, required this.controller});

  final FolioController controller;

  @override
  State<StoryBiblePanel> createState() => _StoryBiblePanelState();
}

class _StoryBiblePanelState extends State<StoryBiblePanel> {
  final TextEditingController _charNameCtrl = TextEditingController();
  final FocusNode _charNameFocus = FocusNode();
  final TextEditingController _charDescCtrl = TextEditingController();
  final FocusNode _charDescFocus = FocusNode();
  final TextEditingController _charGreetingCtrl = TextEditingController();
  final FocusNode _charGreetingFocus = FocusNode();

  final TextEditingController _personaNameCtrl = TextEditingController();
  final FocusNode _personaNameFocus = FocusNode();
  final TextEditingController _personaDescCtrl = TextEditingController();
  final FocusNode _personaDescFocus = FocusNode();

  final TextEditingController _entryNameCtrl = TextEditingController();
  final FocusNode _entryNameFocus = FocusNode();
  final TextEditingController _entryKeysCtrl = TextEditingController();
  final FocusNode _entryKeysFocus = FocusNode();
  final TextEditingController _entryContentCtrl = TextEditingController();
  final FocusNode _entryContentFocus = FocusNode();
  String _entryCategory = _kCategoryLore;
  bool _entryConstant = false;

  final TextEditingController _progDeltaCtrl = TextEditingController();
  final FocusNode _progDeltaFocus = FocusNode();
  final TextEditingController _progChapterCtrl = TextEditingController(
    text: '2',
  );
  final FocusNode _progChapterFocus = FocusNode();

  final TextEditingController _storyMemoryCtrl = TextEditingController();
  final FocusNode _storyMemoryFocus = FocusNode();
  final TextEditingController _authorNoteCtrl = TextEditingController();
  final FocusNode _authorNoteFocus = FocusNode();
  final TextEditingController _regexNameCtrl = TextEditingController();
  final FocusNode _regexNameFocus = FocusNode();
  final TextEditingController _regexPatternCtrl = TextEditingController();
  final FocusNode _regexPatternFocus = FocusNode();
  final TextEditingController _regexReplaceCtrl = TextEditingController();
  final FocusNode _regexReplaceFocus = FocusNode();
  String _regexScope = _kScopeDisplay;

  bool _addingChar = false;
  bool _addingEntry = false;
  bool _editingPersona = false;
  bool _addingRegex = false;
  String? _addingProgressionForEntryId;
  String _syncedThreadId = '';

  @override
  void dispose() {
    _charNameCtrl.dispose();
    _charNameFocus.dispose();
    _charDescCtrl.dispose();
    _charDescFocus.dispose();
    _charGreetingCtrl.dispose();
    _charGreetingFocus.dispose();
    _personaNameCtrl.dispose();
    _personaNameFocus.dispose();
    _personaDescCtrl.dispose();
    _personaDescFocus.dispose();
    _entryNameCtrl.dispose();
    _entryNameFocus.dispose();
    _entryKeysCtrl.dispose();
    _entryKeysFocus.dispose();
    _entryContentCtrl.dispose();
    _entryContentFocus.dispose();
    _progDeltaCtrl.dispose();
    _progDeltaFocus.dispose();
    _progChapterCtrl.dispose();
    _progChapterFocus.dispose();
    _storyMemoryCtrl.dispose();
    _storyMemoryFocus.dispose();
    _authorNoteCtrl.dispose();
    _authorNoteFocus.dispose();
    _regexNameCtrl.dispose();
    _regexNameFocus.dispose();
    _regexPatternCtrl.dispose();
    _regexPatternFocus.dispose();
    _regexReplaceCtrl.dispose();
    _regexReplaceFocus.dispose();
    super.dispose();
  }

  void _syncThreadFields(FolioController ctrl) {
    final tid = ctrl.activeThread?.id ?? '';
    if (tid == _syncedThreadId) return;
    _syncedThreadId = tid;
    _storyMemoryCtrl.text = ctrl.storyState.storyMemory;
    _authorNoteCtrl.text = ctrl.storyState.authorNote;
    final activePersona = ctrl.userPersonas
        .where((p) => p.id == ctrl.storyState.userPersonaId)
        .firstOrNull;
    if (activePersona != null) {
      _personaNameCtrl.text = activePersona.name;
      _personaDescCtrl.text = activePersona.description;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    _syncThreadFields(ctrl);

    final state = ctrl.storyState;
    final activePersona = ctrl.userPersonas
        .where((p) => p.id == state.userPersonaId)
        .firstOrNull;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- 1. Characters (CCv3 / V2 PNG, JSON, .charx + Time Machine) ---
            _SectionHeaderRow(
              icon: BistreUiIcon.assistant,
              title: l10n.t(L10nKey.storyCharactersTitle),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BistreIconButton(
                    icon: BistreUiIcon.folder,
                    size: 13,
                    dimension: 26,
                    semanticsLabel: l10n.t(L10nKey.storyImportCard),
                    onPressed: () => unawaited(
                      ctrl.importCharacterCardFromFile(
                        title: l10n.t(L10nKey.storyImportCard),
                        filterLabel: _kCardFilterSpecLabel,
                      ),
                    ),
                  ),
                  BistreIconButton(
                    icon: BistreUiIcon.plus,
                    size: 13,
                    dimension: 26,
                    semanticsLabel: l10n.t(L10nKey.storyAddCharacter),
                    onPressed: () => setState(() => _addingChar = !_addingChar),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            if (_addingChar) ...[
              FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    QuillInput(
                      controller: _charNameCtrl,
                      focusNode: _charNameFocus,
                      placeholder: l10n.t(L10nKey.storyAddCharacter),
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 6),
                    QuillInput(
                      controller: _charDescCtrl,
                      focusNode: _charDescFocus,
                      placeholder: l10n.t(L10nKey.storyCharactersTitle),
                      maxLines: 3,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 6),
                    QuillInput(
                      controller: _charGreetingCtrl,
                      focusNode: _charGreetingFocus,
                      placeholder: l10n.t(L10nKey.storyViewChat),
                      maxLines: 2,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        EngravedButton(
                          label: l10n.t(L10nKey.threadSave),
                          primary: true,
                          compact: true,
                          onPressed: () {
                            final name = _charNameCtrl.text.trim();
                            if (name.isEmpty) return;
                            unawaited(
                              ctrl.saveCharacterCard(
                                EngineCharacterCard(
                                  name: name,
                                  description: _charDescCtrl.text.trim(),
                                  firstMessage: _charGreetingCtrl.text.trim(),
                                ),
                              ),
                            );
                            _charNameCtrl.clear();
                            _charDescCtrl.clear();
                            _charGreetingCtrl.clear();
                            setState(() => _addingChar = false);
                          },
                        ),
                        const SizedBox(width: 6),
                        EngravedButton(
                          label: l10n.t(L10nKey.threadCancel),
                          compact: true,
                          onPressed: () => setState(() => _addingChar = false),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (ctrl.characterCards.isEmpty)
              FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                child: Row(
                  children: [
                    Expanded(
                      child: InkText(
                        l10n.t(L10nKey.storyAddCharacter),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                    ),
                    EngravedButton(
                      label: l10n.t(L10nKey.storyImportCard),
                      compact: true,
                      onPressed: () => unawaited(
                        ctrl.importCharacterCardFromFile(
                          title: l10n.t(L10nKey.storyImportCard),
                          filterLabel: _kCardFilterSpecLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              for (final card in ctrl.characterCards) ...[
                _CharacterCardTile(
                  card: card,
                  activeInScene: state.activeCharacterIds.contains(card.id),
                  onToggleActive: () =>
                      unawaited(ctrl.toggleActiveCharacterInThread(card.id)),
                  onExport: () =>
                      unawaited(ctrl.exportCharacterCardToClipboard(card.id)),
                  onRestoreSnapshot: () =>
                      unawaited(ctrl.restoreLatestCharacterSnapshot(card.id)),
                  onDelete: () => unawaited(ctrl.deleteCharacterCard(card.id)),
                ),
                const SizedBox(height: 6),
              ],
            const SizedBox(height: 12),

            // --- 2. User Persona ---
            _SectionHeaderRow(
              icon: BistreUiIcon.edit,
              title: l10n.t(L10nKey.storyPersonasTitle),
              trailing: BistreIconButton(
                icon: BistreUiIcon.edit,
                size: 13,
                dimension: 26,
                semanticsLabel: l10n.t(L10nKey.storyPersonasTitle),
                onPressed: () {
                  if (!_editingPersona && activePersona != null) {
                    _personaNameCtrl.text = activePersona.name;
                    _personaDescCtrl.text = activePersona.description;
                  }
                  setState(() => _editingPersona = !_editingPersona);
                },
              ),
            ),
            const SizedBox(height: 6),
            if (_editingPersona)
              FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    QuillInput(
                      controller: _personaNameCtrl,
                      focusNode: _personaNameFocus,
                      placeholder: _kDefaultPersonaName,
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 6),
                    QuillInput(
                      controller: _personaDescCtrl,
                      focusNode: _personaDescFocus,
                      placeholder: l10n.t(L10nKey.storyPersonasTitle),
                      maxLines: 3,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        EngravedButton(
                          label: l10n.t(L10nKey.threadSave),
                          primary: true,
                          compact: true,
                          onPressed: () {
                            final name = _personaNameCtrl.text.trim();
                            if (name.isEmpty) return;
                            unawaited(
                              ctrl.saveUserPersona(
                                EngineUserPersona(
                                  id: activePersona?.id ?? '',
                                  name: name,
                                  description: _personaDescCtrl.text.trim(),
                                  isDefault: true,
                                ),
                              ),
                            );
                            setState(() => _editingPersona = false);
                          },
                        ),
                        const SizedBox(width: 6),
                        EngravedButton(
                          label: l10n.t(L10nKey.threadCancel),
                          compact: true,
                          onPressed: () =>
                              setState(() => _editingPersona = false),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkText(
                      activePersona?.name ?? _kDefaultPersonaName,
                      role: InkTextRole.labelStrong,
                      color: theme.inkPrimary,
                    ),
                    if (activePersona != null &&
                        activePersona.description.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      InkText(
                        activePersona.description,
                        role: InkTextRole.captionMeta,
                        color: theme.inkSecondary,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 12),

            // --- 3. World & Lorebook V3 + Chronological Progressions ---
            _SectionHeaderRow(
              icon: BistreUiIcon.bookOpen,
              title: l10n.t(L10nKey.storyCodexTitle),
              trailing: BistreIconButton(
                icon: BistreUiIcon.plus,
                size: 13,
                dimension: 26,
                semanticsLabel: l10n.t(L10nKey.storyAddEntry),
                onPressed: () => setState(() => _addingEntry = !_addingEntry),
              ),
            ),
            const SizedBox(height: 6),
            if (_addingEntry) ...[
              FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    QuillInput(
                      controller: _entryNameCtrl,
                      focusNode: _entryNameFocus,
                      placeholder: l10n.t(L10nKey.storyAddEntry),
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 6),
                    QuillInput(
                      controller: _entryKeysCtrl,
                      focusNode: _entryKeysFocus,
                      placeholder: l10n.t(L10nKey.storyCodexTitle),
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 6),
                    QuillInput(
                      controller: _entryContentCtrl,
                      focusNode: _entryContentFocus,
                      placeholder: l10n.t(L10nKey.storyStoryMemory),
                      maxLines: 3,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final cat in const <String>[
                          _kCategoryLore,
                          _kCategoryCharacter,
                          _kCategoryLocation,
                        ])
                          InkChip(
                            label: cat,
                            selected: _entryCategory == cat,
                            onSelected: () =>
                                setState(() => _entryCategory = cat),
                          ),
                        InkChip(
                          label: l10n.t(L10nKey.threadPin),
                          selected: _entryConstant,
                          onSelected: () =>
                              setState(() => _entryConstant = !_entryConstant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        EngravedButton(
                          label: l10n.t(L10nKey.threadSave),
                          primary: true,
                          compact: true,
                          onPressed: () {
                            final name = _entryNameCtrl.text.trim();
                            if (name.isEmpty) return;
                            final keys = _entryKeysCtrl.text
                                .split(',')
                                .map((k) => k.trim())
                                .where((k) => k.isNotEmpty)
                                .toList(growable: false);
                            unawaited(
                              ctrl.saveStoryEntry(
                                EngineStoryEntry(
                                  name: name,
                                  category: _entryCategory,
                                  keys: keys,
                                  content: _entryContentCtrl.text.trim(),
                                  constant: _entryConstant,
                                ),
                              ),
                            );
                            _entryNameCtrl.clear();
                            _entryKeysCtrl.clear();
                            _entryContentCtrl.clear();
                            setState(() => _addingEntry = false);
                          },
                        ),
                        const SizedBox(width: 6),
                        EngravedButton(
                          label: l10n.t(L10nKey.threadCancel),
                          compact: true,
                          onPressed: () => setState(() => _addingEntry = false),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            for (final entry in ctrl.storyEntries) ...[
              _StoryEntryTile(
                entry: entry,
                progressions: ctrl.storyProgressions
                    .where((p) => p.entryId == entry.id)
                    .toList(growable: false),
                addingProgression: _addingProgressionForEntryId == entry.id,
                chapterCtrl: _progChapterCtrl,
                chapterFocus: _progChapterFocus,
                deltaCtrl: _progDeltaCtrl,
                deltaFocus: _progDeltaFocus,
                onStartProgression: () => setState(
                  () => _addingProgressionForEntryId =
                      _addingProgressionForEntryId == entry.id
                      ? null
                      : entry.id,
                ),
                onSaveProgression: () {
                  final chOrder =
                      int.tryParse(_progChapterCtrl.text.trim()) ?? 2;
                  unawaited(
                    ctrl.addStoryProgression(
                      entryId: entry.id,
                      chapterOrder: chOrder.clamp(1, 999),
                      deltaText: _progDeltaCtrl.text.trim(),
                    ),
                  );
                  _progDeltaCtrl.clear();
                  setState(() => _addingProgressionForEntryId = null);
                },
                onDelete: () => unawaited(ctrl.deleteStoryEntry(entry.id)),
              ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 12),

            // --- 4. Story Memory (Static Cache Prefix) & Author's Note (@D) ---
            _SectionHeaderRow(
              icon: BistreUiIcon.memory,
              title: l10n.t(L10nKey.storyStoryMemory),
            ),
            const SizedBox(height: 6),
            FolioSurface(
              tone: FolioTone.elevated,
              borderRadius: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  QuillInput(
                    controller: _storyMemoryCtrl,
                    focusNode: _storyMemoryFocus,
                    placeholder: l10n.t(L10nKey.storyStoryMemory),
                    maxLines: 3,
                    submitOnEnter: false,
                    onSubmitted: () {},
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.storyAuthorNote),
                          role: InkTextRole.labelStrong,
                          color: theme.inkPrimary,
                        ),
                      ),
                      WaxSealBadge(label: _depthTag(state.authorNoteDepth)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  QuillInput(
                    controller: _authorNoteCtrl,
                    focusNode: _authorNoteFocus,
                    placeholder: l10n.t(L10nKey.storyAuthorNote),
                    maxLines: 2,
                    submitOnEnter: false,
                    onSubmitted: () {},
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: EngravedButton(
                      label: l10n.t(L10nKey.threadSave),
                      compact: true,
                      onPressed: () => unawaited(
                        ctrl.saveStoryThreadState(
                          state.copyWith(
                            storyMemory: _storyMemoryCtrl.text.trim(),
                            authorNote: _authorNoteCtrl.text.trim(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // --- 5. Safe Linear-Time Text Rules (Regex) ---
            _SectionHeaderRow(
              icon: BistreUiIcon.code,
              title: l10n.t(L10nKey.storyRegexTitle),
              trailing: BistreIconButton(
                icon: BistreUiIcon.plus,
                size: 13,
                dimension: 26,
                semanticsLabel: l10n.t(L10nKey.storyRegexTitle),
                onPressed: () => setState(() => _addingRegex = !_addingRegex),
              ),
            ),
            const SizedBox(height: 6),
            if (_addingRegex) ...[
              FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    QuillInput(
                      controller: _regexNameCtrl,
                      focusNode: _regexNameFocus,
                      placeholder: l10n.t(L10nKey.storyRegexTitle),
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 6),
                    QuillInput(
                      controller: _regexPatternCtrl,
                      focusNode: _regexPatternFocus,
                      placeholder: _kScopeDisplay,
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 6),
                    QuillInput(
                      controller: _regexReplaceCtrl,
                      focusNode: _regexReplaceFocus,
                      placeholder: l10n.t(L10nKey.storyLaserRewrite),
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () {},
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final scope in const <String>[
                          _kScopeDisplay,
                          _kScopePrompt,
                          _kScopeIncoming,
                        ])
                          InkChip(
                            label: scope,
                            selected: _regexScope == scope,
                            onSelected: () =>
                                setState(() => _regexScope = scope),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    EngravedButton(
                      label: l10n.t(L10nKey.threadSave),
                      primary: true,
                      compact: true,
                      onPressed: () {
                        final pat = _regexPatternCtrl.text.trim();
                        if (pat.isEmpty) return;
                        unawaited(
                          ctrl.saveRegexRule(
                            EngineRegexRule(
                              name: _regexNameCtrl.text.trim().isEmpty
                                  ? pat
                                  : _regexNameCtrl.text.trim(),
                              pattern: pat,
                              replacement: _regexReplaceCtrl.text,
                              scope: _regexScope,
                            ),
                          ),
                        );
                        _regexNameCtrl.clear();
                        _regexPatternCtrl.clear();
                        _regexReplaceCtrl.clear();
                        setState(() => _addingRegex = false);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
            for (final rule in ctrl.regexRules) ...[
              FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkText(
                            rule.name,
                            role: InkTextRole.labelStrong,
                            color: theme.inkPrimary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          InkText(
                            rule.pattern,
                            role: InkTextRole.codeBlock,
                            color: theme.inkMuted,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    WaxSealBadge(label: rule.scope),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionHeaderRow extends StatelessWidget {
  const _SectionHeaderRow({
    required this.icon,
    required this.title,
    this.trailing,
  });

  final BistreUiIcon icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Row(
      children: [
        BistreIcon(icon, size: 14, color: theme.accentBrass),
        const SizedBox(width: 6),
        Expanded(
          child: InkText(
            title,
            role: InkTextRole.labelStrong,
            color: theme.inkPrimary,
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _CharacterCardTile extends StatelessWidget {
  const _CharacterCardTile({
    required this.card,
    required this.activeInScene,
    required this.onToggleActive,
    required this.onExport,
    required this.onRestoreSnapshot,
    required this.onDelete,
  });

  final EngineCharacterCard card;
  final bool activeInScene;
  final VoidCallback onToggleActive;
  final VoidCallback onExport;
  final VoidCallback onRestoreSnapshot;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);

    return FolioSurface(
      tone: FolioTone.elevated,
      borderRadius: 10,
      padding: const EdgeInsetsDirectional.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onToggleActive,
                  child: Row(
                    children: [
                      BistreIcon(
                        activeInScene
                            ? BistreUiIcon.check
                            : BistreUiIcon.assistant,
                        size: 13,
                        color: activeInScene ? theme.accentWax : theme.inkMuted,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: InkText(
                          card.name,
                          role: InkTextRole.labelStrong,
                          color: theme.inkPrimary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              BistreIconButton(
                icon: BistreUiIcon.rewind,
                size: 12,
                dimension: 24,
                semanticsLabel: l10n.t(L10nKey.storyTimeMachine),
                onPressed: onRestoreSnapshot,
              ),
              BistreIconButton(
                icon: BistreUiIcon.download,
                size: 12,
                dimension: 24,
                semanticsLabel: l10n.t(L10nKey.storyExportCard),
                onPressed: onExport,
              ),
              BistreIconButton(
                icon: BistreUiIcon.trash,
                size: 12,
                dimension: 24,
                semanticsLabel: l10n.t(L10nKey.threadDelete),
                onPressed: onDelete,
              ),
            ],
          ),
          if (card.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            InkText(
              card.description,
              role: InkTextRole.captionMeta,
              color: theme.inkSecondary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _StoryEntryTile extends StatelessWidget {
  const _StoryEntryTile({
    required this.entry,
    required this.progressions,
    required this.addingProgression,
    required this.chapterCtrl,
    required this.chapterFocus,
    required this.deltaCtrl,
    required this.deltaFocus,
    required this.onStartProgression,
    required this.onSaveProgression,
    required this.onDelete,
  });

  final EngineStoryEntry entry;
  final List<EngineStoryProgression> progressions;
  final bool addingProgression;
  final TextEditingController chapterCtrl;
  final FocusNode chapterFocus;
  final TextEditingController deltaCtrl;
  final FocusNode deltaFocus;
  final VoidCallback onStartProgression;
  final VoidCallback onSaveProgression;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);

    return FolioSurface(
      tone: FolioTone.elevated,
      borderRadius: 10,
      padding: const EdgeInsetsDirectional.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkText(
                  entry.name,
                  role: InkTextRole.labelStrong,
                  color: theme.inkPrimary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              WaxSealBadge(label: entry.category),
              const SizedBox(width: 4),
              BistreIconButton(
                icon: BistreUiIcon.branchTree,
                size: 12,
                dimension: 24,
                semanticsLabel: l10n.t(L10nKey.storyProgressionsTitle),
                onPressed: onStartProgression,
              ),
              BistreIconButton(
                icon: BistreUiIcon.trash,
                size: 12,
                dimension: 24,
                semanticsLabel: l10n.t(L10nKey.threadDelete),
                onPressed: onDelete,
              ),
            ],
          ),
          if (entry.keys.isNotEmpty) ...[
            const SizedBox(height: 3),
            InkText(
              _keysSummary(entry.keys),
              role: InkTextRole.captionMeta,
              color: theme.accentBrass,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (entry.content.isNotEmpty) ...[
            const SizedBox(height: 4),
            InkText(
              entry.content,
              role: InkTextRole.captionMeta,
              color: theme.inkSecondary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (progressions.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final p in progressions)
              Padding(
                padding: const EdgeInsetsDirectional.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    WaxSealBadge(label: _chapterTag(p.chapterOrder)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: InkText(
                        p.deltaText,
                        role: InkTextRole.captionMeta,
                        color: theme.inkSecondary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (addingProgression) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                SizedBox(
                  width: 58,
                  child: QuillInput(
                    controller: chapterCtrl,
                    focusNode: chapterFocus,
                    placeholder: _chapterTag(2),
                    maxLines: 1,
                    submitOnEnter: false,
                    onSubmitted: () {},
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: QuillInput(
                    controller: deltaCtrl,
                    focusNode: deltaFocus,
                    placeholder: l10n.t(L10nKey.storyProgressionsTitle),
                    maxLines: 1,
                    submitOnEnter: false,
                    onSubmitted: onSaveProgression,
                  ),
                ),
                const SizedBox(width: 4),
                EngravedButton(
                  label: l10n.t(L10nKey.threadSave),
                  compact: true,
                  onPressed: onSaveProgression,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
