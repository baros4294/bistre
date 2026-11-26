import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  for (final layout in ShellLayout.values) {
    testWidgets(
      '"Allow once" on an unknown price allows the chat and retries ($layout)',
      (tester) async {
        final shell = await ShellHarness.pump(tester, layout: layout);
        await tester.enterText(find.byType(EditableText).last, 'hello');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        final threadId = shell.controller.activeThread!.id;
        final sentTo = shell.gateway
            .callsTo('sendAndStreamReply')
            .single
            .args['threadId'];
        expect(sentTo, threadId);

        shell.gateway.emit(
          const DiagnosticRaisedEvent(key: 'diag.wallet.price_unknown'),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(shell.l10n.tRawKey('diag.wallet.price_unknown')),
          findsOneWidget,
        );

        await tester.tap(find.text(shell.t(L10nKey.chatFixAllowUnpricedOnce)));
        await tester.pumpAndSettle();

        final order = shell.gateway.calls
            .map((c) => c.method)
            .where((m) => m == 'allowUnpricedOnce' || m == 'regenerateReply')
            .toList();
        expect(order, <String>['allowUnpricedOnce', 'regenerateReply']);
        expect(
          shell.gateway.callsTo('allowUnpricedOnce').single.args['threadId'],
          threadId,
        );
      },
    );
  }
}
