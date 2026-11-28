import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/settings/auto_compact_row.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// How full a chat may get before it is shortened is set with a slider or a typed number;
/// numbers outside the allowed range snap to its nearest end.
void main() {
  for (final (layout, scale, locale) in <(ShellLayout, double, String)>[
    (ShellLayout.desktop, 1, 'en'),
    (ShellLayout.phone, 2, 'en'),
    (ShellLayout.phone, 1, 'ar'),
  ]) {
    testWidgets('the auto-shorten point is typed or slid '
        '($layout, $scale, $locale)', (tester) async {
      final shell = await ShellHarness.pump(
        tester,
        layout: layout,
        textScale: scale,
        locale: locale,
      );
      final ctrl = shell.controller;
      // Saving a setting re-applies the saved locale, so save the one under test.
      await ctrl.updateSettings(
        ctrl.settings.copyWith(locale: locale),
        quiet: true,
      );
      ctrl.openSettings(SettingsTab.defaultModels);
      await tester.pumpAndSettle();
      final row = find.byType(AutoCompactRow);
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(ctrl.settings.autoCompactAtPercent, 85);

      final box = find.descendant(of: row, matching: find.byType(EditableText));
      for (final (typed, saved) in <(String, int)>[
        ('70', 70),
        ('20', kAutoCompactMinPercent),
        ('120', kAutoCompactMaxPercent),
        ('abc', kAutoCompactMaxPercent),
      ]) {
        await tester.enterText(box, typed);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        // Leaving the box applies what was typed.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(ctrl.settings.autoCompactAtPercent, saved, reason: typed);
        expect(tester.widget<EditableText>(box).controller.text, '$saved');
      }

      final slider = find.descendant(
        of: row,
        matching: find.byType(BistreSlider),
      );
      expect(tester.widget<BistreSlider>(slider).value, 95);
      // Toward the start edge, which is on the right in Arabic.
      final width = tester.getSize(slider).width;
      expect(
        Directionality.of(tester.element(slider)),
        locale == 'ar' ? TextDirection.rtl : TextDirection.ltr,
      );
      await tester.drag(slider, Offset(locale == 'ar' ? width : -width, 0));
      await tester.pumpAndSettle();
      expect(ctrl.settings.autoCompactAtPercent, kAutoCompactMinPercent);
      expect(
        tester.widget<EditableText>(box).controller.text,
        '$kAutoCompactMinPercent',
      );
      // The thumb sits at the start edge: on the right in Arabic.
      final thumb = find.descendant(
        of: slider,
        matching: find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == 16 && w.height == 16,
        ),
      );
      final track = tester.getRect(slider);
      final thumbX = tester.getCenter(thumb).dx;
      if (locale == 'ar') {
        expect(thumbX, greaterThan(track.right - 16));
        expect(thumbX, lessThanOrEqualTo(track.right));
      } else {
        expect(thumbX, lessThan(track.left + 16));
        expect(thumbX, greaterThanOrEqualTo(track.left));
      }
      expect(find.byType(QuillInput), findsWidgets);
      await tester.pump(const Duration(seconds: 9));
    });
  }
}
