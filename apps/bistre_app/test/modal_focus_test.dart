import 'package:bistre_app/design/bistre_motion_widgets.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

bool _focusInside(WidgetTester tester, Finder modal) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final modalElement = tester.element(modal);
  var inside = false;
  focused.visitAncestorElements((e) {
    if (e == modalElement) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

void main() {
  testWidgets(
    'Tab stays inside the command palette and focus comes back after',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final composer = find.byType(EditableText).last;
      await tester.tap(composer);
      await tester.pump();
      final composerFocus = tester.widget<EditableText>(composer).focusNode;
      expect(composerFocus.hasFocus, isTrue);

      shell.controller.toggleCommandPalette();
      await tester.pumpAndSettle();
      final modal = find.byType(FolioModalBackdrop);
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          _focusInside(tester, modal),
          isTrue,
          reason: 'Tab $i left the palette for the hidden page behind it',
        );
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(shell.controller.commandPaletteOpen, isFalse);
      expect(
        composerFocus.hasFocus,
        isTrue,
        reason: 'focus returns where it was',
      );
    },
  );
}
