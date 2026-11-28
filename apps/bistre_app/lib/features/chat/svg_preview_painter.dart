import 'package:flutter/widgets.dart';

import '../../design/bistre_theme.dart';

/// Most numbers one path may hold; a longer `d` draws what came before the cut.
const int kMaxSvgPathNumbers = 20000;

/// Builds a [Path] from SVG path data (`M L H V C S Q T A Z`, absolute and relative, with
/// implicit repeats and compact arc flags). Reading stops at the first malformed token or at
/// [kMaxSvgPathNumbers]; what was read before still draws.
Path parseSvgPathData(String data) {
  final path = Path();
  final reader = _PathReader(data);
  var cur = Offset.zero;
  var start = Offset.zero;
  // The previous curve's second control point, for the smooth forms S and T.
  Offset? lastCubic;
  Offset? lastQuad;
  String? cmd;
  while (true) {
    final next = reader.command();
    if (next != null) {
      cmd = next;
    } else if (cmd == null || !reader.hasNumber) {
      break;
    } else if (cmd == 'M' || cmd == 'm') {
      // Pairs after a move are lines.
      cmd = cmd == 'M' ? 'L' : 'l';
    }
    final c = cmd;
    final rel = c == c.toLowerCase();
    Offset at(Offset p) => rel ? cur + p : p;
    var cubic = false;
    var quad = false;
    switch (c.toUpperCase()) {
      case 'Z':
        path.close();
        cur = start;
        cmd = null;
      case 'M':
        final p = reader.point();
        if (p == null) return path;
        cur = at(p);
        start = cur;
        path.moveTo(cur.dx, cur.dy);
      case 'L':
        final p = reader.point();
        if (p == null) return path;
        cur = at(p);
        path.lineTo(cur.dx, cur.dy);
      case 'H':
        final x = reader.number();
        if (x == null) return path;
        cur = Offset(rel ? cur.dx + x : x, cur.dy);
        path.lineTo(cur.dx, cur.dy);
      case 'V':
        final y = reader.number();
        if (y == null) return path;
        cur = Offset(cur.dx, rel ? cur.dy + y : y);
        path.lineTo(cur.dx, cur.dy);
      case 'C':
        final a = reader.point();
        final b = reader.point();
        final p = reader.point();
        if (a == null || b == null || p == null) return path;
        final c1 = at(a);
        final c2 = at(b);
        cur = at(p);
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, cur.dx, cur.dy);
        lastCubic = c2;
        cubic = true;
      case 'S':
        final b = reader.point();
        final p = reader.point();
        if (b == null || p == null) return path;
        final c1 = lastCubic == null ? cur : cur * 2 - lastCubic;
        final c2 = at(b);
        cur = at(p);
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, cur.dx, cur.dy);
        lastCubic = c2;
        cubic = true;
      case 'Q':
        final a = reader.point();
        final p = reader.point();
        if (a == null || p == null) return path;
        final c1 = at(a);
        cur = at(p);
        path.quadraticBezierTo(c1.dx, c1.dy, cur.dx, cur.dy);
        lastQuad = c1;
        quad = true;
      case 'T':
        final p = reader.point();
        if (p == null) return path;
        final c1 = lastQuad == null ? cur : cur * 2 - lastQuad;
        cur = at(p);
        path.quadraticBezierTo(c1.dx, c1.dy, cur.dx, cur.dy);
        lastQuad = c1;
        quad = true;
      case 'A':
        final rx = reader.number();
        final ry = reader.number();
        final rotation = reader.number();
        final large = reader.flag();
        final sweep = reader.flag();
        final p = reader.point();
        if (rx == null ||
            ry == null ||
            rotation == null ||
            large == null ||
            sweep == null ||
            p == null) {
          return path;
        }
        cur = at(p);
        if (rx == 0 || ry == 0) {
          path.lineTo(cur.dx, cur.dy);
        } else {
          // SVG's sweep flag 1 turns toward positive angles: clockwise on a y-down canvas.
          path.arcToPoint(
            cur,
            radius: Radius.elliptical(rx.abs(), ry.abs()),
            rotation: rotation,
            largeArc: large,
            clockwise: sweep,
          );
        }
      default:
        return path;
    }
    if (!cubic) lastCubic = null;
    if (!quad) lastQuad = null;
  }
  return path;
}

/// Reads SVG path data left to right; every read is bounded by the text and the number cap.
class _PathReader {
  _PathReader(this._s);

  final String _s;
  int _i = 0;
  int _numbers = 0;

  static final RegExp _numberAt = RegExp(
    r'[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?',
  );

  void _skip() {
    while (_i < _s.length && ' \t\r\n,'.contains(_s[_i])) {
      _i++;
    }
  }

  bool get hasNumber {
    _skip();
    return _numbers < kMaxSvgPathNumbers &&
        _numberAt.matchAsPrefix(_s, _i) != null;
  }

  String? command() {
    _skip();
    if (_i >= _s.length) return null;
    final ch = _s[_i];
    if (!'MmLlHhVvCcSsQqTtAaZz'.contains(ch)) return null;
    _i++;
    return ch;
  }

  double? number() {
    _skip();
    if (_numbers >= kMaxSvgPathNumbers) return null;
    final m = _numberAt.matchAsPrefix(_s, _i);
    if (m == null) return null;
    _i = m.end;
    _numbers++;
    return double.tryParse(m.group(0)!);
  }

  Offset? point() {
    final x = number();
    if (x == null) return null;
    final y = number();
    return y == null ? null : Offset(x, y);
  }

  /// An arc flag is one `0` or `1`, which may touch the next number (`a1 1 0 011 1`).
  bool? flag() {
    _skip();
    if (_i >= _s.length || (_s[_i] != '0' && _s[_i] != '1')) return null;
    return _s[_i++] == '1';
  }
}

/// Safe, offline pure-Dart renderer for SVG geometry (`rect`, `circle`, `ellipse`, `line`,
/// `polygon`, `polyline`, `path`) inside fenced `svg` blocks. Ignores scripts, external links,
/// and filters.
class SafeSvgPreviewPainter extends CustomPainter {
  const SafeSvgPreviewPainter({
    required this.svgSource,
    required this.fallbackStroke,
    required this.fallbackFill,
  });

  final String svgSource;
  final Color fallbackStroke;
  final Color fallbackFill;

  static final RegExp _tagPattern = RegExp(
    r'<(rect|circle|ellipse|line|polygon|polyline|path)\b([^>]*)/?>',
    caseSensitive: false,
  );
  static final RegExp _viewBoxPattern = RegExp(
    r'''viewBox\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final RegExp _attrPattern = RegExp(
    r'''([A-Za-z_-]+)\s*=\s*["']([^"']*)["']''',
  );

  static Map<String, String> _parseAttrs(String raw) {
    final map = <String, String>{};
    for (final m in _attrPattern.allMatches(raw)) {
      map[m.group(1)!.toLowerCase()] = m.group(2)!.trim();
    }
    return map;
  }

  static double _num(Map<String, String> attrs, String key, [double def = 0]) {
    final raw = attrs[key];
    if (raw == null) return def;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.+-]'), '');
    return double.tryParse(cleaned) ?? def;
  }

  static Color? _parseColor(String? raw, Color fallback) {
    if (raw == null || raw.isEmpty) return null;
    final s = raw.trim().toLowerCase();
    if (s == 'none' || s == 'transparent') return null;
    if (s == 'currentcolor') return fallback;
    if (s.startsWith('#')) {
      final hex = s.substring(1);
      if (hex.length == 3) {
        final expanded =
            '#${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
        return BistreAccentOption.tryParseHex(expanded) ?? fallback;
      }
      if (hex.length == 6) {
        return BistreAccentOption.tryParseHex(s) ?? fallback;
      }
    }
    return fallback;
  }

  @override
  void paint(Canvas canvas, Size size) {
    var vbX = 0.0;
    var vbY = 0.0;
    var vbW = 200.0;
    var vbH = 200.0;
    final vbMatch = _viewBoxPattern.firstMatch(svgSource);
    if (vbMatch != null) {
      final parts = vbMatch
          .group(1)!
          .trim()
          .split(RegExp(r'[\s,]+'))
          .map(double.tryParse)
          .whereType<double>()
          .toList(growable: false);
      if (parts.length == 4 && parts[2] > 0 && parts[3] > 0) {
        vbX = parts[0];
        vbY = parts[1];
        vbW = parts[2];
        vbH = parts[3];
      }
    }

    final scaleX = size.width / vbW;
    final scaleY = size.height / vbH;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final dx = (size.width - vbW * scale) / 2 - vbX * scale;
    final dy = (size.height - vbH * scale) / 2 - vbY * scale;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);

    for (final m in _tagPattern.allMatches(svgSource).take(128)) {
      final tag = m.group(1)!.toLowerCase();
      final attrs = _parseAttrs(m.group(2) ?? '');
      final fillColor = _parseColor(
        attrs['fill'] ?? (tag == 'line' ? 'none' : 'currentColor'),
        fallbackFill,
      );
      final strokeColor = _parseColor(attrs['stroke'], fallbackStroke);
      final strokeWidth = _num(attrs, 'stroke-width', 1.5);

      Paint? fillPaint;
      if (fillColor != null) {
        fillPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = fillColor;
      }
      Paint? strokePaint;
      if (strokeColor != null) {
        strokePaint = Paint()
          ..style = PaintingStyle.stroke
          ..color = strokeColor
          ..strokeWidth = strokeWidth;
      }

      switch (tag) {
        case 'rect':
          final rect = Rect.fromLTWH(
            _num(attrs, 'x'),
            _num(attrs, 'y'),
            _num(attrs, 'width'),
            _num(attrs, 'height'),
          );
          final rx = _num(attrs, 'rx');
          if (rx > 0) {
            final rrect = RRect.fromRectAndRadius(rect, Radius.circular(rx));
            if (fillPaint != null) canvas.drawRRect(rrect, fillPaint);
            if (strokePaint != null) canvas.drawRRect(rrect, strokePaint);
          } else {
            if (fillPaint != null) canvas.drawRect(rect, fillPaint);
            if (strokePaint != null) canvas.drawRect(rect, strokePaint);
          }
        case 'circle':
          final c = Offset(_num(attrs, 'cx'), _num(attrs, 'cy'));
          final r = _num(attrs, 'r');
          if (fillPaint != null) canvas.drawCircle(c, r, fillPaint);
          if (strokePaint != null) canvas.drawCircle(c, r, strokePaint);
        case 'ellipse':
          final rect = Rect.fromCenter(
            center: Offset(_num(attrs, 'cx'), _num(attrs, 'cy')),
            width: _num(attrs, 'rx') * 2,
            height: _num(attrs, 'ry') * 2,
          );
          if (fillPaint != null) canvas.drawOval(rect, fillPaint);
          if (strokePaint != null) canvas.drawOval(rect, strokePaint);
        case 'line':
          final p1 = Offset(_num(attrs, 'x1'), _num(attrs, 'y1'));
          final p2 = Offset(_num(attrs, 'x2'), _num(attrs, 'y2'));
          final lp =
              strokePaint ??
              (Paint()
                ..style = PaintingStyle.stroke
                ..color = fallbackStroke
                ..strokeWidth = strokeWidth);
          canvas.drawLine(p1, p2, lp);
        case 'path':
          final path = parseSvgPathData(attrs['d'] ?? '');
          if (attrs['fill-rule'] == 'evenodd') {
            path.fillType = PathFillType.evenOdd;
          }
          if (fillPaint != null) canvas.drawPath(path, fillPaint);
          if (strokePaint != null) canvas.drawPath(path, strokePaint);
        case 'polygon':
        case 'polyline':
          final rawPts = attrs['points'] ?? '';
          final nums = rawPts
              .trim()
              .split(RegExp(r'[\s,]+'))
              .map(double.tryParse)
              .whereType<double>()
              .toList(growable: false);
          if (nums.length >= 4) {
            final path = Path()..moveTo(nums[0], nums[1]);
            for (var i = 2; i + 1 < nums.length; i += 2) {
              path.lineTo(nums[i], nums[i + 1]);
            }
            if (tag == 'polygon') path.close();
            if (fillPaint != null && tag == 'polygon') {
              canvas.drawPath(path, fillPaint);
            }
            if (strokePaint != null) canvas.drawPath(path, strokePaint);
          }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(SafeSvgPreviewPainter oldDelegate) =>
      oldDelegate.svgSource != svgSource ||
      oldDelegate.fallbackStroke != fallbackStroke ||
      oldDelegate.fallbackFill != fallbackFill;
}
