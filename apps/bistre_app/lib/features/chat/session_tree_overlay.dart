import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import 'plain_preview.dart';

/// Visual DAG Session Tree / Undo Tree & `Ctrl+Alt+G` Jump-to-Earlier-Prompt overlay.
/// Displays every turn and sibling fork in the active thread so users can inspect branches
/// or jump cleanly to any earlier prompt without losing history.
class SessionTreeOverlay extends StatefulWidget {
  const SessionTreeOverlay({
    super.key,
    required this.controller,
    required this.onClose,
    this.onlyUserPrompts = false,
  });

  final FolioController controller;
  final VoidCallback onClose;
  final bool onlyUserPrompts;

  @override
  State<SessionTreeOverlay> createState() => _SessionTreeOverlayState();
}

class _SessionTreeOverlayState extends State<SessionTreeOverlay> {
  final TextEditingController _filterCtrl = TextEditingController();
  final FocusNode _filterFocus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final visibleIds = ctrl.visibleBranchNodes.map((n) => n.id).toSet();
    final allNodes = ctrl.allThreadNodes;

    final filtered = allNodes
        .where((n) {
          if (widget.onlyUserPrompts && n.role != 'user') return false;
          if (_query.isEmpty) return true;
          return n.content.toLowerCase().contains(_query);
        })
        .toList(growable: false);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            child: ColoredBox(color: theme.scrim.withValues(alpha: 0.48)),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620, maxHeight: 540),
            child: FolioSurface(
              tone: FolioTone.elevated,
              padding: const EdgeInsetsDirectional.all(16),
              borderRadius: 14,
              boxShadow: theme.floatingShadow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.branchTree,
                        size: 16,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InkText(
                          widget.onlyUserPrompts
                              ? l10n.t(L10nKey.chatTreeJumpPrompt)
                              : l10n.t(L10nKey.chatTreeTitle),
                          role: InkTextRole.titleMedium,
                        ),
                      ),
                      BistreIconButton(
                        icon: BistreUiIcon.close,
                        size: 14,
                        dimension: 28,
                        semanticsLabel: l10n.t(L10nKey.settingsClose),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  QuillInput(
                    controller: _filterCtrl,
                    focusNode: _filterFocus,
                    placeholder: l10n.t(L10nKey.shellSearchPlaceholder),
                    maxLines: 1,
                    compact: true,
                    onSubmitted: () {},
                    onChanged: (v) =>
                        setState(() => _query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 10),
                  const FolioDivider(),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: InkText(
                              l10n.t(L10nKey.chatTreeEmpty),
                              role: InkTextRole.bodyCompact,
                              color: theme.inkMuted,
                            ),
                          )
                        : SmoothScrollable(
                            builder: (_, scroll) => ListView.builder(
                              controller: scroll,
                              itemCount: filtered.length,
                              itemBuilder: (context, idx) {
                                final node = filtered[idx];
                                final onActivePath = visibleIds.contains(
                                  node.id,
                                );
                                final depth = _depthOf(node, allNodes);
                                return _TreeNodeRow(
                                  node: node,
                                  depth: depth,
                                  onActivePath: onActivePath,
                                  summary: plainPreview(node.content),
                                  // The same names the chat shows.
                                  roleLabel: node.role == 'assistant'
                                      ? ctrl.activeAssistant?.name ??
                                            l10n.t(L10nKey.shellRoleAssistant)
                                      : node.role == 'compaction_summary'
                                      ? l10n.t(L10nKey.chatCompactedTitle)
                                      : ctrl.settings.userDisplayName
                                            .trim()
                                            .isNotEmpty
                                      ? ctrl.settings.userDisplayName.trim()
                                      : l10n.t(L10nKey.shellRoleUser),
                                  onSelect: () {
                                    ctrl.focusBranchNode(node.id);
                                    widget.onClose();
                                  },
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
      ],
    );
  }

  static int _depthOf(EngineNode node, List<EngineNode> all) {
    final byId = <String, EngineNode>{for (final n in all) n.id: n};
    var depth = 0;
    var cursor = node.parentId;
    while (cursor != null && depth < 12) {
      depth++;
      cursor = byId[cursor]?.parentId;
    }
    return depth;
  }
}

class _TreeNodeRow extends StatefulWidget {
  const _TreeNodeRow({
    required this.node,
    required this.depth,
    required this.onActivePath,
    required this.summary,
    required this.roleLabel,
    required this.onSelect,
  });

  final EngineNode node;
  final int depth;
  final bool onActivePath;
  final String summary;
  final String roleLabel;
  final VoidCallback onSelect;

  @override
  State<_TreeNodeRow> createState() => _TreeNodeRowState();
}

class _TreeNodeRowState extends State<_TreeNodeRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final indent = (widget.depth.clamp(0, 4) * 14).toDouble();

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(indent, 3, 0, 3),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: PressFeedback(
          pressScale: kRowPressScale,
          hoverScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSelect,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _hovered
                    ? theme.hoverTint
                    : widget.onActivePath
                    ? theme.bgSurface.withValues(alpha: 0.72)
                    : null,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: widget.onActivePath
                      ? theme.accentBrass.withValues(alpha: 0.55)
                      : theme.borderHairline.withValues(alpha: 0.6),
                ),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 7,
                      height: 7,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.onActivePath
                              ? theme.accentBrass
                              : theme.inkMuted.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkText(
                            widget.roleLabel,
                            role: InkTextRole.captionMeta,
                            color: widget.onActivePath
                                ? theme.accentBrass
                                : theme.inkMuted,
                          ),
                          const SizedBox(height: 2),
                          InkText(
                            widget.summary,
                            role: InkTextRole.bodyCompact,
                            color: theme.inkPrimary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
