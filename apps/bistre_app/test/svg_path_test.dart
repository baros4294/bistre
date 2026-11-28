import 'package:bistre_app/features/chat/svg_preview_painter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fenced `svg` previews draw `<path>` data: every command, relative forms, implicit repeats,
/// compact arc flags, and a bounded read that keeps what came before a bad token.
void main() {
  Rect bounds(String d) => parseSvgPathData(d).getBounds();

  test('absolute and relative lines draw the same square', () {
    const square = Rect.fromLTRB(10, 10, 90, 90);
    expect(bounds('M10 10 L90 10 L90 90 L10 90 Z'), square);
    expect(bounds('m10,10 h80 v80 h-80 z'), square);
    // Pairs after a move are lines.
    expect(bounds('M10 10 90 10 90 90'), square);
  });

  test('a smooth quadratic mirrors the previous control point', () {
    // Mirrored, the second curve bows above the line; unmirrored it would be flat.
    expect(bounds('M0 0 Q5 10 10 0 T20 0').top, lessThan(0));
  });

  test('arcs read compact flags and turn toward positive angles', () {
    final arc = bounds('M0 50a50 50 0 01100 0');
    expect(arc.left, closeTo(0, 0.5));
    expect(arc.right, closeTo(100, 0.5));
    expect(arc.top, closeTo(0, 1));
    expect(arc.bottom, closeTo(50, 0.5));
  });

  test('cubic curves reach their end point', () {
    final curve = bounds('M0 0 C0 100 100 100 100 0');
    expect(curve.left, 0);
    expect(curve.right, 100);
    expect(curve.bottom, greaterThan(50));
  });

  test('a bad token keeps what came before it', () {
    expect(bounds('M0 0 L10 10 L x 40'), const Rect.fromLTRB(0, 0, 10, 10));
    expect(parseSvgPathData('nonsense').getBounds(), Rect.zero);
  });

  test('a huge path stops at the number cap', () {
    final d = StringBuffer('M0 0');
    for (var i = 1; i <= kMaxSvgPathNumbers; i++) {
      d.write(' L$i 0');
    }
    final right = bounds(d.toString()).right;
    expect(right, lessThan(kMaxSvgPathNumbers / 2 + 1));
    expect(right, greaterThan(kMaxSvgPathNumbers / 2 - 2));
  });
}
