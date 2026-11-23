import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Compact radial conversation-limit gauge (`docs/design/DESIGN.md` §8).
///
/// [usedTokens] comes from core (`context_usage`): the estimate of what the next request sends,
/// after any compaction or context pin, so the gauge never counts text the model will not see.
class ContextGaugeRing extends StatelessWidget {
  const ContextGaugeRing({
    super.key,
    required this.usedTokens,
    this.limitTokens,
    this.size = 18,
  });

  final int usedTokens;
  final int? limitTokens;
  final double size;

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final used = usedTokens;
    final limit = limitTokens;
    final fraction = (limit == null || limit <= 0)
        ? 0.0
        : (used / limit).clamp(0.0, 1.0);
    final ringColor = fraction >= 0.9
        ? theme.statusErr
        : fraction >= 0.75
        ? theme.statusWarn
        : theme.accentBrass;
    final label = limit == null
        ? l10n.t(L10nKey.chatContextGaugeUsed, <String, Object?>{
            'used': _compact(used),
          })
        : l10n.t(L10nKey.chatContextGaugeOfLimit, <String, Object?>{
            'used': _compact(used),
            'limit': _compact(limit),
          });
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                size: Size.square(size),
                painter: _GaugePainter(
                  fraction: fraction,
                  track: theme.borderHairline,
                  fill: ringColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            InkText(
              limit == null
                  ? _compact(used)
                  : l10n.t(L10nKey.chatContextGaugeShort, <String, Object?>{
                      'used': _compact(used),
                      'limit': _compact(limit),
                      'percent': (fraction * 100).round(),
                    }),
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  const _GaugePainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.16;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2);
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(arcRect, 0, math.pi * 2, false, trackPaint);
    if (fraction > 0) {
      final fillPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = fill;
      canvas.drawArc(
        arcRect,
        -math.pi / 2,
        math.pi * 2 * fraction,
        false,
        fillPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.track != track || old.fill != fill;
}
