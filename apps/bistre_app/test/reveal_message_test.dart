import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets(
    'a search hit or pinned reply opens at that exact message (P23)',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
      final chat = gateway.seedThread(title: 'Long', updatedAtMs: 1000);
      String? parent;
      final ids = <String>[];
      for (var i = 0; i < 14; i++) {
        final node = await gateway.appendNode(
          threadId: chat.id,
          parentId: parent,
          role: i.isEven ? 'user' : 'assistant',
          content: 'marker-$i\n\n${'Line of text. ' * 40}',
        );
        ids.add(node.id);
        parent = node.id;
      }
      final shell = await ShellHarness.pump(tester, gateway: gateway);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        find.textContaining('marker-2'),
        findsNothing,
        reason: 'opens at the end',
      );

      await shell.controller.revealNode(chat.id, ids[2]);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final target = find.textContaining('marker-2');
      expect(target, findsOneWidget);
      final view = tester.getRect(find.byType(CustomScrollView).last);
      final rect = tester.getRect(target.first);
      expect(view.overlaps(rect), isTrue, reason: 'the message is in view');
    },
  );
}
