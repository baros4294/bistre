import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  for (final layout in ShellLayout.values) {
    testWidgets(
      'a settings file that loosens safety asks before applying ($layout)',
      (tester) async {
        final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
          ..importLoosensSafety = true;
        final shell = await ShellHarness.pump(
          tester,
          layout: layout,
          gateway: gateway,
        );

        expect(await shell.controller.importSettingsJson('{}'), isFalse);
        await tester.pump();
        expect(
          find.text(shell.t(L10nKey.diagImportLoosensSafety)),
          findsOneWidget,
        );

        await tester.tap(find.text(shell.t(L10nKey.settingsImportAnyway)));
        await tester.pumpAndSettle();

        expect(
          gateway
              .callsTo('importSettingsJson')
              .map((c) => c.args['allowLoosening']),
          <Object?>[false, true],
        );
        // Let the confirmation and success toasts time out.
        await tester.pump(const Duration(seconds: 15));
      },
    );
  }
}
