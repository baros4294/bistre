import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/features/chat/composer_tools_control.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// The composer controls stay in one row whenever their compact form fits: 200% text on a
/// wide window used to split Tools / Thinking and the voice / Send actions into two rows.
void main() {
  Future<(Offset, Offset)> centers(
    WidgetTester tester,
    ShellLayout layout,
    double textScale, {
    String locale = 'en',
  }) async {
    final shell = await ShellHarness.pump(
      tester,
      layout: layout,
      textScale: textScale,
      locale: locale,
    );
    final tools = tester.getCenter(find.byType(ComposerToolsControl));
    final send = tester.getCenter(
      find.text(shell.t(L10nKey.shellComposerSend)),
    );
    return (tools, send);
  }

  Future<(double, double)> rowTops(
    WidgetTester tester,
    ShellLayout layout,
    double textScale,
  ) async {
    final (tools, send) = await centers(tester, layout, textScale);
    return (tools.dy, send.dy);
  }

  testWidgets('desktop keeps one row at 100% and at 200% text', (tester) async {
    for (final scale in <double>[1.0, 2.0]) {
      final (tools, send) = await rowTops(tester, ShellLayout.desktop, scale);
      expect(send, closeTo(tools, 4), reason: 'one row at ${scale * 100}%');
    }
  });

  testWidgets('a phone keeps the composer in one row at 100% and 200% text', (
    tester,
  ) async {
    for (final scale in <double>[1.0, 2.0]) {
      final shell = await ShellHarness.pump(
        tester,
        layout: ShellLayout.phone,
        textScale: scale,
      );
      final field = tester.getRect(find.byKey(const Key('composer_input')));
      final plus = tester.getRect(
        find.byWidgetPredicate(
          (w) =>
              w is BistreIconButton &&
              w.semanticsLabel == shell.t(L10nKey.composerToolsShow),
        ),
      );
      final voice = tester.getRect(
        find.byWidgetPredicate(
          (w) =>
              w is BistreIconButton &&
              w.semanticsLabel == shell.t(L10nKey.composerVoiceDictate),
        ),
      );
      // + and the voice action sit on the field's row, at its start and end.
      expect(plus.bottom, greaterThan(field.top), reason: '+ at ${scale}x');
      expect(
        voice.bottom,
        greaterThan(field.top),
        reason: 'voice at ${scale}x',
      );
      expect(plus.right, lessThanOrEqualTo(field.left + 1));
      expect(voice.left, greaterThanOrEqualTo(field.right - 1));
      // The occasional controls wait in the closed tray.
      expect(find.byType(ComposerToolsControl).hitTestable(), findsNothing);
    }
  });

  testWidgets('Arabic at 200% keeps one row with Send at the start edge', (
    tester,
  ) async {
    final (tools, send) = await centers(
      tester,
      ShellLayout.desktop,
      2.0,
      locale: 'ar',
    );
    expect(send.dy, closeTo(tools.dy, 4));
    expect(send.dx, lessThan(tools.dx), reason: 'RTL: actions sit on the left');
  });

  testWidgets('a wide window shows the full labels in one row', (tester) async {
    final shell = await ShellHarness.pump(tester);
    tester.view.physicalSize = const Size(2040, 1290);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    final full = shell.t(L10nKey.chatThinkingChip, <String, Object?>{
      'level': shell.t(L10nKey.chatEffortAuto),
    });
    expect(find.text(full), findsOneWidget);
    expect(
      tester.getCenter(find.text(shell.t(L10nKey.shellComposerSend))).dy,
      closeTo(tester.getCenter(find.text(full)).dy, 4),
    );
  });

  testWidgets('the default desktop width keeps the Thinking label in one row', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    await tester.pumpAndSettle();
    final full = shell.t(L10nKey.chatThinkingChip, <String, Object?>{
      'level': shell.t(L10nKey.chatEffortAuto),
    });
    expect(find.text(full), findsOneWidget);
    expect(
      tester.getCenter(find.text(shell.t(L10nKey.shellComposerSend))).dy,
      closeTo(tester.getCenter(find.text(full)).dy, 4),
    );
  });

  testWidgets(
    'the Thinking chip keeps its level in words before Tools and Live do',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      tester.view.physicalSize = const Size(2040, 1290);
      await shell.controller.setReasoningEffort('xhigh');
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      final full = shell.t(L10nKey.chatThinkingChip, <String, Object?>{
        'level': shell.t(L10nKey.chatEffortExtra),
      });
      expect(find.text(full), findsOneWidget);
      expect(
        tester.getCenter(find.text(shell.t(L10nKey.shellComposerSend))).dy,
        closeTo(tester.getCenter(find.text(full)).dy, 4),
      );
      await tester.pump(const Duration(seconds: 9));
    },
  );
}
