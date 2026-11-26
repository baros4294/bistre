import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../shell/folio_controller.dart';
import 'composer_tools_control.dart';
import 'composer_trigger_menu.dart';
import 'context_gauge_ring.dart';
import 'thinking_control.dart';

/// Unified floating composer sheet respecting user reading width:
/// - Quoted-reply bar
/// - IME-safe `QuillInput`
/// - Inline diagnostic alert banner
/// - Quick Assistant switcher (zero hardcoded mode badges) & crisp Send/Stop CTA
class FolioComposer extends StatefulWidget {
  const FolioComposer({
    super.key,
    required this.controller,
    required this.focusNode,
  });

  final FolioController controller;
  final FocusNode focusNode;

  @override
  State<FolioComposer> createState() => _FolioComposerState();
}

class _FolioComposerState extends State<FolioComposer> {
  final TextEditingController _textController = TextEditingController();

  /// The text last handed to the draft save, so selection-only changes save nothing.
  String _lastDraftText = '';

  /// Text that was sent while the IME was still composing; removed once it commits (U17).
  String? _sentWhileComposing;
  int _syncedDraftEpoch = -1;
  bool _focused = false;
  String _triggerPrefix = '';
  String _triggerQuery = '';
  int _triggerSelectedIndex = 0;

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

  /// Every change to the text, typed or programmatic (a clear after sending, a slash command,
  /// an inserted skill), updates the saved draft (U35). A restored draft is not saved back.
  void _onComposerTextChanged() {
    // U17: edits skipped during an IME composition run as soon as it ends.
    if (!_textController.value.composing.isValid) {
      final sent = _sentWhileComposing;
      if (sent != null) {
        _sentWhileComposing = null;
        _clearSentText(sent);
        return;
      }
      _syncDraftIfEpochChanged();
    }
    final text = _textController.text;
    if (text == _lastDraftText) return;
    _lastDraftText = text;
    widget.controller.scheduleDraftSave(text);
  }

  void _handleTextChanged(String text) {
    final trimmedStart = text.trimLeft();
    String nextTrigger = '';
    String nextQuery = '';
    if (trimmedStart.startsWith('/') && !trimmedStart.contains(' ')) {
      nextTrigger = '/';
      nextQuery = trimmedStart.substring(1);
    } else {
      final match = RegExp(r'(?:^|\s)@([a-zA-Z0-9._/-]*)$').firstMatch(text);
      if (match != null) {
        nextTrigger = '@';
        nextQuery = match.group(1) ?? '';
      }
    }
    if (nextTrigger == '@' && _triggerPrefix != '@') {
      // U19: the workspace is read once, asynchronously, when the menu opens.
      unawaited(widget.controller.loadWorkspaceEntries());
    }
    if (nextTrigger != _triggerPrefix || nextQuery != _triggerQuery) {
      setState(() {
        _triggerPrefix = nextTrigger;
        _triggerQuery = nextQuery;
        _triggerSelectedIndex = 0;
      });
    }
  }

  void _applyTriggerOption(String token) {
    final ctrl = widget.controller;
    setState(() {
      _triggerPrefix = '';
      _triggerQuery = '';
      _triggerSelectedIndex = 0;
    });
    if (token == '@mount') {
      final current = _textController.text;
      final replaced = current.replaceFirst(RegExp(r'@[a-zA-Z0-9._/-]*$'), '');
      _textController.value = TextEditingValue(
        text: replaced,
        selection: TextSelection.collapsed(offset: replaced.length),
      );
      unawaited(() async {
        final picked = await BistreDesktopHost.pickLocalFolder(title: token);
        if (picked != null && picked.isNotEmpty) {
          await ctrl.setWorkspaceRootPath(picked);
        }
      }());
      return;
    }
    if (token.startsWith('/')) {
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
      return;
    }
    final current = _textController.text;
    final replaced = current.replaceFirst(RegExp(r'@[a-zA-Z0-9._/-]*$'), token);
    _textController.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: replaced.length),
    );
    widget.focusNode.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncDraftIfEpochChanged);
    widget.focusNode.addListener(_onFocusChanged);
    _syncDraftIfEpochChanged();
    _textController.addListener(_onComposerTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncDraftIfEpochChanged);
    widget.focusNode.removeListener(_onFocusChanged);
    _textController.removeListener(_onComposerTextChanged);
    unawaited(widget.controller.flushPendingDraft());
    _textController.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focused != widget.focusNode.hasFocus) {
      setState(() => _focused = widget.focusNode.hasFocus);
    }
  }

  void _syncDraftIfEpochChanged() {
    final epoch = widget.controller.draftEpoch;
    if (epoch == _syncedDraftEpoch) return;
    if (_textController.value.composing.isValid) return;

    _syncedDraftEpoch = epoch;
    final restored = widget.controller.restoredDraft;
    _lastDraftText = restored;
    if (_textController.text != restored) {
      _textController.value = TextEditingValue(
        text: restored,
        selection: TextSelection.collapsed(offset: restored.length),
      );
    }
  }

  /// Removes exactly the text that was sent. Anything typed while the message was being sent
  /// stays, and the field is never edited during IME composition.
  void _clearSentText(String sent) {
    final value = _textController.value;
    if (value.composing.isValid) {
      _sentWhileComposing = sent;
      return;
    }
    final current = value.text;
    if (current == sent) {
      _textController.clear();
    } else if (current.startsWith(sent)) {
      final rest = current.substring(sent.length).trimLeft();
      _textController.value = TextEditingValue(
        text: rest,
        selection: TextSelection.collapsed(offset: rest.length),
      );
    }
  }

  Future<void> _submit() async {
    // The text field takes Enter before the menu's key handler sees it: while the `/` or `@`
    // menu is open, Enter picks the highlighted entry and never sends the typed command.
    if (_triggerPrefix.isNotEmpty) {
      // U18: never pick while the IME is composing (the Send button can still be tapped).
      if (_textController.value.composing.isValid) return;
      final items = _buildTriggerItems(
        BistreLocalizations.of(context),
        widget.controller,
      );
      if (items.isNotEmpty) {
        _applyTriggerOption(
          items[_triggerSelectedIndex.clamp(0, items.length - 1)].token,
        );
        return;
      }
    }
    final text = _textController.text;
    final ok = await widget.controller.submitPassage(text);
    if (ok && mounted) {
      _clearSentText(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final quote = ctrl.quotedExcerpt;
    final assistant = ctrl.activeAssistant;
    final diag = ctrl.lastDiagnosticKey;
    final readingWidth = theme.typography.readingWidthPx.clamp(600.0, 1120.0);
    final needsProviderKey =
        diag == 'diag.provider.not_configured' ||
        diag == 'diag.provider.pinned_unavailable' ||
        diag == 'diag.provider.model_required' ||
        diag == 'diag.provider.auth_failed' ||
        diag == 'diag.provider.quota_exhausted';
    final needsShorten = diag == 'diag.provider.context_overflow';
    final needsSpendingLimit = diag == 'diag.wallet.ceiling_exceeded';
    final needsPriceAllowance = diag == 'diag.wallet.price_unknown';
    final needsHookReview = diag == 'diag.hooks.approval_required';
    final needsContinue = diag == 'diag.provider.reply_truncated';
    final providerReason = ctrl.lastDiagnosticReason;
    // Narrow layouts (effective width / text scale < 600 px) split the toolbar into two
    // rows while streaming or at >= 130% text.
    final scale = textScaleOf(context);
    final twoRowToolbar =
        MediaQuery.sizeOf(context).width / scale < 600 &&
        (ctrl.isStreaming || scale >= kComposerTwoRowTextScale);

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: readingWidth),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            BistreSpacing.s24,
            BistreSpacing.s8,
            BistreSpacing.s24,
            BistreSpacing.s16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (ctrl.backoffRetryAt != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    bottom: BistreSpacing.s8,
                  ),
                  child: _BackoffNotice(
                    retryAt: ctrl.backoffRetryAt!,
                    attempt: ctrl.backoffAttempt,
                    reasonDetail: ctrl.retryReasonDetail,
                    onRetryNow: () => unawaited(ctrl.retryNow()),
                  ),
                ),
              if (ctrl.liveVoiceActive || ctrl.liveVoiceError != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    bottom: BistreSpacing.s8,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.bgElevated,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: ctrl.liveVoiceError != null
                            ? theme.statusErr.withValues(alpha: 0.5)
                            : theme.accentBrass.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        12,
                        6,
                        8,
                        6,
                      ),
                      child: Row(
                        children: [
                          BistreIcon(
                            BistreUiIcon.audioLines,
                            size: 14,
                            color: ctrl.liveVoiceError != null
                                ? theme.statusErr
                                : theme.accentBrass,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: InkText(
                              ctrl.liveVoiceError ??
                                  (ctrl.liveVoiceTranscript.isNotEmpty
                                      ? ctrl.liveVoiceTranscript
                                      : l10n.t(
                                          ctrl.liveVoiceState == 'connecting'
                                              ? L10nKey
                                                    .composerLiveVoiceConnecting
                                              : L10nKey
                                                    .composerLiveVoiceListening,
                                        )),
                              role: InkTextRole.captionMeta,
                              color: ctrl.liveVoiceError != null
                                  ? theme.statusErr
                                  : theme.inkPrimary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          EngravedButton(
                            label: l10n.t(L10nKey.composerLiveVoiceEnd),
                            compact: true,
                            onPressed: () => unawaited(ctrl.stopLiveVoice()),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (diag != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    bottom: BistreSpacing.s8,
                  ),
                  child: FolioFadeSlide(
                    beginOffset: const Offset(0, 0.12),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.bgElevated,
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: theme.borderHairline),
                        boxShadow: theme.cardShadow,
                      ),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          BistreSpacing.s12,
                          8,
                          8,
                          8,
                        ),
                        // Compact inline notice: a status dot, one plain sentence in body ink,
                        // one fix button, and dismiss; announced to screen readers.
                        child: Row(
                          children: [
                            SizedBox.square(
                              dimension: 6,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: theme.statusErr,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            const SizedBox(width: BistreSpacing.s8),
                            Expanded(
                              child: Semantics(
                                liveRegion: true,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkText(
                                      l10n.tRawKey(diag),
                                      role: InkTextRole.bodyCompact,
                                    ),
                                    // P4: the provider's own reason, as it said it.
                                    if (providerReason != null)
                                      InkText(
                                        l10n.t(
                                          L10nKey.chatDiagProviderReason,
                                          <String, Object?>{
                                            'reason': providerReason,
                                          },
                                        ),
                                        role: InkTextRole.captionMeta,
                                        color: theme.inkSecondary,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            // Fixable errors jump straight to the fix.
                            if (needsProviderKey) ...[
                              const SizedBox(width: BistreSpacing.s8),
                              EngravedButton(
                                label: l10n.t(L10nKey.settingsTabProviders),
                                compact: true,
                                onPressed: ctrl.openSettings,
                              ),
                            ],
                            if (needsShorten) ...[
                              const SizedBox(width: BistreSpacing.s8),
                              EngravedButton(
                                label: l10n.t(L10nKey.chatFixShorten),
                                compact: true,
                                onPressed: () {
                                  ctrl.clearDiagnostic();
                                  unawaited(ctrl.compactActiveThread());
                                },
                              ),
                            ],
                            if (needsHookReview) ...[
                              const SizedBox(width: BistreSpacing.s8),
                              EngravedButton(
                                label: l10n.t(L10nKey.chatFixReviewHooks),
                                compact: true,
                                onPressed: () =>
                                    ctrl.openSettings(SettingsTab.agent),
                              ),
                            ],
                            if (needsContinue) ...[
                              const SizedBox(width: BistreSpacing.s8),
                              EngravedButton(
                                label: l10n.t(L10nKey.chatFixContinue),
                                compact: true,
                                onPressed: () {
                                  ctrl.clearDiagnostic();
                                  unawaited(
                                    ctrl.submitPassage(
                                      l10n.t(L10nKey.chatFixContinueMessage),
                                    ),
                                  );
                                },
                              ),
                            ],
                            if (needsPriceAllowance) ...[
                              const SizedBox(width: BistreSpacing.s8),
                              EngravedButton(
                                label: l10n.t(L10nKey.chatFixAllowUnpricedOnce),
                                compact: true,
                                onPressed: () =>
                                    unawaited(ctrl.allowUnpricedOnceAndRetry()),
                              ),
                            ],
                            if (needsSpendingLimit) ...[
                              const SizedBox(width: BistreSpacing.s8),
                              EngravedButton(
                                label: l10n.t(L10nKey.chatFixSpendingLimit),
                                compact: true,
                                onPressed: () =>
                                    ctrl.openSettings(SettingsTab.trust),
                              ),
                            ],
                            const SizedBox(width: 4),
                            BistreIconButton(
                              icon: BistreUiIcon.close,
                              size: 13,
                              dimension: 26,
                              semanticsLabel: l10n.t(L10nKey.shellDismiss),
                              onPressed: ctrl.clearDiagnostic,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.bgElevated,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _focused ? theme.accentBrass : theme.borderHairline,
                    width: _focused ? 1.5 : 1,
                  ),
                  boxShadow: theme.floatingShadow,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (ctrl.pendingSteering.isNotEmpty) ...[
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.bgSurface.withValues(alpha: 0.65),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(15),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                            BistreSpacing.s12,
                            8,
                            8,
                            8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  WaxSealBadge(
                                    label: l10n.t(
                                      L10nKey.composerSteerQueued,
                                      <String, Object?>{
                                        'count': ctrl.pendingSteering.length,
                                      },
                                    ),
                                    status: WaxSealStatus.warn,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              for (final item in ctrl.pendingSteering)
                                Padding(
                                  padding: const EdgeInsetsDirectional.only(
                                    top: 3,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: InkText(
                                          item.content,
                                          role: InkTextRole.captionMeta,
                                          color: theme.inkPrimary,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      EngravedButton(
                                        label: l10n.t(
                                          L10nKey.composerSteerNowAction,
                                        ),
                                        compact: true,
                                        onPressed: () => unawaited(
                                          ctrl.promoteQueuedSteeringNow(item),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      BistreIconButton(
                                        icon: BistreUiIcon.close,
                                        size: 12,
                                        dimension: 22,
                                        semanticsLabel: l10n.t(
                                          L10nKey.shellRemove,
                                        ),
                                        onPressed: () => unawaited(
                                          ctrl.removeSteeringMessage(item.id),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const FolioDivider(),
                    ],
                    if (quote != null) ...[
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.bgSurface.withValues(alpha: 0.55),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(15),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                            BistreSpacing.s12,
                            8,
                            8,
                            8,
                          ),
                          child: Row(
                            children: [
                              BistreIcon(
                                BistreUiIcon.reply,
                                size: 13,
                                color: theme.accentBrass,
                              ),
                              const SizedBox(width: BistreSpacing.s8),
                              Expanded(
                                child: InkText(
                                  l10n.t(
                                    L10nKey.chatReplyingTo,
                                    <String, Object?>{'excerpt': quote},
                                  ),
                                  role: InkTextRole.captionMeta,
                                  color: theme.inkSecondary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              BistreIconButton(
                                icon: BistreUiIcon.close,
                                size: 13,
                                dimension: 24,
                                semanticsLabel: l10n.t(L10nKey.chatReplyClear),
                                onPressed: ctrl.clearQuote,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const FolioDivider(),
                    ],
                    if (_triggerPrefix.isNotEmpty) ...[
                      Builder(
                        builder: (context) {
                          final items = _buildTriggerItems(l10n, ctrl);
                          if (items.isEmpty) return const SizedBox.shrink();
                          final safeIdx = _triggerSelectedIndex.clamp(
                            0,
                            items.length - 1,
                          );
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ComposerTriggerMenu(
                                title: _triggerPrefix == '/'
                                    ? l10n.t(L10nKey.composerSlashTitle)
                                    : l10n.t(L10nKey.composerMentionTitle),
                                items: items,
                                selectedIndex: safeIdx,
                                reduceMotionOverride: ctrl.reduceMotionOverride,
                                onHoverIndex: (idx) =>
                                    setState(() => _triggerSelectedIndex = idx),
                                onSelect: (item) =>
                                    _applyTriggerOption(item.token),
                              ),
                              const FolioDivider(),
                            ],
                          );
                        },
                      ),
                    ],
                    if (ctrl.attachments.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          BistreSpacing.s12,
                          8,
                          BistreSpacing.s12,
                          6,
                        ),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final att in ctrl.attachments)
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: theme.bgSurface,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: theme.borderHairline,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsetsDirectional.fromSTEB(
                                    8,
                                    3,
                                    4,
                                    3,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () =>
                                            ctrl.openAttachmentPreview(att),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            BistreIcon(
                                              BistreUiIcon.paperclip,
                                              size: 11,
                                              color: theme.accentBrass,
                                            ),
                                            const SizedBox(width: 5),
                                            InkText(
                                              att.name,
                                              role: InkTextRole.captionMeta,
                                              color: theme.inkPrimary,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      BistreIconButton(
                                        icon: BistreUiIcon.close,
                                        size: 10,
                                        dimension: 18,
                                        semanticsLabel: l10n.t(
                                          L10nKey.shellRemove,
                                        ),
                                        onPressed: () =>
                                            ctrl.removeAttachment(att.id),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const FolioDivider(),
                    ],
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        BistreSpacing.s16,
                        13,
                        BistreSpacing.s16,
                        BistreSpacing.s8,
                      ),
                      child: Focus(
                        onKeyEvent: (_, event) {
                          // D3: Esc in the empty composer (not mid-IME, no menu open) stops
                          // the reply; with text in it Esc does nothing to the reply.
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.escape &&
                              _triggerPrefix.isEmpty &&
                              ctrl.isStreaming &&
                              _textController.text.isEmpty &&
                              !_textController.value.composing.isValid) {
                            unawaited(ctrl.cancelStreaming());
                            return KeyEventResult.handled;
                          }
                          // U18: arrows, Tab, and Enter belong to the IME while it composes.
                          if (_triggerPrefix.isEmpty ||
                              event is! KeyDownEvent ||
                              _textController.value.composing.isValid) {
                            return KeyEventResult.ignored;
                          }
                          final items = _buildTriggerItems(l10n, ctrl);
                          if (items.isEmpty) return KeyEventResult.ignored;
                          if (event.logicalKey == LogicalKeyboardKey.escape) {
                            setState(() {
                              _triggerPrefix = '';
                              _triggerQuery = '';
                            });
                            return KeyEventResult.handled;
                          }
                          if (event.logicalKey ==
                              LogicalKeyboardKey.arrowDown) {
                            setState(
                              () => _triggerSelectedIndex =
                                  (_triggerSelectedIndex + 1) % items.length,
                            );
                            return KeyEventResult.handled;
                          }
                          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                            setState(
                              () => _triggerSelectedIndex =
                                  (_triggerSelectedIndex - 1 + items.length) %
                                  items.length,
                            );
                            return KeyEventResult.handled;
                          }
                          if (event.logicalKey == LogicalKeyboardKey.tab ||
                              event.logicalKey == LogicalKeyboardKey.enter) {
                            final chosen =
                                items[_triggerSelectedIndex.clamp(
                                  0,
                                  items.length - 1,
                                )];
                            _applyTriggerOption(chosen.token);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: QuillInput(
                          key: const Key('composer_input'),
                          controller: _textController,
                          focusNode: widget.focusNode,
                          placeholder: ctrl.isStreaming
                              ? l10n.t(L10nKey.composerSteerPlaceholder)
                              : assistant != null
                              ? l10n.t(
                                  L10nKey.composerPlaceholderAssistant,
                                  <String, Object?>{'name': assistant.name},
                                )
                              : l10n.t(L10nKey.shellComposerPlaceholder),
                          submitOnEnter: ctrl.sendOnEnter,
                          frameless: true,
                          onSubmitted: () => unawaited(_submit()),
                          onChanged: _handleTextChanged,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        10,
                        0,
                        10,
                        10,
                      ),
                      child: _ComposerToolbar(
                        twoRows: twoRowToolbar,
                        gauge: ValueListenableBuilder<EngineContextBreakdown>(
                          valueListenable: ctrl.contextBreakdown,
                          builder: (context, usage, _) => ContextGaugeRing(
                            usage: usage,
                            limitTokens: ctrl.activeContextLimitOrFetch,
                            sessionSpendMicros: ctrl.activeThreadSpendMicros,
                            uploadedFilesCount: ctrl.attachments.length,
                            showLabel:
                                MediaQuery.sizeOf(context).width / scale >= 600,
                            loadWithDraft: () => ctrl.contextBreakdownWithDraft(
                              _textController.text,
                            ),
                            onShorten: () =>
                                unawaited(ctrl.compactActiveThread()),
                            onOpenPrices: () =>
                                ctrl.openSettings(SettingsTab.trust),
                          ),
                        ),
                        leading: <Widget>[
                          BistreIconButton(
                            icon: BistreUiIcon.paperclip,
                            size: 15,
                            dimension: 30,
                            semanticsLabel: l10n.t(L10nKey.composerAttachFile),
                            onPressed: () => unawaited(
                              ctrl.pickComposerAttachment(
                                title: l10n.t(L10nKey.composerAttachFile),
                                filterLabel: l10n.t(L10nKey.composerAttachFile),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          ComposerToolsControl(
                            controller: ctrl,
                            compact:
                                MediaQuery.sizeOf(context).width / scale < 600,
                          ),
                          const SizedBox(width: 4),
                          ThinkingControl(
                            compact:
                                MediaQuery.sizeOf(context).width / scale < 600,
                            value: ctrl.settings.reasoningEffort,
                            reduceMotionOverride: ctrl.reduceMotionOverride,
                            onChanged: (v) =>
                                unawaited(ctrl.setReasoningEffort(v)),
                          ),
                          // Only this label rebuilds when a draft save lands.
                          ValueListenableBuilder<bool>(
                            valueListenable: ctrl.draftSavedState,
                            builder: (context, saved, _) => saved
                                ? Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                      start: BistreSpacing.s8,
                                    ),
                                    child: InkText(
                                      l10n.t(L10nKey.shellComposerDraftSaved),
                                      role: InkTextRole.captionMeta,
                                      color: theme.statusOk,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                        trailing: <Widget>[
                          if (ctrl.isStreaming) ...[
                            EngravedButton(
                              label: l10n.t(L10nKey.composerSteerNowAction),
                              compact: true,
                              onPressed: () async {
                                final text = _textController.text.trim();
                                if (text.isEmpty) return;
                                _textController.clear();
                                await ctrl.steerActiveRunNow(text);
                              },
                            ),
                            const SizedBox(width: 6),
                            EngravedButton(
                              label: l10n.t(L10nKey.composerQueueAction),
                              primary: true,
                              compact: true,
                              leading: BistreIcon(
                                BistreUiIcon.send,
                                size: 12,
                                color: theme.onAccentWax,
                              ),
                              onPressed: () => unawaited(_submit()),
                            ),
                            const SizedBox(width: 6),
                            EngravedButton(
                              label: l10n.t(L10nKey.chatActionStop),
                              compact: true,
                              leading: BistreIcon(
                                BistreUiIcon.stop,
                                size: 12,
                                color: theme.inkPrimary,
                              ),
                              onPressed: () =>
                                  unawaited(ctrl.cancelStreaming()),
                            ),
                          ] else ...[
                            BistreIconButton(
                              icon: BistreUiIcon.mic,
                              size: 14,
                              dimension: 30,
                              active: ctrl.dictatingActive,
                              color: ctrl.dictatingActive
                                  ? theme.accentWax
                                  : theme.inkSecondary,
                              semanticsLabel: l10n.t(
                                L10nKey.composerVoiceDictate,
                              ),
                              onPressed: () async {
                                final spoken = await ctrl.dictateVoiceOnce();
                                if (spoken == null || !mounted) return;
                                // Never mutate while IME composition is active.
                                if (_textController.value.composing.isValid) {
                                  return;
                                }
                                final cur = _textController.text;
                                final next = cur.trim().isEmpty
                                    ? spoken
                                    : '$cur $spoken';
                                _textController.value = TextEditingValue(
                                  text: next,
                                  selection: TextSelection.collapsed(
                                    offset: next.length,
                                  ),
                                );
                                _handleTextChanged(next);
                              },
                            ),
                            const SizedBox(width: 4),
                            EngravedButton(
                              label:
                                  MediaQuery.sizeOf(context).width / scale < 600
                                  ? ''
                                  : l10n.t(L10nKey.composerLiveVoicePill),
                              semanticsLabel: l10n.t(
                                L10nKey.composerLiveVoicePill,
                              ),
                              compact: true,
                              primary: ctrl.liveVoiceActive,
                              leading: BistreIcon(
                                BistreUiIcon.audioLines,
                                size: 13,
                                color: ctrl.liveVoiceActive
                                    ? theme.onAccentWax
                                    : theme.accentBrass,
                              ),
                              onPressed: () =>
                                  unawaited(ctrl.toggleLiveVoiceSession()),
                            ),
                            const SizedBox(width: 6),
                            // A quiet Send control: the message, not the button, is
                            // the focal point.
                            EngravedButton(
                              label: l10n.t(L10nKey.shellComposerSend),
                              compact: true,
                              leading: BistreIcon(
                                BistreUiIcon.send,
                                size: 13,
                                color: theme.inkSecondary,
                              ),
                              onPressed: () => unawaited(_submit()),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom composer controls: one row normally; two rows on compact phones while streaming or
/// at large text so `Stop` / `Queue` / `Send` never squeeze the leading tools.
class _ComposerToolbar extends StatelessWidget {
  const _ComposerToolbar({
    required this.twoRows,
    required this.leading,
    required this.trailing,
    required this.gauge,
  });

  final bool twoRows;
  final List<Widget> leading;
  final List<Widget> trailing;
  final Widget gauge;

  @override
  Widget build(BuildContext context) {
    final scale = textScaleOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveWidth = constraints.maxWidth / scale;
        final split = twoRows || effectiveWidth < 580;
        if (!split) {
          // Leading controls wrap inside the flexible start group, so the gauge and the
          // trailing actions never push the row past its width.
          return Row(
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: BistreSpacing.s4,
                  children: leading,
                ),
              ),
              gauge,
              const SizedBox(width: BistreSpacing.s8),
              ...trailing,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: BistreSpacing.s4,
                    children: leading,
                  ),
                ),
                gauge,
              ],
            ),
            const SizedBox(height: BistreSpacing.s8),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: BistreSpacing.s4,
              children: trailing,
            ),
          ],
        );
      },
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

  /// Which automatic try failed (P20).
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

  /// U37: a new wait (a later try) restarts the countdown; the ticker of a wait that ran
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
                      widget.reasonDetail!,
                      role: InkTextRole.codeBlock,
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
