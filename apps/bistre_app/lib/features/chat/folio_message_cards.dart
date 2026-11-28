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

/// A summary standing in for earlier messages. The user can correct it (Edit) or bring the
/// full messages back (Undo); both wait while a reply is being written.
class _CompactionSummaryCard extends StatefulWidget {
  const _CompactionSummaryCard({required this.node, required this.ctrl});

  final EngineNode node;
  final FolioController ctrl;

  @override
  State<_CompactionSummaryCard> createState() => _CompactionSummaryCardState();
}

class _CompactionSummaryCardState extends State<_CompactionSummaryCard>
    with AutomaticKeepAliveClientMixin<_CompactionSummaryCard> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _editing = false;

  /// An open edit survives scrolling the card out of view.
  @override
  bool get wantKeepAlive => _editing;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  void _setEditing(bool editing) {
    setState(() => _editing = editing);
    updateKeepAlive();
  }

  void _startEdit() {
    _text.text = widget.node.content;
    _setEditing(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _save() async {
    final ok = await widget.ctrl.rewriteCompactionSummary(
      widget.node.id,
      _text.text,
    );
    if (ok && mounted) _setEditing(false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.ctrl;
    final idle = !ctrl.isStreaming;
    final canSave = idle && _text.text.trim().isNotEmpty;
    final actions = _editing
        ? <Widget>[
            EngravedButton(
              label: l10n.t(L10nKey.threadCancel),
              compact: true,
              onPressed: () => _setEditing(false),
            ),
            EngravedButton(
              label: l10n.t(L10nKey.threadSave),
              primary: true,
              compact: true,
              onPressed: canSave ? () => unawaited(_save()) : null,
            ),
          ]
        : <Widget>[
            if (idle)
              EngravedButton(
                label: l10n.t(L10nKey.chatActionEdit),
                compact: true,
                onPressed: _startEdit,
              ),
            if (idle)
              EngravedButton(
                label: l10n.t(L10nKey.chatUndoCompaction),
                compact: true,
                onPressed: () => unawaited(ctrl.undoCompaction(widget.node.id)),
              ),
          ];
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 10),
      child: FolioSurface(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
              ],
            ),
            const SizedBox(height: 8),
            if (_editing)
              QuillInput(
                controller: _text,
                focusNode: _focus,
                placeholder: l10n.t(L10nKey.chatCompactedTitle),
                maxLines: 12,
                submitOnEnter: false,
                onSubmitted: () {
                  if (canSave) unawaited(_save());
                },
              )
            else
              InkText(
                widget.node.content,
                role: InkTextRole.bodyCompact,
                color: theme.inkSecondary,
              ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: actions,
              ),
            ],
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
    this.prefs = const UiDisplayPrefs(),
    required this.reduceMotionOverride,
    required this.onCopyCode,
    this.onQuoteThinking,
    this.onApproveToolOnce,
    this.onApproveToolChat,
    this.onDenyTool,
    this.onStopTool,
    this.onRewindCheckpoint,
  });

  final String assistantName;
  final EngineProvider? provider;
  final String modelId;
  final String buffer;
  final String thinkingBuffer;
  final List<ToolActivityEntry> toolActivities;
  final FolioLayoutMode layoutMode;
  final UiDisplayPrefs prefs;
  final bool reduceMotionOverride;
  final ValueChanged<String> onCopyCode;
  final ValueChanged<String>? onQuoteThinking;
  final ValueChanged<String>? onApproveToolOnce;
  final ValueChanged<String>? onApproveToolChat;
  final ValueChanged<String>? onDenyTool;
  final ValueChanged<String>? onStopTool;
  final ValueChanged<String>? onRewindCheckpoint;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    // Hidden tool cards never hide a question: approvals always show.
    final shownTools = prefs.showToolCards
        ? toolActivities
        : <ToolActivityEntry>[
            for (final e in toolActivities)
              if (e.status == 'awaiting_approval') e,
          ];
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
        if (thinkingBuffer.isNotEmpty && prefs.showThinkingCards) ...[
          const SizedBox(height: 10),
          ReasoningBlock(
            thinkingText: thinkingBuffer,
            isStreaming: buffer.isEmpty,
            onQuoteIntoComposer: onQuoteThinking,
            autoCollapse: prefs.autoCollapseThinking,
          ),
        ],
        if (shownTools.isNotEmpty) ...[
          const SizedBox(height: 6),
          ToolTimelineView(
            entries: shownTools,
            onApproveOnce: onApproveToolOnce,
            onApproveChat: onApproveToolChat,
            onDeny: onDenyTool,
            onStop: onStopTool,
            onRewindCheckpoint: onRewindCheckpoint,
          ),
        ],
        if (buffer.isNotEmpty) ...[
          const SizedBox(height: 10),
          MarkdownFolioView(
            markdown: buffer,
            onCopyCode: onCopyCode,
            renderMath: prefs.renderMathFormulas,
            foldCodeBlocks: prefs.autoCollapseCodeBlocks,
          ),
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
  const _ReadingColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final readingWidth = BistreTheme.of(context).typography.readingWidthPx
        .clamp(BistreSpacing.readingWidthMin, BistreSpacing.readingWidthMax);
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

class _ProviderSetupBanner extends StatelessWidget {
  const _ProviderSetupBanner({required this.onOpenProviders});

  final VoidCallback onOpenProviders;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.bgElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: theme.borderHairline),
          boxShadow: theme.cardShadow,
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  BistreIcon(
                    BistreUiIcon.key,
                    size: 16,
                    color: theme.accentBrass,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: InkText(
                      l10n.t(L10nKey.providerSetupTitle),
                      role: InkTextRole.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              InkText(
                l10n.t(L10nKey.providerSetupBody),
                role: InkTextRole.bodyCompact,
                color: theme.inkSecondary,
              ),
              const SizedBox(height: 14),
              EngravedButton(
                label: l10n.t(L10nKey.providerSetupCta),
                primary: true,
                compact: true,
                leading: BistreIcon(
                  BistreUiIcon.key,
                  size: 13,
                  color: theme.onAccentWax,
                ),
                onPressed: onOpenProviders,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [name] cut in the middle to at most [max] characters, keeping the extension:
/// `quarterly-report-final-v2.pdf` reads `quarterly-re…v2.pdf`.
String middleEllipsis(String name, {int max = 28}) {
  final chars = name.characters;
  if (chars.length <= max) return name;
  final dot = name.lastIndexOf('.');
  final ext = dot > 0 && name.length - dot <= 8 ? name.substring(dot) : '';
  final room = max - ext.characters.length - 1;
  final stem = (ext.isEmpty ? name : name.substring(0, dot)).characters;
  final head = (room * 0.6).ceil();
  final tail = room - head;
  return '${stem.take(head)}…${tail > 0 ? stem.takeLast(tail) : ''}$ext';
}

/// The icon for a sent file's kind.
BistreUiIcon attachmentIconFor(String mimeType, String name) {
  final m = mimeType.toLowerCase();
  final n = name.toLowerCase();
  if (m.startsWith('audio/')) return BistreUiIcon.audioLines;
  if (m.contains('csv') || m.contains('spreadsheet') || n.endsWith('.xlsx')) {
    return BistreUiIcon.tableGrid;
  }
  if (m.contains('json') ||
      m.contains('javascript') ||
      m.contains('x-') && m.startsWith('text/')) {
    return BistreUiIcon.code;
  }
  if (m.startsWith('image/')) return BistreUiIcon.eye;
  return BistreUiIcon.document;
}

/// A work check core sent while the chat's goal was open: a quiet line, not a message.
class _GoalCheckNote extends StatelessWidget {
  const _GoalCheckNote();

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        vertical: BistreSpacing.s8,
      ),
      child: Row(
        children: [
          BistreIcon(BistreUiIcon.check, size: 12, color: theme.inkMuted),
          const SizedBox(width: BistreSpacing.s8),
          Expanded(
            child: InkText(
              l10n.t(L10nKey.chatGoalCheckNote),
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            ),
          ),
        ],
      ),
    );
  }
}

extension _PassageMenuEntries on _PassageItemState {
  /// Right-click menu mirroring the message action bar plus translate, pin & turn details.
  List<ContextMenuEntry> _buildPassageMenuEntries(
    BistreLocalizationController l10n,
    bool isAssistant,
  ) {
    final w = widget;
    final edit = w.onEditResend;
    final regenerate = w.onRegenerate;
    final translate = w.onTranslate;
    final pin = w.onToggleContextPin;
    final pinReply = w.onTogglePinReply;
    final inspectTurn = w.onInspectTurnDetails;
    final delete = w.onDelete;
    final exclude = w.onToggleExcluded;
    return <ContextMenuEntry>[
      if (isAssistant)
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatActionReply),
          icon: BistreUiIcon.reply,
          onSelected: w.onReply,
        ),
      if (!isAssistant && edit != null)
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatActionEdit),
          icon: BistreUiIcon.edit,
          onSelected: _startEdit,
        ),
      if (isAssistant && w.onEditReply != null)
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatActionEditReply),
          icon: BistreUiIcon.edit,
          onSelected: _startEdit,
        ),
      if (exclude != null)
        ContextMenuEntry(
          label: l10n.t(
            w.isExcluded
                ? L10nKey.chatActionIncludeContext
                : L10nKey.chatActionExcludeContext,
          ),
          icon: w.isExcluded ? BistreUiIcon.eye : BistreUiIcon.eyeOff,
          onSelected: exclude,
        ),
      ContextMenuEntry(
        label: l10n.t(L10nKey.chatActionCopy),
        icon: BistreUiIcon.copy,
        onSelected: w.onCopy,
      ),
      if (regenerate != null)
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatActionRegenerate),
          icon: BistreUiIcon.refresh,
          onSelected: regenerate,
        ),
      if (translate != null)
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatActionTranslate),
          icon: BistreUiIcon.globe,
          onSelected: translate,
        ),
      if (pinReply != null)
        ContextMenuEntry(
          label: w.isPinnedReply
              ? l10n.t(L10nKey.chatUnpinReply)
              : l10n.t(L10nKey.chatPinReply),
          icon: w.isPinnedReply ? BistreUiIcon.pinFilled : BistreUiIcon.pin,
          onSelected: pinReply,
        ),
      if (w.onSaveAsSkill case final saveSkill? when isAssistant)
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatActionSaveSkill),
          icon: BistreUiIcon.bookOpen,
          onSelected: saveSkill,
        ),
      if (inspectTurn != null)
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatTurnDetails),
          icon: BistreUiIcon.info,
          onSelected: inspectTurn,
        ),
      if (pin != null)
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatPinContextStart),
          // The same icon as the reply's action bar, never the reply pin's.
          icon: BistreUiIcon.branchTree,
          onSelected: pin,
        ),
      if (delete != null)
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatActionDelete),
          icon: BistreUiIcon.trash,
          onSelected: delete,
          destructive: true,
        ),
    ];
  }
}
