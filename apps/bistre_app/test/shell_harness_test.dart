import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets(
    'sidebar day groups follow the injected clock, not the wall clock',
    (tester) async {
      final now = DateTime(2026, 3, 14, 10, 30);
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
        ..seedThread(
          title: 'From yesterday',
          updatedAtMs: DateTime(2026, 3, 13, 12).millisecondsSinceEpoch,
        )
        ..seedThread(
          title: 'From January',
          updatedAtMs: DateTime(2026, 1, 2).millisecondsSinceEpoch,
        );
      final shell = await ShellHarness.pump(
        tester,
        gateway: gateway,
        clock: () => now,
      );
      // The newest chat opens at launch, so its title is in both the sidebar and the header.
      expect(find.text('From yesterday'), findsWidgets);
      expect(find.text(shell.t(L10nKey.sidebarGroupYesterday)), findsOneWidget);
      expect(find.text(shell.t(L10nKey.sidebarGroupOlder)), findsOneWidget);
    },
  );

  testWidgets('the shell pumps at phone, desktop, 200% text and RTL', (
    tester,
  ) async {
    for (final layout in ShellLayout.values) {
      for (final textScale in const <double>[1.0, 2.0]) {
        for (final locale in const <String>['en', 'ar']) {
          final shell = await ShellHarness.pump(
            tester,
            layout: layout,
            textScale: textScale,
            locale: locale,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '$layout x$textScale $locale',
          );
          expect(shell.l10n.activeLocale, locale);
        }
      }
    }
  });
}
