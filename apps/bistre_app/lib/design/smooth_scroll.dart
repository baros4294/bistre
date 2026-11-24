import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'bistre_theme.dart';

/// Smooth mouse-wheel scrolling (DESIGN §6): each wheel notch glides via a critically damped
/// spring driven directly by Flutter's VSync ticker, preserving live scroll velocity across
/// consecutive notches instead of restarting from zero. Trackpads stay 1:1 (small deltas or
/// pan-zoom), and Reduce motion snaps immediately.
class SmoothScrollController extends ScrollController {
  SmoothScrollController({super.initialScrollOffset});

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _SmoothWheelPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

/// Owns a [SmoothScrollController] for a scroll view that has no state of its own.
class SmoothScrollable extends StatefulWidget {
  const SmoothScrollable({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<SmoothScrollable> createState() => _SmoothScrollableState();
}

class _SmoothScrollableState extends State<SmoothScrollable> {
  final SmoothScrollController _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}

class _SmoothWheelPosition extends ScrollPositionWithSingleContext {
  _SmoothWheelPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// Wheel notches at or below this size come from smooth devices and stay 1:1.
  static const double _smoothDeviceDelta = 16;
  static final SpringDescription _wheelSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 320);

  double? _wheelTarget;

  @override
  void pointerScroll(double delta) {
    if (delta.abs() <= _smoothDeviceDelta ||
        BistreMotion.shouldReduceMotion(context.storageContext)) {
      _wheelTarget = null;
      super.pointerScroll(delta);
      return;
    }
    final activeBallistic = activity is BallisticScrollActivity;
    final pending = _wheelTarget;
    final base = pending != null && activeBallistic ? pending : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;

    // Preserve in-flight scroll velocity across consecutive wheel notches so rapid scrolling
    // feels continuous and VSync-locked rather than restarting from zero on every detent.
    final currentVelocity = activeBallistic ? activity!.velocity : 0.0;
    updateUserScrollDirection(
      delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    _wheelTarget = target;
    final sim = ScrollSpringSimulation(
      _wheelSpring,
      pixels,
      target,
      currentVelocity,
      tolerance: physics.toleranceFor(this),
    );
    beginActivity(BallisticScrollActivity(this, sim, context.vsync, false));
  }
}
