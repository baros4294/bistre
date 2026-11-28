import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/hover_hint.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a hint goes away when its control moves out from under the pointer',
    (tester) async {
      var shifted = false;
      late StateSetter setHost;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: BistreTheme(
            data: BistreThemeData.warmSepia,
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (_) => StatefulBuilder(
                    builder: (context, setState) {
                      setHost = setState;
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: shifted ? 400 : 100,
                            top: 100,
                          ),
                          child: const HoverHint(
                            message: 'New chat',
                            child: SizedBox(width: 40, height: 40),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(120, 120));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('New chat'), findsOneWidget);

      setHost(() => shifted = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('New chat'),
        findsNothing,
        reason: 'the pointer is no longer on it',
      );
      await mouse.removePointer();
    },
  );
}
