import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  testWidgets('tool rows are folded once per change, not every frame', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final threadId = shell.controller.activeThread!.id;
    shell.gateway
      ..emit(RunStartedEvent(threadId: threadId, nodeId: 'live'))
      ..emit(
        ToolExecutionUpdatedEvent(
          threadId: threadId,
          runId: 'run-1',
          callId: 'call_1',
          toolName: 'read',
          summary: 'read a',
          status: 'completed',
          riskTier: 'tier0_read_only',
          outputText: 'x' * 4000,
          durationMs: 2,
        ),
      );
    await tester.pump();
    await tester.pump();
    final before = ToolTimelineView.debugFolds;
    for (var i = 0; i < 30; i++) {
      shell.gateway.emit(
        DeltaBatchEvent(threadId: threadId, nodeId: 'live', textDelta: 'word '),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(ToolTimelineView.debugFolds - before, 0);
    shell.gateway.emit(
      RunFinishedEvent(threadId: threadId, nodeId: 'live', cancelled: false),
    );
    await tester.pump(const Duration(seconds: 2));
  });
}
