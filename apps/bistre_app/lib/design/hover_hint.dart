import 'dart:async';

import 'package:flutter/widgets.dart';

import 'bistre_motion_widgets.dart';
import 'bistre_theme.dart';
import 'ink_primitives.dart';

/// A quiet hint bubble that names a control after the pointer rests on it (Parchment v2.6.0
/// `HoverHint`): it appears 500 ms after hover starts, under the control (above it near the
/// bottom edge, start- or end-aligned near the sides), and goes on exit or press. Pointer-only:
/// touch has no hover, and screen readers already get the control's own label.
class HoverHint extends StatefulWidget {
  const HoverHint({super.key, required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  State<HoverHint> createState() => _HoverHintState();
}

class _HoverHintState extends State<HoverHint> {
  static const Duration _delay = Duration(milliseconds: 500);

  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  Timer? _timer;
  Alignment _target = Alignment.bottomCenter;
  Alignment _follower = Alignment.topCenter;
  Offset _gap = const Offset(0, 6);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _enter() {
    _timer?.cancel();
    _timer = Timer(_delay, _show);
  }

  void _leave() {
    _timer?.cancel();
    _timer = null;
    if (_portal.isShowing) _portal.hide();
  }

  void _show() {
    _timer = null;
    final box = context.findRenderObject();
    final view = MediaQuery.maybeSizeOf(context);
    if (!mounted || box is! RenderBox || !box.hasSize || view == null) return;
    final center = box.localToGlobal(box.size.center(Offset.zero));
    final below = center.dy < view.height - 64;
    final x = center.dx < 120
        ? -1.0
        : center.dx > view.width - 120
        ? 1.0
        : 0.0;
    _target = Alignment(x, below ? 1 : -1);
    _follower = Alignment(x, below ? -1 : 1);
    _gap = Offset(0, below ? 6 : -6);
    _portal.show();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.message.isEmpty) return widget.child;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildHint,
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          opaque: false,
          onEnter: (_) => _enter(),
          onExit: (_) => _leave(),
          child: Listener(onPointerDown: (_) => _leave(), child: widget.child),
        ),
      ),
    );
  }

  Widget _buildHint(BuildContext context) {
    final theme = BistreTheme.of(context);
    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: _target,
      followerAnchor: _follower,
      offset: _gap,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: Align(
            alignment: _follower,
            widthFactor: 1,
            heightFactor: 1,
            child: FolioFadeSlide(
              beginOffset: Offset.zero,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: FolioSurface(
                  tone: FolioTone.elevated,
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  borderRadius: 6,
                  boxShadow: theme.floatingShadow,
                  child: InkText(
                    widget.message,
                    role: InkTextRole.captionMeta,
                    color: theme.inkPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
