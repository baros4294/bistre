part of 'folio_composer.dart';

/// Bottom composer controls, measured rather than guessed (any locale, any text size). The
/// first form that fits in one row wins:
/// 0. full labels;
/// 1. the context ring without its numbers (they stay in its hover card);
/// 2. icon-only Tools and Live;
/// 3. the short thinking label too;
/// then two rows, or two rows on phones while a reply streams (Stop / Queue / Steer).
/// Each form's width is measured whenever it is on screen and remembered for the current
/// text size, locale, and reply state, so widening the window brings the fuller form back.
class _ComposerToolbar extends StatefulWidget {
  const _ComposerToolbar({
    required this.twoRows,
    required this.measureKey,
    required this.leading,
    required this.trailing,
    required this.gauge,
  });

  final bool twoRows;

  /// Anything that changes the controls' widths (text size, locale, streaming, which
  /// chips the model shows).
  final Object measureKey;
  final List<Widget> Function(bool compact, bool shortThinking) leading;
  final List<Widget> Function(bool compact) trailing;
  final Widget Function(bool compact) gauge;

  @override
  State<_ComposerToolbar> createState() => _ComposerToolbarState();
}

class _ComposerToolbarState extends State<_ComposerToolbar> {
  /// Forms measured so far: full labels, the ring without numbers, icon-only Tools and Live.
  static const int _measuredForms = 3;

  /// Bound on remembered states (text size x locale x replying), cleared when exceeded.
  static const int _maxKeys = 8;

  /// One-row width each form needs, per [_ComposerToolbar.measureKey].
  final Map<Object, List<double?>> _needs = <Object, List<double?>>{};

  /// The toolbar's width at the last layout.
  double _width = double.infinity;

  List<double?> get _need {
    if (_needs.length >= _maxKeys && !_needs.containsKey(widget.measureKey)) {
      _needs.clear();
    }
    return _needs.putIfAbsent(
      widget.measureKey,
      () => List<double?>.filled(_measuredForms, null),
    );
  }

  int get _form {
    final need = _need;
    for (var form = 0; form < need.length; form++) {
      final w = need[form];
      if (w == null || _width >= w) return form;
    }
    return need.length;
  }

  /// After each layout: remember the width this form needs and the toolbar width; rebuild
  /// only when that changes the form. No `LayoutBuilder`, so streaming never lays the shell
  /// out again.
  void _onMeasured(double need, double width) {
    final form = _form;
    _width = width;
    if (form < _measuredForms) _need[form] = need;
    if (_form == form) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final form = _form;
    final compact = form >= 2;
    return ComposerToolbarLayout(
      forceTwoRows: widget.twoRows,
      onMeasured: _onMeasured,
      leading: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: BistreSpacing.s4,
        children: widget.leading(compact, form >= 3),
      ),
      gauge: widget.gauge(form >= 1),
      // Wraps (end-aligned) when even its own row is too narrow: Steer, Queue, and Stop
      // on a phone.
      trailing: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: BistreSpacing.s4,
        children: widget.trailing(compact),
      ),
    );
  }
}

/// Backoff notice with countdown, plain reason, and an inline trailing `Retry now`.
/// The 1 s ticker runs only while a retry is pending (never idle polling).
class _BackoffNotice extends StatefulWidget {
  const _BackoffNotice({
    required this.retryAt,
    required this.onRetryNow,
    this.attempt,
    this.reasonDetail,
  });

  final DateTime retryAt;

  /// Which automatic try failed.
  final int? attempt;
  final VoidCallback onRetryNow;
  final String? reasonDetail;

  @override
  State<_BackoffNotice> createState() => _BackoffNoticeState();
}

class _BackoffNoticeState extends State<_BackoffNotice> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _startTicker();
  }

  /// A new wait (a later try) restarts the countdown; the ticker of a wait that ran
  /// out has stopped, which froze the next one.
  @override
  void didUpdateWidget(_BackoffNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.retryAt != widget.retryAt) _startTicker();
  }

  /// Seconds left, counted down by the ticker from the wait's length when it started.
  int _seconds = 0;

  void _startTicker() {
    _ticker?.cancel();
    final ms = widget.retryAt.difference(DateTime.now()).inMilliseconds;
    _seconds = ms <= 0 ? 0 : (ms + 999) ~/ 1000;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds = _seconds > 0 ? _seconds - 1 : 0);
      if (_seconds == 0) _ticker?.cancel();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final seconds = _seconds;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.bgElevated,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: theme.statusWarn.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          BistreSpacing.s12,
          6,
          6,
          6,
        ),
        child: Row(
          children: [
            BistreIcon(BistreUiIcon.refresh, size: 13, color: theme.statusWarn),
            const SizedBox(width: BistreSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkText(
                    widget.attempt == null
                        ? l10n.t(L10nKey.chatBackoffNotice, <String, Object?>{
                            'seconds': seconds,
                          })
                        : l10n.t(
                            L10nKey.chatBackoffNoticeAttempt,
                            <String, Object?>{
                              'seconds': seconds,
                              'attempt': widget.attempt,
                            },
                          ),
                    role: InkTextRole.captionMeta,
                    color: theme.inkSecondary,
                  ),
                  if (widget.reasonDetail != null &&
                      widget.reasonDetail!.trim().isNotEmpty)
                    InkText(
                      l10n.tRawKey(widget.reasonDetail!),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            EngravedButton(
              label: l10n.t(L10nKey.chatActionRetryNow),
              compact: true,
              onPressed: widget.onRetryNow,
            ),
          ],
        ),
      ),
    );
  }
}

/// Slash commands and pasting, run by the composer.
extension _ComposerCommands on _FolioComposerState {
  /// Runs the slash command [token] (or inserts the skill it names).
  void _runSlashCommand(String token, FolioController ctrl) {
    _textController.clear();
    switch (token) {
      case '/plan':
        unawaited(ctrl.setActiveThreadMode('plan'));
      case '/build':
        unawaited(ctrl.setActiveThreadMode('code'));
      case '/write':
        unawaited(ctrl.setActiveThreadMode('write'));
      case '/compact':
        unawaited(ctrl.compactActiveThread());
      case '/tree':
        ctrl.openSessionTree();
      case '/clear':
        unawaited(ctrl.createNewFolio());
      case '/rewind':
        unawaited(ctrl.rewindLastTurn());
      // These take the rest of the line: the command waits in the field for it.
      case '/goal' || '/btw' || '/guide' || '/draft':
        final typed = '$token ';
        _textController.value = TextEditingValue(
          text: typed,
          selection: TextSelection.collapsed(offset: typed.length),
        );
      case '/continue':
        final l10n = BistreLocalizations.of(context);
        unawaited(ctrl.submitPassage(l10n.t(L10nKey.chatFixContinueMessage)));
      case '/summarize':
        unawaited(ctrl.summarizeIntoNewChat());
      default:
        final skillName = token.substring(1);
        final skill = ctrl.discoveredSkills
            .where((s) => s.name == skillName)
            .firstOrNull;
        if (skill != null) {
          unawaited(() async {
            final body = await ctrl.loadSkillBody(skill.path);
            if (!mounted || body.trim().isEmpty) return;
            final inserted = '$body\n';
            _textController.value = TextEditingValue(
              text: inserted,
              selection: TextSelection.collapsed(offset: inserted.length),
            );
          }());
        }
    }
    widget.focusNode.requestFocus();
  }

  /// The commands that take the rest of the line: `/compact <what to keep>`, `/goal [goal]`
  /// (alone it clears the goal), `/btw <question>`, `/guide <direction>` (regenerates the
  /// last reply that way), and `/draft [note]` (writes your next message into the field).
  /// Returns whether [text] was one.
  Future<bool> _runArgumentCommand(String text) async {
    final ctrl = widget.controller;
    final match = RegExp(
      r'^\s*/(compact|goal|btw|guide|draft)(?:\s+(\S[\s\S]*?))?\s*$',
    ).firstMatch(text);
    if (match == null) return false;
    final name = match.group(1)!;
    final rest = match.group(2)?.trim() ?? '';
    if (name != 'goal' && name != 'draft' && rest.isEmpty) return false;
    _clearSentText(text);
    switch (name) {
      case 'compact':
        await ctrl.compactActiveThread(instructions: rest);
      case 'goal':
        await ctrl.setThreadGoal(rest);
      case 'guide':
        await ctrl.guideLastReply(rest);
      case 'draft':
        final drafted = await ctrl.draftNextMessage(rest);
        // The draft lands only in an untouched field: typing meanwhile wins.
        if (drafted != null &&
            mounted &&
            _textController.text.isEmpty &&
            !_textController.value.composing.isValid) {
          _textController.value = TextEditingValue(
            text: drafted,
            selection: TextSelection.collapsed(offset: drafted.length),
          );
        }
      case _:
        await ctrl.askSideQuestion(rest);
    }
    return true;
  }

  /// Types the clipboard's text at the cursor, unless it became attachments.
  Future<void> _paste(BistreLocalizationController l10n) async {
    final text = await widget.controller.takeComposerPaste(
      textFileName: l10n.t(L10nKey.composerPastedTextName),
      imageFileName: l10n.t(L10nKey.composerPastedImageName),
    );
    if (!mounted || text == null || text.isEmpty) return;
    final value = _textController.value;
    final at = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final next = value.replaced(at, text);
    _textController.value = next;
    _handleTextChanged(next.text);
  }
}

/// The slash and mention suggestions the composer offers for the text typed so far.
extension _ComposerTriggerItems on _FolioComposerState {
  List<ComposerTriggerItem> _buildTriggerItems(
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final q = _triggerQuery.toLowerCase();
    if (_triggerPrefix == '/') {
      final items = <ComposerTriggerItem>[
        ComposerTriggerItem(
          token: '/plan',
          label: '/plan',
          description: l10n.t(L10nKey.composerSlashPlanDesc),
          icon: BistreUiIcon.document,
        ),
        ComposerTriggerItem(
          token: '/build',
          label: '/build',
          description: l10n.t(L10nKey.composerSlashBuildDesc),
          icon: BistreUiIcon.code,
        ),
        ComposerTriggerItem(
          token: '/write',
          label: '/write',
          description: l10n.t(L10nKey.composerSlashWriteDesc),
          icon: BistreUiIcon.edit,
        ),
        ComposerTriggerItem(
          token: '/compact',
          label: '/compact',
          description: l10n.t(L10nKey.composerSlashCompactDesc),
          icon: BistreUiIcon.think,
        ),
        ComposerTriggerItem(
          token: '/tree',
          label: '/tree',
          description: l10n.t(L10nKey.composerSlashTreeDesc),
          icon: BistreUiIcon.branchTree,
        ),
        ComposerTriggerItem(
          token: '/clear',
          label: '/clear',
          description: l10n.t(L10nKey.composerSlashClearDesc),
          icon: BistreUiIcon.newChat,
        ),
        if (!ctrl.isStreaming &&
            ctrl.visibleBranchNodes.any((n) => n.role == 'user'))
          ComposerTriggerItem(
            token: '/rewind',
            label: '/rewind',
            description: l10n.t(L10nKey.composerSlashRewindDesc),
            icon: BistreUiIcon.rewind,
          ),
        ComposerTriggerItem(
          token: '/goal',
          label: '/goal',
          description: l10n.t(L10nKey.composerSlashGoalDesc),
          icon: BistreUiIcon.check,
        ),
        ComposerTriggerItem(
          token: '/draft',
          label: '/draft',
          description: l10n.t(L10nKey.composerSlashDraftDesc),
          icon: BistreUiIcon.edit,
        ),
        if (ctrl.visibleBranchNodes.isNotEmpty) ...[
          ComposerTriggerItem(
            token: '/btw',
            label: '/btw',
            description: l10n.t(L10nKey.composerSlashBtwDesc),
            icon: BistreUiIcon.chat,
          ),
          if (!ctrl.isStreaming) ...[
            if (ctrl.visibleBranchNodes.last.role == 'assistant') ...[
              ComposerTriggerItem(
                token: '/continue',
                label: '/continue',
                description: l10n.t(L10nKey.composerSlashContinueDesc),
                icon: BistreUiIcon.reply,
              ),
              ComposerTriggerItem(
                token: '/guide',
                label: '/guide',
                description: l10n.t(L10nKey.composerSlashGuideDesc),
                icon: BistreUiIcon.refresh,
              ),
            ],
            ComposerTriggerItem(
              token: '/summarize',
              label: '/summarize',
              description: l10n.t(L10nKey.composerSlashSummarizeDesc),
              icon: BistreUiIcon.newChat,
            ),
          ],
        ],
        for (final skill in ctrl.discoveredSkills)
          ComposerTriggerItem(
            token: '/${skill.name}',
            label: '/${skill.name}',
            description: skill.description,
            icon: BistreUiIcon.think,
            badge: l10n.t(L10nKey.settingsTabMemory),
          ),
      ];
      if (q.isEmpty) return items;
      return items
          .where(
            (i) =>
                i.label.toLowerCase().contains(q) ||
                i.description.toLowerCase().contains(q),
          )
          .toList();
    }
    final items = <ComposerTriggerItem>[
      ComposerTriggerItem(
        token: '@mount',
        label: '@mount',
        description: l10n.t(L10nKey.composerMentionMountDesc),
        icon: BistreUiIcon.folder,
      ),
      ComposerTriggerItem(
        token: '@file ',
        label: '@file',
        description: l10n.t(L10nKey.composerMentionFileDesc),
        icon: BistreUiIcon.document,
      ),
      ComposerTriggerItem(
        token: '@diff ',
        label: '@diff',
        description: l10n.t(L10nKey.composerMentionDiffDesc),
        icon: BistreUiIcon.code,
      ),
      ComposerTriggerItem(
        token: '@memory ',
        label: '@memory',
        description: l10n.t(L10nKey.composerMentionMemoryDesc),
        icon: BistreUiIcon.memory,
      ),
      ComposerTriggerItem(
        token: '@thread ',
        label: '@thread',
        description: l10n.t(L10nKey.composerMentionThreadDesc),
        icon: BistreUiIcon.chat,
      ),
      ComposerTriggerItem(
        token: '@mcp ',
        label: '@mcp',
        description: l10n.t(L10nKey.composerMentionMcpDesc),
        icon: BistreUiIcon.server,
      ),
    ];
    final root = ctrl.workspaceRootPath.trim();
    for (final (name, isDir) in ctrl.workspaceEntries) {
      items.add(
        ComposerTriggerItem(
          token: '@file $name ',
          label: name,
          description: root,
          icon: isDir ? BistreUiIcon.folder : BistreUiIcon.document,
        ),
      );
    }
    if (q.isEmpty) return items;
    return items
        .where(
          (i) =>
              i.label.toLowerCase().contains(q) ||
              i.description.toLowerCase().contains(q),
        )
        .toList();
  }
}

/// The composer chips the active model's catalog entry calls for. Each shows for what the
/// model does: a model that thinks and draws shows both; an unknown model keeps Thinking.
List<Widget> _modelControls(
  FolioController ctrl,
  EngineModelCatalogInfo? info, {
  required bool compact,
}) => <Widget>[
  if (info == null || (info.writesText && info.reasoning != false))
    ThinkingControl(
      compact: compact,
      value: ctrl.settings.reasoningEffort,
      reduceMotionOverride: ctrl.reduceMotionOverride,
      allowedLevels: info?.effortLevels ?? const <String>[],
      onChanged: (v) => unawaited(ctrl.setReasoningEffort(v)),
    ),
  if (info != null && info.hasMediaChoices) ...[
    const SizedBox(width: 4),
    MediaOptionsControl(
      compact: compact,
      info: info,
      value: ctrl.mediaOptions,
      reduceMotionOverride: ctrl.reduceMotionOverride,
      onChanged: (v) => unawaited(ctrl.setMediaOptions(v)),
    ),
  ],
];
