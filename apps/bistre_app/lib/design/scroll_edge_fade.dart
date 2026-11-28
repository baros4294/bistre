import 'package:flutter/widgets.dart';

import 'bistre_theme.dart';

/// Fades the top or bottom edge of a vertically scrolling [child] where more content lies
/// beyond it, so a row cut at the edge reads as "there is more" instead of as clipped text
/// (DESIGN §1.2). The fade follows the scroll position and disappears at each end; nothing
/// moves or resizes.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({super.key, required this.child});

  final Widget child;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  /// How far into the view the fade reaches, in logical pixels.
  static const double _extentPx = 24;

  bool _moreBefore = false;
  bool _moreAfter = false;

  bool _onMetrics(ScrollMetrics m) {
    if (m.axis != Axis.vertical) return false;
    final before = m.pixels > m.minScrollExtent + 0.5;
    final after = m.pixels < m.maxScrollExtent - 0.5;
    if (before != _moreBefore || after != _moreAfter) {
      // Metrics arrive during layout; the fade changes on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _moreBefore = before;
          _moreAfter = after;
        });
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final listener = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => n.depth == 0 && _onMetrics(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => n.depth == 0 && _onMetrics(n.metrics),
        child: widget.child,
      ),
    );
    // The mask stays in the tree at each end (fully opaque there), so the scroll view's
    // state survives the fade coming and going. Only the alpha matters under dstIn; the hue is any opaque theme ink.
    final solid = theme.inkPrimary.withValues(alpha: 1);
    final clear = solid.withValues(alpha: 0);
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final stop = rect.height <= 0
            ? 0.0
            : (_extentPx / rect.height).clamp(0.0, 0.5);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            _moreBefore ? clear : solid,
            solid,
            solid,
            _moreAfter ? clear : solid,
          ],
          stops: <double>[0, stop, 1 - stop, 1],
        ).createShader(rect);
      },
      child: listener,
    );
  }
}
