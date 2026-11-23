import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'bistre_theme.dart';

/// Smooth mouse-wheel scrolling (DESIGN §6, owner decision 2026-11-24): each wheel notch glides
/// to its target instead of jumping, and quick notches extend the same glide. Trackpads stay
/// 1:1 (they arrive as pan-zoom or as small deltas), and Reduce motion keeps the plain jump.
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
  static const Duration _glide = Duration(milliseconds: 170);

  double? _wheelTarget;

  @override
  void pointerScroll(double delta) {
    if (delta.abs() <= _smoothDeviceDelta ||
        BistreMotion.shouldReduceMotion(context.storageContext)) {
      _wheelTarget = null;
      super.pointerScroll(delta);
      return;
    }
    final pending = _wheelTarget;
    final base = pending != null && activity is DrivenScrollActivity
        ? pending
        : pixels;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) return;
    updateUserScrollDirection(
      delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    _wheelTarget = target;
    unawaited(
      animateTo(
        target,
        duration: _glide,
        curve: Curves.easeOutCubic,
      ).whenComplete(() {
        if (_wheelTarget == target) _wheelTarget = null;
      }),
    );
  }
}
