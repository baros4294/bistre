import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/composer_asides.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Chat actions beside the runs: leaving a message out of the context, a reply edited as
/// a new version, `/goal`, `/btw`, summarize into a new chat, and a reply's raw request.
Finder _iconButton(String label) => find.byWidgetPredicate(
  (w) => w is BistreIconButton && w.semanticsLabel == label,
);

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is EngravedButton && w.label == label);

/// A chat with one turn; [replyMeta] is the reply's provider metadata.
FakeEngineGateway _chat({Map<String, Object?>? replyMeta}) {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final thread = gateway.seedThread(title: 'Trip', updatedAtMs: 2000);
  final question = gateway.seedNode(
    threadId: thread.id,
    role: 'user',
    content: 'Where to?',
  );
  gateway.seedNode(
    threadId: thread.id,
    parentId: question.id,
    role: 'assistant',
    content: 'Porto.',
    meta: replyMeta,
  );
  return gateway;
}

Future<ShellHarness> _open(WidgetTester tester, FakeEngineGateway g) async {
  final shell = await ShellHarness.pump(
    tester,
    gateway: g,
    layout: ShellLayout.phone,
  );
  await shell.controller.selectThread(shell.controller.threads.first.id);
  await tester.pumpAndSettle();
  return shell;
}

Future<void> _openMore(WidgetTester tester, ShellHarness shell) async {
  await tester.tap(_iconButton(shell.t(L10nKey.chatActionMore)).last);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  final composer = find.byType(EditableText).last;
  await tester.enterText(composer, text);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a reply left out of the context is dimmed and comes back', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    final reply = shell.controller.visibleBranchNodes.last;
    await _openMore(tester, shell);
    await tester.tap(_iconButton(shell.t(L10nKey.chatActionExcludeContext)));
    await tester.pumpAndSettle();
    expect(shell.controller.isExcluded(reply.id), isTrue);
    expect(find.text(shell.t(L10nKey.chatExcludedNote)), findsOneWidget);
    final leftOut = gateway.callsTo('setNodeExcluded').single;
    expect(leftOut.args['nodeId'], reply.id);
    expect(leftOut.args['excluded'], isTrue);

    await tester.tap(_iconButton(shell.t(L10nKey.chatActionIncludeContext)));
    await tester.pumpAndSettle();
    expect(shell.controller.isExcluded(reply.id), isFalse);
    expect(find.text(shell.t(L10nKey.chatExcludedNote)), findsNothing);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('an edited reply is saved as a new version and shown', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    final reply = shell.controller.visibleBranchNodes.last;
    await _openMore(tester, shell);
    await tester.tap(_iconButton(shell.t(L10nKey.chatActionEditReply)));
    await tester.pumpAndSettle();
    final editor = find.byWidgetPredicate(
      (w) => w is EditableText && w.controller.text == 'Porto.',
    );
    await tester.enterText(editor, 'Porto, then Braga.');
    await tester.tap(_button(shell.t(L10nKey.chatActionSaveVersion)));
    await tester.pumpAndSettle();
    final edit = gateway.callsTo('editReply').single;
    expect(edit.args['nodeId'], reply.id);
    final shown = shell.controller.visibleBranchNodes.last;
    expect(shown.content, 'Porto, then Braga.');
    expect(shown.usageMeta?.editedFrom, reply.id);
    expect(shown.parentId, reply.parentId);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('/goal sets the goal above the composer; Clear goal removes it', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    await _type(tester, '/goal Plan three days in Porto');
    final set = gateway.callsTo('setThreadGoal').single;
    expect(set.args['objective'], 'Plan three days in Porto');
    expect(gateway.callsTo('sendAndStreamReply'), isEmpty);
    expect(
      find.text(
        shell.t(L10nKey.composerGoalOpen, <String, Object?>{
          'goal': 'Plan three days in Porto',
        }),
      ),
      findsOneWidget,
    );

    await tester.tap(_iconButton(shell.t(L10nKey.composerGoalClear)));
    await tester.pumpAndSettle();
    expect(shell.controller.threadGoal, isNull);
    expect(gateway.callsTo('setThreadGoal').last.args['objective'], isEmpty);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('/btw answers beside the chat and adds nothing to it', (
    tester,
  ) async {
    final gateway = _chat()..sideAnswer = 'About 300 km.';
    final shell = await _open(tester, gateway);
    final before = shell.controller.visibleBranchNodes.length;
    await _type(tester, '/btw how far is Braga?');
    expect(
      gateway.callsTo('askSideQuestion').single.args['question'],
      'how far is Braga?',
    );
    expect(find.text(shell.t(L10nKey.composerSideTitle)), findsOneWidget);
    expect(
      find.textContaining('About 300 km.', findRichText: true),
      findsWidgets,
    );
    expect(shell.controller.visibleBranchNodes, hasLength(before));
    expect(gateway.callsTo('sendAndStreamReply'), isEmpty);

    await tester.tap(
      find.descendant(
        of: find.byType(ComposerAsides),
        matching: _iconButton(shell.t(L10nKey.shellDismiss)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(shell.t(L10nKey.composerSideTitle)), findsNothing);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('/summarize opens a new chat that starts from the summary', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    final source = shell.controller.activeThread!.id;
    await _type(tester, '/summarize');
    expect(
      gateway.callsTo('summarizeIntoNewChat').single.args['threadId'],
      source,
    );
    final fresh = shell.controller.activeThread!;
    expect(fresh.id, isNot(source));
    expect(
      shell.controller.visibleBranchNodes.single.role,
      'compaction_summary',
    );
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a goal check shows as a quiet note, never as your message', (
    tester,
  ) async {
    final gateway = _chat();
    final thread = gateway.seedThread(title: 'Goal', updatedAtMs: 3000);
    final ask = gateway.seedNode(
      threadId: thread.id,
      role: 'user',
      content: 'Port the parser tests',
    );
    final reply = gateway.seedNode(
      threadId: thread.id,
      parentId: ask.id,
      role: 'assistant',
      content: 'Ported two of them.',
    );
    gateway.seedNode(
      threadId: thread.id,
      parentId: reply.id,
      role: 'user',
      content: 'Check your work against the goal.',
      meta: <String, Object?>{'goal_check': true},
    );
    final shell = await ShellHarness.pump(
      tester,
      gateway: gateway,
      layout: ShellLayout.phone,
    );
    await shell.controller.selectThread(thread.id);
    await tester.pumpAndSettle();
    expect(find.text(shell.t(L10nKey.chatGoalCheckNote)), findsOneWidget);
    expect(find.text('Check your work against the goal.'), findsNothing);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('Turn details shows the raw request while core keeps it', (
    tester,
  ) async {
    final gateway = _chat(
      replyMeta: <String, Object?>{'request_id': 'req-1', 'model_id': 'm'},
    );
    gateway.rawExchanges['req-1'] = const EngineRawExchange(
      url: 'https://api.example.test/v1/responses',
      requestBody: '{"store":false}',
      response: 'data: {"type":"done"}',
      truncated: true,
    );
    final shell = await _open(tester, gateway);
    await _openMore(tester, shell);
    await tester.tap(_iconButton(shell.t(L10nKey.chatTurnDetails)));
    await tester.pumpAndSettle();
    expect(find.text(shell.t(L10nKey.chatTurnRawRequest)), findsOneWidget);
    expect(find.text(shell.t(L10nKey.chatTurnRawResponse)), findsOneWidget);
    expect(find.text(shell.t(L10nKey.chatTurnRawTruncated)), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('Turn details says when core no longer keeps the raw request', (
    tester,
  ) async {
    final gateway = _chat(
      replyMeta: <String, Object?>{'request_id': 'req-gone', 'model_id': 'm'},
    );
    final shell = await _open(tester, gateway);
    await _openMore(tester, shell);
    await tester.tap(_iconButton(shell.t(L10nKey.chatTurnDetails)));
    await tester.pumpAndSettle();
    expect(find.text(shell.t(L10nKey.chatTurnRawGone)), findsOneWidget);
    expect(find.text(shell.t(L10nKey.chatTurnRawRequest)), findsNothing);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('with confirming on, Regenerate runs on the second press', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    await shell.controller.saveUiPrefs(
      shell.controller.uiPrefs.copyWith(confirmBeforeRegenerating: true),
      quiet: true,
    );
    await tester.pumpAndSettle();
    await tester.tap(_iconButton(shell.t(L10nKey.chatActionRegenerate)).last);
    await tester.pumpAndSettle();
    expect(gateway.callsTo('regenerateReply'), isEmpty);
    await tester.tap(
      _iconButton(shell.t(L10nKey.chatActionRegenerateConfirm)).last,
    );
    await tester.pumpAndSettle();
    expect(gateway.callsTo('regenerateReply'), hasLength(1));
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('the history limit is saved where core reads it', (tester) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    await shell.controller.setHistoryMessageLimit(20);
    expect(shell.controller.historyMessageLimit, 20);
    expect(await gateway.getKvMeta(kHistoryLimitKvKey), '20');
    // A limit Settings does not offer is refused.
    await shell.controller.setHistoryMessageLimit(7);
    expect(await gateway.getKvMeta(kHistoryLimitKvKey), '20');
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('Code text size scales code blocks apart from the text size', (
    tester,
  ) async {
    final shell = await _open(tester, _chat());
    await shell.controller.saveUiPrefs(
      shell.controller.uiPrefs.copyWith(codeTextPercent: 130),
      quiet: true,
    );
    expect(shell.controller.resolvedTypography.codeScale, closeTo(1.3, 1e-9));
    expect(shell.controller.uiPrefs.textSizePercent, 100);
    await tester.pump(const Duration(seconds: 9));
  });
}
