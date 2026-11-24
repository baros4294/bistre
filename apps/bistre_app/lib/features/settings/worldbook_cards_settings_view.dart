import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Dedicated World Book & Character Cards settings tab:
/// - Import/export `.png` / `.json` / `.charx` character cards
/// - Active card summary + delete
/// - Global & per-chat World Book / Lorebook keyword entries
class WorldbookCardsSettingsView extends StatefulWidget {
  const WorldbookCardsSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<WorldbookCardsSettingsView> createState() =>
      _WorldbookCardsSettingsViewState();
}

class _WorldbookCardsSettingsViewState
    extends State<WorldbookCardsSettingsView> {
  final TextEditingController _entryTitleCtrl = TextEditingController();
  final TextEditingController _entryKeysCtrl = TextEditingController();
  final TextEditingController _entryBodyCtrl = TextEditingController();
  final FocusNode _entryTitleFocus = FocusNode();
  final FocusNode _entryKeysFocus = FocusNode();
  final FocusNode _entryBodyFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.refreshStoryStudio());
  }

  @override
  void dispose() {
    _entryTitleCtrl.dispose();
    _entryKeysCtrl.dispose();
    _entryBodyCtrl.dispose();
    _entryTitleFocus.dispose();
    _entryKeysFocus.dispose();
    _entryBodyFocus.dispose();
    super.dispose();
  }

  Future<void> _addLoreEntry() async {
    final title = _entryTitleCtrl.text.trim();
    final content = _entryBodyCtrl.text.trim();
    if (title.isEmpty || content.isEmpty) return;
    final keys = _entryKeysCtrl.text
        .split(',')
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
    final entry = EngineStoryEntry(
      id: 'lore_${DateTime.now().microsecondsSinceEpoch}',
      name: title,
      content: content,
      keys: keys,
    );
    await widget.controller.saveStoryEntry(entry);
    if (mounted) {
      _entryTitleCtrl.clear();
      _entryKeysCtrl.clear();
      _entryBodyCtrl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final cards = ctrl.characterCards;
    final entries = ctrl.storyEntries;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Character & Scenario Cards
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsWorldBookCardsHeading),
              subtitle: l10n.t(L10nKey.settingsWorldBookCardsHint),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsWorldBookImportCard),
                  trailing: EngravedButton(
                    label: l10n.t(L10nKey.settingsWorldBookImportCard),
                    primary: true,
                    compact: true,
                    leading: BistreIcon(
                      BistreUiIcon.plus,
                      size: 13,
                      color: theme.onAccentWax,
                    ),
                    onPressed: () => unawaited(
                      ctrl.importCharacterCardFromFile(
                        title: l10n.t(L10nKey.settingsWorldBookImportCard),
                        filterLabel: 'Character Card (.png, .json, .charx)',
                      ),
                    ),
                  ),
                ),
                if (cards.isEmpty)
                  Padding(
                    padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
                    child: InkText(
                      l10n.t(L10nKey.settingsWorldBookCardsEmpty),
                      role: InkTextRole.bodyCompact,
                      color: theme.inkMuted,
                    ),
                  )
                else
                  for (final card in cards)
                    BistreSettingRow(
                      label: card.name,
                      description: card.description.trim().isNotEmpty
                          ? card.description.trim()
                          : card.creatorNotes.trim(),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          EngravedButton(
                            label: l10n.t(L10nKey.chatActionCopy),
                            compact: true,
                            onPressed: () => unawaited(
                              ctrl.exportCharacterCardToClipboard(card.id),
                            ),
                          ),
                          const SizedBox(width: 6),
                          BistreIconButton(
                            icon: BistreUiIcon.trash,
                            size: 14,
                            dimension: 28,
                            semanticsLabel: l10n.t(L10nKey.threadDelete),
                            onPressed: () =>
                                unawaited(ctrl.deleteCharacterCard(card.id)),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s24),

            // 2. Global & Per-Chat World Book / Lorebook Entries
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsWorldBookLoreHeading),
              subtitle: l10n.t(L10nKey.settingsWorldBookLoreHint),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsWorldBookAddEntry),
                  bottom: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: QuillInput(
                              controller: _entryTitleCtrl,
                              focusNode: _entryTitleFocus,
                              placeholder: l10n.t(
                                L10nKey.settingsWorldBookEntryTitle,
                              ),
                              maxLines: 1,
                              submitOnEnter: false,
                              onSubmitted: () {},
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: QuillInput(
                              controller: _entryKeysCtrl,
                              focusNode: _entryKeysFocus,
                              placeholder: l10n.t(
                                L10nKey.settingsWorldBookEntryKeys,
                              ),
                              maxLines: 1,
                              submitOnEnter: false,
                              onSubmitted: () {},
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      QuillInput(
                        controller: _entryBodyCtrl,
                        focusNode: _entryBodyFocus,
                        placeholder: l10n.t(L10nKey.settingsWorldBookEntryBody),
                        maxLines: 3,
                        submitOnEnter: false,
                        onSubmitted: () {},
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: EngravedButton(
                          label: l10n.t(L10nKey.settingsWorldBookAddEntry),
                          primary: true,
                          compact: true,
                          onPressed: () => unawaited(_addLoreEntry()),
                        ),
                      ),
                    ],
                  ),
                ),
                if (entries.isEmpty)
                  Padding(
                    padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
                    child: InkText(
                      l10n.t(L10nKey.settingsWorldBookLoreEmpty),
                      role: InkTextRole.bodyCompact,
                      color: theme.inkMuted,
                    ),
                  )
                else
                  for (final entry in entries)
                    BistreSettingRow(
                      label: entry.name,
                      description: entry.keys.isNotEmpty
                          ? '${entry.keys.join(', ')} — ${entry.content}'
                          : entry.content,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          BistreSwitch(
                            value: entry.enabled,
                            semanticsLabel: entry.name,
                            reduceMotionOverride: ctrl.reduceMotionOverride,
                            onChanged: (on) => unawaited(
                              ctrl.saveStoryEntry(
                                EngineStoryEntry(
                                  id: entry.id,
                                  bookId: entry.bookId,
                                  category: entry.category,
                                  name: entry.name,
                                  content: entry.content,
                                  keys: entry.keys,
                                  enabled: on,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          BistreIconButton(
                            icon: BistreUiIcon.trash,
                            size: 14,
                            dimension: 28,
                            semanticsLabel: l10n.t(L10nKey.threadDelete),
                            onPressed: () =>
                                unawaited(ctrl.deleteStoryEntry(entry.id)),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
