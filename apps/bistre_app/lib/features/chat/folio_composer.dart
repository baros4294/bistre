import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import 'chat_mode_selector.dart';
import 'context_gauge_ring.dart';

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
  final OverlayPortalController _assistantMenuCtrl = OverlayPortalController();
  final LayerLink _assistantLink = LayerLink();
  int _syncedDraftEpoch = -1;
  bool _focused = false;
  String _triggerPrefix = '';

  /// Command tokens offered after `@` / `/` (syntax, not translatable copy).
  static const List<String> _mentionOptions = <String>[
    '@file ',
    '@diff ',
    '@thread ',
    '@memory ',
    '@mcp ',
  ];

  static const List<String> _slashOptions = <String>[
    '/plan',
    '/build',
    '/write',
    '/compact',
    '/tree',
    '/clear',
  ];

  void _handleTextChanged(String text) {
    widget.controller.scheduleDraftSave(text);
    final trimmedStart = text.trimLeft();
    String nextTrigger = '';
    if (trimmedStart.startsWith('/') && !trimmedStart.contains(' ')) {
      nextTrigger = '/';
    } else if (text.endsWith('@') ||
        RegExp(r'(?:^|\s)@[a-zA-Z]*$').hasMatch(text)) {
      nextTrigger = '@';
    }
    if (nextTrigger != _triggerPrefix) {
      setState(() => _triggerPrefix = nextTrigger);
    }
  }

  void _applyTriggerOption(String token) {
    final ctrl = widget.controller;
    setState(() => _triggerPrefix = '');
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
      }
      return;
    }
    final current = _textController.text;
    final replaced = current.replaceFirst(RegExp(r'@[a-zA-Z]*$'), token);
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
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncDraftIfEpochChanged);
    widget.focusNode.removeListener(_onFocusChanged);
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
    if (value.composing.isValid) return;
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
        diag == 'diag.provider.model_required' ||
        diag == 'diag.provider.auth_failed' ||
        diag == 'diag.provider.quota_exhausted';
    final needsShorten = diag == 'diag.provider.context_overflow';
    final needsSpendingLimit = diag == 'diag.wallet.ceiling_exceeded';
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
                    onRetryNow: () => unawaited(ctrl.retryNow()),
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
                        // Parchment v2.6.0 notice: a status dot, one plain sentence in body ink,
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
                                child: InkText(
                                  l10n.tRawKey(diag),
                                  role: InkTextRole.bodyCompact,
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
                              semanticsLabel: l10n.t(L10nKey.threadCancel),
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
                                      BistreIconButton(
                                        icon: BistreUiIcon.close,
                                        size: 12,
                                        dimension: 22,
                                        semanticsLabel: l10n.t(
                                          L10nKey.threadCancel,
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
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.bgSurface.withValues(alpha: 0.72),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(15),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                            BistreSpacing.s12,
                            8,
                            BistreSpacing.s12,
                            8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              InkText(
                                _triggerPrefix == '/'
                                    ? l10n.t(L10nKey.composerSlashTitle)
                                    : l10n.t(L10nKey.composerMentionTitle),
                                role: InkTextRole.captionMeta,
                                color: theme.accentBrass,
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final item
                                      in _triggerPrefix == '/'
                                          ? _slashOptions
                                          : _mentionOptions)
                                    InkChip(
                                      label: item.trim(),
                                      selected: false,
                                      onSelected: () =>
                                          _applyTriggerOption(item),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const FolioDivider(),
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
                                      const SizedBox(width: 4),
                                      BistreIconButton(
                                        icon: BistreUiIcon.close,
                                        size: 10,
                                        dimension: 18,
                                        semanticsLabel: l10n.t(
                                          L10nKey.threadCancel,
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
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        10,
                        0,
                        10,
                        10,
                      ),
                      child: _ComposerToolbar(
                        twoRows: twoRowToolbar,
                        gauge: ContextGaugeRing(
                          threadId: ctrl.activeThread?.id ?? '',
                          text: ctrl.contextGaugeText,
                          limitTokens: ctrl.activeContextLimitOrFetch,
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
                          if (ctrl.activeThread != null) ...[
                            ChatModeSelector(
                              activeMode: ctrl.activeThreadMode,
                              onSelect: (m) =>
                                  unawaited(ctrl.setActiveThreadMode(m)),
                            ),
                            const SizedBox(width: 4),
                          ],
                          if (assistant != null)
                            FolioOverlay(
                              controller: _assistantMenuCtrl,
                              overlayBuilder: (ctx) => _buildAssistantPopover(
                                ctx,
                                theme,
                                l10n,
                                ctrl,
                              ),
                              child: CompositedTransformTarget(
                                link: _assistantLink,
                                child: _AssistantTriggerPill(
                                  assistant: assistant,
                                  onTap: _assistantMenuCtrl.toggle,
                                ),
                              ),
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
                          ] else
                            // A quiet Send (Parchment v2.6.0): the message, not the button, is
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

  Widget _buildAssistantPopover(
    BuildContext context,
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final dir = Directionality.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _assistantMenuCtrl.hide,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _assistantLink,
          showWhenUnlinked: false,
          targetAnchor: AlignmentDirectional.topStart.resolve(dir),
          followerAnchor: AlignmentDirectional.bottomStart.resolve(dir),
          offset: const Offset(0, -8),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, 0.06),
            reduceMotionOverride: ctrl.reduceMotionOverride,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 268),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FolioSurface(
                  tone: FolioTone.elevated,
                  padding: const EdgeInsetsDirectional.symmetric(vertical: 6),
                  borderRadius: 12,
                  boxShadow: theme.floatingShadow,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          12,
                          4,
                          12,
                          6,
                        ),
                        child: InkText(
                          l10n.t(L10nKey.sidebarSectionAssistants),
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
                        ),
                      ),
                      const FolioDivider(),
                      for (final EngineAssistant a in ctrl.assistants)
                        _AssistantPopoverOption(
                          assistant: a,
                          selected: ctrl.activeAssistantId == a.id,
                          onTap: () {
                            _assistantMenuCtrl.hide();
                            unawaited(ctrl.selectAssistant(a.id));
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AssistantTriggerPill extends StatefulWidget {
  const _AssistantTriggerPill({required this.assistant, required this.onTap});

  final EngineAssistant assistant;
  final VoidCallback onTap;

  @override
  State<_AssistantTriggerPill> createState() => _AssistantTriggerPillState();
}

class _AssistantTriggerPillState extends State<_AssistantTriggerPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final hasLabIcon = widget.assistant.iconSlug.isNotEmpty;

    return Semantics(
      button: true,
      label: widget.assistant.name,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: _hovered
                  ? theme.bgSurface
                  : theme.bgSurface.withValues(alpha: 0.60),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 9,
                vertical: 5,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasLabIcon)
                    LabIcon(iconSlug: widget.assistant.iconSlug, size: 13)
                  else
                    BistreIcon(
                      BistreUiIcon.assistant,
                      size: 13,
                      color: theme.accentBrass,
                    ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: InkText(
                      widget.assistant.name,
                      role: InkTextRole.captionMeta,
                      color: theme.inkSecondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 5),
                  BistreIcon(
                    BistreUiIcon.chevronDown,
                    size: 11,
                    color: theme.inkMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantPopoverOption extends StatefulWidget {
  const _AssistantPopoverOption({
    required this.assistant,
    required this.selected,
    required this.onTap,
  });

  final EngineAssistant assistant;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_AssistantPopoverOption> createState() =>
      _AssistantPopoverOptionState();
}

class _AssistantPopoverOptionState extends State<_AssistantPopoverOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final hasLabIcon = widget.assistant.iconSlug.isNotEmpty;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hovered || widget.selected ? theme.hoverTint : null,
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            child: Row(
              children: [
                if (hasLabIcon)
                  LabIcon(iconSlug: widget.assistant.iconSlug, size: 15)
                else
                  BistreIcon(
                    BistreUiIcon.assistant,
                    size: 14,
                    color: widget.selected
                        ? theme.accentBrass
                        : theme.inkSecondary,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkText(
                        widget.assistant.name,
                        role: InkTextRole.labelStrong,
                        color: theme.inkPrimary,
                      ),
                      if (widget.assistant.roleSubtitle.isNotEmpty)
                        InkText(
                          widget.assistant.roleSubtitle,
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (widget.selected)
                  BistreIcon(
                    BistreUiIcon.check,
                    size: 13,
                    color: theme.accentBrass,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom composer controls: one row normally; two rows on compact phones while streaming or
/// at large text so `Stop` / `Queue` / `Send` never squeeze the assistant picker.
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
    if (!twoRows) {
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
  }
}

/// Backoff notice with countdown, plain reason, and an inline trailing `Retry now`.
/// The 1 s ticker runs only while a retry is pending (never idle polling).
class _BackoffNotice extends StatefulWidget {
  const _BackoffNotice({required this.retryAt, required this.onRetryNow});

  final DateTime retryAt;
  final VoidCallback onRetryNow;

  @override
  State<_BackoffNotice> createState() => _BackoffNoticeState();
}

class _BackoffNoticeState extends State<_BackoffNotice> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (DateTime.now().isAfter(widget.retryAt)) {
        _ticker?.cancel();
      }
      setState(() {});
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
    final remaining = widget.retryAt.difference(DateTime.now()).inSeconds;
    final seconds = remaining < 0 ? 0 : remaining + 1;
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
              child: InkText(
                l10n.t(L10nKey.chatBackoffNotice, <String, Object?>{
                  'seconds': seconds,
                }),
                role: InkTextRole.captionMeta,
                color: theme.inkSecondary,
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
