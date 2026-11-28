import 'dart:io';

import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/features/chat/composer_phone_controls.dart';
import 'package:bistre_app/features/chat/folio_composer.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// A folder can be added from the composer, beside the attach-file button.
void main() {
  for (final (layout, scale, locale) in <(ShellLayout, double, String)>[
    (ShellLayout.desktop, 1, 'en'),
    (ShellLayout.phone, 2, 'en'),
    (ShellLayout.phone, 1, 'ar'),
  ]) {
    testWidgets('the composer adds a folder ($layout, $scale, $locale)', (
      tester,
    ) async {
      const channel = MethodChannel('bistre/desktop_host');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        return call.method == 'pickLocalFolder' ? r'C:\work\notes' : null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final shell = await ShellHarness.pump(
        tester,
        layout: layout,
        textScale: scale,
        locale: locale,
      );
      final ctrl = shell.controller;
      // On a phone the composer's extra buttons sit in the + tray.
      if (layout == ShellLayout.phone) {
        await tester.tap(find.byType(ComposerTrayToggle));
        await tester.pumpAndSettle();
      }
      final button = find.descendant(
        of: find.byType(FolioComposer),
        matching: find.byWidgetPredicate(
          (w) => w is BistreIconButton && w.icon == BistreUiIcon.folder,
        ),
      );
      expect(button, findsOneWidget);
      expect(tester.widget<BistreIconButton>(button).active, isFalse);
      expect(tester.takeException(), isNull);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(ctrl.workspaceFolders, <String>[r'C:\work\notes']);
      expect(ctrl.workspaceRootPath, r'C:\work\notes');
      expect(tester.widget<BistreIconButton>(button).active, isTrue);
      await tester.pump(const Duration(seconds: 9));
      // The mock is the Windows and Android host picker; on Linux core runs the picker.
    }, skip: Platform.isLinux);
  }
}
