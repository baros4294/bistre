import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Two chats: A (newest, opens at launch, with one message) and B (empty).
Future<(ShellHarness, EngineThread, EngineThread)> _twoChats(
  WidgetTester tester,
  ShellLayout layout,
) async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final b = gateway.seedThread(title: 'Chat B', updatedAtMs: 1000);
  final a = gateway.seedThread(title: 'Chat A', updatedAtMs: 2000);
  await gateway.appendNode(
    threadId: a.id,
    role: 'user',
    content: 'earlier message in A',
  );
  final shell = await ShellHarness.pump(
    tester,
    layout: layout,
    gateway: gateway,
  );
  expect(shell.controller.activeThread?.id, a.id);
  return (shell, a, b);
}

void main() {
  for (final layout in ShellLayout.values) {
    testWidgets(
      'Enter while the next chat is loading never sends into it ($layout)',
      (tester) async {
        final (shell, a, b) = await _twoChats(tester, layout);
        shell.gateway.gate('listNodesWindow');
        final switching = shell.controller.selectThread(b.id);
        await tester.pump();

        await tester.enterText(find.byType(EditableText).last, 'meant for A');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        shell.gateway.release('listNodesWindow');
        await switching;
        await tester.pumpAndSettle();

        final sends = shell.gateway.callsTo('sendAndStreamReply').toList();
        for (final send in sends) {
          final parent = send.args['parentId'];
          final parentThread = parent == null
              ? null
              : (await shell.gateway.listNodes(
                  send.args['threadId']! as String,
                )).where((n) => n.id == parent).firstOrNull;
          expect(
            parent == null || parentThread != null,
            isTrue,
            reason:
                'a message was sent into ${send.args['threadId']} under a parent '
                'from another chat: $send',
          );
        }
        expect(
          sends.where((s) => s.args['threadId'] == b.id),
          isEmpty,
          reason: 'nothing typed for A may be sent into B',
        );
        expect(shell.controller.activeThread?.id, b.id);
      },
    );
  }

  testWidgets(
    'a send that finishes after switching chats stays in its own chat',
    (tester) async {
      final (shell, a, b) = await _twoChats(tester, ShellLayout.desktop);
      shell.gateway.gate('sendAndStreamReply');
      final sending = shell.controller.submitPassage('still for A');
      await tester.pump();
      await shell.controller.selectThread(b.id);
      await tester.pump();
      shell.gateway.release('sendAndStreamReply');
      await sending;
      await tester.pumpAndSettle();

      expect(shell.controller.activeThread?.id, b.id);
      expect(
        shell.controller.nodes.where((n) => n.threadId == a.id),
        isEmpty,
        reason: "chat A's message must not appear in chat B",
      );
    },
  );

  testWidgets(
    'a mode change that finishes after switching chats changes only its chat',
    (tester) async {
      final (shell, a, b) = await _twoChats(tester, ShellLayout.desktop);
      shell.gateway.gate('updateThread');
      final changing = shell.controller.setActiveThreadMode('code');
      await tester.pump();
      await shell.controller.selectThread(b.id);
      await tester.pump();
      shell.gateway.release('updateThread');
      await changing;
      await tester.pumpAndSettle();

      expect(
        shell.controller.activeThread?.id,
        b.id,
        reason: 'the header stays on B',
      );
      expect(shell.controller.activeThread?.mode, 'chat');
      final stored = (await shell.gateway.listThreads()).firstWhere(
        (t) => t.id == a.id,
      );
      expect(stored.mode, 'code');
    },
  );
}
