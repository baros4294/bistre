part of 'folio_message_feed.dart';

/// Longest message you sent that shows in full at once (characters); a longer one opens
/// with Show more.
const int kLongMessageChars = 3000;

/// Height a collapsed long message shows, in logical pixels at 100% text.
const double kCollapsedMessageHeight = 220;

class _PassageItem extends StatefulWidget {
  const _PassageItem({
    required this.node,
    required this.onOpenAttachment,
    this.attachmentPath,
    this.userName = '',
    this.userAvatarPath = '',
    required this.assistantName,
    required this.activeProvider,
    required this.layoutMode,
    required this.showTokenMetrics,
    this.prefs = const UiDisplayPrefs(),
    this.editorialDialogueStyling = false,
    this.isPinnedContextStart = false,
    required this.branchInfo,
    required this.showBottomDivider,
    required this.reduceMotionOverride,
    this.showActionsAtRest = false,
    required this.onCopy,
    this.onCopyPlain,
    this.onBranchNewChat,
    this.onSaveAsSkill,
    required this.onCopyCode,
    required this.onSaveCode,
    required this.onReply,
    required this.onQuoteThinking,
    required this.onToggleContextPin,
    required this.onEditResend,
    required this.onRegenerate,
    required this.onDelete,
    required this.onBranchDelta,
    this.isPinnedReply = false,
    this.onTogglePinReply,
    this.onInspectTurnDetails,
    this.onTranslate,
    this.sourceCount = 0,
    this.isSpeaking = false,
    this.onSpeak,
    this.isExcluded = false,
    this.onToggleExcluded,
    this.onEditReply,
  });

  final EngineNode node;

  /// Opens a file sent with this message.
  final ValueChanged<EngineNodeAttachment> onOpenAttachment;

  /// Where a sent file is on disk; with it, a sent picture shows as a thumbnail.
  final String Function(EngineNodeAttachment)? attachmentPath;

  /// Settings > Your name; empty shows the plain `You` label.
  final String userName;
  final String userAvatarPath;
  final String assistantName;
  final EngineProvider? activeProvider;
  final FolioLayoutMode layoutMode;
  final bool showTokenMetrics;

  /// Settings > Appearance display choices (each one is read here).
  final UiDisplayPrefs prefs;
  final bool editorialDialogueStyling;
  final bool isPinnedContextStart;
  final bool isPinnedReply;
  final BranchSlotInfo? branchInfo;
  final bool showBottomDivider;
  final bool reduceMotionOverride;

  /// Touch screens have no hover: the newest turns keep their actions visible.
  final bool showActionsAtRest;
  final VoidCallback onCopy;
  final VoidCallback? onCopyPlain;
  final VoidCallback? onBranchNewChat;

  /// Saves this reply as one of Bistre's skills.
  final VoidCallback? onSaveAsSkill;
  final ValueChanged<String> onCopyCode;
  final Future<void> Function(String code, String language) onSaveCode;
  final VoidCallback onReply;
  final ValueChanged<String> onQuoteThinking;
  final VoidCallback? onToggleContextPin;
  final VoidCallback? onTogglePinReply;
  final VoidCallback? onInspectTurnDetails;
  final VoidCallback? onTranslate;

  /// Web pages this reply used; shown as a globe with a count.
  final int sourceCount;
  final bool isSpeaking;
  final VoidCallback? onSpeak;
  final Future<bool> Function(String edited)? onEditResend;

  /// Left out of the chat's context: shown dimmed, never sent.
  final bool isExcluded;
  final VoidCallback? onToggleExcluded;

  /// Saves the edited text as a new version of this reply.
  final Future<bool> Function(String edited)? onEditReply;
  final VoidCallback? onRegenerate;
  final VoidCallback? onDelete;
  final ValueChanged<int>? onBranchDelta;

  @override
  State<_PassageItem> createState() => _PassageItemState();
}

class _PassageItemState extends State<_PassageItem>
    with AutomaticKeepAliveClientMixin<_PassageItem> {
  bool _hovered = false;
  bool _focused = false;

  /// Touch screens have no hover: a tap on the message shows or hides its actions.
  bool _revealed = false;
  bool _editing = false;
  bool _moreActionsOpen = false;

  /// A long message you sent shows its start until opened (`kLongMessageChars`).
  bool _longOpen = false;

  /// Settings > Confirm before regenerating: the first press arms Regenerate.
  bool _regenerateArmed = false;
  final TextEditingController _editCtrl = TextEditingController();
  final FocusNode _editFocus = FocusNode();

  @override
  void dispose() {
    _editCtrl.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  /// An open inline edit keeps its card alive, so scrolling it out of view (with the
  /// focus elsewhere) never throws the half-written text away.
  @override
  bool get wantKeepAlive => _editing;

  void _setEditing(bool editing) {
    setState(() => _editing = editing);
    updateKeepAlive();
  }

  void _startEdit() {
    _editCtrl.text = widget.node.content;
    _setEditing(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  Future<void> _submitEdit() async {
    final cb = widget.node.role == 'assistant'
        ? widget.onEditReply
        : widget.onEditResend;
    if (cb == null) return;
    final ok = await cb(_editCtrl.text);
    if (ok && mounted) {
      _setEditing(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final isAssistant = widget.node.role == 'assistant';
    // With Show your name off, your messages keep their picture, time, and actions.
    final speaker = isAssistant
        ? widget.assistantName
        : !widget.prefs.showUserName
        ? ''
        : widget.userName.isNotEmpty
        ? widget.userName
        : l10n.t(L10nKey.shellRoleUser);
    final usage = isAssistant ? widget.node.usageMeta : null;
    final actionBar = _buildActionBar(theme, l10n, isAssistant);

    final readBody = _editing
        ? _buildInlineEditor(theme, l10n, isAssistant)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isAssistant &&
                  usage != null &&
                  usage.hasThinking &&
                  widget.prefs.showThinkingCards)
                ReasoningBlock(
                  thinkingText: usage.thinkingText,
                  durationMs: usage.thinkingDurationMs,
                  onQuoteIntoComposer: widget.onQuoteThinking,
                  autoCollapse: widget.prefs.autoCollapseThinking,
                ),
              if (!isAssistant && !widget.prefs.renderUserMarkdown)
                _collapsedIfLong(
                  InkText(widget.node.content, color: theme.inkPrimary),
                  l10n,
                  isAssistant,
                )
              else
                _collapsedIfLong(
                  MarkdownFolioView(
                    onSaveCode: (code, language) =>
                        unawaited(widget.onSaveCode(code, language)),
                    markdown: widget.node.content,
                    onCopyCode: widget.onCopyCode,
                    editorialDialogueStyling: widget.editorialDialogueStyling,
                    renderMath: widget.prefs.renderMathFormulas,
                    foldCodeBlocks: widget.prefs.autoCollapseCodeBlocks,
                  ),
                  l10n,
                  isAssistant,
                ),
              // The files sent with this message, each opening its preview. A reply's
              // own pictures and media always show: they are the reply.
              if (widget.node.attachments.isNotEmpty &&
                  (isAssistant || widget.prefs.showSentFiles))
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: 8),
                  child: Wrap(
                    spacing: BistreSpacing.s8,
                    runSpacing: BistreSpacing.s4,
                    children: [
                      // A picture as a thumbnail; any other file as a type icon,
                      // the name shortened in the middle so its extension stays,
                      // and the size.
                      for (final a in widget.node.attachments)
                        if (widget.attachmentPath case final pathOf?
                            when a.mimeType.startsWith('image/') &&
                                a.mimeType != 'image/svg+xml')
                          SentPictureThumb(
                            path: pathOf(a),
                            name: a.name,
                            onOpen: () => widget.onOpenAttachment(a),
                          )
                        else
                          EngravedButton(
                            label: l10n.joinMeta(<String>[
                              middleEllipsis(a.name),
                              if (a.sizeBytes > 0) l10n.fileSize(a.sizeBytes),
                            ]),
                            semanticsLabel: a.name,
                            compact: true,
                            leading: BistreIcon(
                              attachmentIconFor(a.mimeType, a.name),
                              size: 12,
                              color: theme.inkSecondary,
                            ),
                            onPressed: () => widget.onOpenAttachment(a),
                          ),
                    ],
                  ),
                ),
              if (isAssistant &&
                  widget.showTokenMetrics &&
                  usage != null &&
                  (usage.hasTokens || usage.modelId.isNotEmpty)) ...[
                const SizedBox(height: 10),
                _buildMetricsFooter(theme, l10n, usage),
              ],
            ],
          );
    // A left-out message stays readable, dimmed, under a plain note.
    final contentBody = widget.isExcluded && !_editing
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkText(
                l10n.t(L10nKey.chatExcludedNote),
                role: InkTextRole.captionMeta,
                color: theme.inkMuted,
              ),
              const SizedBox(height: BistreSpacing.s4),
              Opacity(opacity: 0.55, child: readBody),
            ],
          )
        : readBody;

    final Widget inner;
    if (widget.layoutMode == FolioLayoutMode.bubbles) {
      if (isAssistant) {
        // DESIGN §1.1: the bubble holds only the message; who spoke and the actions
        // sit above it.
        inner = Padding(
          padding: const EdgeInsetsDirectional.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
                child: _buildSpeakerHeader(
                  theme,
                  speaker,
                  true,
                  usage,
                  actionBar,
                ),
              ),
              const SizedBox(height: 6),
              FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 14),
                borderRadius: 14,
                boxShadow: theme.cardShadow,
                child: contentBody,
              ),
            ],
          ),
        );
      } else {
        inner = Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(
              top: 6,
              bottom: 6,
              start: 48,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              // The header above is as wide as the bubble, so the name lines up with it.
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.symmetric(
                        horizontal: 4,
                      ),
                      child: _buildSpeakerHeader(
                        theme,
                        speaker,
                        false,
                        null,
                        actionBar,
                      ),
                    ),
                    const SizedBox(height: 4),
                    FolioSurface(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        15,
                        10,
                        15,
                        10,
                      ),
                      customBorderRadius: const BorderRadiusDirectional.only(
                        topStart: Radius.circular(16),
                        topEnd: Radius.circular(4),
                        bottomStart: Radius.circular(16),
                        bottomEnd: Radius.circular(16),
                      ),
                      child: contentBody,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    } else if (!isAssistant) {
      inner = Padding(
        padding: const EdgeInsetsDirectional.only(
          top: BistreSpacing.s8,
          bottom: BistreSpacing.s12,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.bgSurface.withValues(
              alpha: theme.isDark ? 0.58 : 0.65,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSpeakerHeader(theme, speaker, false, null, actionBar),
                const SizedBox(height: 6),
                contentBody,
              ],
            ),
          ),
        ),
      );
    } else {
      inner = Padding(
        padding: const EdgeInsetsDirectional.only(
          top: BistreSpacing.s8,
          bottom: BistreSpacing.s16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSpeakerHeader(theme, speaker, true, usage, actionBar),
            const SizedBox(height: 10),
            contentBody,
            if (widget.showBottomDivider) ...[
              const SizedBox(height: BistreSpacing.s24),
              const FolioDivider(),
            ],
          ],
        ),
      );
    }

    return FocusableActionDetector(
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      child: ContextMenuRegion(
        entries: _editing
            ? const <ContextMenuEntry>[]
            : _buildPassageMenuEntries(l10n, isAssistant),
        child: isTouchPlatform
            ? GestureDetector(
                onTap: () => setState(() => _revealed = !_revealed),
                child: inner,
              )
            : inner,
      ),
    );
  }

  Widget _buildInlineEditor(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    bool isAssistant,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        QuillInput(
          controller: _editCtrl,
          focusNode: _editFocus,
          placeholder: l10n.t(L10nKey.shellComposerPlaceholder),
          maxLines: 6,
          submitOnEnter: false,
          onSubmitted: () => unawaited(_submitEdit()),
        ),
        const SizedBox(height: 8),
        // Wraps so a long save label at phone width or 200% text moves to its own line.
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            EngravedButton(
              label: l10n.t(L10nKey.threadCancel),
              compact: true,
              onPressed: () => _setEditing(false),
            ),
            EngravedButton(
              label: l10n.t(
                isAssistant
                    ? L10nKey.chatActionSaveVersion
                    : L10nKey.chatActionSaveResend,
              ),
              primary: true,
              compact: true,
              onPressed: () => unawaited(_submitEdit()),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMetricsFooter(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    NodeUsageMeta usage,
  ) {
    if (!usage.hasTokens && usage.costMicros <= 0) {
      return const SizedBox.shrink();
    }
    // ↑ sent, ↓ received, then the cost: shapes read in every language; the words go to
    // screen readers, and hovering (or tapping) opens the full breakdown.
    final args = <String, Object?>{
      'input': usage.inputTokens,
      'output': usage.outputTokens,
      'cost': usage.costMicros > 0
          ? FolioController.formatMicrosUsd(usage.costMicros, showSubCent: true)
          : '',
    };
    final hasCost = usage.costMicros > 0;
    final summary = l10n.t(
      hasCost ? L10nKey.chatTokensMetaCost : L10nKey.chatTokensMeta,
      args,
    );
    final spoken = l10n.t(
      hasCost ? L10nKey.chatTokensSpokenCost : L10nKey.chatTokensSpoken,
      args,
    );

    return Row(
      children: [
        if (usage.modelId.isNotEmpty) ...[
          LabIcon(
            iconSlug: usage.iconSlug.isNotEmpty
                ? usage.iconSlug
                : widget.activeProvider?.iconSlug,
            customIconPath: widget.activeProvider?.customIconPath,
            dialect: widget.activeProvider?.dialect,
            providerName: usage.providerName.isNotEmpty
                ? usage.providerName
                : widget.activeProvider?.name,
            modelId: usage.modelId,
            size: 13,
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: UsageDetailsPill(
              usage: usage,
              summaryText: summary,
              spokenLabel: spoken,
              reduceMotionOverride: widget.reduceMotionOverride,
            ),
          ),
        ),
        // A reply that used web pages says so in the chat; the count opens them.
        if (widget.sourceCount > 0 && widget.onInspectTurnDetails != null)
          EngravedButton(
            label: widget.sourceCount.toString(),
            semanticsLabel: l10n.t(L10nKey.chatTurnSources, <String, Object?>{
              'count': widget.sourceCount,
            }),
            compact: true,
            leading: BistreIcon(
              BistreUiIcon.globe,
              size: 12,
              color: theme.inkSecondary,
            ),
            onPressed: widget.onInspectTurnDetails,
          ),
        if (!usage.costKnown && usage.hasTokens)
          CostUnavailableButton(usage: usage),
      ],
    );
  }

  /// The reply's model (and provider) under Settings > Appearance, or null when hidden.
  String? _modelLabel(NodeUsageMeta? usage) {
    final prefs = widget.prefs;
    if (usage == null || usage.modelId.isEmpty || !prefs.showModelName) {
      return null;
    }
    final l10n = BistreLocalizations.of(context);
    // Each name is its own direction run; the sentence follows the app's direction.
    if (!prefs.showProviderAfterModel || usage.providerName.isEmpty) {
      return l10n.isolate(usage.modelId);
    }
    return l10n.t(L10nKey.shellModelOnProvider, <String, Object?>{
      'model': l10n.isolate(usage.modelId),
      'provider': l10n.isolate(usage.providerName),
    });
  }

  static String _formatClockTime(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  Widget _buildSpeakerHeader(
    BistreThemeData theme,
    String speaker,
    bool isAssistant,
    NodeUsageMeta? usage,
    Widget actionBar,
  ) {
    final l10n = BistreLocalizations.of(context);
    final timeLabel =
        widget.prefs.showUserTimestamp && widget.node.createdAtMs > 0
        ? _formatClockTime(widget.node.createdAtMs)
        : null;
    return Row(
      children: [
        if (isAssistant && !widget.prefs.showModelIcon)
          const SizedBox.shrink()
        else if (isAssistant)
          LabIcon(
            iconSlug: (usage != null && usage.iconSlug.isNotEmpty)
                ? usage.iconSlug
                : widget.activeProvider?.iconSlug,
            customIconPath: widget.activeProvider?.customIconPath,
            dialect: widget.activeProvider?.dialect,
            providerName: (usage != null && usage.providerName.isNotEmpty)
                ? usage.providerName
                : widget.activeProvider?.name,
            modelId: usage?.modelId,
            size: 15,
          )
        else if (widget.prefs.showUserAvatar &&
            widget.userAvatarPath.isNotEmpty)
          UserAvatarThumb(
            path: widget.userAvatarPath,
            size: 18,
            fallbackIcon: BistreUiIcon.edit,
            fallbackColor: theme.accentBrass,
          )
        else
          BistreIcon(BistreUiIcon.edit, size: 14, color: theme.accentBrass),
        const SizedBox(width: BistreSpacing.s8),
        // One line: the name, then the model label, which shortens first. The free room
        // stays before the actions, so they sit at the end of the row; when even a short
        // name cannot sit beside them (a phone at 200% text) they drop below it.
        Expanded(
          child: LabelControlLayout(
            gap: BistreSpacing.s8,
            stackGap: BistreSpacing.s4,
            minLabelWidth: 72,
            control: actionBar,
            label: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  if (speaker.isNotEmpty)
                    TextSpan(
                      text: l10n.isolate(speaker),
                      style: BistreTypography.labelStrong(
                        isAssistant ? theme.inkPrimary : theme.inkSecondary,
                        config: theme.typography,
                      ),
                    ),
                  if (_modelLabel(usage) case final label?) ...[
                    const WidgetSpan(child: SizedBox(width: BistreSpacing.s8)),
                    TextSpan(
                      text: label,
                      style: BistreTypography.captionMeta(
                        theme.inkMuted,
                        config: theme.typography,
                      ),
                    ),
                  ],
                  if (timeLabel != null) ...[
                    if (speaker.isNotEmpty)
                      const WidgetSpan(
                        child: SizedBox(width: BistreSpacing.s8),
                      ),
                    TextSpan(
                      text: timeLabel,
                      style: BistreTypography.captionMeta(
                        theme.inkMuted,
                        config: theme.typography,
                      ),
                    ),
                  ],
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  /// A message you sent longer than [kLongMessageChars] shows its first
  /// [kCollapsedMessageHeight] logical pixels (scaled with the text) until Show more; a
  /// reply does too under Settings > Collapse long replies.
  Widget _collapsedIfLong(
    Widget message,
    BistreLocalizationController l10n,
    bool isAssistant,
  ) {
    if ((isAssistant && !widget.prefs.collapseLongMessages) ||
        _editing ||
        widget.node.content.length <= kLongMessageChars) {
      return message;
    }
    final height = MediaQuery.textScalerOf(context)
        .scale(kCollapsedMessageHeight);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_longOpen)
          message
        else
          ClipRect(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: height),
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: message,
              ),
            ),
          ),
        const SizedBox(height: BistreSpacing.s4),
        EngravedButton(
          label: l10n.t(
            _longOpen ? L10nKey.chatActionShowLess : L10nKey.chatActionShowMore,
          ),
          compact: true,
          onPressed: () => setState(() => _longOpen = !_longOpen),
        ),
      ],
    );
  }

  Widget _buildActionBar(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    bool isAssistant,
  ) {
    final branch = widget.branchInfo;
    // Controls appear when needed (DESIGN §1.1): hidden at rest on pointer
    // devices, revealed on hover or keyboard focus (focusing a hidden button reveals the bar).
    final alwaysShow =
        branch != null ||
        _hovered ||
        _focused ||
        _editing ||
        _revealed ||
        widget.showActionsAtRest;

    // A hidden action never takes a tap (Regenerate is a paid call).
    return IgnorePointer(
      ignoring: !alwaysShow,
      child: AnimatedOpacity(
        opacity: alwaysShow ? 1.0 : 0.0,
        duration: BistreMotion.overlayDuration(
          context,
          reduceMotionOverride: widget.reduceMotionOverride,
        ),
        // The actions wrap onto a second line when they are wider than the row (a phone at
        // 200% text with every action open).
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (branch != null && widget.onBranchDelta != null) ...[
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.bgSurface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: theme.borderHairline),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 3,
                    vertical: 1,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      BistreIconButton(
                        icon: BistreUiIcon.chevronStart,
                        size: 12,
                        dimension: 22,
                        semanticsLabel: l10n.t(L10nKey.chatBranchPrev),
                        onPressed: branch.index > 0
                            ? () => widget.onBranchDelta!(-1)
                            : null,
                      ),
                      Padding(
                        padding: const EdgeInsetsDirectional.symmetric(
                          horizontal: 3,
                        ),
                        child: InkText(
                          l10n.t(L10nKey.chatBranchIndicator, <String, Object?>{
                            'current': branch.index + 1,
                            'total': branch.total,
                          }),
                          role: InkTextRole.captionMeta,
                          color: theme.accentBrass,
                        ),
                      ),
                      BistreIconButton(
                        icon: BistreUiIcon.chevronEnd,
                        size: 12,
                        dimension: 22,
                        semanticsLabel: l10n.t(L10nKey.chatBranchNext),
                        onPressed: branch.index + 1 < branch.total
                            ? () => widget.onBranchDelta!(1)
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (!isAssistant && widget.onEditResend != null && !_editing)
              BistreIconButton(
                icon: BistreUiIcon.edit,
                size: 14,
                dimension: 28,
                semanticsLabel: l10n.t(L10nKey.chatActionEdit),
                onPressed: _startEdit,
              ),
            BistreIconButton(
              icon: BistreUiIcon.copy,
              size: 14,
              dimension: 28,
              semanticsLabel: l10n.t(L10nKey.chatActionCopy),
              onPressed: widget.onCopy,
            ),
            if (widget.onSpeak != null)
              BistreIconButton(
                icon: widget.isSpeaking
                    ? BistreUiIcon.stop
                    : BistreUiIcon.volume,
                size: 14,
                dimension: 28,
                active: widget.isSpeaking,
                color: widget.isSpeaking ? theme.accentWax : null,
                semanticsLabel: widget.isSpeaking
                    ? l10n.t(L10nKey.chatActionStop)
                    : l10n.t(L10nKey.chatActionListen),
                onPressed: widget.onSpeak,
              ),
            if (widget.onRegenerate case final regenerate?)
              BistreIconButton(
                icon: _regenerateArmed
                    ? BistreUiIcon.check
                    : BistreUiIcon.refresh,
                size: 14,
                dimension: 28,
                active: _regenerateArmed,
                color: _regenerateArmed ? theme.accentWax : null,
                semanticsLabel: l10n.t(
                  _regenerateArmed
                      ? L10nKey.chatActionRegenerateConfirm
                      : L10nKey.chatActionRegenerate,
                ),
                onPressed: () {
                  if (widget.prefs.confirmBeforeRegenerating &&
                      !_regenerateArmed) {
                    setState(() => _regenerateArmed = true);
                    return;
                  }
                  setState(() => _regenerateArmed = false);
                  regenerate();
                },
              ),
            if (_moreActionsOpen) ...[
              if (isAssistant)
                BistreIconButton(
                  icon: BistreUiIcon.reply,
                  size: 14,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.chatActionReply),
                  onPressed: widget.onReply,
                ),
              if (widget.onTogglePinReply != null && !_editing)
                BistreIconButton(
                  icon: widget.isPinnedReply
                      ? BistreUiIcon.pinFilled
                      : BistreUiIcon.pin,
                  size: 13,
                  dimension: 28,
                  color: widget.isPinnedReply
                      ? theme.accentBrass
                      : theme.inkMuted,
                  semanticsLabel: widget.isPinnedReply
                      ? l10n.t(L10nKey.chatUnpinReply)
                      : l10n.t(L10nKey.chatPinReply),
                  onPressed: widget.onTogglePinReply,
                ),
              if (widget.onToggleContextPin != null && !_editing)
                BistreIconButton(
                  icon: BistreUiIcon.branchTree,
                  size: 13,
                  dimension: 28,
                  color: widget.isPinnedContextStart
                      ? theme.accentBrass
                      : theme.inkMuted,
                  semanticsLabel: l10n.t(L10nKey.chatPinContextStart),
                  onPressed: widget.onToggleContextPin,
                ),
              if (isAssistant && widget.onEditReply != null && !_editing)
                BistreIconButton(
                  icon: BistreUiIcon.edit,
                  size: 13,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.chatActionEditReply),
                  onPressed: _startEdit,
                ),
              if (widget.onToggleExcluded != null && !_editing)
                BistreIconButton(
                  icon: widget.isExcluded
                      ? BistreUiIcon.eye
                      : BistreUiIcon.eyeOff,
                  size: 13,
                  dimension: 28,
                  active: widget.isExcluded,
                  semanticsLabel: l10n.t(
                    widget.isExcluded
                        ? L10nKey.chatActionIncludeContext
                        : L10nKey.chatActionExcludeContext,
                  ),
                  onPressed: widget.onToggleExcluded,
                ),
              if (widget.onTranslate != null && !_editing)
                BistreIconButton(
                  icon: BistreUiIcon.globe,
                  size: 13,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.chatActionTranslate),
                  onPressed: widget.onTranslate,
                ),
              if (widget.onInspectTurnDetails != null)
                BistreIconButton(
                  icon: BistreUiIcon.info,
                  size: 13,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.chatTurnDetails),
                  onPressed: widget.onInspectTurnDetails,
                ),
              if (widget.onCopyPlain != null)
                BistreIconButton(
                  icon: BistreUiIcon.document,
                  size: 13,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.chatActionCopyPlain),
                  onPressed: widget.onCopyPlain,
                ),
              if (isAssistant && widget.onSaveAsSkill != null && !_editing)
                BistreIconButton(
                  icon: BistreUiIcon.bookOpen,
                  size: 13,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.chatActionSaveSkill),
                  onPressed: widget.onSaveAsSkill,
                ),
              if (widget.onBranchNewChat != null && !_editing)
                BistreIconButton(
                  icon: BistreUiIcon.newChat,
                  size: 13,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.chatActionBranchNewChat),
                  onPressed: widget.onBranchNewChat,
                ),
              if (widget.onDelete != null && !_editing)
                BistreIconButton(
                  icon: BistreUiIcon.trash,
                  size: 14,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.chatActionDelete),
                  onPressed: widget.onDelete,
                ),
            ],
            BistreIconButton(
              icon: _moreActionsOpen
                  ? BistreUiIcon.chevronEnd
                  : BistreUiIcon.sliders,
              size: 13,
              dimension: 28,
              active: _moreActionsOpen,
              semanticsLabel: l10n.t(L10nKey.chatActionMore),
              onPressed: () =>
                  setState(() => _moreActionsOpen = !_moreActionsOpen),
            ),
          ],
        ),
      ),
    );
  }
}
