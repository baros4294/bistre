import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  for (final layout in ShellLayout.values) {
    testWidgets(
      'workspace hooks are listed and run only once allowed ($layout)',
      (tester) async {
        final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
          ..workspaceHooks = const EngineWorkspaceHooksStatus(
            hooks: <EngineWorkspaceHook>[
              EngineWorkspaceHook(
                event: 'pre_tool_use',
                command: 'cargo fmt --check',
                toolFilter: 'edit',
              ),
            ],
            digest: 'abc123',
            approved: false,
          );
        final shell = await ShellHarness.pump(
          tester,
          layout: layout,
          gateway: gateway,
        );
        await shell.controller.setWorkspaceRootPath('C:/work/repo');
        shell.controller.openSettings(SettingsTab.agent);
        await tester.pumpAndSettle();

        expect(find.text('cargo fmt --check'), findsOneWidget);
        expect(
          find.text(shell.t(L10nKey.settingsAgentHooksPending)),
          findsOneWidget,
        );

        final allow = find.text(shell.t(L10nKey.settingsAgentHooksAllow));
        await tester.ensureVisible(allow);
        await tester.tap(allow);
        await tester.pumpAndSettle();

        final call = gateway.callsTo('approveWorkspaceHooks').single;
        expect(call.args, <String, Object?>{
          'workspaceRoot': 'C:/work/repo',
          'digest': 'abc123',
        });
        expect(
          find.text(shell.t(L10nKey.settingsAgentHooksAllowed)),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 10));
      },
    );
  }
}
