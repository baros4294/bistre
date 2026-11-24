import 'dart:async';

import 'package:flutter/foundation.dart';
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
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import '../shell/live_turn_notifier.dart';
import 'code_wrap_scope.dart';
import 'cost_unavailable_button.dart';
import 'markdown_folio_view.dart';
import 'message_nav_rail.dart';
import 'reasoning_block.dart';
import 'tool_timeline_view.dart';
import 'usage_details_pill.dart';

part 'folio_message_cards.dart';

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
  late int _lastNodeCount;
  late int _lastStreamLen;
  String? _lastThreadId;

  @override
  void initState() {
    super.initState();
    _lastNodeCount = widget.controller.visibleBranchNodes.length;
    _lastStreamLen = widget.controller.streamingBuffer.length;
    _lastThreadId = widget.controller.activeThread?.id;
    widget.controller.addListener(_onControllerUpdated);
    widget.controller.liveTurn.addListener(_onLiveTurnGrew);
    _scrollController.addListener(_onScrollPositionChanged);
    if (widget.controller.visibleBranchNodes.isNotEmpty) {
      _anchorAtBottom();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdated);
    widget.controller.liveTurn.removeListener(_onLiveTurnGrew);
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

  /// Follows the live reply without rebuilding the feed (leaf notifier, no setState).
  void _onLiveTurnGrew() {
    final len = widget.controller.liveTurn.value?.text.length ?? 0;
    final grew = len > _lastStreamLen;
    _lastStreamLen = len;
    if (!grew || !_autoFollow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _onControllerUpdated() {
    final ctrl = widget.controller;
    final threadId = ctrl.activeThread?.id;
    final visibleCount = ctrl.visibleBranchNodes.length;
    final streamLen = ctrl.streamingBuffer.length;

    if (threadId != _lastThreadId) {
      _lastThreadId = threadId;
      _lastNodeCount = visibleCount;
      _lastStreamLen = streamLen;
      _autoFollow = true;
      _codeWrapOverrides.clear();
      _anchorAtBottom();
      return;
    }

    final grew = visibleCount > _lastNodeCount || streamLen > _lastStreamLen;
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
    if (distFromBottom < 24 && !_autoFollow) {
      _autoFollow = true;
    }
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
      return _buildWelcomeDesk(theme, l10n, ctrl);
    }

    final activeProv = ctrl.activeProvider;
    final itemCount = visibleNodes.length + (ctrl.isStreaming ? 1 : 0);
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverList.builder(
          itemCount: itemCount,
          itemBuilder: (context, index) {
            if (index >= visibleNodes.length) {
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
                      toolActivities: ctrl.toolActivities,
                      layoutMode: ctrl.layoutMode,
                      reduceMotionOverride: ctrl.reduceMotionOverride,
                      onCopyCode: (code) => unawaited(ctrl.copyText(code)),
                      onQuoteThinking: widget.onReplyToPassage,
                      onRewindCheckpoint: (cpId) =>
                          unawaited(ctrl.rewindCheckpoint(cpId)),
                    ),
                  ),
                ),
              );
            }

            final node = visibleNodes[index];
            if (node.role == 'compaction_summary') {
              return _ReadingColumn(
                child: RepaintBoundary(
                  child: _CompactionSummaryCard(
                    node: node,
                    onUndo: !ctrl.isStreaming
                        ? () => unawaited(ctrl.undoCompaction(node.id))
                        : null,
                  ),
                ),
              );
            }

            final branchInfo = ctrl.branchInfoFor(node);
            final isLast = index + 1 == itemCount;
            final isPinnedStart = ctrl.pinnedContextNodeId == node.id;
            return _ReadingColumn(
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
                      userName: ctrl.settings.userDisplayName.trim(),
                      assistantName:
                          ctrl.activeAssistant?.name ??
                          l10n.t(L10nKey.shellRoleAssistant),
                      activeProvider: activeProv,
                      layoutMode: ctrl.layoutMode,
                      showTokenMetrics: ctrl.showTokenMetrics,
                      editorialDialogueStyling:
                          ctrl.activeThreadMode == 'write' &&
                          ctrl.storyState.dialogueStyling,
                      isPinnedContextStart: isPinnedStart,
                      branchInfo: branchInfo,
                      showBottomDivider: !isLast && node.role == 'assistant',
                      reduceMotionOverride: ctrl.reduceMotionOverride,
                      showActionsAtRest:
                          _isTouchPlatform && index + 2 >= itemCount,
                      onCopy: () => unawaited(ctrl.copyText(node.content)),
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
                      onEditResend: node.role == 'user' && !ctrl.isStreaming
                          ? (edited) =>
                                ctrl.editUserMessageAndResend(node.id, edited)
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
    final activeProv = ctrl.activeProvider;
    final activeModel = ctrl.activeModelId;
    // Quiet empty chat: one rubric-marked line with the model beneath it at the top
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
                    if (ctrl.hasConfiguredProvider &&
                        activeProv != null &&
                        activeModel.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      InkText(
                        activeModel,
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
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

/// Phones and tablets (no hover): actions stay visible on the newest turns.
bool get _isTouchPlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

class _PassageItem extends StatefulWidget {
  const _PassageItem({
    required this.node,
    this.userName = '',
    required this.assistantName,
    required this.activeProvider,
    required this.layoutMode,
    required this.showTokenMetrics,
    this.editorialDialogueStyling = false,
    this.isPinnedContextStart = false,
    required this.branchInfo,
    required this.showBottomDivider,
    required this.reduceMotionOverride,
    this.showActionsAtRest = false,
    required this.onCopy,
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
  });

  final EngineNode node;

  /// Settings > Your name; empty shows the plain `You` label.
  final String userName;
  final String assistantName;
  final EngineProvider? activeProvider;
  final FolioLayoutMode layoutMode;
  final bool showTokenMetrics;
  final bool editorialDialogueStyling;
  final bool isPinnedContextStart;
  final bool isPinnedReply;
  final BranchSlotInfo? branchInfo;
  final bool showBottomDivider;
  final bool reduceMotionOverride;

  /// Touch screens have no hover: the newest turns keep their actions visible.
  final bool showActionsAtRest;
  final VoidCallback onCopy;
  final ValueChanged<String> onCopyCode;
  final Future<void> Function(String code, String language) onSaveCode;
  final VoidCallback onReply;
  final ValueChanged<String> onQuoteThinking;
  final VoidCallback? onToggleContextPin;
  final VoidCallback? onTogglePinReply;
  final VoidCallback? onInspectTurnDetails;
  final Future<bool> Function(String edited)? onEditResend;
  final VoidCallback? onRegenerate;
  final VoidCallback? onDelete;
  final ValueChanged<int>? onBranchDelta;

  @override
  State<_PassageItem> createState() => _PassageItemState();
}

class _PassageItemState extends State<_PassageItem> {
  bool _hovered = false;
  bool _focused = false;
  bool _editing = false;
  bool _moreActionsOpen = false;
  final TextEditingController _editCtrl = TextEditingController();
  final FocusNode _editFocus = FocusNode();

  @override
  void dispose() {
    _editCtrl.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _startEdit() {
    _editCtrl.text = widget.node.content;
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  Future<void> _submitEdit() async {
    final cb = widget.onEditResend;
    if (cb == null) return;
    final ok = await cb(_editCtrl.text);
    if (ok && mounted) {
      setState(() => _editing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final isAssistant = widget.node.role == 'assistant';
    final speaker = isAssistant
        ? widget.assistantName
        : widget.userName.isNotEmpty
        ? widget.userName
        : l10n.t(L10nKey.shellRoleUser);
    final usage = isAssistant ? widget.node.usageMeta : null;
    final actionBar = _buildActionBar(theme, l10n, isAssistant);

    final contentBody = _editing
        ? _buildInlineEditor(theme, l10n)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isAssistant && usage != null && usage.hasThinking)
                ReasoningBlock(
                  thinkingText: usage.thinkingText,
                  durationMs: usage.thinkingDurationMs,
                  onQuoteIntoComposer: widget.onQuoteThinking,
                ),
              MarkdownFolioView(
                onSaveCode: (code, language) =>
                    unawaited(widget.onSaveCode(code, language)),
                markdown: widget.node.content,
                onCopyCode: widget.onCopyCode,
                editorialDialogueStyling: widget.editorialDialogueStyling,
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

    final Widget inner;
    if (widget.layoutMode == FolioLayoutMode.bubbles) {
      if (isAssistant) {
        inner = Padding(
          padding: const EdgeInsetsDirectional.symmetric(vertical: 6),
          child: FolioSurface(
            tone: FolioTone.elevated,
            padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 14),
            borderRadius: 14,
            boxShadow: theme.cardShadow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSpeakerHeader(theme, speaker, true, usage, actionBar),
                const SizedBox(height: 8),
                contentBody,
              ],
            ),
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
              child: FolioSurface(
                padding: const EdgeInsetsDirectional.fromSTEB(15, 10, 15, 10),
                customBorderRadius: const BorderRadiusDirectional.only(
                  topStart: Radius.circular(16),
                  topEnd: Radius.circular(4),
                  bottomStart: Radius.circular(16),
                  bottomEnd: Radius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSpeakerHeader(theme, speaker, false, null, actionBar),
                    const SizedBox(height: 4),
                    contentBody,
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
            : _menuEntries(l10n, isAssistant),
        child: inner,
      ),
    );
  }

  /// Right-click menu mirroring the message action bar plus pin & turn details.
  List<ContextMenuEntry> _menuEntries(
    BistreLocalizationController l10n,
    bool isAssistant,
  ) {
    final w = widget;
    final edit = w.onEditResend;
    final regenerate = w.onRegenerate;
    final pin = w.onToggleContextPin;
    final pinReply = w.onTogglePinReply;
    final inspectTurn = w.onInspectTurnDetails;
    final delete = w.onDelete;
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
      if (pinReply != null)
        ContextMenuEntry(
          label: w.isPinnedReply
              ? l10n.t(L10nKey.chatUnpinReply)
              : l10n.t(L10nKey.chatPinReply),
          icon: w.isPinnedReply ? BistreUiIcon.pinFilled : BistreUiIcon.pin,
          onSelected: pinReply,
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
          icon: w.isPinnedContextStart
              ? BistreUiIcon.pinFilled
              : BistreUiIcon.pin,
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

  Widget _buildInlineEditor(
    BistreThemeData theme,
    BistreLocalizationController l10n,
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
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            EngravedButton(
              label: l10n.t(L10nKey.threadCancel),
              compact: true,
              onPressed: () => setState(() => _editing = false),
            ),
            const SizedBox(width: 8),
            EngravedButton(
              label: l10n.t(L10nKey.chatActionSaveResend),
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
    final parts = <String>[];
    if (usage.modelId.isNotEmpty) {
      parts.add(usage.modelId);
    }
    if (usage.hasTokens) {
      parts.add(
        l10n.t(L10nKey.chatTokensMeta, <String, Object?>{
          'input': usage.inputTokens,
          'output': usage.outputTokens,
        }),
      );
    }
    if (usage.costMicros > 0) {
      parts.add(
        FolioController.formatMicrosUsd(usage.costMicros, showSubCent: true),
      );
    }
    if (parts.isEmpty) return const SizedBox.shrink();

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
              summaryText: l10n.joinMeta(parts),
              reduceMotionOverride: widget.reduceMotionOverride,
            ),
          ),
        ),
        if (!usage.costKnown && usage.hasTokens)
          CostUnavailableButton(usage: usage),
      ],
    );
  }

  Widget _buildSpeakerHeader(
    BistreThemeData theme,
    String speaker,
    bool isAssistant,
    NodeUsageMeta? usage,
    Widget actionBar,
  ) {
    return Row(
      children: [
        if (isAssistant)
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
        else
          BistreIcon(BistreUiIcon.edit, size: 14, color: theme.accentBrass),
        const SizedBox(width: BistreSpacing.s8),
        Expanded(
          child: InkText(
            speaker,
            role: InkTextRole.labelStrong,
            color: isAssistant ? theme.inkPrimary : theme.inkSecondary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actionBar,
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
        widget.showActionsAtRest;

    return AnimatedOpacity(
      opacity: alwaysShow ? 1.0 : 0.0,
      duration: BistreMotion.overlayDuration(
        context,
        reduceMotionOverride: widget.reduceMotionOverride,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
          if (widget.onRegenerate != null)
            BistreIconButton(
              icon: BistreUiIcon.refresh,
              size: 14,
              dimension: 28,
              semanticsLabel: l10n.t(L10nKey.chatActionRegenerate),
              onPressed: widget.onRegenerate,
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
            if (widget.onInspectTurnDetails != null)
              BistreIconButton(
                icon: BistreUiIcon.info,
                size: 13,
                dimension: 28,
                semanticsLabel: l10n.t(L10nKey.chatTurnDetails),
                onPressed: widget.onInspectTurnDetails,
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
    );
  }
}
