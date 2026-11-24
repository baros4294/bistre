import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bistre_theme.dart';
import 'ink_primitives.dart';

/// Smooth GPU-composited entrance animation (transform + opacity only, zero layout passes).
/// Automatically resolves to instant render when system reduced motion or user override is active.
class FolioFadeSlide extends StatefulWidget {
  const FolioFadeSlide({
    super.key,
    required this.child,
    this.beginOffset = const Offset(0, 0.035),
    this.beginScale = 1.0,
    this.reduceMotionOverride = false,
  });

  final Widget child;
  final Offset beginOffset;

  /// Pop-in pills (toasts, Jump to latest) also grow from this scale (DESIGN §6: 0.90).
  final double beginScale;
  final bool reduceMotionOverride;

  @override
  State<FolioFadeSlide> createState() => _FolioFadeSlideState();
}

class _FolioFadeSlideState extends State<FolioFadeSlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: BistreMotion.arriving,
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: BistreMotion.easeOut,
    );
    _opacity = curved;
    _slide = Tween<Offset>(
      begin: widget.beginOffset,
      end: Offset.zero,
    ).animate(curved);
    _scale = Tween<double>(begin: widget.beginScale, end: 1).animate(curved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final dur = BistreMotion.overlayDuration(
      context,
      reduceMotionOverride: widget.reduceMotionOverride,
    );
    if (dur == Duration.zero) {
      _controller.value = 1.0;
    } else {
      _controller.duration = dur;
      // Ignore unawaited animation start; controller disposes cleanly in dispose().
      _controller.forward().ignore();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: widget.beginScale == 1.0
            ? widget.child
            : ScaleTransition(scale: _scale, child: widget.child),
      ),
    );
  }
}

/// GPU-composited modal scrim + scale/fade sheet with Escape & backdrop dismissal.
class FolioModalBackdrop extends StatefulWidget {
  const FolioModalBackdrop({
    super.key,
    required this.onDismiss,
    required this.child,
    this.reduceMotionOverride = false,
    this.alignment = AlignmentDirectional.center,
  });

  final VoidCallback onDismiss;
  final Widget child;
  final bool reduceMotionOverride;
  final AlignmentGeometry alignment;

  @override
  State<FolioModalBackdrop> createState() => _FolioModalBackdropState();
}

class _FolioModalBackdropState extends State<FolioModalBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: BistreMotion.easeOut,
    );
    _fade = curved;
    _scale = Tween<double>(begin: 0.96, end: 1.0).animate(curved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final dur = BistreMotion.overlayDuration(
      context,
      reduceMotionOverride: widget.reduceMotionOverride,
    );
    if (dur == Duration.zero) {
      _controller.value = 1.0;
    } else {
      _controller.duration = dur;
      _controller.forward().ignore();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onDismiss();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          FadeTransition(
            opacity: _fade,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onDismiss,
              child: ColoredBox(color: theme.scrim),
            ),
          ),
          Align(
            alignment: widget.alignment,
            child: FadeTransition(
              opacity: _fade,
              child: ScaleTransition(scale: _scale, child: widget.child),
            ),
          ),
        ],
      ),
    );
  }
}

/// RTL-aware slide-over sidebar drawer using GPU `SlideTransition` + `FadeTransition` scrim.
class FolioDrawerFrame extends StatefulWidget {
  const FolioDrawerFrame({
    super.key,
    required this.onDismiss,
    required this.child,
    this.reduceMotionOverride = false,
  });

  final VoidCallback onDismiss;
  final Widget child;
  final bool reduceMotionOverride;

  @override
  State<FolioDrawerFrame> createState() => _FolioDrawerFrameState();
}

class _FolioDrawerFrameState extends State<FolioDrawerFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: BistreMotion.travelling,
    );
    _fade = CurvedAnimation(parent: _controller, curve: BistreMotion.easeOut);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final dur = BistreMotion.panelDuration(
      context,
      reduceMotionOverride: widget.reduceMotionOverride,
    );
    if (dur == Duration.zero) {
      _controller.value = 1.0;
    } else {
      _controller.duration = dur;
      _controller.forward().ignore();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final slide = Tween<Offset>(
      begin: Offset(isRtl ? 1.0 : -1.0, 0),
      end: Offset.zero,
    ).animate(_fade);

    return Stack(
      fit: StackFit.expand,
      children: [
        FadeTransition(
          opacity: _fade,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            child: ColoredBox(color: theme.scrim),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: SlideTransition(position: slide, child: widget.child),
        ),
      ],
    );
  }
}

/// Calm pulsing activity dot (Parchment v2.6.0 `KissStreamingPulseDot`, 750 ms loop).
/// Static under Reduce motion; uses only GPU opacity + scale transforms.
class StreamingPulseDot extends StatefulWidget {
  const StreamingPulseDot({
    super.key,
    this.color,
    this.size = 7,
    this.reduceMotionOverride = false,
  });

  final Color? color;
  final double size;
  final bool reduceMotionOverride;

  @override
  State<StreamingPulseDot> createState() => _StreamingPulseDotState();
}

class _StreamingPulseDotState extends State<StreamingPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    _opacity = Tween<double>(begin: 0.35, end: 1.0).animate(curved);
    _scale = Tween<double>(begin: 0.82, end: 1.0).animate(curved);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = BistreMotion.shouldReduceMotion(
      context,
      reduceMotionOverride: widget.reduceMotionOverride,
    );
    if (reduce) {
      if (_running) {
        _controller.stop();
        _running = false;
      }
      _controller.value = 1.0;
    } else if (!_running) {
      _running = true;
      _controller.repeat(reverse: true).ignore();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? BistreTheme.of(context).accentBrass;
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _opacity,
        child: ScaleTransition(
          scale: _scale,
          child: SizedBox.square(
            dimension: widget.size,
            child: DecoratedBox(
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}

/// Calm breathing ink-nib cursor animated strictly via `FadeTransition` while streaming.
class FolioStreamingCursor extends StatefulWidget {
  const FolioStreamingCursor({super.key, this.reduceMotionOverride = false});

  final bool reduceMotionOverride;

  @override
  State<FolioStreamingCursor> createState() => _FolioStreamingCursorState();
}

class _FolioStreamingCursorState extends State<FolioStreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
      lowerBound: 0.25,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_running) return;
    _running = true;
    if (BistreMotion.shouldReduceMotion(
      context,
      reduceMotionOverride: widget.reduceMotionOverride,
    )) {
      _controller.value = 1.0;
    } else {
      _controller.repeat(reverse: true).ignore();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return FadeTransition(
      opacity: _controller,
      child: SizedBox(
        width: 8,
        height: 16,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.accentWax,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// Smooth top-end sliding notification pill for copy/pin/save actions.
class FolioToastBanner extends StatelessWidget {
  const FolioToastBanner({
    super.key,
    required this.message,
    this.reduceMotionOverride = false,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final bool reduceMotionOverride;

  /// Optional trailing action (e.g. `Undo` after deleting a chat).
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final hasAction = actionLabel != null && onAction != null;
    return IgnorePointer(
      ignoring: !hasAction,
      child: Align(
        alignment: AlignmentDirectional.topEnd,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            top: BistreSpacing.s16,
            end: BistreSpacing.s16,
          ),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, -0.5),
            beginScale: 0.9,
            reduceMotionOverride: reduceMotionOverride,
            child: FolioSurface(
              tone: FolioTone.elevated,
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: BistreSpacing.s16,
                vertical: BistreSpacing.s8,
              ),
              borderRadius: 999,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: InkText(
                      message,
                      role: InkTextRole.captionMeta,
                      color: theme.inkPrimary,
                    ),
                  ),
                  if (hasAction) ...[
                    const SizedBox(width: BistreSpacing.s8),
                    EngravedButton(
                      label: actionLabel!,
                      compact: true,
                      onPressed: onAction,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
