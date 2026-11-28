import 'package:bistre_app/bridge/engine_models.dart';
import 'package:bistre_app/features/settings/usage_by_purpose_section.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Default models lists what paid requests were for, so background work shows beside chats.
void main() {
  for (final (layout, scale, locale) in <(ShellLayout, double, String)>[
    (ShellLayout.desktop, 1, 'en'),
    (ShellLayout.phone, 2, 'en'),
    (ShellLayout.phone, 1, 'ar'),
  ]) {
    testWidgets('use per purpose is listed ($layout, $scale, $locale)', (
      tester,
    ) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
        ..purposeUsage = const <EnginePurposeUsage>[
          EnginePurposeUsage(
            purpose: EngineSpendPurpose.chat,
            requests: 12,
            costMicros: 840000,
          ),
          EnginePurposeUsage(
            purpose: EngineSpendPurpose.title,
            requests: 1,
            costMicros: 2000,
          ),
        ];
      final shell = await ShellHarness.pump(
        tester,
        layout: layout,
        textScale: scale,
        locale: locale,
        gateway: gateway,
      );
      final ctrl = shell.controller;
      await ctrl.updateSettings(
        ctrl.settings.copyWith(locale: locale),
        quiet: true,
      );
      ctrl.openSettings(SettingsTab.defaultModels);
      await tester.pumpAndSettle();
      final section = find.byType(UsageByPurposeSection);
      await tester.ensureVisible(section);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final l10n = shell.l10n;
      for (final text in <String>[
        l10n.t(L10nKey.settingsDefaultModelsUsageHeading),
        l10n.t(L10nKey.settingsDefaultModelsUsageChat),
        l10n.t(L10nKey.settingsDefaultModelsUsageTitle),
      ]) {
        expect(
          find.descendant(of: section, matching: find.text(text)),
          findsOneWidget,
          reason: text,
        );
      }
      // Purposes with no use are left out.
      expect(
        find.descendant(
          of: section,
          matching: find.text(l10n.t(L10nKey.settingsDefaultModelsUsageVoice)),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: section,
          matching: find.textContaining(r'$0.84', findRichText: true),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 9));
    });
  }

  testWidgets('nothing shows before any use', (tester) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.openSettings(SettingsTab.defaultModels);
    await tester.pumpAndSettle();
    expect(
      find.text(shell.l10n.t(L10nKey.settingsDefaultModelsUsageHeading)),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 9));
  });
}
