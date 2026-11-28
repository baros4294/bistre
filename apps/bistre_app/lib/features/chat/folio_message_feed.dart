import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_selection_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/context_menu.dart';
import '../../design/ink_primitives.dart';
import '../../design/label_control_layout.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../design/user_avatar_thumb.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import '../shell/live_turn_notifier.dart';
import 'code_wrap_scope.dart';
import 'committed_tool_steps.dart';
import 'cost_unavailable_button.dart';
import 'earlier_messages_button.dart';
import 'markdown_folio_view.dart';
import 'message_nav_rail.dart';
import 'plain_preview.dart';
import 'reasoning_block.dart';
import 'sent_picture_thumb.dart';
import 'tool_timeline_view.dart';
import 'usage_details_pill.dart';

part 'folio_message_cards.dart';
part 'folio_passage_item.dart';

/// Calm Studio Atelier reading canvas:
/// - Unconfigured Welcome Desk: ONE calm setup card without promotional brand-icon clutter
///   and a SINGLE primary CTA (zero duplicate Add API Key buttons anywhere else in the app).
/// - Ready Welcome Desk: Active assistant & color lab badge + clean vertical starter list.
/// - Conversation Feed: respects user-configured reading width & fonts, supports inline user
///   message editing & branching, single-node deletion, branch switcher, and subtle token/cost footer.
class FolioMessageFeed extends StatefulWidget {
  const FolioMessageFeed({
    super.key,
    required this.controller,
    required this.onReplyToPassage,
    required this.onSubmitStarterPrompt,
    required this.onSelectSearchHit,
  });

  final FolioController controller;
  final ValueChanged<String> onReplyToPassage;
  final ValueChanged<String> onSubmitStarterPrompt;
  final ValueChanged<EngineSearchHit> onSelectSearchHit;

  @override
  State<FolioMessageFeed> createState() => _FolioMessageFeedState();
}

class _FolioMessageFeedState extends State<FolioMessageFeed> {
  final ScrollController _scrollController = SmoothScrollController();
  final CodeWrapOverrides _codeWrapOverrides = CodeWrapOverrides();
  final BistreSelectionControls _selectionControls = BistreSelectionControls();
  bool _autoFollow = true;
  bool _showJumpToLatest = false;
  double? _lastViewport;
  late int _lastNodeCount;
  late int _lastStreamLen;
  String? _lastThreadId;

  @override
  void initState() {
    super.initState();
    _lastNodeCount = widget.controller.visibleBranchNodes.length;
    _lastStreamLen = _liveSize();
    _lastThreadId = widget.controller.activeThread?.id;
    widget.controller.addListener(_onControllerUpdated);
    widget.controller.liveTurn.addListener(_onLiveTurnGrew);
    widget.controller.revealRequest.addListener(_onRevealRequested);
    _scrollController.addListener(_onScrollPositionChanged);
    if (widget.controller.visibleBranchNodes.isNotEmpty) {
      _anchorAtBottom();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdated);
    widget.controller.liveTurn.removeListener(_onLiveTurnGrew);
    widget.controller.revealRequest.removeListener(_onRevealRequested);
    _scrollController.removeListener(_onScrollPositionChanged);
    _scrollController.dispose();
    _codeWrapOverrides.dispose();
    super.dispose();
  }

  /// Opens a chat at its newest message. Lazily built slivers only estimate their extent, so
  /// the jump repeats on the next frame until the true end is reached.
  void _anchorAtBottom([int attempts = 3]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      _scrollController.jumpTo(pos.maxScrollExtent);
      if (attempts > 1) _anchorAtBottom(attempts - 1);
    });
  }

  /// How much the live reply shows: its text, its thinking, and its tool rows with
  /// their output, so growth of any of them keeps the reader at the bottom.
  int _liveSize() {
    final ctrl = widget.controller;
    final turn = ctrl.liveTurn.value;
    var size = (turn?.text.length ?? 0) + (turn?.thinking.length ?? 0);
    for (final row in ctrl.toolActivities) {
      size += 1 + row.outputText.length + (row.diffText?.length ?? 0);
    }
    return size;
  }

  /// Follows the live reply without rebuilding the feed (leaf notifier, no setState).
  void _onLiveTurnGrew() {
    final len = _liveSize();
    final grew = len > _lastStreamLen;
    _lastStreamLen = len;
    // Settings > Follow replies while they are written.
    final follows = widget.controller.uiPrefs.followWhileStreaming;
    if (!grew || !_autoFollow || !follows) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _onControllerUpdated() {
    final ctrl = widget.controller;
    final threadId = ctrl.activeThread?.id;
    final visibleCount = ctrl.visibleBranchNodes.length;
    final streamLen = _liveSize();

    if (threadId != _lastThreadId) {
      _lastThreadId = threadId;
      _lastNodeCount = visibleCount;
      _lastStreamLen = streamLen;
      _autoFollow = true;
      _codeWrapOverrides.clear();
      _anchorAtBottom();
      return;
    }

    // A new message always scrolls into view; a reply growing only when it is followed.
    final grew =
        visibleCount > _lastNodeCount ||
        (streamLen > _lastStreamLen && ctrl.uiPrefs.followWhileStreaming);
    _lastNodeCount = visibleCount;
    _lastStreamLen = streamLen;

    if (grew && _autoFollow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
    }
  }

  void _onScrollPositionChanged() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final distFromBottom = pos.maxScrollExtent - pos.pixels;
    final shouldShow = distFromBottom > 120;
    if (shouldShow != _showJumpToLatest) {
      setState(() => _showJumpToLatest = shouldShow);
    }
    // Following resumes only when a scroll ends near the bottom (idle, below) or on
    // Jump to latest, never mid-drag, so a slow upward drag is not pulled back down.
  }

  /// A notice or a taller composer shortens the chat from below; a reader at the bottom
  /// stays there, so the last reply's usage line is never hidden under the change.
  bool _handleMetrics(ScrollMetricsNotification notification) {
    final viewport = notification.metrics.viewportDimension;
    final shrank = _lastViewport != null && viewport < _lastViewport!;
    _lastViewport = viewport;
    if (shrank && _autoFollow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
    }
    return false;
  }

  bool _handleUserScroll(UserScrollNotification notification) {
    if (notification.direction == ScrollDirection.forward) {
      _autoFollow = false;
    } else if (notification.direction == ScrollDirection.idle &&
        _scrollController.hasClients) {
      final dist =
          _scrollController.position.maxScrollExtent -
          _scrollController.position.pixels;
      if (dist < 28) {
        _autoFollow = true;
      }
    }
    return false;
  }

  void _jumpToLatest() {
    _autoFollow = true;
    setState(() => _showJumpToLatest = false);
    if (!_scrollController.hasClients) return;
    final dur = BistreMotion.panelDuration(
      context,
      reduceMotionOverride: widget.controller.reduceMotionOverride,
    );
    if (dur == Duration.zero) {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    } else {
      unawaited(
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: dur,
          curve: BistreMotion.easeOut,
        ),
      );
    }
  }

  void _scrollToOffset(double target) {
    if (!_scrollController.hasClients) return;
    final clamped = target.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    final dur = BistreMotion.panelDuration(
      context,
      reduceMotionOverride: widget.controller.reduceMotionOverride,
    );
    if (dur == Duration.zero) {
      _scrollController.jumpTo(clamped);
    } else {
      unawaited(
        _scrollController.animateTo(
          clamped,
          duration: dur,
          curve: BistreMotion.easeOut,
        ),
      );
    }
  }

  /// The message being revealed carries this key so it can be scrolled into view once
  /// the lazy list has built it.
  final GlobalKey _revealKey = GlobalKey();
  String? _revealNodeId;

  void _onRevealRequested() {
    final nodeId = widget.controller.revealRequest.value;
    if (nodeId == null) return;
    final index = widget.controller.visibleBranchNodes.indexWhere(
      (n) => n.id == nodeId,
    );
    if (index < 0) return;
    setState(() => _revealNodeId = nodeId);
    _autoFollow = false;
    _revealIndex(index, 6);
  }

  /// Jumps near the message by its share of the list, then, once it is built, scrolls it into
  /// view exactly (lazily built items only estimate their extent, so this repeats).
  void _revealIndex(int index, int attempts) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _revealKey.currentContext;
      if (target != null) {
        unawaited(Scrollable.ensureVisible(target, alignment: 0.1));
        return;
      }
      final total = widget.controller.visibleBranchNodes.length;
      final frac = total <= 1 ? 0.0 : (index / (total - 1)).clamp(0.0, 1.0);
      _scrollController.jumpTo(
        frac * _scrollController.position.maxScrollExtent,
      );
      if (attempts > 1) _revealIndex(index, attempts - 1);
    });
  }

  void _jumpToTurnIndex(int index) {
    final total = widget.controller.visibleBranchNodes.length;
    if (total <= 1 || !_scrollController.hasClients) return;
    _autoFollow = index >= total - 1;
    final frac = (index / (total - 1)).clamp(0.0, 1.0);
    _scrollToOffset(frac * _scrollController.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final visibleNodes = ctrl.visibleBranchNodes;
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: ctrl.search,
        builder: (context, _) => Stack(
          fit: StackFit.expand,
          children: [
            LayoutBuilder(
              builder: (context, constraints) => CodeWrapScope(
                wrapByDefault: ctrl.codeWrapFor(constraints.maxWidth),
                overrides: _codeWrapOverrides,
                child: SelectableRegion(
                  selectionControls: _selectionControls,
                  contextMenuBuilder: buildBistreSelectableContextMenu,
                  child: NotificationListener<ScrollMetricsNotification>(
                    onNotification: _handleMetrics,
                    child: NotificationListener<UserScrollNotification>(
                      onNotification: _handleUserScroll,
                      child: RawScrollbar(
                        controller: _scrollController,
                        thumbColor: theme.inkMuted.withValues(alpha: 0.22),
                        radius: const Radius.circular(999),
                        thickness: 4,
                        child: _buildFeedContent(context, theme, l10n, ctrl),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (ctrl.searchQuery.isEmpty && visibleNodes.length >= 2)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(end: 10),
                  child: MessageNavRail(
                    nodes: visibleNodes,
                    visible:
                        ctrl.messageNavVisibility == 'always' ||
                        (ctrl.messageNavVisibility == 'while_scrolling' &&
                            _showJumpToLatest),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onJumpTop: () {
                      _autoFollow = false;
                      _scrollToOffset(0);
                    },
                    onJumpPrev: () {
                      if (!_scrollController.hasClients) return;
                      _autoFollow = false;
                      _scrollToOffset(
                        _scrollController.position.pixels -
                            _scrollController.position.viewportDimension * 0.75,
                      );
                    },
                    onJumpNext: () {
                      if (!_scrollController.hasClients) return;
                      _scrollToOffset(
                        _scrollController.position.pixels +
                            _scrollController.position.viewportDimension * 0.75,
                      );
                    },
                    onJumpLatest: _jumpToLatest,
                    onJumpToIndex: _jumpToTurnIndex,
                  ),
                ),
              ),
            if (_showJumpToLatest &&
                ctrl.searchQuery.isEmpty &&
                visibleNodes.isNotEmpty)
              Align(
                alignment: AlignmentDirectional.bottomCenter,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    bottom: BistreSpacing.s12,
                  ),
                  child: FolioFadeSlide(
                    beginOffset: const Offset(0, 0.5),
                    beginScale: 0.9,
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    child: EngravedButton(
                      label: l10n.t(L10nKey.chatActionJumpLatest),
                      compact: true,
                      onPressed: _jumpToLatest,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeedContent(
    BuildContext context,
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    if (ctrl.searchQuery.isNotEmpty) {
      return _buildSearchResults(theme, l10n, ctrl);
    }

    final visibleNodes = ctrl.visibleBranchNodes;
    if (visibleNodes.isEmpty && !ctrl.isStreaming) {
      // Only messages are selectable; clicks on the empty page select nothing.
      return SelectionContainer.disabled(
        child: _buildWelcomeDesk(theme, l10n, ctrl),
      );
    }

    final activeProv = ctrl.activeProvider;
    final itemCount = visibleNodes.length + (ctrl.isStreaming ? 1 : 0);
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverToBoxAdapter(
          child: ctrl.hasEarlierNodes
              ? EarlierMessagesButton(controller: ctrl)
              : const SizedBox(height: 12),
        ),
        SliverList.builder(
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (index >= visibleNodes.length) {
              // Finished rows already sit in the feed's checklist. Tool rows change only with
              // a controller notify, so they are filtered here, never once per delta batch.
              final liveToolRows = uncommittedToolRows(
                ctrl.toolActivities,
                visibleNodes,
              );
              // Leaf-isolated live reply: only this subtree rebuilds per 16 ms delta batch.
              return _ReadingColumn(
                child: RepaintBoundary(
                  child: ValueListenableBuilder<LiveTurn?>(
                    valueListenable: ctrl.liveTurn,
                    builder: (context, turn, _) => _StreamingPassageCard(
                      assistantName:
                          ctrl.activeAssistant?.name ??
                          l10n.t(L10nKey.shellRoleAssistant),
                      provider: activeProv,
                      modelId: ctrl.activeModelId,
                      buffer: turn?.text ?? '',
                      thinkingBuffer: turn?.thinking ?? '',
                      toolActivities: liveToolRows,
                      layoutMode: ctrl.layoutMode,
                      prefs: ctrl.uiPrefs,
                      reduceMotionOverride: ctrl.reduceMotionOverride,
                      onCopyCode: (code) => unawaited(ctrl.copyText(code)),
                      onQuoteThinking: widget.onReplyToPassage,
                      onApproveToolOnce: (callId) => unawaited(
                        ctrl.respondToolApproval(callId, 'approve_once'),
                      ),
                      onApproveToolChat: (callId) => unawaited(
                        ctrl.respondToolApproval(callId, 'approve_for_thread'),
                      ),
                      onDenyTool: (callId) =>
                          unawaited(ctrl.respondToolApproval(callId, 'deny')),
                      onStopTool: (callId) =>
                          unawaited(ctrl.respondToolApproval(callId, 'stop')),
                      onRewindCheckpoint: (cpId) =>
                          unawaited(ctrl.rewindCheckpoint(cpId)),
                    ),
                  ),
                ),
              );
            }

            final node = visibleNodes[index];
            final asked = askUserQuestionOf(visibleNodes, index);
            if (asked != null) {
              final open =
                  index + 1 == visibleNodes.length && !ctrl.isStreaming;
              return _ReadingColumn(
                child: AskUserCard(
                  question: asked,
                  onAnswer: open
                      ? (option) => unawaited(ctrl.submitPassage(option))
                      : null,
                ),
              );
            }
            if (isToolStepNode(node)) {
              // A run of tool steps shows once, as one checklist, at its first node.
              if (!startsToolSteps(visibleNodes, index)) {
                return const SizedBox.shrink();
              }
              return _ReadingColumn(
                child: RepaintBoundary(
                  child: ToolTimelineView(
                    entries: committedToolEntries(
                      visibleNodes,
                      index,
                      withThinking: ctrl.uiPrefs.showThinkingCards,
                    ),
                    collapsed: true,
                    onRewindCheckpoint: (cpId) =>
                        unawaited(ctrl.rewindCheckpoint(cpId)),
                  ),
                ),
              );
            }
            if (node.role == 'compaction_summary') {
              return _ReadingColumn(
                child: RepaintBoundary(
                  child: _CompactionSummaryCard(node: node, ctrl: ctrl),
                ),
              );
            }

            if (node.role == 'user' && (node.usageMeta?.goalCheck ?? false)) {
              return const _ReadingColumn(child: _GoalCheckNote());
            }
            final branchInfo = ctrl.branchInfoFor(node);
            final isLast = index + 1 == itemCount;
            final isPinnedStart = ctrl.pinnedContextNodeId == node.id;
            return _ReadingColumn(
              key: node.id == _revealNodeId ? _revealKey : null,
              child: RepaintBoundary(
                key: ValueKey<String>(node.id),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isPinnedStart)
                      _PinnedContextBanner(
                        onClear: () =>
                            unawaited(ctrl.toggleContextStartPin(node.id)),
                      ),
                    _PassageItem(
                      node: node,
                      onOpenAttachment: ctrl.openSentAttachment,
                      attachmentPath: ctrl.sentAttachmentPath,
                      userName: ctrl.settings.userDisplayName.trim(),
                      userAvatarPath: ctrl.profileAvatarPath,
                      assistantName:
                          ctrl.activeAssistant?.name ??
                          l10n.t(L10nKey.shellRoleAssistant),
                      activeProvider: activeProv,
                      layoutMode: ctrl.layoutMode,
                      showTokenMetrics: ctrl.showTokenMetrics,
                      prefs: ctrl.uiPrefs,
                      editorialDialogueStyling:
                          ctrl.activeThreadMode == 'write' &&
                          ctrl.storyState.dialogueStyling,
                      isPinnedContextStart: isPinnedStart,
                      branchInfo: branchInfo,
                      showBottomDivider: !isLast && node.role == 'assistant',
                      reduceMotionOverride: ctrl.reduceMotionOverride,
                      showActionsAtRest:
                          // No hover on touch: the newest turns show their actions.
                          isTouchPlatform && index + 2 >= itemCount,
                      onCopy: () => unawaited(ctrl.copyText(node.content)),
                      onCopyPlain: node.content.trim().isEmpty
                          ? null
                          : () => unawaited(
                              ctrl.copyText(markdownToPlainText(node.content)),
                            ),
                      onBranchNewChat: !ctrl.isStreaming
                          ? () => unawaited(ctrl.branchIntoNewChat(node.id))
                          : null,
                      onSaveAsSkill:
                          node.role == 'assistant' &&
                              node.content.trim().isNotEmpty
                          ? () => unawaited(ctrl.saveReplyAsSkill(node))
                          : null,
                      onCopyCode: (code) => unawaited(ctrl.copyText(code)),
                      onSaveCode: (code, language) => ctrl.saveCodeBlock(
                        code,
                        language,
                        saveTitle: l10n.t(L10nKey.chatCodeSave),
                      ),
                      onReply: () => widget.onReplyToPassage(node.content),
                      onQuoteThinking: widget.onReplyToPassage,
                      onToggleContextPin: !ctrl.isStreaming
                          ? () => unawaited(ctrl.toggleContextStartPin(node.id))
                          : null,
                      isPinnedReply: ctrl.isNodePinned(node.id),
                      onTogglePinReply: () =>
                          unawaited(ctrl.togglePinNode(node.id)),
                      onInspectTurnDetails: () => ctrl.openTurnDetails(node),
                      onTranslate:
                          !ctrl.isStreaming && node.content.trim().isNotEmpty
                          ? () => unawaited(ctrl.translateMessage(node))
                          : null,
                      sourceCount: node.role == 'assistant'
                          ? ctrl.groundingFor(node.id).length
                          : 0,
                      isSpeaking: ctrl.speakingNodeId == node.id,
                      onSpeak: node.role == 'assistant'
                          ? () => unawaited(
                              ctrl.speakAssistantMessage(node.id, node.content),
                            )
                          : null,
                      onEditResend: node.role == 'user' && !ctrl.isStreaming
                          ? (edited) =>
                                ctrl.editUserMessageAndResend(node.id, edited)
                          : null,
                      onEditReply: node.role == 'assistant' && !ctrl.isStreaming
                          ? (edited) =>
                                ctrl.editReplyAsNewVersion(node.id, edited)
                          : null,
                      isExcluded: ctrl.isExcluded(node.id),
                      onToggleExcluded: !ctrl.isStreaming
                          ? () => unawaited(ctrl.toggleNodeExcluded(node.id))
                          : null,
                      onRegenerate:
                          node.role == 'assistant' && !ctrl.isStreaming
                          ? () => unawaited(
                              ctrl.regenerateFromAssistantNode(node),
                            )
                          : null,
                      onDelete: !ctrl.isStreaming
                          ? () => unawaited(ctrl.deleteMessageNode(node.id))
                          : null,
                      onBranchDelta: branchInfo != null
                          ? (delta) {
                              ctrl.selectSiblingBranch(
                                branchInfo.parentKey,
                                delta,
                              );
                              // Smooth programmatic glide when switching sibling branch (DESIGN §6).
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted || !_scrollController.hasClients) {
                                  return;
                                }
                                final pos = _scrollController.position;
                                if (pos.pixels > pos.maxScrollExtent) {
                                  _jumpToLatest();
                                }
                              });
                            }
                          : null,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: BistreSpacing.s24)),
      ],
    );
  }

  Widget _buildSearchResults(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: BistreSpacing.s12)),
        SliverList.builder(
          itemCount: ctrl.searchHits.length,
          itemBuilder: (context, index) {
            final hit = ctrl.searchHits[index];
            final roleLabel = hit.role == 'assistant'
                ? l10n.t(L10nKey.shellRoleAssistant)
                : l10n.t(L10nKey.shellRoleUser);
            return _ReadingColumn(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  bottom: BistreSpacing.s8,
                ),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: PressFeedback(
                    pressScale: kRowPressScale,
                    hoverScale: 1,
                    child: GestureDetector(
                      onTap: () => widget.onSelectSearchHit(hit),
                      child: FolioSurface(
                        tone: FolioTone.elevated,
                        boxShadow: theme.cardShadow,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                BistreIcon(
                                  BistreUiIcon.search,
                                  size: 13,
                                  color: theme.accentBrass,
                                ),
                                const SizedBox(width: 6),
                                InkText(
                                  roleLabel,
                                  role: InkTextRole.captionMeta,
                                  color: theme.accentBrass,
                                ),
                              ],
                            ),
                            const SizedBox(height: BistreSpacing.s4),
                            InkText(hit.snippet, role: InkTextRole.bodyCompact),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildWelcomeDesk(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    // Quiet empty chat: one rubric-marked line (the header already names the model) at the top
    // of the reading column; without a key, one setup card. Opening a new chat is a 100+/day
    // action, so nothing animates in.
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsetsDirectional.fromSTEB(
        0,
        48,
        0,
        BistreSpacing.s16,
      ),
      child: _ReadingColumn(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: rubricMark(theme),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  BistreSpacing.s12,
                  BistreSpacing.s4,
                  BistreSpacing.s8,
                  BistreSpacing.s4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkText(
                      l10n.t(L10nKey.chatEmptyIntro),
                      role: InkTextRole.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
            if (!ctrl.hasConfiguredProvider) ...[
              const SizedBox(height: BistreSpacing.s24),
              _ProviderSetupBanner(onOpenProviders: ctrl.openSettings),
            ],
          ],
        ),
      ),
    );
  }
}
