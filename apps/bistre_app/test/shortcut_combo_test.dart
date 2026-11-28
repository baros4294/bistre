import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/shell/shortcut_combo.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// Custom shortcuts: whatever can be recorded also fires, and no recording takes a key away
/// from typing, editing, or another action.
void main() {
  test('function keys and digits can be recorded and bound', () {
    final f5 = ShortcutCombo.record(LogicalKeyboardKey.f5)!;
    expect(f5.combo, 'F5');
    expect(ShortcutCombo.parse('F5')?.trigger, LogicalKeyboardKey.f5);
    final digit = ShortcutCombo.record(LogicalKeyboardKey.digit2, alt: true)!;
    expect(digit.combo, 'Alt+2');
    expect(ShortcutCombo.parse('Alt+2')?.trigger, LogicalKeyboardKey.digit2);
  });

  test('a letter needs Ctrl, Alt or Meta, and editing keys stay', () {
    expect(
      ShortcutCombo.record(LogicalKeyboardKey.keyA, shift: true)?.refusal,
      ShortcutRefusal.needsModifier,
    );
    for (final key in [
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyZ,
    ]) {
      expect(
        ShortcutCombo.record(key, control: true)?.refusal,
        ShortcutRefusal.editing,
      );
    }
    expect(
      ShortcutCombo.record(LogicalKeyboardKey.keyK, control: true)?.combo,
      'Ctrl+K',
    );
    expect(
      ShortcutCombo.record(LogicalKeyboardKey.arrowUp, control: true),
      isNull,
    );
    expect(ShortcutCombo.same('ctrl+shift+f', 'Ctrl+Shift+F'), isTrue);
  });

  testWidgets('a shortcut another action uses is refused and named', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.openSettings(SettingsTab.shortcuts);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(shell.t(L10nKey.shortcutSidebar)));
    await tester.pumpAndSettle();

    // Ctrl+K opens the command palette.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(shell.controller.shortcutFor('sidebar'), 'Ctrl+B');
    expect(
      find.text(
        shell.t(L10nKey.shortcutsTaken, <String, Object?>{
          'action': shell.t(L10nKey.shortcutPalette),
        }),
      ),
      findsOneWidget,
    );

    // Recording goes on: a free shortcut is saved.
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.pumpAndSettle();
    expect(shell.controller.shortcutFor('sidebar'), 'F6');
    await tester.pump(const Duration(seconds: 9));
  });
}
