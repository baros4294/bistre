import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

Finder _switch(String label) => find.byWidgetPredicate(
  (w) => w is BistreSwitch && w.semanticsLabel == label,
);

void main() {
  testWidgets(
    'Updates tab exposes auto-check switch, checks on boot only when enabled, and offers Reinstall when up to date',
    (tester) async {
      // 1. Boot with otaAutoCheck = false performs zero update checks.
      final gwOff = FakeEngineGateway(seedConnectedOpenAi: true);
      await gwOff.saveSettings(const EngineSettings(otaAutoCheck: false));
      final shellOff = await ShellHarness.pump(tester, gateway: gwOff);
      await tester.pumpAndSettle();
      expect(gwOff.callsTo('checkForUpdates'), isEmpty);

      // 2. Updates tab shows the Check for updates on launch switch and toggles it.
      shellOff.controller.openSettings(SettingsTab.updates);
      await tester.pumpAndSettle();
      final autoSwitch = _switch(shellOff.t(L10nKey.settingsOtaAutoCheck));
      expect(autoSwitch, findsOneWidget);
      await tester.ensureVisible(autoSwitch);
      await tester.pumpAndSettle();
      await tester.tap(autoSwitch);
      await tester.pumpAndSettle();
      expect(shellOff.controller.settings.otaAutoCheck, isTrue);

      // 3. When up to date (latest == current), Reinstall this version button appears and stages.
      gwOff.updateCheckOverride = const EngineUpdateCheck(
        currentVersion: '0.1.0',
        latestVersion: '0.1.0',
        updateAvailable: false,
        track: 'track_b',
        ownershipMode: 'self_managed',
        signatureVerified: true,
        activeRunsBlocking: false,
        releaseNotes: '',
        downloadUrl: 'https://example.invalid/bistre-0.1.0.zip',
        sha256Hex: '0000',
        downloadSizeBytes: 12400000,
        checkedAtMs: 1700000000000,
      );
      await shellOff.controller.checkForUpdates();
      await tester.pumpAndSettle();
      final reinstallBtn = find.text(shellOff.t(L10nKey.settingsOtaReinstall));
      expect(reinstallBtn, findsOneWidget);
      await tester.ensureVisible(reinstallBtn);
      await tester.pumpAndSettle();
      await tester.tap(reinstallBtn);
      await tester.pumpAndSettle();
      expect(gwOff.callsTo('reinstallUpdate'), hasLength(1));

      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets('boot with otaAutoCheck = true runs a quiet update check', (
    tester,
  ) async {
    final gwOn = FakeEngineGateway(seedConnectedOpenAi: true);
    await gwOn.saveSettings(const EngineSettings());
    await ShellHarness.pump(tester, gateway: gwOn);
    await tester.pumpAndSettle();
    expect(gwOn.callsTo('checkForUpdates'), hasLength(1));
    await tester.pump(const Duration(seconds: 9));
  });
}
