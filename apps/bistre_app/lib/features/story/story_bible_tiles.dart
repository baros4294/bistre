part of 'story_bible_panel.dart';

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
                child: PressFeedback(
                  pressScale: kRowPressScale,
                  hoverScale: 1,
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
                          color: activeInScene
                              ? theme.accentWax
                              : theme.inkMuted,
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
