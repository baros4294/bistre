import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bistre_icons.dart';
import 'bistre_theme.dart';
import 'disclosure_reveal.dart';
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
  /// U26: Tab cycles inside the modal, and focus goes back where it was when it closes.
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'modal');
  final FocusNode? _returnFocus = FocusManager.instance.primaryFocus;
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
    final back = _returnFocus;
    // After the frame that removes the modal (and lifts the background's ExcludeFocus).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (back != null && back.context != null && back.canRequestFocus) {
        back.requestFocus();
      }
    });
    _scope.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return FocusScope(
      node: _scope,
      autofocus: true,
      child: Focus(
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

/// Calm pulsing activity dot (750 ms loop).
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

/// Centered top floating notification pill (`• <plain sentence> [Action] ×`)
/// with spring pop-in, `liveRegion` semantics, and accessible dismiss control.
class FolioToastBanner extends StatelessWidget {
  const FolioToastBanner({
    super.key,
    required this.message,
    this.reduceMotionOverride = false,
    this.dotColor,
    this.actionLabel,
    this.onAction,
    this.dismissLabel,
    this.onDismiss,
  });

  final String message;
  final bool reduceMotionOverride;
  final Color? dotColor;

  /// Optional trailing action (e.g. `Undo` after deleting a chat).
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? dismissLabel;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final hasAction = actionLabel != null && onAction != null;
    final hasDismiss = onDismiss != null;
    return Align(
      alignment: AlignmentDirectional.topCenter,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          top: BistreSpacing.s12,
          start: BistreSpacing.s16,
          end: BistreSpacing.s16,
        ),
        child: FolioFadeSlide(
          beginOffset: const Offset(0, -0.45),
          beginScale: 0.9,
          reduceMotionOverride: reduceMotionOverride,
          child: Semantics(
            liveRegion: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.fromSTEB(14, 7, 8, 7),
                borderRadius: 999,
                boxShadow: theme.floatingShadow,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 7,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: dotColor ?? theme.accentBrass,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Flexible(
                      child: InkText(
                        message,
                        role: InkTextRole.bodyCompact,
                        color: theme.inkPrimary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
                    if (hasDismiss) ...[
                      const SizedBox(width: 4),
                      BistreIconButton(
                        icon: BistreUiIcon.close,
                        size: 13,
                        dimension: 28,
                        semanticsLabel: dismissLabel ?? message,
                        onPressed: onDismiss,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Slim top notification bar tucked directly under the workspace header
/// (for OTA update notices and non-blocking workspace recovery banners).
class FolioTopBanner extends StatelessWidget {
  const FolioTopBanner({
    super.key,
    required this.visible,
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.dismissLabel,
    this.onDismiss,
    this.accentColor,
  });

  final bool visible;
  final BistreUiIcon icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? dismissLabel;
  final VoidCallback? onDismiss;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final accent = accentColor ?? theme.accentBrass;
    return DisclosureReveal(
      open: visible,
      child: Semantics(
        liveRegion: true,
        child: ColoredBox(
          color: theme.bgSurface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 12, 6),
                child: Row(
                  children: [
                    BistreIcon(icon, size: 15, color: accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InkText(
                        message,
                        role: InkTextRole.bodyCompact,
                        color: theme.inkPrimary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (actionLabel != null && onAction != null) ...[
                      const SizedBox(width: 10),
                      EngravedButton(
                        label: actionLabel!,
                        primary: true,
                        compact: true,
                        onPressed: onAction,
                      ),
                    ],
                    if (onDismiss != null) ...[
                      const SizedBox(width: 6),
                      BistreIconButton(
                        icon: BistreUiIcon.close,
                        size: 13,
                        dimension: 28,
                        semanticsLabel: dismissLabel ?? message,
                        onPressed: onDismiss,
                      ),
                    ],
                  ],
                ),
              ),
              const FolioDivider(),
            ],
          ),
        ),
      ),
    );
  }
}
