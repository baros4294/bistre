import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// Puts [text] in the focused field with the IME still composing its last [composing] chars.
Future<void> _compose(WidgetTester tester, String text, int composing) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange(start: text.length - composing, end: text.length),
    ),
  );
  await tester.pump();
}

Future<void> _commitComposition(WidgetTester tester, String text) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Enter while composing in the / menu picks nothing', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    await tester.tap(find.byType(EditableText).last);
    await tester.pump();
    await _compose(tester, '/pla', 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      shell.controller.activeThread?.mode,
      isNot('plan'),
      reason: 'the IME owns Enter while it composes',
    );
    expect(shell.gateway.callsTo('sendAndStreamReply'), isEmpty);
  });

  testWidgets(
    'a message sent mid-composition is cleared when the IME commits',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final field = find.byType(EditableText).last;
      await tester.tap(field);
      await tester.pump();
      await _compose(tester, 'xin chào', 4);
      await tester.tap(find.text(shell.t(L10nKey.shellComposerSend)).last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(shell.gateway.callsTo('sendAndStreamReply'), hasLength(1));
      expect(
        tester.widget<EditableText>(field).controller.text,
        'xin chào',
        reason: 'never edited while composing',
      );
      await _commitComposition(tester, 'xin chào');
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<EditableText>(field).controller.text,
        isEmpty,
        reason: 'cleared once the IME lets go, so it cannot be sent twice',
      );
    },
  );

  testWidgets('arrows while composing in the palette stay with the IME', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.toggleCommandPalette();
    await tester.pumpAndSettle();
    final query = find.byType(EditableText).last;
    await tester.tap(query);
    await tester.pump();
    await _compose(tester, 'ne', 2);
    final before = shell.controller.commandPaletteOpen;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(shell.controller.commandPaletteOpen, before, reason: 'no entry ran');
  });
}
