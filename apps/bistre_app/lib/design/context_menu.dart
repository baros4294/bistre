import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bistre_icons.dart';
import 'bistre_motion_widgets.dart';
import 'bistre_theme.dart';
import 'ink_primitives.dart';
import 'press_feedback.dart';

/// One row of a [ContextMenuRegion] menu.
class ContextMenuEntry {
  const ContextMenuEntry({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
  });

  final String label;
  final BistreUiIcon icon;
  final VoidCallback onSelected;
  final bool destructive;
}

/// Right-click menu for a region (touch keeps the visible action bar instead: a long-press is
/// text selection there).
/// `PlatformContextMenu`. It opens at the pointer, stays inside the window, fades out on
/// close, and dismisses on Escape, an outside tap, or a choice. The entries repeat actions
/// that also exist as visible or hover controls, so nothing is reachable only from here.
class ContextMenuRegion extends StatefulWidget {
  const ContextMenuRegion({
    super.key,
    required this.entries,
    required this.child,
  });

  final List<ContextMenuEntry> entries;
  final Widget child;

  @override
  State<ContextMenuRegion> createState() => _ContextMenuRegionState();
}

class _ContextMenuRegionState extends State<ContextMenuRegion> {
  static const double _menuWidth = 220;
  static const double _rowHeight = 36;

  final FolioOverlayController _menu = FolioOverlayController();
  Offset _at = Offset.zero;

  void _open(Offset global) {
    if (widget.entries.isEmpty) return;
    setState(() => _at = global);
    _menu.show();
  }

  @override
  Widget build(BuildContext context) {
    return FolioOverlay(
      controller: _menu,
      overlayBuilder: _buildMenu,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (d) => _open(d.globalPosition),
        child: widget.child,
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    final theme = BistreTheme.of(context);
    final view = MediaQuery.sizeOf(context);
    final height = widget.entries.length * _rowHeight + 12;
    final left = _at.dx.clamp(8.0, view.width - _menuWidth - 8);
    final top = _at.dy.clamp(8.0, view.height - height - 8);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _menu.hide,
            onSecondaryTap: _menu.hide,
            child: const SizedBox.expand(),
          ),
        ),
        // Window coordinates are physical by nature: the menu opens where the pointer is.
        Positioned.fromRect(
          rect: Rect.fromLTWH(
            left.toDouble(),
            top.toDouble(),
            _menuWidth,
            height,
          ),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, -0.02),
            child: FocusScope(
              autofocus: true,
              child: FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.all(6),
                borderRadius: 10,
                boxShadow: theme.floatingShadow,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, e) in widget.entries.indexed)
                      _MenuRow(
                        entry: e,
                        autofocus: i == 0,
                        onChosen: () {
                          _menu.hideNow();
                          e.onSelected();
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({
    required this.entry,
    required this.onChosen,
    required this.autofocus,
  });

  final ContextMenuEntry entry;
  final VoidCallback onChosen;
  final bool autofocus;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _lit = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final color = widget.entry.destructive ? theme.statusErr : theme.inkPrimary;
    return Semantics(
      button: true,
      label: widget.entry.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        autofocus: widget.autofocus,
        onShowHoverHighlight: (v) => setState(() => _lit = v),
        onShowFocusHighlight: (v) => setState(() => _lit = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onChosen();
              return null;
            },
          ),
        },
        mouseCursor: SystemMouseCursors.click,
        child: PressFeedback(
          pressScale: kRowPressScale,
          hoverScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onChosen,
            child: EaseDecoration(
              decoration: BoxDecoration(
                color: _lit
                    ? theme.hoverTint
                    : theme.hoverTint.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SizedBox(
                height: 36,
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 10,
                  ),
                  child: Row(
                    children: [
                      BistreIcon(widget.entry.icon, size: 14, color: color),
                      const SizedBox(width: 10),
                      Expanded(
                        child: InkText(
                          widget.entry.label,
                          role: InkTextRole.bodyCompact,
                          color: color,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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
