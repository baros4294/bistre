import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/shell/folio_shell_screen.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// Settings > Appearance: Enter-sends and the app text size change what the composer and
/// every screen do, at once.
Finder _composer() => find.byType(EditableText).last;

void main() {
  testWidgets('with Enter-sends off, Enter adds a line and Ctrl+Enter sends', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final ctrl = shell.controller;
    await ctrl.updateSettings(
      ctrl.settings.copyWith(sendOnEnter: false),
      quiet: true,
    );
    await tester.pumpAndSettle();
    await tester.tap(_composer());
    await tester.enterText(_composer(), 'first line');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(shell.gateway.callsTo('sendAndStreamReply'), isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 300));
    expect(shell.gateway.callsTo('sendAndStreamReply'), hasLength(1));
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets(
    'the app text size scales every screen and is set in Appearance',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;
      double scale() =>
          MediaQuery.textScalerOf(tester.element(find.byType(FolioShellScreen)))
              .scale(10);
      expect(scale(), closeTo(10, 0.01));

      ctrl.openSettings(SettingsTab.appearance);
      await tester.pumpAndSettle();
      final option = find.descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w is BistreSettingRow &&
              w.label == shell.t(L10nKey.settingsAppearanceTextSize),
        ),
        matching: find.byType(BistreSegmentedControl<int>),
      );
      await tester.ensureVisible(option);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: option,
          matching: find.text(
            shell.t(L10nKey.settingsAppearanceTextSizeValue, <String, Object?>{
              'percent': 130,
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(ctrl.uiPrefs.textSizePercent, 130);
      expect(scale(), closeTo(13, 0.01));
      expect(
        UiDisplayPrefs.fromJson(const {'textSizePercent': 77}).textSizePercent,
        100,
        reason: 'a size no longer offered falls back to the system size',
      );
    },
  );
}
