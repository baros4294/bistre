import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/disclosure_reveal.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../shell/folio_controller.dart';
import 'composer_asides.dart';
import 'composer_folder_button.dart';
import 'composer_notice.dart';
import 'composer_phone_controls.dart';
import 'composer_toolbar_layout.dart';
import 'composer_tools_control.dart';
import 'composer_trigger_menu.dart';
import 'context_gauge_ring.dart';
import 'media_options_control.dart';
import 'thinking_control.dart';

part 'folio_composer_parts.dart';

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
  /// Phone: the tray of occasional controls under the field is open.
  bool _trayOpen = false;

  final TextEditingController _textController = TextEditingController();

  /// The text last handed to the draft save, so selection-only changes save nothing.
  String _lastDraftText = '';

  /// Text that was sent while the IME was still composing; removed once it commits.
  String? _sentWhileComposing;
  int _syncedDraftEpoch = -1;
  late int _syncedInsertEpoch = widget.controller.draftInsert?.epoch ?? 0;
  bool _focused = false;
  String _triggerPrefix = '';
  String _triggerQuery = '';
  int _triggerSelectedIndex = 0;

  /// Every change to the text, typed or programmatic (a clear after sending, a slash command,
  /// an inserted skill), updates the saved draft. A restored draft is not saved back.
  void _onComposerTextChanged() {
    // Edits skipped during an IME composition run as soon as it ends.
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
      // The workspace is read once, asynchronously, when the menu opens.
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
      unawaited(chooseChatFolder(ctrl, token, add: false));
      return;
    }
    if (token.startsWith('/')) {
      _runSlashCommand(token, ctrl);
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
    _insertDraftIfNew();
    final epoch = widget.controller.draftEpoch;
    if (epoch == _syncedDraftEpoch) return;
    if (_textController.value.composing.isValid) return;

    _syncedDraftEpoch = epoch;
    _syncedInsertEpoch = widget.controller.draftInsert?.epoch ?? 0;
    final restored = widget.controller.restoredDraft;
    _lastDraftText = restored;
    if (_textController.text != restored) {
      _textController.value = TextEditingValue(
        text: restored,
        selection: TextSelection.collapsed(offset: restored.length),
      );
    }
  }

  /// Adds a drafted reply after the text already typed (a blank line between), never
  /// during IME composition; it lands once the composition ends.
  void _insertDraftIfNew() {
    final insert = widget.controller.draftInsert;
    if (insert == null || insert.epoch == _syncedInsertEpoch) return;
    if (_textController.value.composing.isValid) return;
    _syncedInsertEpoch = insert.epoch;
    final typed = _textController.text.trimRight();
    final next = typed.isEmpty ? insert.text : '$typed\n\n${insert.text}';
    _textController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
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

  /// Speech to text once; the words join the draft (never while an IME composes).
  Future<void> _dictate() async {
    final ctrl = widget.controller;
    final spoken = await ctrl.dictateVoiceOnce();
    if (spoken == null || !mounted) return;
    // Never mutate while IME composition is active.
    if (_textController.value.composing.isValid) {
      return;
    }
    final cur = _textController.text;
    final next = cur.trim().isEmpty ? spoken : '$cur $spoken';
    _textController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _handleTextChanged(next);
  }

  /// Sends the typed text into the reply in progress right away.
  Future<void> _steerNow() async {
    final ctrl = widget.controller;
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    await ctrl.steerActiveRunNow(text);
  }

  Future<void> _submit() async {
    // The text field takes Enter before the menu's key handler sees it: while the `/` or `@`
    // menu is open, Enter picks the highlighted entry and never sends the typed command.
    if (_triggerPrefix.isNotEmpty) {
      // Never pick while the IME is composing (the Send button can still be tapped).
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
    if (await _runArgumentCommand(text)) return;
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
    final readingWidth = theme.typography.readingWidthPx.clamp(
      BistreSpacing.readingWidthMin,
      BistreSpacing.readingWidthMax,
    );
    final needsShorten =
        ctrl.lastDiagnosticKey == 'diag.provider.context_overflow';
    final scale = textScaleOf(context);
    Widget gaugeFor(bool compact) =>
        ValueListenableBuilder<EngineContextBreakdown>(
          valueListenable: ctrl.contextBreakdown,
          builder: (context, usage, _) => ContextGaugeRing(
            usage: usage,
            limitTokens: ctrl.activeContextLimitOrFetch,
            sessionSpendMicros: ctrl.activeThreadSpendMicros,
            uploadedFilesCount: ctrl.attachments.length,
            showLabel: !compact,
            overLimit: needsShorten,
            loadWithDraft: () =>
                ctrl.contextBreakdownWithDraft(_textController.text),
            onShorten: () => unawaited(ctrl.compactActiveThread()),
            onOpenPrices: () => ctrl.openSettings(SettingsTab.trust),
          ),
        );

    Widget liveButton(bool compact) => EngravedButton(
      label: compact ? '' : l10n.t(L10nKey.composerLiveVoicePill),
      semanticsLabel: l10n.t(L10nKey.composerLiveVoicePill),
      compact: true,
      primary: ctrl.liveVoiceActive,
      leading: BistreIcon(
        BistreUiIcon.audioLines,
        size: 13,
        color: ctrl.liveVoiceActive ? theme.onAccentWax : theme.accentBrass,
      ),
      onPressed: () => unawaited(ctrl.toggleLiveVoiceSession()),
    );

    final info = ctrl.activeModelInfo;
    // The Thinking chip names the chosen level, so it shortens only after Tools and Live.
    List<Widget> leadingFor(bool compact, [bool shortThinking = false]) =>
        <Widget>[
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
          ComposerFolderButton(controller: ctrl),
          const SizedBox(width: 4),
          ComposerToolsControl(controller: ctrl, compact: compact),
          const SizedBox(width: 4),
          ..._modelControls(ctrl, info, compact: shortThinking),
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
        ];

    List<Widget> trailingFor(bool compact) => <Widget>[
      if (ctrl.isStreaming) ...[
        EngravedButton(
          label: l10n.t(L10nKey.composerSteerNowAction),
          compact: true,
          onPressed: () => unawaited(_steerNow()),
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
          onPressed: () => unawaited(ctrl.cancelStreaming()),
        ),
      ] else ...[
        BistreIconButton(
          icon: BistreUiIcon.mic,
          size: 14,
          dimension: 30,
          active: ctrl.dictatingActive,
          color: ctrl.dictatingActive ? theme.accentWax : theme.inkSecondary,
          semanticsLabel: l10n.t(L10nKey.composerVoiceDictate),
          onPressed: () => unawaited(_dictate()),
        ),
        if (BistreDesktopHost.canCaptureMic) ...[
          const SizedBox(width: 4),
          liveButton(compact),
        ],
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
    ];

    // Phones keep one row: a + that opens a tray of the occasional controls, the conversation
    // ring, the field, and one send / voice / stop action at the end (DESIGN §1.2).
    final phone = MediaQuery.sizeOf(context).width < kComposerPhoneWidth;

    final Widget composerField = Focus(
      onKeyEvent: (_, event) {
        // Esc in the empty composer (not mid-IME, no menu open) stops
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
        // Arrows, Tab, and Enter belong to the IME while it composes.
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
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          setState(
            () => _triggerSelectedIndex =
                (_triggerSelectedIndex + 1) % items.length,
          );
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          setState(
            () => _triggerSelectedIndex =
                (_triggerSelectedIndex - 1 + items.length) % items.length,
          );
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.tab ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          final chosen =
              items[_triggerSelectedIndex.clamp(0, items.length - 1)];
          _applyTriggerOption(chosen.token);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      // Ctrl+V and the touch toolbar's Paste: copied files, a picture, or long text join
      // the message as files.
      child: Actions(
        actions: <Type, Action<Intent>>{
          PasteTextIntent: CallbackAction<PasteTextIntent>(
            onInvoke: (_) {
              unawaited(_paste(l10n));
              return null;
            },
          ),
        },
        child: QuillInput(
          key: const Key('composer_input'),
          controller: _textController,
          focusNode: widget.focusNode,
          placeholder: ctrl.isStreaming
              ? l10n.t(L10nKey.composerSteerPlaceholder)
              : assistant != null
              ? l10n.t(L10nKey.composerPlaceholderAssistant, <String, Object?>{
                  'name': assistant.name,
                })
              : l10n.t(L10nKey.shellComposerPlaceholder),
          submitOnEnter: ctrl.sendOnEnter,
          frameless: true,
          onSubmitted: () => unawaited(_submit()),
          onChanged: _handleTextChanged,
        ),
      ),
    );

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
                              ctrl.liveVoiceError != null
                                  ? l10n.tRawKey(ctrl.liveVoiceError!)
                                  : (ctrl.liveVoiceTranscript.isNotEmpty
                                        ? l10n.t(
                                            L10nKey.composerLiveVoiceLine,
                                            <String, Object?>{
                                              'speaker':
                                                  ctrl.liveVoiceTranscriptIsUser
                                                  ? l10n.t(
                                                      L10nKey.shellRoleUser,
                                                    )
                                                  : l10n.t(
                                                      L10nKey
                                                          .shellRoleAssistant,
                                                    ),
                                              'text': l10n.isolate(
                                                ctrl.liveVoiceTranscript,
                                              ),
                                            },
                                          )
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
              if (ComposerAsides.shows(ctrl))
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    bottom: BistreSpacing.s8,
                  ),
                  child: ComposerAsides(controller: ctrl),
                ),
              if (ComposerNotice.shows(ctrl))
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    bottom: BistreSpacing.s8,
                  ),
                  child: ComposerNotice(controller: ctrl),
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
                                      PressableArea(
                                        label: att.name,
                                        onPressed: () =>
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
                      child: phone
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                ComposerTrayToggle(
                                  open: _trayOpen,
                                  // Marks a Thinking choice other than Auto (stored as
                                  // `default`; any unknown value also reads as Auto) or a
                                  // format this model takes.
                                  marked:
                                      thinkingLabelKey(
                                            ctrl.settings.reasoningEffort,
                                          ) !=
                                          L10nKey.chatEffortAuto ||
                                      (info != null &&
                                          !ctrl.mediaOptions
                                              .forModel(info)
                                              .isEmpty),
                                  onToggle: () =>
                                      setState(() => _trayOpen = !_trayOpen),
                                ),
                                const SizedBox(width: BistreSpacing.s4),
                                // Centred on the same line as + and the send action.
                                SizedBox(
                                  height: 36 * iconScaleOf(context),
                                  child: Center(child: gaugeFor(true)),
                                ),
                                const SizedBox(width: BistreSpacing.s8),
                                Expanded(child: composerField),
                                const SizedBox(width: BistreSpacing.s4),
                                ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: _textController,
                                  builder: (context, value, _) =>
                                      ComposerSendActions(
                                        streaming: ctrl.isStreaming,
                                        hasText: value.text.trim().isNotEmpty,
                                        dictating: ctrl.dictatingActive,
                                        onSend: () => unawaited(_submit()),
                                        onStop: () =>
                                            unawaited(ctrl.cancelStreaming()),
                                        onDictate: () => unawaited(_dictate()),
                                      ),
                                ),
                              ],
                            )
                          : composerField,
                    ),
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        10,
                        0,
                        10,
                        10,
                      ),
                      child: phone
                          ? DisclosureReveal(
                              open: _trayOpen,
                              child: Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  top: BistreSpacing.s4,
                                ),
                                child: Wrap(
                                  spacing: BistreSpacing.s4,
                                  runSpacing: BistreSpacing.s4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  // The tray has room: every control keeps its name, and
                                  // the row wraps at large text.
                                  children: [
                                    ...leadingFor(false),
                                    if (BistreDesktopHost.canCaptureMic)
                                      liveButton(false),
                                    if (ctrl.isStreaming)
                                      EngravedButton(
                                        label: l10n.t(
                                          L10nKey.composerSteerNowAction,
                                        ),
                                        compact: true,
                                        onPressed: () => unawaited(_steerNow()),
                                      ),
                                  ],
                                ),
                              ),
                            )
                          : _ComposerToolbar(
                              twoRows: false,
                              // The model decides which chips show (Thinking, Format).
                              measureKey: (
                                scale,
                                l10n.activeLocale,
                                ctrl.isStreaming,
                                info?.writesText,
                                info?.reasoning,
                                info?.hasMediaChoices,
                              ),
                              gauge: gaugeFor,
                              leading: leadingFor,
                              trailing: trailingFor,
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
