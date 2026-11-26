import 'package:bistre_app/features/inspector/chat_inspector_drawer.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

Finder _promptField() => find
    .descendant(
      of: find.byType(ChatInspectorDrawer),
      matching: find.byType(EditableText),
    )
    .at(1);

void main() {
  testWidgets(
    'a chat\'s prompt edit survives switching chats while it saves (U36)',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
      final b = gateway.seedThread(title: 'Chat B', updatedAtMs: 1000);
      final a = gateway.seedThread(title: 'Chat A', updatedAtMs: 2000);
      final shell = await ShellHarness.pump(tester, gateway: gateway);
      shell.controller.toggleInspector();
      await tester.pumpAndSettle();

      // The save of the edit is slow (a busy disk); the user moves on before it finishes.
      gateway.gate('updateThread');
      await tester.enterText(_promptField(), 'Answer in French');
      await tester.pump();
      await shell.controller.selectThread(b.id);
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(_promptField()).controller.text,
        isEmpty,
        reason: 'chat B has no prompt',
      );
      await shell.controller.selectThread(a.id);
      await tester.pumpAndSettle();
      // The slow save only finishes now, after the user came back.
      gateway.release('updateThread');
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(_promptField()).controller.text,
        'Answer in French',
      );
      final stored = (await gateway.listThreads()).firstWhere(
        (t) => t.id == a.id,
      );
      expect(stored.systemPromptOverride, 'Answer in French');
      expect(
        (await gateway.listThreads())
            .firstWhere((t) => t.id == b.id)
            .systemPromptOverride,
        isNull,
        reason: 'the edit never lands on the chat that was opened next',
      );
    },
  );
}
