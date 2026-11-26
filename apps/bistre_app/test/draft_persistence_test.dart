import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  for (final layout in ShellLayout.values) {
    testWidgets(
      'a sent message does not come back as the draft (U35, $layout)',
      (tester) async {
        final shell = await ShellHarness.pump(tester, layout: layout);
        await tester.enterText(find.byType(EditableText).last, 'hello');
        // Let the debounced draft save run, as when the user pauses before sending.
        await tester.pump(const Duration(milliseconds: 400));
        final threadId = shell.controller.activeThread!.id;
        expect(await shell.gateway.loadDraft(threadId), 'hello');

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(shell.gateway.callsTo('sendAndStreamReply'), hasLength(1));
        expect(
          await shell.gateway.loadDraft(threadId),
          isEmpty,
          reason: 'reopening the chat must not show the sent text again',
        );
      },
    );
  }

  testWidgets('a slash command clears the saved draft (U35)', (tester) async {
    final shell = await ShellHarness.pump(tester);
    await tester.enterText(find.byType(EditableText).last, '/plan');
    await tester.pump(const Duration(milliseconds: 400));
    final threadId = shell.controller.activeThread!.id;
    expect(await shell.gateway.loadDraft(threadId), '/plan');

    await tester.tap(find.text('/plan').first);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(shell.gateway.callsTo('sendAndStreamReply'), isEmpty);
    expect(await shell.gateway.loadDraft(threadId), isEmpty);
  });

  testWidgets('the last keystrokes are saved when the app is paused (P27)', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    await tester.enterText(find.byType(EditableText).last, 'half a thou');
    // No debounce wait: the app goes to the background right away.
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    final threadId = shell.controller.activeThread!.id;
    expect(await shell.gateway.loadDraft(threadId), 'half a thou');
    for (final state in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('Enter in the / menu runs the command instead of sending it', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    await tester.enterText(find.byType(EditableText).last, '/plan');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      shell.gateway.callsTo('sendAndStreamReply'),
      isEmpty,
      reason: '"/plan" must never reach the model as a chat message',
    );
    expect(shell.controller.activeThread!.mode, 'plan');
    await tester.pump(const Duration(milliseconds: 400));
  });
}
