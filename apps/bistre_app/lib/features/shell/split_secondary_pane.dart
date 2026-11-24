import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import 'folio_controller.dart';

/// Side-by-side Split View secondary reference pane on wide desktop screens:
/// lets the user compare another chat thread beside the active workspace.
class SplitSecondaryPane extends StatefulWidget {
  const SplitSecondaryPane({super.key, required this.controller});

  final FolioController controller;

  @override
  State<SplitSecondaryPane> createState() => _SplitSecondaryPaneState();
}

class _SplitSecondaryPaneState extends State<SplitSecondaryPane> {
  String? _loadedThreadId;
  List<EngineNode> _nodes = const <EngineNode>[];

  @override
  void initState() {
    super.initState();
    _syncNodes();
  }

  @override
  void didUpdateWidget(SplitSecondaryPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncNodes();
  }

  void _syncNodes() {
    final tid = widget.controller.splitSecondaryThreadId;
    if (tid == null || tid == _loadedThreadId) return;
    _loadedThreadId = tid;
    if (tid == widget.controller.activeThread?.id) {
      _nodes = widget.controller.visibleBranchNodes;
      return;
    }
    unawaited(
      widget.controller.loadThreadPreviewNodes(tid).then((list) {
        if (mounted && _loadedThreadId == tid) {
          setState(() => _nodes = list);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final tid = ctrl.splitSecondaryThreadId;
    final thread = ctrl.threads.where((t) => t.id == tid).firstOrNull;

    return ColoredBox(
      color: theme.bgCanvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 10, 10),
            child: Row(
              children: [
                BistreIcon(
                  BistreUiIcon.sidebar,
                  size: 14,
                  color: theme.accentBrass,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkText(
                    thread?.title ?? l10n.t(L10nKey.paletteSplitView),
                    role: InkTextRole.labelStrong,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (thread != null && thread.id != ctrl.activeThread?.id) ...[
                  EngravedButton(
                    label: l10n.t(L10nKey.chatOpenHere),
                    compact: true,
                    onPressed: () => unawaited(ctrl.selectThread(thread.id)),
                  ),
                  const SizedBox(width: 6),
                ],
                BistreIconButton(
                  icon: BistreUiIcon.close,
                  size: 13,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.threadCancel),
                  onPressed: ctrl.toggleSplitView,
                ),
              ],
            ),
          ),
          const FolioDivider(),
          Expanded(
            child: _nodes.isEmpty
                ? Center(
                    child: InkText(
                      l10n.t(L10nKey.chatEmptyIntro),
                      role: InkTextRole.bodyCompact,
                      color: theme.inkMuted,
                    ),
                  )
                : SmoothScrollable(
                    builder: (_, scroll) => ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsetsDirectional.all(16),
                      itemCount: _nodes.length,
                      itemBuilder: (context, index) {
                        final n = _nodes[index];
                        final isUser = n.role == 'user';
                        return Padding(
                          padding: const EdgeInsetsDirectional.only(bottom: 10),
                          child: FolioSurface(
                            tone: isUser
                                ? FolioTone.canvas
                                : FolioTone.elevated,
                            borderRadius: 10,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                InkText(
                                  isUser
                                      ? l10n.t(L10nKey.shellRoleUser)
                                      : l10n.t(L10nKey.shellRoleAssistant),
                                  role: InkTextRole.captionMeta,
                                  color: isUser
                                      ? theme.accentBrass
                                      : theme.inkMuted,
                                ),
                                const SizedBox(height: 4),
                                InkText(
                                  n.content,
                                  role: InkTextRole.bodyCompact,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
