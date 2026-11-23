import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import 'folio_controller.dart';

/// Open chats as tabs under the header (Parchment v2.6.0). Shown once two or more chats are
/// open; the current tab carries the one `rubricMark`. Switching tabs is a 100+/day action, so
/// nothing animates.
class ChatTabStrip extends StatelessWidget {
  const ChatTabStrip({super.key, required this.controller});

  final FolioController controller;

  @override
  Widget build(BuildContext context) {
    final tabs = controller.openTabs;
    if (tabs.length < 2) return const SizedBox.shrink();
    final activeId = controller.activeThread?.id;
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final thread in tabs)
            _ChatTab(
              thread: thread,
              selected: thread.id == activeId,
              onSelect: () => unawaited(controller.selectThread(thread.id)),
              onClose: () => unawaited(controller.closeTab(thread.id)),
            ),
        ],
      ),
    );
  }
}

class _ChatTab extends StatefulWidget {
  const _ChatTab({
    required this.thread,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  final EngineThread thread;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: BistreSpacing.s4),
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.thread.title,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onSelect();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSelect,
            child: DecoratedBox(
              decoration: widget.selected
                  ? rubricMark(theme, fill: theme.bgElevated)
                  : BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: _focused
                          ? Border.all(color: theme.accentBrass, width: 2)
                          : null,
                    ),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(10, 2, 2, 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: InkText(
                        widget.thread.title,
                        role: InkTextRole.captionMeta,
                        color: widget.selected
                            ? theme.inkPrimary
                            : theme.inkSecondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    BistreIconButton(
                      icon: BistreUiIcon.close,
                      size: 11,
                      dimension: 24,
                      semanticsLabel: l10n.t(L10nKey.shellCloseTab),
                      onPressed: widget.onClose,
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
