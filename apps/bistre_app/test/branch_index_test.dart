import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets(
    'branch info is computed from one index, not one pass per message',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
      final chat = gateway.seedThread(title: 'Long', updatedAtMs: 1000);
      String? parent;
      for (var i = 0; i < 300; i++) {
        final node = await gateway.appendNode(
          threadId: chat.id,
          parentId: parent,
          role: i.isEven ? 'user' : 'assistant',
          content: 'm$i',
        );
        parent = node.id;
      }
      final shell = await ShellHarness.pump(tester, gateway: gateway);
      await tester.pump();
      final ctrl = shell.controller;
      final before = ctrl.debugBranchIndexBuilds;
      for (final node in ctrl.visibleBranchNodes) {
        ctrl.branchInfoFor(node);
      }
      expect(ctrl.visibleBranchNodes, hasLength(300));
      expect(ctrl.debugBranchIndexBuilds - before, lessThanOrEqualTo(1));
    },
  );
}
