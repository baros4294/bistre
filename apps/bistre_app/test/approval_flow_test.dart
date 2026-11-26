import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Pushes a running reply plus a paused `edit` call for the active chat.
Future<String> _pauseActiveChatOnEdit(ShellHarness shell) async {
  final threadId = shell.controller.activeThread!.id;
  shell.gateway
    ..emit(RunStartedEvent(threadId: threadId, nodeId: 'reply-live'))
    ..emit(
      ToolApprovalRequestedEvent(
        threadId: threadId,
        runId: 'run-7',
        callId: 'call_0',
        toolName: 'edit',
        argumentsJson: '{"path":"note.txt"}',
        riskTier: 'tier1_reversible_edit',
      ),
    );
  // A live reply animates its cursor forever, so pump a bounded frame budget, not settle.
  await _pumpFrames(shell.tester);
  return threadId;
}

void main() {
  for (final layout in ShellLayout.values) {
    testWidgets('Stop answers the exact paused run with stop ($layout)', (
      tester,
    ) async {
      final shell = await ShellHarness.pump(tester, layout: layout);
      final threadId = await _pauseActiveChatOnEdit(shell);

      await tester.tap(find.text(shell.t(L10nKey.toolStop)));
      await _pumpFrames(tester);

      final calls = shell.gateway.callsTo('respondToolApproval').toList();
      expect(calls, hasLength(1));
      expect(calls.single.args, <String, Object?>{
        'threadId': threadId,
        'runId': 'run-7',
        'callId': 'call_0',
        'decision': 'stop',
      });
    });
  }

  testWidgets('Deny and approve answers carry the run id too', (tester) async {
    final shell = await ShellHarness.pump(
      tester,
      gateway: FakeEngineGateway(seedConnectedOpenAi: true),
    );
    await _pauseActiveChatOnEdit(shell);
    await tester.tap(find.text(shell.t(L10nKey.toolApproveChat)));
    await _pumpFrames(tester);
    final call = shell.gateway.callsTo('respondToolApproval').single;
    expect(call.args['runId'], 'run-7');
    expect(call.args['decision'], 'approve_for_thread');
  });
}
