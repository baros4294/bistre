import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'bistre_theme.dart';

/// Smooth critically damped horizontal reveal for docked desktop sidebars and side panels.
/// Reverses cleanly from current width/velocity on rapid toggles, respects RTL directionality,
/// and snaps instantaneously under Reduce motion.
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

  /// `false` for leading sidebar, `true` for trailing inspector/studio dock.
  final bool fromTrailingEdge;
  final bool reduceMotionOverride;

  @override
  State<SidebarSlideReveal> createState() => _SidebarSlideRevealState();
}

class _SidebarSlideRevealState extends State<SidebarSlideReveal>
    with SingleTickerProviderStateMixin {
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 460,
  );
  static const Tolerance _tolerance = Tolerance(
    distance: 0.002,
    velocity: 0.02,
  );

  late final AnimationController _progress = AnimationController.unbounded(
    vsync: this,
    value: widget.open ? 1.0 : 0.0,
  );

  @override
  void didUpdateWidget(SidebarSlideReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open == widget.open) return;
    final target = widget.open ? 1.0 : 0.0;
    if (BistreMotion.shouldReduceMotion(
      context,
      reduceMotionOverride: widget.reduceMotionOverride,
    )) {
      _progress.value = target;
      return;
    }
    unawaited(
      _progress
          .animateWith(
            SpringSimulation(
              _spring,
              _progress.value,
              target,
              _progress.velocity,
              tolerance: _tolerance,
            ),
          )
          .then((_) => _progress.value = target),
    );
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final align = widget.fromTrailingEdge
        ? AlignmentDirectional.centerStart
        : AlignmentDirectional.centerEnd;
    return AnimatedBuilder(
      animation: _progress,
      child: RepaintBoundary(child: widget.child),
      builder: (context, child) {
        final t = _progress.value.clamp(0.0, 1.0);
        if (t == 0 && !widget.open) return const SizedBox.shrink();
        return ClipRect(
          clipBehavior: t < 1 ? Clip.hardEdge : Clip.none,
          child: Align(
            alignment: align,
            widthFactor: t,
            child: Opacity(opacity: (t / 0.55).clamp(0.0, 1.0), child: child),
          ),
        );
      },
    );
  }
}
