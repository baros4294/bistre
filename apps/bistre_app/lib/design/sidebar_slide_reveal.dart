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

/// Horizontal reveal for the trailing docks (inspector, Studio). The panel keeps a fixed width
/// and is clipped by the reveal; it stays mounted while closed.
class SidebarSlideReveal extends StatefulWidget {
  const SidebarSlideReveal({
    super.key,
    required this.open,
    required this.child,
    this.fromTrailingEdge = false,
    this.reduceMotionOverride = false,
  });

  final bool open;
  final Widget child;

  /// `false` for a leading panel, `true` for a trailing dock.
  final bool fromTrailingEdge;
  final bool reduceMotionOverride;

  @override
  State<SidebarSlideReveal> createState() => _SidebarSlideRevealState();
}

class _SidebarSlideRevealState extends State<SidebarSlideReveal>
    with SingleTickerProviderStateMixin, _DockMotion {
  @override
  bool get dockOpen => widget.open;
  @override
  bool get dockReduceMotionOverride => widget.reduceMotionOverride;

  @override
  void didUpdateWidget(SidebarSlideReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open != widget.open) moveDock();
  }

  @override
  Widget build(BuildContext context) {
    final align = widget.fromTrailingEdge
        ? AlignmentDirectional.centerStart
        : AlignmentDirectional.centerEnd;
    return AnimatedBuilder(
      animation: progress,
      child: RepaintBoundary(child: widget.child),
      builder: (context, child) {
        final t = progress.value;
        return ClipRect(
          clipBehavior: t < 1 ? Clip.hardEdge : Clip.none,
          child: Align(
            alignment: align,
            widthFactor: t,
            child: hiddenWhenClosed(child!, t),
          ),
        );
      },
    );
  }
}

/// The leading sidebar beside the main area (A-W 3a). The main area is laid out once, at its
/// final width, when the sidebar is toggled; while the sidebar slides in or out, both are only
/// moved, so the chat never re-lays out (re-wraps text, shifts titles) on every frame. The
/// sidebar keeps its own width and stays mounted while closed. RTL slides from the right.
class SidebarDock extends StatefulWidget {
  const SidebarDock({
    super.key,
    required this.open,
    required this.sidebar,
    required this.child,
    this.reduceMotionOverride = false,
  });

  final bool open;
  final Widget sidebar;
  final Widget child;
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
          rtl: rtl,
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
    required this.rtl,
  }) : super(relayout: progress);

  final Animation<double> progress;
  final bool open;
  final bool rtl;

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
    if (rtl) {
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
      oldDelegate.rtl != rtl ||
      oldDelegate.progress != progress;
}
