import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets('an unsent inline edit survives scrolling it out of view', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
    final chat = gateway.seedThread(title: 'Long', updatedAtMs: 1000);
    String? parent;
    for (var i = 0; i < 40; i++) {
      final node = await gateway.appendNode(
        threadId: chat.id,
        parentId: parent,
        role: i.isEven ? 'user' : 'assistant',
        content: i.isEven
            ? 'question number $i'
            : 'answer number $i\n\n${'A long paragraph line. ' * 30}',
      );
      parent = node.id;
    }
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    final feed = find.byType(CustomScrollView).last;
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: feed, matching: find.byType(Scrollable)).first,
        )
        .position;

    position.jumpTo(0);
    await tester.pumpAndSettle();
    final first = find.textContaining('question number 0', findRichText: true);
    expect(first, findsWidgets);
    // Touch has no hover: a tap on the message shows its actions.
    await tester.tap(first.first);
    await tester.pumpAndSettle();
    final editLabel = shell.t(L10nKey.chatActionEdit);
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) => w is BistreIconButton && w.semanticsLabel == editLabel,
          )
          .first,
    );
    await tester.pumpAndSettle();

    final editor = find.byWidgetPredicate(
      (w) => w is EditableText && w.controller.text == 'question number 0',
    );
    expect(editor, findsOneWidget);
    await tester.enterText(editor, 'question number 0, reworded');
    await tester.pump();
    // The user clicks elsewhere (a focused field would keep itself alive on its own).
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('question number 0', findRichText: true),
      findsNothing,
      reason: 'the edited message is scrolled far out of view',
    );
    position.jumpTo(0);
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (w) =>
            w is EditableText &&
            w.controller.text == 'question number 0, reworded',
      ),
      findsOneWidget,
      reason: 'the half-written edit is still open with its text',
    );
    semantics.dispose();
  });
}
