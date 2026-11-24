import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import 'bistre_theme.dart';

/// Press scale for wide rows (sidebar chats, list rows, tabs): the full 0.96 would shrink a
/// 300 px row by 12 px, which reads as a jump rather than a press.
const double kRowPressScale = 0.985;

/// Spring press and hover feedback for every clickable (DESIGN §6, Parchment v2.6.0
/// `kissClickable`): pressing scales to 0.96, hovering scales to 1.012 and lifts 0.75 px.
/// Pointer events pass through untouched, so the action still fires on the event; the motion
/// only describes it. Reduced motion (system or in-app setting) makes it instant.
class PressFeedback extends StatefulWidget {
  const PressFeedback({
    super.key,
    required this.child,
    this.enabled = true,
    this.pressScale = 0.96,
    this.hoverScale = 1.012,
  });

  final Widget child;
  final bool enabled;
  final double pressScale;
  final double hoverScale;

  @override
  State<PressFeedback> createState() => _PressFeedbackState();
}

class _PressFeedbackState extends State<PressFeedback>
    with TickerProviderStateMixin {
  static final SpringDescription _scaleSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 680, ratio: 0.78);
  static final SpringDescription _liftSpring =
      SpringDescription.withDampingRatio(mass: 1, stiffness: 560);

  late final AnimationController _scale = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  late final AnimationController _lift = AnimationController.unbounded(
    vsync: this,
  );
  bool _hovered = false;
  bool _pressed = false;

  @override
  void dispose() {
    _scale.dispose();
    _lift.dispose();
    super.dispose();
  }

  void _sync() {
    final enabled = widget.enabled;
    final scale = !enabled
        ? 1.0
        : _pressed
        ? widget.pressScale
        : _hovered
        ? widget.hoverScale
        : 1.0;
    final lift = enabled && _hovered && !_pressed ? -0.75 : 0.0;
    if (BistreMotion.shouldReduceMotion(context)) {
      _scale.value = 1;
      _lift.value = 0;
      return;
    }
    _scale.animateWith(
      SpringSimulation(_scaleSpring, _scale.value, scale, _scale.velocity),
    );
    _lift.animateWith(
      SpringSimulation(_liftSpring, _lift.value, lift, _lift.velocity),
    );
  }

  void _setHovered(bool v) {
    if (_hovered == v) return;
    _hovered = v;
    _sync();
  }

  void _setPressed(bool v) {
    if (_pressed == v) return;
    _pressed = v;
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      opaque: false,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[_scale, _lift]),
          builder: (context, child) => Transform(
            alignment: Alignment.center,
            transform: Matrix4.translationValues(0, _lift.value, 0)
              ..scaleByDouble(_scale.value, _scale.value, 1, 1),
            child: child,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// A [DecoratedBox] whose colour and border cross-fade over `BistreMotion.travelling` when the
/// decoration changes (DESIGN §6: selection, toggle, chip, and hover colours never snap).
/// Instant under Reduce motion.
class EaseDecoration extends StatelessWidget {
  const EaseDecoration({
    super.key,
    required this.decoration,
    required this.child,
  });

  final Decoration decoration;
  final Widget child;

  @override
  Widget build(BuildContext context) => _EaseDecoration(
    decoration: decoration,
    duration: BistreMotion.shouldReduceMotion(context)
        ? Duration.zero
        : BistreMotion.travelling,
    child: child,
  );
}

class _EaseDecoration extends ImplicitlyAnimatedWidget {
  const _EaseDecoration({
    required this.decoration,
    required this.child,
    required super.duration,
  }) : super(curve: Curves.easeOut);

  final Decoration decoration;
  final Widget child;

  @override
  AnimatedWidgetBaseState<_EaseDecoration> createState() =>
      _EaseDecorationState();
}

class _EaseDecorationState extends AnimatedWidgetBaseState<_EaseDecoration> {
  DecorationTween? _decoration;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _decoration = visitor(
      _decoration,
      widget.decoration,
      (dynamic value) => DecorationTween(begin: value as Decoration),
    ) as DecorationTween?;
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: _decoration?.evaluate(animation) ?? widget.decoration,
    child: widget.child,
  );
}
