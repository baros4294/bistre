import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

DiagnosticRaisedEvent _backoff(int ms, int attempt) => DiagnosticRaisedEvent(
  key: 'diag.run.backoff_waiting',
  detailCode:
      'retry_in_ms=$ms;attempt=$attempt;reason=diag.provider.rate_limited',
);

void main() {
  testWidgets('the retry notice says which try it is and keeps counting', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final threadId = shell.controller.activeThread!.id;
    String notice(int seconds, int attempt) => shell.t(
      L10nKey.chatBackoffNoticeAttempt,
      <String, Object?>{'seconds': seconds, 'attempt': attempt},
    );

    shell.gateway
      ..emit(RunStartedEvent(threadId: threadId, nodeId: 'live'))
      ..emit(_backoff(2000, 1));
    await tester.pump();
    await tester.pump();
    expect(find.text(notice(2, 1)), findsOneWidget);
    // The reason reads as words, never as a raw diagnostic key.
    expect(find.text('diag.provider.rate_limited'), findsNothing);
    expect(
      find.text(shell.l10n.tRawKey('diag.provider.rate_limited')),
      findsOneWidget,
    );

    // The first wait runs out (its ticker stops), then a second, longer one starts.
    await tester.pump(const Duration(milliseconds: 2600));
    shell.gateway.emit(_backoff(5000, 2));
    await tester.pump();
    await tester.pump();
    expect(find.text(notice(5, 2)), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(
      find.text(notice(4, 2)),
      findsOneWidget,
      reason: 'the countdown keeps going for the new wait',
    );
    shell.gateway.emit(
      RunFinishedEvent(threadId: threadId, nodeId: 'live', cancelled: false),
    );
    await tester.pump(const Duration(seconds: 6));
  });
}
