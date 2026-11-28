import 'package:bistre_app/design/bistre_motion_widgets.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets(
    'a failed update check shows a plain message in Updates, not a raw key or a chat error',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
        ..updateCheckFailure = 'diag.ota.integrity_failed:asset_mismatch';
      final shell = await ShellHarness.pump(tester, gateway: gateway);
      await shell.controller.checkForUpdates();
      await tester.pump();
      expect(
        shell.controller.lastDiagnosticKey,
        isNull,
        reason: 'update errors never show in the chat composer',
      );
      expect(shell.controller.lastOtaDiagnostic, 'diag.ota.integrity_failed');
      expect(shell.controller.lastOtaDetail, 'asset_mismatch');

      shell.controller.openSettings(SettingsTab.updates);
      await tester.pumpAndSettle();
      expect(
        find.text(shell.l10n.tRawKey('diag.ota.integrity_failed')),
        findsOneWidget,
      );
      expect(find.textContaining('diag.ota.'), findsNothing);
      // The detail stays behind "Technical details".
      expect(find.text('asset_mismatch'), findsNothing);
      await tester.tap(find.text(shell.t(L10nKey.settingsOtaTechnicalDetails)));
      await tester.pumpAndSettle();
      expect(find.textContaining('asset_mismatch'), findsOneWidget);
    },
  );

  testWidgets('a failed update download offers Open Updates', (tester) async {
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
      ..stageUpdateFailure = 'diag.ota.integrity_failed:asset_mismatch';
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    await shell.controller.checkForUpdates();
    await shell.controller.stageAvailableUpdate();
    await tester.pump();
    expect(shell.controller.lastDiagnosticKey, isNull);
    final toast = shell.controller.toast.value;
    expect(toast?.key, L10nKey.toastUpdateStageFailed);
    expect(toast?.actionKey, L10nKey.settingsOtaOpenUpdates);
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets(
    'an update staged earlier offers Install update, which says why it failed',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
        ..pendingUpdate = '9.0.0'
        ..installFailure = 'diag.ota.install_failed:install_cancelled';
      final shell = await ShellHarness.pump(tester, gateway: gateway);
      await tester.pumpAndSettle();
      expect(shell.controller.pendingUpdateVersion, '9.0.0');
      shell.controller.openSettings(SettingsTab.updates);
      await tester.pumpAndSettle();
      expect(
        find.text(
          shell.t(L10nKey.settingsOtaStagedReady, <String, Object?>{
            'version': '9.0.0',
          }),
        ),
        findsOneWidget,
      );
      final install = find.text(shell.t(L10nKey.settingsOtaInstall));
      await tester.ensureVisible(install);
      await tester.pumpAndSettle();
      await tester.tap(install);
      await tester.pumpAndSettle();
      expect(gateway.callsTo('installStagedUpdate'), hasLength(1));
      expect(find.text(shell.t(L10nKey.diagOtaInstallFailed)), findsOneWidget);
      expect(
        shell.controller.pendingUpdateVersion,
        '9.0.0',
        reason: 'a failed install stays offered',
      );
    },
  );

  testWidgets('notice close buttons say Dismiss, not Cancel', (tester) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.showToast(L10nKey.toastCopied);
    await tester.pump();
    final banner = tester.widget<FolioToastBanner>(
      find.byType(FolioToastBanner),
    );
    expect(banner.dismissLabel, shell.t(L10nKey.shellDismiss));
    await tester.pump(const Duration(seconds: 4));
  });
}
