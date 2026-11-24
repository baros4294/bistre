part of 'folio_message_feed.dart';

class _PinnedContextBanner extends StatelessWidget {
  const _PinnedContextBanner({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 4, bottom: 6),
      child: Row(
        children: [
          const Expanded(child: FolioDivider()),
          const SizedBox(width: 10),
          BistreIcon(
            BistreUiIcon.pinFilled,
            size: 12,
            color: theme.accentBrass,
          ),
          const SizedBox(width: 5),
          InkText(
            l10n.t(L10nKey.chatPinnedContextBanner),
            role: InkTextRole.captionMeta,
            color: theme.accentBrass,
          ),
          const SizedBox(width: 6),
          BistreIconButton(
            icon: BistreUiIcon.close,
            size: 11,
            dimension: 20,
            semanticsLabel: l10n.t(L10nKey.threadUnpin),
            onPressed: onClear,
          ),
          const SizedBox(width: 10),
          const Expanded(child: FolioDivider()),
        ],
      ),
    );
  }
}

class _CompactionSummaryCard extends StatelessWidget {
  const _CompactionSummaryCard({required this.node, required this.onUndo});

  final EngineNode node;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 10),
      child: FolioSurface(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                BistreIcon(
                  BistreUiIcon.document,
                  size: 14,
                  color: theme.accentBrass,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkText(
                    l10n.t(L10nKey.chatCompactedTitle),
                    role: InkTextRole.labelStrong,
                    color: theme.accentBrass,
                  ),
                ),
                if (onUndo != null)
                  EngravedButton(
                    label: l10n.t(L10nKey.chatUndoCompaction),
                    compact: true,
                    onPressed: onUndo,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            InkText(
              node.content,
              role: InkTextRole.bodyCompact,
              color: theme.inkSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _StreamingPassageCard extends StatelessWidget {
  const _StreamingPassageCard({
    required this.assistantName,
    required this.provider,
    required this.modelId,
    required this.buffer,
    this.thinkingBuffer = '',
    this.toolActivities = const <ToolActivityEntry>[],
    required this.layoutMode,
    required this.reduceMotionOverride,
    required this.onCopyCode,
    this.onQuoteThinking,
    this.onApproveToolOnce,
    this.onApproveToolChat,
    this.onDenyTool,
    this.onRewindCheckpoint,
  });

  final String assistantName;
  final EngineProvider? provider;
  final String modelId;
  final String buffer;
  final String thinkingBuffer;
  final List<ToolActivityEntry> toolActivities;
  final FolioLayoutMode layoutMode;
  final bool reduceMotionOverride;
  final ValueChanged<String> onCopyCode;
  final ValueChanged<String>? onQuoteThinking;
  final ValueChanged<String>? onApproveToolOnce;
  final ValueChanged<String>? onApproveToolChat;
  final ValueChanged<String>? onDenyTool;
  final ValueChanged<String>? onRewindCheckpoint;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            LabIcon(
              iconSlug: provider?.iconSlug,
              customIconPath: provider?.customIconPath,
              dialect: provider?.dialect,
              providerName: provider?.name,
              modelId: modelId,
              size: 15,
            ),
            const SizedBox(width: BistreSpacing.s8),
            InkText(
              assistantName,
              role: InkTextRole.labelStrong,
              color: theme.inkPrimary,
            ),
            const SizedBox(width: BistreSpacing.s8),
            FolioStreamingCursor(reduceMotionOverride: reduceMotionOverride),
          ],
        ),
        if (thinkingBuffer.isNotEmpty) ...[
          const SizedBox(height: 10),
          ReasoningBlock(
            thinkingText: thinkingBuffer,
            isStreaming: buffer.isEmpty,
            onQuoteIntoComposer: onQuoteThinking,
          ),
        ],
        if (toolActivities.isNotEmpty) ...[
          const SizedBox(height: 6),
          ToolTimelineView(
            entries: toolActivities,
            onApproveOnce: onApproveToolOnce,
            onApproveChat: onApproveToolChat,
            onDeny: onDenyTool,
            onRewindCheckpoint: onRewindCheckpoint,
          ),
        ],
        if (buffer.isNotEmpty) ...[
          const SizedBox(height: 10),
          MarkdownFolioView(markdown: buffer, onCopyCode: onCopyCode),
        ],
      ],
    );

    if (layoutMode == FolioLayoutMode.bubbles) {
      return Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          vertical: BistreSpacing.s8,
        ),
        child: FolioSurface(
          tone: FolioTone.elevated,
          padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
          borderRadius: 14,
          boxShadow: theme.cardShadow,
          child: body,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        vertical: BistreSpacing.s12,
      ),
      child: body,
    );
  }
}

/// Centers one feed item inside the reading measure while the scroll surface stays full width.
class _ReadingColumn extends StatelessWidget {
  const _ReadingColumn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final readingWidth = BistreTheme.of(context).typography.readingWidthPx
        .clamp(600.0, 1120.0);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: readingWidth),
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: BistreSpacing.s24,
          ),
          child: child,
        ),
      ),
    );
  }
}
