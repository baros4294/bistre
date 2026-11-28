import 'dart:convert';
import 'dart:io';

import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/design/math_font_gate.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

// 1x1 transparent PNG.
const String _kTinyPngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

Finder _switch(String label) => find.byWidgetPredicate(
  (w) => w is BistreSwitch && w.semanticsLabel == label,
);

void main() {
  testWidgets(
    'profile avatar renders via ResizeImage in user messages and sidebar, and timestamps toggle works',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('bistre_avatar_test_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final avatarFile = File('${tmp.path}/me.png');
      avatarFile.writeAsBytesSync(base64Decode(_kTinyPngB64));

      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;
      await ctrl.setProfileAvatarPath(avatarFile.path);
      await ctrl.submitPassage('Hello with avatar');
      await tester.pumpAndSettle();

      // Both user message header and sidebar render bounded ResizeImage thumbnails.
      final avatars = find.byWidgetPredicate(
        (w) => w is Image && w.image is ResizeImage,
      );
      expect(avatars, findsAtLeastNWidgets(2));

      // Enabling Show message times displays the timestamp in message headers.
      expect(ctrl.uiPrefs.showUserTimestamp, isFalse);
      ctrl.openSettings(SettingsTab.appearance);
      await tester.pumpAndSettle();
      final tsSwitch = _switch(shell.t(L10nKey.settingsPrefsShowTimestamps));
      expect(tsSwitch, findsOneWidget);
      await tester.ensureVisible(tsSwitch);
      await tester.pumpAndSettle();
      await tester.tap(tsSwitch);
      await tester.pumpAndSettle();
      expect(ctrl.uiPrefs.showUserTimestamp, isTrue);

      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets(
    'inline dollar currency stays plain text while real inline math still renders',
    (tester) async {
      await tester.runAsync(MathFontGate.ensureLoaded);
      final shell = await ShellHarness.pump(tester);
      await shell.controller.submitPassage(
        r'Plan costs $10 to $20 per month, while $\alpha + \beta$ is math.',
      );
      await tester.pumpAndSettle();

      final richTexts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.textSpan?.toPlainText() ?? t.data ?? '')
          .join('\n');
      expect(richTexts, contains(r'Plan costs $10 to $20 per month'));
      expect(richTexts, contains('α + β'));

      await tester.pump(const Duration(seconds: 9));
    },
  );
}
