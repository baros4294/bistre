import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets(
    'a reply that finished unseen is still marked new after a restart',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
      final unseen = gateway.seedThread(title: 'Unseen', updatedAtMs: 1000);
      final seen = gateway.seedThread(title: 'Seen', updatedAtMs: 2000);
      final never = gateway.seedThread(
        title: 'Never opened',
        updatedAtMs: 3000,
      );
      for (final t in [unseen, seen, never]) {
        gateway.seedNode(threadId: t.id, role: 'user', content: 'hi');
        gateway.seedAgentRun(threadId: t.id, status: 'completed');
      }
      // The reply in "Unseen" arrived after it was last looked at; "Seen" was read to the end.
      await gateway.setKvMeta('thread.last_viewed_rev:${unseen.id}', '0');
      await gateway.setKvMeta('thread.last_viewed_rev:${seen.id}', '1');

      final shell = await ShellHarness.pump(tester, gateway: gateway);
      final ctrl = shell.controller;
      expect(ctrl.threadRunState(unseen.id), ThreadRunState.doneUnread);
      expect(ctrl.threadRunState(seen.id), ThreadRunState.idle);
      expect(
        ctrl.threadRunState(never.id),
        ThreadRunState.idle,
        reason: 'a chat with no viewing record (older data) gets no badge',
      );

      await ctrl.selectThread(unseen.id);
      await tester.pump();
      expect(ctrl.threadRunState(unseen.id), ThreadRunState.idle);
      expect(
        await gateway.getKvMeta('thread.last_viewed_rev:${unseen.id}'),
        '1',
        reason: 'opening a chat records what was seen',
      );
      await tester.pump(const Duration(seconds: 9));
    },
  );
}
