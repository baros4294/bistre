import 'package:bistre_app/design/bistre_motion_widgets.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Motion follows reading direction and Reduce motion, also when either changes later.
Widget _host(Widget child, {TextDirection direction = TextDirection.ltr}) =>
    MediaQuery(
      data: const MediaQueryData(size: Size(400, 300)),
      child: Directionality(
        textDirection: direction,
        child: BistreTheme(data: BistreThemeData.warmSepia, child: child),
      ),
    );

void main() {
  testWidgets('a sideways entrance starts from the reading end in RTL', (
    tester,
  ) async {
    Future<double> startX(TextDirection direction) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _host(
          const Center(
            child: FolioFadeSlide(
              beginOffset: Offset(0.5, 0),
              child: SizedBox(key: ValueKey('panel'), width: 100, height: 40),
            ),
          ),
          direction: direction,
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      final x = tester.getTopLeft(find.byKey(const ValueKey('panel'))).dx;
      await tester.pumpAndSettle();
      return x - tester.getTopLeft(find.byKey(const ValueKey('panel'))).dx;
    }

    expect(await startX(TextDirection.ltr), greaterThan(0));
    expect(
      await startX(TextDirection.rtl),
      lessThan(0),
      reason: 'in RTL the trailing side is on the left',
    );
  });

  testWidgets('the streaming cursor stops when Reduce motion turns on', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const FolioStreamingCursor()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue, reason: 'it breathes');

    await tester.pumpWidget(
      _host(const FolioStreamingCursor(reduceMotionOverride: true)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
