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
      SpringDescription.withDampingRatio(mass: 1, stiffness: 420);

  double? _wheelTarget;
  double _wheelDirection = 0;
  ScrollActivity? _wheelActivity;

  @override
  void beginActivity(ScrollActivity? newActivity) {
    if (!identical(newActivity, _wheelActivity)) {
      _wheelTarget = null;
      _wheelDirection = 0;
      _wheelActivity = null;
    }
    super.beginActivity(newActivity);
  }

  @override
  void pointerScroll(double delta) {
    if (delta == 0) return;
    if (delta.abs() <= _smoothDeviceDelta ||
        BistreMotion.shouldReduceMotion(context.storageContext)) {
      _wheelTarget = null;
      _wheelDirection = 0;
      _wheelActivity = null;
      super.pointerScroll(delta);
      return;
    }

    final dir = delta.sign;
    final activeWheel =
        identical(activity, _wheelActivity) &&
        activity is BallisticScrollActivity;
    final continuingSameDir =
        activeWheel && _wheelTarget != null && _wheelDirection == dir;

    final base = continuingSameDir ? _wheelTarget! : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    if ((target - pixels).abs() < 0.5) {
      _wheelTarget = null;
      _wheelDirection = 0;
      _wheelActivity = null;
      return;
    }

    // Only carry in-flight velocity when continuing in the exact same direction;
    // reversing direction immediately zeros velocity so the viewport never jumps backwards.
    final liveVelocity = continuingSameDir ? activity!.velocity : 0.0;
    final currentVelocity = liveVelocity.sign == dir ? liveVelocity : 0.0;

    updateUserScrollDirection(
      delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    _wheelTarget = target;
    _wheelDirection = dir;
    final sim = ScrollSpringSimulation(
      _wheelSpring,
      pixels,
      target,
      currentVelocity,
      tolerance: physics.toleranceFor(this),
    );
    final nextActivity = BallisticScrollActivity(
      this,
      sim,
      context.vsync,
      false,
    );
    _wheelActivity = nextActivity;
    beginActivity(nextActivity);
  }
}
