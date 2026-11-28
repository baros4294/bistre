import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

Finder _switch(String label) => find.byWidgetPredicate(
  (w) => w is BistreSwitch && w.semanticsLabel == label,
);

void main() {
  testWidgets(
    'Anthropic advanced switches save prompt cache duration and server compaction',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;

      // OpenAI Advanced must not show Anthropic-only switches.
      ctrl.openSettings();
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          EngravedButton,
          shell.t(L10nKey.settingsProviderAdvancedTitle),
        ),
      );
      await tester.pumpAndSettle();
      expect(_switch(shell.t(L10nKey.settingsProviderCacheHour)), findsNothing);
      expect(
        _switch(shell.t(L10nKey.settingsProviderServerCompaction)),
        findsNothing,
      );

      // Select Anthropic and open Advanced.
      await tester.tap(find.text('Anthropic').first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          EngravedButton,
          shell.t(L10nKey.settingsProviderAdvancedTitle),
        ),
      );
      await tester.pumpAndSettle();

      final cacheHour = _switch(shell.t(L10nKey.settingsProviderCacheHour));
      final serverCompact = _switch(
        shell.t(L10nKey.settingsProviderServerCompaction),
      );
      expect(cacheHour, findsOneWidget);
      expect(serverCompact, findsOneWidget);
      expect(tester.widget<BistreSwitch>(cacheHour).value, isFalse);
      expect(tester.widget<BistreSwitch>(serverCompact).value, isTrue);

      await tester.ensureVisible(cacheHour);
      await tester.pumpAndSettle();
      await tester.tap(cacheHour);
      await tester.pumpAndSettle();

      await tester.ensureVisible(serverCompact);
      await tester.pumpAndSettle();
      await tester.tap(serverCompact);
      await tester.pumpAndSettle();

      final saved = await ctrl.loadProviderAdvanced('anthropic');
      expect(saved.anthropicCache1h, isTrue);
      expect(saved.enableServerCompaction, isFalse);

      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets(
    'each provider shows only the switches its API format has, and Gemini saves its tools',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;
      Future<void> openAdvanced(String provider) async {
        ctrl.openSettings();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(provider).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text(provider).first);
        await tester.pumpAndSettle();
        final advanced = find.widgetWithText(
          EngravedButton,
          shell.t(L10nKey.settingsProviderAdvancedTitle),
        );
        await tester.ensureVisible(advanced);
        await tester.pumpAndSettle();
        await tester.tap(advanced);
        await tester.pumpAndSettle();
        expect(
          find.text(
            shell.t(
              L10nKey.settingsProviderAdvancedPageTitle,
              <String, Object?>{'name': provider},
            ),
          ),
          findsOneWidget,
          reason: '$provider Advanced is open',
        );
      }

      String ownTools(String name) => shell.t(
        L10nKey.settingsProviderOwnTools,
        <String, Object?>{'name': name},
      );
      final store = shell.t(L10nKey.settingsProviderStoreServer);

      await openAdvanced('OpenAI');
      expect(_switch(ownTools('OpenAI')), findsNothing);
      expect(find.text(store), findsOneWidget, reason: 'Responses keeps state');
      final paid = _switch(
        shell.t(L10nKey.settingsProviderPaidTools, <String, Object?>{
          'name': 'OpenAI',
        }),
      );
      expect(paid, findsOneWidget, reason: 'paid search is offered, off');
      await tester.ensureVisible(paid);
      await tester.pumpAndSettle();
      await tester.tap(paid);
      await tester.pumpAndSettle();
      expect(
        (await ctrl.loadProviderAdvanced('openai')).paidProviderTools,
        isTrue,
      );

      await openAdvanced('Google Gemini');
      final tools = _switch(ownTools('Google Gemini'));
      expect(tools, findsOneWidget);
      expect(
        find.text(
          shell.t(L10nKey.settingsProviderOwnToolsCapped, <String, Object?>{
            'name': 'Google Gemini',
          }),
        ),
        findsOneWidget,
        reason: 'the default daily limit holds them back, and the row says so',
      );
      await tester.ensureVisible(tools);
      await tester.pumpAndSettle();
      await tester.tap(tools);
      await tester.pumpAndSettle();
      expect(
        (await ctrl.loadProviderAdvanced('google_gemini')).providerTools,
        isTrue,
      );

      await ctrl.createCustomProvider(
        name: 'Proxy',
        baseUrl: 'https://proxy.example.com/v1',
        defaultModel: 'm',
      );
      await openAdvanced('Proxy');
      expect(
        find.text(store),
        findsNothing,
        reason: 'Chat Completions keeps nothing on the server',
      );
      expect(_switch(ownTools('Proxy')), findsNothing);
      await tester.pump(const Duration(seconds: 9));
    },
  );
}
