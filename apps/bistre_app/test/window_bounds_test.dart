import 'dart:async';

import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/platform/desktop_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  testWidgets('resizing saves once and never undoes a setting change (U22)', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final ctrl = shell.controller;
    final before = shell.gateway.callsTo('saveSettings').length;
    for (var w = 900; w < 1000; w += 10) {
      unawaited(
        ctrl.persistWindowBounds(
          DesktopWindowBounds(
            x: 10,
            y: 10,
            width: w,
            height: 700,
            maximized: false,
          ),
        ),
      );
    }
    // A setting changed while the window is still being resized.
    final nextTheme = ctrl.isDark ? 'day' : 'night';
    await ctrl.updateSettings(ctrl.settings.copyWith(theme: nextTheme));
    await tester.pump(const Duration(seconds: 1));
    final saves = shell.gateway.callsTo('saveSettings').length - before;
    expect(saves, lessThanOrEqualTo(2), reason: 'not one save per resize tick');
    final stored = await shell.gateway.loadSettings();
    expect(stored.theme, nextTheme, reason: 'the change is not undone');
    expect(stored.windowBoundsJson, contains('990'));
    // Let the 'settings saved' toast run out.
    await tester.pump(const Duration(seconds: 6));
  });
}
