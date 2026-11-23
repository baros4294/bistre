import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Approximate tokens for `text` (~4 characters per token).
int estimateTokens(String text) => (text.length + 3) ~/ 4;

/// 32-bit FNV-1a over UTF-16 code units: cache key for a chat's text snapshot.
int fnv1a32(String text) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < text.length; i++) {
    hash ^= text.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Texts above this size are counted off the UI thread.
const int kBackgroundCountThreshold = 64 * 1024;

/// Compact radial conversation-limit gauge (`docs/design/DESIGN.md` §8).
///
/// Shows a length estimate immediately, then the background count for exactly this chat's
/// text; a count computed for another chat or an older text is never shown.
class ContextGaugeRing extends StatefulWidget {
  const ContextGaugeRing({
    super.key,
    required this.threadId,
    required this.text,
    this.limitTokens,
    this.size = 18,
  });

  final String threadId;
  final String text;
  final int? limitTokens;
  final double size;

  @override
  State<ContextGaugeRing> createState() => _ContextGaugeRingState();
}

class _ContextGaugeRingState extends State<ContextGaugeRing> {
  String? _countedThread;
  int? _countedHash;
  int? _counted;

  @override
  void initState() {
    super.initState();
    _scheduleCount();
  }

  @override
  void didUpdateWidget(ContextGaugeRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.threadId != widget.threadId ||
        oldWidget.text != widget.text) {
      _scheduleCount();
    }
  }

  void _scheduleCount() {
    final thread = widget.threadId;
    final text = widget.text;
    final hash = fnv1a32(text);
    if (_countedThread == thread && _countedHash == hash) return;
    if (text.length < kBackgroundCountThreshold) {
      _countedThread = thread;
      _countedHash = hash;
      _counted = estimateTokens(text);
      return;
    }
    // Large chats: count in a background isolate; apply only if still current.
    unawaited(
      compute(estimateTokens, text).then((value) {
        if (!mounted ||
            widget.threadId != thread ||
            fnv1a32(widget.text) != hash) {
          return;
        }
        setState(() {
          _countedThread = thread;
          _countedHash = hash;
          _counted = value;
        });
      }, onError: (Object _) {}),
    );
  }

  int get _used {
    final counted = _counted;
    if (counted != null &&
        _countedThread == widget.threadId &&
        _countedHash == fnv1a32(widget.text)) {
      return counted;
    }
    return estimateTokens(widget.text);
  }

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final used = _used;
    final limit = widget.limitTokens;
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
                size: Size.square(widget.size),
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
