import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'bistre_theme.dart';

/// Shared open/close motion for docked panels (DESIGN §6): `travelling` (180 ms) with
/// `Curves.easeOutCubic`, reversing from wherever it is on a rapid toggle, instant under Reduce
/// motion (including a change mid-flight).
mixin _DockMotion<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
  bool get dockOpen;
  bool get dockReduceMotionOverride;

  late final AnimationController progress = AnimationController(
    vsync: this,
    value: dockOpen ? 1.0 : 0.0,
  );

  void moveDock() {
    final target = dockOpen ? 1.0 : 0.0;
    if (BistreMotion.shouldReduceMotion(
      context,
      reduceMotionOverride: dockReduceMotionOverride,
    )) {
      progress.value = target;
      return;
    }
    final remaining = (target - progress.value).abs();
    if (remaining == 0) return;
    // A fresh `animateTo` starts at the current value, so a reversal never jumps.
    progress.animateTo(
      target,
      duration: BistreMotion.travelling * remaining,
      curve: Curves.easeOutCubic,
    );
  }

  /// Hidden panels stay mounted (their state, scroll offsets, and caches survive) but are not
  /// painted, not ticking, not focusable, and not read by screen readers.
  Widget hiddenWhenClosed(Widget child, double t) {
    final hidden = t == 0 && !dockOpen;
    return Offstage(
      offstage: hidden,
      child: TickerMode(
        enabled: !hidden,
        child: ExcludeFocus(
          excluding: !dockOpen,
          child: ExcludeSemantics(excluding: !dockOpen, child: child),
        ),
      ),
    );
  }

  @override
  void dispose() {
    progress.dispose();
    super.dispose();
  }
}

/// A docked panel beside the main area: the sidebar at the leading edge, or a trailing dock
/// (inspector, Studio) with [trailing]. The main area is laid out once, at its final width,
/// when the panel is toggled; while the panel slides in or out, both are only moved, so the
/// chat never re-lays out (re-wraps text, shifts titles) on every frame. The panel keeps its
/// own width and stays mounted while closed. RTL mirrors both edges.
class SidebarDock extends StatefulWidget {
  const SidebarDock({
    super.key,
    required this.open,
    required this.sidebar,
    required this.child,
    this.trailing = false,
    this.reduceMotionOverride = false,
  });

  final bool open;
  final Widget sidebar;
  final Widget child;

  /// The panel sits at the trailing edge (the end in reading order).
  final bool trailing;
  final bool reduceMotionOverride;

  @override
  State<SidebarDock> createState() => _SidebarDockState();
}

class _SidebarDockState extends State<SidebarDock>
    with SingleTickerProviderStateMixin, _DockMotion {
  @override
  bool get dockOpen => widget.open;
  @override
  bool get dockReduceMotionOverride => widget.reduceMotionOverride;

  @override
  void didUpdateWidget(SidebarDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open != widget.open) moveDock();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return ClipRect(
      child: CustomMultiChildLayout(
        delegate: _SidebarDockDelegate(
          progress: progress,
          open: widget.open,
          fromRight: rtl != widget.trailing,
        ),
        children: [
          LayoutId(
            id: _DockSlot.sidebar,
            child: AnimatedBuilder(
              animation: progress,
              child: RepaintBoundary(child: widget.sidebar),
              builder: (context, child) =>
                  hiddenWhenClosed(child!, progress.value),
            ),
          ),
          LayoutId(
            id: _DockSlot.main,
            child: RepaintBoundary(child: widget.child),
          ),
        ],
      ),
    );
  }
}

enum _DockSlot { sidebar, main }

class _SidebarDockDelegate extends MultiChildLayoutDelegate {
  _SidebarDockDelegate({
    required this.progress,
    required this.open,
    required this.fromRight,
  }) : super(relayout: progress);

  final Animation<double> progress;
  final bool open;

  /// The panel enters from the right edge (a leading panel in RTL, a trailing one in LTR).
  final bool fromRight;

  @override
  void performLayout(Size size) {
    final sidebar = layoutChild(
      _DockSlot.sidebar,
      BoxConstraints(
        maxWidth: size.width,
        minHeight: size.height,
        maxHeight: size.height,
      ),
    );
    final width = sidebar.width;
    // The final width from the first frame: the same constraints every frame after that, so
    // the main area's own layout is skipped while it slides.
    final mainWidth = open ? math.max(0.0, size.width - width) : size.width;
    layoutChild(
      _DockSlot.main,
      BoxConstraints.tightFor(width: mainWidth, height: size.height),
    );
    final shown = width * progress.value;
    if (fromRight) {
      positionChild(_DockSlot.sidebar, Offset(size.width - shown, 0));
      positionChild(_DockSlot.main, Offset(size.width - shown - mainWidth, 0));
    } else {
      positionChild(_DockSlot.sidebar, Offset(shown - width, 0));
      positionChild(_DockSlot.main, Offset(shown, 0));
    }
  }

  @override
  bool shouldRelayout(_SidebarDockDelegate oldDelegate) =>
      oldDelegate.open != open ||
      oldDelegate.fromRight != fromRight ||
      oldDelegate.progress != progress;
}
