import 'dart:ui';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets('deleting a chat that is replying stops its run at once (U5)', (
    tester,
  ) async {
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
    final chat = gateway.seedThread(title: 'Busy', updatedAtMs: 2000);
    gateway.seedThread(title: 'Other', updatedAtMs: 1000);
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    gateway.emit(RunStartedEvent(threadId: chat.id, nodeId: 'live'));
    await tester.pump();

    await shell.controller.deleteThread(chat.id);
    await tester.pump();
    expect(
      gateway.callsTo('cancelActiveRun').map((c) => c.args['threadId']),
      contains(chat.id),
      reason: 'a deleted chat must not keep spending during the Undo window',
    );
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets(
    'switching windows keeps the Undo window; closing commits it (U7)',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
      final chat = gateway.seedThread(title: 'Gone', updatedAtMs: 2000);
      gateway.seedThread(title: 'Other', updatedAtMs: 1000);
      final shell = await ShellHarness.pump(tester, gateway: gateway);
      await shell.controller.deleteThread(chat.id);
      await tester.pump();

      // Alt-Tab on desktop: the app only becomes inactive, it is not closing.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(
        gateway.callsTo('deleteThread'),
        isEmpty,
        reason: 'Undo must still work',
      );

      await shell.controller.undoDeleteThread(chat.id);
      await tester.pump();
      expect((await gateway.listThreads()).map((t) => t.id), contains(chat.id));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 9));
    },
  );
}
