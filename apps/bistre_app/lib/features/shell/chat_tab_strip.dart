import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../chat/content_direction.dart';
import 'folio_controller.dart';

/// Open chats as tabs under the header. Shown once two or more chats are open; the current
/// tab is a raised sheet, streaming tabs pulse, and trailing `+` / overview icon buttons
/// create a new tab or open the tab overview modal (its hint names the count).
class ChatTabStrip extends StatelessWidget {
  const ChatTabStrip({super.key, required this.controller});

  final FolioController controller;

  @override
  Widget build(BuildContext context) {
    final tabs = controller.openTabs;
    if (tabs.length < 2) return const SizedBox.shrink();
    final l10n = BistreLocalizations.of(context);
    final activeId = controller.activeThread?.id;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final thread in tabs)
                  _ChatTab(
                    thread: thread,
                    selected: thread.id == activeId,
                    streaming: controller.isThreadStreaming(thread.id),
                    reduceMotionOverride: controller.reduceMotionOverride,
                    onSelect: () =>
                        unawaited(controller.selectThread(thread.id)),
                    onClose: () => unawaited(controller.closeTab(thread.id)),
                  ),
                BistreIconButton(
                  icon: BistreUiIcon.plus,
                  size: 13,
                  dimension: 30,
                  semanticsLabel: l10n.t(L10nKey.shellTabsNewTab),
                  onPressed: () => unawaited(controller.createNewFolio()),
                ),
              ],
            ),
          ),
          const SizedBox(width: BistreSpacing.s8),
          // The tabs show how many are open; the overview button names the count in
          // its hint and screen-reader label only.
          BistreIconButton(
            icon: BistreUiIcon.chevronDown,
            size: 13,
            dimension: 30,
            semanticsLabel: l10n.t(L10nKey.shellTabsCount, <String, Object?>{
              'count': tabs.length,
            }),
            onPressed: controller.openTabSwitcher,
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
    required this.streaming,
    required this.reduceMotionOverride,
    required this.onSelect,
    required this.onClose,
  });

  final EngineThread thread;
  final bool selected;
  final bool streaming;
  final bool reduceMotionOverride;
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
          child: PressFeedback(
            pressScale: kRowPressScale,
            hoverScale: 1,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onSelect,
              child: DecoratedBox(
                // The open tab is a raised sheet; the one accent bar stays in the sidebar.
                decoration: widget.selected
                    ? BoxDecoration(
                        color: theme.bgElevated,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: theme.borderHairline),
                      )
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
                      if (widget.streaming) ...[
                        StreamingPulseDot(
                          color: theme.accentBrass,
                          reduceMotionOverride: widget.reduceMotionOverride,
                        ),
                        const SizedBox(width: 6),
                      ],
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: OwnDirection(
                          text: widget.thread.title,
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
      ),
    );
  }
}
