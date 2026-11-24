import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'bistre_theme.dart';

/// The one sanctioned height animation (DESIGN §6, owner decision 2026-11-24): a disclosure's
/// content grows and shrinks on a critically damped spring while it fades, like Parchment
/// v2.6.0. Toggling mid-motion reverses from the current height and speed. The content stays
/// mounted while it closes and is dropped once closed. Reduce motion snaps it.
class DisclosureReveal extends StatefulWidget {
  const DisclosureReveal({super.key, required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<DisclosureReveal> createState() => _DisclosureRevealState();
}

class _DisclosureRevealState extends State<DisclosureReveal>
    with SingleTickerProviderStateMixin {
  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 420,
  );
  static const Tolerance _tolerance = Tolerance(
    distance: 0.002,
    velocity: 0.02,
  );

  late final AnimationController _progress = AnimationController.unbounded(
    vsync: this,
    value: widget.open ? 1 : 0,
  );

  @override
  void didUpdateWidget(DisclosureReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open == widget.open) return;
    final target = widget.open ? 1.0 : 0.0;
    if (BistreMotion.shouldReduceMotion(context)) {
      _progress.value = target;
      return;
    }
    // The spring stops within its tolerance; land exactly on the target when it finishes (an
    // interrupted run never completes, so a newer toggle is never overwritten).
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
    return AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) {
        final t = _progress.value.clamp(0.0, 1.0);
        if (t == 0 && !widget.open) return const SizedBox.shrink();
        // One tree shape while visible, so the content keeps its state when the motion ends.
        return ClipRect(
          clipBehavior: t < 1 ? Clip.hardEdge : Clip.none,
          child: Align(
            alignment: AlignmentDirectional.topStart,
            heightFactor: t,
            // The content fades in over the first 60% of the growth (and out over the last
            // 60% of the shrink), so text never shows half-clipped at full strength.
            child: Opacity(opacity: (t / 0.6).clamp(0.0, 1.0), child: child),
          ),
        );
      },
    );
  }
}
