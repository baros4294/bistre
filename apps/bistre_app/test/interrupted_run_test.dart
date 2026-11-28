import 'dart:io';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/composer_notice.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// A chat whose last reply a restart cut off (core marks that run `diag.run.interrupted`).
Future<(FakeEngineGateway, String, String)> _cutOffChat() async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final chat = gateway.seedThread(title: 'Cut off', updatedAtMs: 1000);
  final user = await gateway.appendNode(
    threadId: chat.id,
    role: 'user',
    content: 'Summarise the notes',
  );
  gateway.seedAgentRun(
    threadId: chat.id,
    status: 'failed',
    errorKey: 'diag.run.interrupted',
  );
  return (gateway, chat.id, user.id);
}

Finder _tryAgain(ShellHarness shell) =>
    find.widgetWithText(EngravedButton, shell.t(L10nKey.chatActionRegenerate));

void main() {
  for (final (layout, scale, locale) in <(ShellLayout, double, String)>[
    (ShellLayout.desktop, 1, 'en'),
    (ShellLayout.phone, 2, 'en'),
    (ShellLayout.phone, 1, 'ar'),
  ]) {
    testWidgets('a reply a restart cut off offers Try again ($layout, $scale, '
        '$locale)', (tester) async {
      final (gateway, chatId, userId) = await _cutOffChat();
      final shell = await ShellHarness.pump(
        tester,
        layout: layout,
        textScale: scale,
        locale: locale,
        gateway: gateway,
      );
      await shell.controller.selectThread(chatId);
      await tester.pumpAndSettle();
      final notice = find.text(shell.l10n.tRawKey('diag.run.interrupted'));
      expect(notice, findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(_tryAgain(shell));
      await tester.pumpAndSettle();
      final retried = gateway.calls.where((c) => c.method == 'regenerateReply');
      expect(retried.single.args['userNodeId'], userId);
      expect(notice, findsNothing);
      await tester.pump(const Duration(seconds: 9));
    });
  }

  testWidgets('closing the notice hides it; another chat never shows it', (
    tester,
  ) async {
    final (gateway, chatId, _) = await _cutOffChat();
    final other = gateway.seedThread(title: 'Other', updatedAtMs: 900);
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    final notice = find.text(shell.l10n.tRawKey('diag.run.interrupted'));
    await shell.controller.selectThread(other.id);
    await tester.pumpAndSettle();
    expect(notice, findsNothing);

    await shell.controller.selectThread(chatId);
    await tester.pumpAndSettle();
    expect(notice, findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(ComposerNotice),
        matching: find.byType(BistreIconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(notice, findsNothing);
    expect(gateway.calls.where((c) => c.method == 'regenerateReply'), isEmpty);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('the keep-going switch shows only with the background service', (
    tester,
  ) async {
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
      ..seedPowerStatus(const EnginePowerGuardStatus(daemonConnected: true));
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    shell.controller.openSettings(SettingsTab.agent);
    await tester.pumpAndSettle();
    expect(find.text(shell.t(L10nKey.settingsSleepDaemonActive)), findsOne);
    expect(
      find.text(shell.t(L10nKey.settingsSleepWindowsBattery)),
      Platform.isWindows ? findsOne : findsNothing,
    );
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('without the background service the switch is not shown', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.openSettings(SettingsTab.agent);
    await tester.pumpAndSettle();
    expect(find.text(shell.t(L10nKey.settingsSleepDaemonActive)), findsNothing);
    await tester.pump(const Duration(seconds: 9));
  });
}
