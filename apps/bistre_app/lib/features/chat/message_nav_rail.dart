import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/hover_hint.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Floating vertical message navigation rail on the trailing edge of the conversation feed:
/// `Jump to top`, `Previous turn`, `Next turn`, `Jump to latest`, and `Conversation map`
/// opening a filterable, keyboard-navigable `Message Map (N/N)` popover.
class MessageNavRail extends StatefulWidget {
  const MessageNavRail({
    super.key,
    required this.nodes,
    required this.visible,
    required this.onJumpTop,
    required this.onJumpPrev,
    required this.onJumpNext,
    required this.onJumpLatest,
    required this.onJumpToIndex,
    this.reduceMotionOverride = false,
  });

  final List<EngineNode> nodes;
  final bool visible;
  final VoidCallback onJumpTop;
  final VoidCallback onJumpPrev;
  final VoidCallback onJumpNext;
  final VoidCallback onJumpLatest;
  final ValueChanged<int> onJumpToIndex;
  final bool reduceMotionOverride;

  @override
  State<MessageNavRail> createState() => _MessageNavRailState();
}

class _MessageNavRailState extends State<MessageNavRail> {
  final FolioOverlayController _mapOverlay = FolioOverlayController();
  final LayerLink _mapLink = LayerLink();
  final TextEditingController _filterCtrl = TextEditingController();
  final FocusNode _filterFocus = FocusNode();
  bool _promptsOnly = false;
  int _selectedRow = 0;

  @override
  void dispose() {
    _filterCtrl.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  List<(int, EngineNode)> _filteredEntries() {
    final q = _filterCtrl.text.trim().toLowerCase();
    final out = <(int, EngineNode)>[];
    for (var i = 0; i < widget.nodes.length; i++) {
      final n = widget.nodes[i];
      if (_promptsOnly && n.role != 'user') continue;
      if (q.isNotEmpty && !n.content.toLowerCase().contains(q)) continue;
      out.add((i, n));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nodes.length < 2) return const SizedBox.shrink();
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final showRail = widget.visible || _mapOverlay.isShowing;

    return IgnorePointer(
      ignoring: !showRail,
      child: AnimatedOpacity(
        opacity: showRail ? 1.0 : 0.0,
        duration: BistreMotion.overlayDuration(
          context,
          reduceMotionOverride: widget.reduceMotionOverride,
        ),
        child: FolioOverlay(
          controller: _mapOverlay,
          overlayBuilder: _buildMapPopover,
          child: CompositedTransformTarget(
            link: _mapLink,
            child: FolioSurface(
              tone: FolioTone.elevated,
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 3,
                vertical: 4,
              ),
              borderRadius: 12,
              boxShadow: theme.cardShadow,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HoverHint(
                    message: l10n.t(L10nKey.chatNavTop),
                    child: BistreIconButton(
                      icon: BistreUiIcon.chevronUp,
                      size: 13,
                      dimension: 28,
                      semanticsLabel: l10n.t(L10nKey.chatNavTop),
                      onPressed: widget.onJumpTop,
                    ),
                  ),
                  HoverHint(
                    message: l10n.t(L10nKey.chatNavPrev),
                    child: BistreIconButton(
                      icon: BistreUiIcon.arrowBack,
                      size: 12,
                      dimension: 28,
                      semanticsLabel: l10n.t(L10nKey.chatNavPrev),
                      onPressed: widget.onJumpPrev,
                    ),
                  ),
                  HoverHint(
                    message: l10n.t(L10nKey.chatNavMap),
                    child: BistreIconButton(
                      icon: BistreUiIcon.branchTree,
                      size: 13,
                      dimension: 28,
                      active: _mapOverlay.isShowing,
                      semanticsLabel: l10n.t(L10nKey.chatNavMap),
                      onPressed: () {
                        _selectedRow = 0;
                        _mapOverlay.toggle();
                        if (_mapOverlay.isShowing) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _filterFocus.requestFocus();
                          });
                        }
                      },
                    ),
                  ),
                  HoverHint(
                    message: l10n.t(L10nKey.chatNavNext),
                    child: BistreIconButton(
                      icon: BistreUiIcon.chevronEnd,
                      size: 12,
                      dimension: 28,
                      semanticsLabel: l10n.t(L10nKey.chatNavNext),
                      onPressed: widget.onJumpNext,
                    ),
                  ),
                  HoverHint(
                    message: l10n.t(L10nKey.chatJumpToLatest),
                    child: BistreIconButton(
                      icon: BistreUiIcon.chevronDown,
                      size: 13,
                      dimension: 28,
                      semanticsLabel: l10n.t(L10nKey.chatJumpToLatest),
                      onPressed: widget.onJumpLatest,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMapPopover(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final dir = Directionality.of(context);
    final entries = _filteredEntries();
    if (_selectedRow >= entries.length) {
      _selectedRow = entries.isEmpty ? 0 : entries.length - 1;
    }

    final mapTitle =
        '${l10n.t(L10nKey.chatNavMap)} (${entries.length}/${widget.nodes.length})';
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _mapOverlay.hide,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _mapLink,
          showWhenUnlinked: false,
          targetAnchor: AlignmentDirectional.centerStart.resolve(dir),
          followerAnchor: AlignmentDirectional.centerEnd.resolve(dir),
          offset: Offset(dir == TextDirection.rtl ? 10 : -10, 0),
          child: Focus(
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.escape) {
                _mapOverlay.hide();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
                  entries.isNotEmpty) {
                setState(
                  () => _selectedRow = (_selectedRow + 1) % entries.length,
                );
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                  entries.isNotEmpty) {
                setState(
                  () => _selectedRow =
                      (_selectedRow - 1 + entries.length) % entries.length,
                );
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.enter &&
                  entries.isNotEmpty) {
                final targetIdx = entries[_selectedRow].$1;
                _mapOverlay.hide();
                widget.onJumpToIndex(targetIdx);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: FolioFadeSlide(
              beginOffset: const Offset(0.04, 0),
              reduceMotionOverride: widget.reduceMotionOverride,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: 280,
                  maxWidth: 340,
                  maxHeight: 420,
                ),
                child: FolioSurface(
                  tone: FolioTone.elevated,
                  boxShadow: theme.floatingShadow,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: InkText(
                              mapTitle,
                              role: InkTextRole.labelStrong,
                            ),
                          ),
                          InkChip(
                            label: l10n.t(L10nKey.chatNavPromptsOnly),
                            selected: _promptsOnly,
                            onSelected: () => setState(() {
                              _promptsOnly = !_promptsOnly;
                              _selectedRow = 0;
                            }),
                          ),
                          const SizedBox(width: 4),
                          BistreIconButton(
                            icon: BistreUiIcon.close,
                            size: 12,
                            dimension: 24,
                            semanticsLabel: l10n.t(L10nKey.threadCancel),
                            onPressed: _mapOverlay.hide,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      QuillInput(
                        controller: _filterCtrl,
                        focusNode: _filterFocus,
                        placeholder: l10n.t(L10nKey.chatNavFilterPlaceholder),
                        maxLines: 1,
                        compact: true,
                        submitOnEnter: false,
                        onChanged: (_) => setState(() => _selectedRow = 0),
                        onSubmitted: () {
                          if (entries.isNotEmpty) {
                            final idx = entries[_selectedRow].$1;
                            _mapOverlay.hide();
                            widget.onJumpToIndex(idx);
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      const FolioDivider(),
                      const SizedBox(height: 4),
                      Flexible(
                        child: entries.isEmpty
                            ? Padding(
                                padding: const EdgeInsetsDirectional.all(14),
                                child: InkText(
                                  l10n.t(L10nKey.sidebarEmptyFiltered),
                                  role: InkTextRole.captionMeta,
                                  color: theme.inkMuted,
                                ),
                              )
                            : SmoothScrollable(
                                builder: (_, scroll) => ListView.builder(
                                  controller: scroll,
                                  shrinkWrap: true,
                                  itemCount: entries.length,
                                  itemBuilder: (context, rowIdx) {
                                    final (nodeIdx, node) = entries[rowIdx];
                                    final isUser = node.role == 'user';
                                    final turnNum = '#${nodeIdx + 1}';
                                    final rawPreview = node.content
                                        .replaceAll('\n', ' ')
                                        .trim();
                                    final preview = rawPreview.isEmpty
                                        ? l10n.t(L10nKey.chatEmptyIntro)
                                        : rawPreview;
                                    final selected = rowIdx == _selectedRow;
                                    return MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      onEnter: (_) =>
                                          setState(() => _selectedRow = rowIdx),
                                      child: PressFeedback(
                                        pressScale: kRowPressScale,
                                        hoverScale: 1,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            _mapOverlay.hide();
                                            widget.onJumpToIndex(nodeIdx);
                                          },
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: selected
                                                  ? theme.hoverTint
                                                  : null,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsetsDirectional.symmetric(
                                                    horizontal: 8,
                                                    vertical: 6,
                                                  ),
                                              child: Row(
                                                children: [
                                                  InkText(
                                                    turnNum,
                                                    role:
                                                        InkTextRole.captionMeta,
                                                    color: isUser
                                                        ? theme.accentBrass
                                                        : theme.inkMuted,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  InkText(
                                                    isUser
                                                        ? l10n.t(
                                                            L10nKey
                                                                .shellRoleUser,
                                                          )
                                                        : l10n.t(
                                                            L10nKey
                                                                .shellRoleAssistant,
                                                          ),
                                                    role:
                                                        InkTextRole.labelStrong,
                                                    color: isUser
                                                        ? theme.accentBrass
                                                        : theme.inkSecondary,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: InkText(
                                                      preview,
                                                      role: InkTextRole
                                                          .captionMeta,
                                                      color: theme.inkPrimary,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
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
