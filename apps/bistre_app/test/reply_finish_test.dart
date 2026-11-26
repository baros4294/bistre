import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets('a provider error shows what the provider said (P4)', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    shell.gateway.emit(
      const DiagnosticRaisedEvent(
        key: 'diag.provider.request_failed',
        detailCode: 'http_404;reason=The model `m` does not exist',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.text(
        shell.t(L10nKey.chatDiagProviderReason, <String, Object?>{
          'reason': 'The model `m` does not exist',
        }),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a reply cut at its length limit offers Continue (R10)', (
    tester,
  ) async {
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
    final chat = gateway.seedThread(title: 'Long', updatedAtMs: 1000);
    await gateway.appendNode(threadId: chat.id, role: 'user', content: 'write');
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    gateway.emit(
      const DiagnosticRaisedEvent(key: 'diag.provider.reply_truncated'),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text(shell.t(L10nKey.chatFixContinue)));
    await tester.pump(const Duration(milliseconds: 300));
    final sent = gateway.callsTo('sendAndStreamReply').single.args;
    expect(sent['userContent'], shell.t(L10nKey.chatFixContinueMessage));
    await tester.pump(const Duration(seconds: 3));
  });
}
