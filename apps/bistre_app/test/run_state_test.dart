import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Two chats, "A" (older) and "B" (newer), with B open.
Future<(ShellHarness, String, String)> _twoChats(WidgetTester tester) async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final a = gateway.seedThread(title: 'Chat A', updatedAtMs: 1000);
  final b = gateway.seedThread(title: 'Chat B', updatedAtMs: 2000);
  final shell = await ShellHarness.pump(tester, gateway: gateway);
  await shell.controller.selectThread(b.id);
  await _frames(tester);
  return (shell, a.id, b.id);
}

void main() {
  testWidgets('a second run never takes over the first', (tester) async {
    final (shell, a, b) = await _twoChats(tester);
    final ctrl = shell.controller;
    shell.gateway
      ..emit(RunStartedEvent(threadId: a, nodeId: 'a-live'))
      ..emit(RunStartedEvent(threadId: b, nodeId: 'b-live'));
    await _frames(tester);
    expect(ctrl.isThreadStreaming(a), isTrue);
    expect(ctrl.isThreadStreaming(b), isTrue);
    expect(ctrl.isStreaming, isTrue, reason: 'B (open) is replying');
    shell.gateway.emit(
      const RunFinishedEvent(threadId: 'x', nodeId: 'none', cancelled: false),
    );
    shell.gateway.emit(
      RunFinishedEvent(threadId: b, nodeId: 'b-live', cancelled: false),
    );
    await _frames(tester);
    expect(ctrl.isThreadStreaming(a), isTrue, reason: 'A still replies');
    expect(ctrl.isThreadStreaming(b), isFalse);
    expect(ctrl.threadRunState(a), ThreadRunState.running);
    expect(
      find.bySemanticsLabel(shell.t(L10nKey.sidebarRunRunning)),
      findsOneWidget,
    );
  });

  testWidgets('a reply that finished in the background is marked new', (
    tester,
  ) async {
    final (shell, a, _) = await _twoChats(tester);
    shell.gateway
      ..emit(RunStartedEvent(threadId: a, nodeId: 'a-live'))
      ..emit(RunFinishedEvent(threadId: a, nodeId: 'a-live', cancelled: false));
    await _frames(tester);
    expect(shell.controller.threadRunState(a), ThreadRunState.doneUnread);
    expect(
      find.bySemanticsLabel(shell.t(L10nKey.sidebarRunDoneUnread)),
      findsOneWidget,
    );
    await shell.controller.selectThread(a);
    await _frames(tester);
    expect(shell.controller.threadRunState(a), ThreadRunState.idle);
  });

  testWidgets('an approval asked in a background chat waits there', (
    tester,
  ) async {
    final (shell, a, _) = await _twoChats(tester);
    shell.gateway
      ..emit(RunStartedEvent(threadId: a, nodeId: 'a-live'))
      ..emit(
        ToolApprovalRequestedEvent(
          threadId: a,
          runId: 'run-a',
          callId: 'call_0',
          toolName: 'edit',
          argumentsJson: '{"path":"note.txt"}',
          riskTier: 'tier1_reversible_edit',
        ),
      );
    await _frames(tester);
    expect(shell.controller.threadRunState(a), ThreadRunState.awaitingApproval);
    expect(shell.controller.toolActivities, isEmpty, reason: 'B shows none');
    await shell.controller.selectThread(a);
    await _frames(tester);
    expect(
      shell.controller.toolActivities.map((e) => e.status),
      contains('awaiting_approval'),
    );
  });

  testWidgets('a lost RunFinished is repaired from the run list', (
    tester,
  ) async {
    final (shell, a, _) = await _twoChats(tester);
    shell.gateway.emit(RunStartedEvent(threadId: a, nodeId: 'a-live'));
    await _frames(tester);
    expect(shell.controller.isThreadStreaming(a), isTrue);
    // The run ended in core, but its RunFinished never arrived.
    shell.gateway.seedAgentRun(threadId: a, status: 'completed');
    shell.gateway.emit(const EventsLaggedEvent());
    await _frames(tester);
    expect(shell.controller.isThreadStreaming(a), isFalse);
  });

  testWidgets('a new run starts with no tool rows from earlier runs', (
    tester,
  ) async {
    final (shell, _, b) = await _twoChats(tester);
    shell.gateway
      ..emit(RunStartedEvent(threadId: b, nodeId: 'b-1'))
      ..emit(
        ToolExecutionUpdatedEvent(
          threadId: b,
          runId: 'run-1',
          callId: 'call_old',
          toolName: 'read',
          summary: 'read a.txt',
          status: 'completed',
          riskTier: 'tier0_read_only',
          outputText: 'x' * 200000,
          durationMs: 3,
        ),
      );
    await _frames(tester);
    final kept = shell.controller.toolActivities.single.outputText.length;
    expect(kept, lessThan(200000), reason: 'tool output is capped');
    shell.gateway
      ..emit(RunFinishedEvent(threadId: b, nodeId: 'b-1', cancelled: false))
      ..emit(RunStartedEvent(threadId: b, nodeId: 'b-2'));
    await _frames(tester);
    expect(shell.controller.toolActivities, isEmpty);
  });

  testWidgets('coming back to the app tells core and rechecks runs', (
    tester,
  ) async {
    final (shell, a, _) = await _twoChats(tester);
    shell.gateway.emit(RunStartedEvent(threadId: a, nodeId: 'a-live'));
    await _frames(tester);
    shell.gateway.seedAgentRun(threadId: a, status: 'failed');
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await _frames(tester);
    expect(
      shell.gateway.callsTo('notifyPowerEvent').map((c) => c.args['eventKind']),
      contains('app_resumed'),
    );
    expect(shell.controller.isThreadStreaming(a), isFalse);
  });
}
