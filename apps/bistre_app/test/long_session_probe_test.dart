import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/chat/markdown_folio_view.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// Probe: a 500-turn tool session keeps every UI-side
/// collection bounded, and once the run ends nothing keeps the app awake (zero idle polling:
/// no scheduled frame, no running animation).
void main() {
  testWidgets(
    'a 500-turn tool session stays bounded and goes idle after the run',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;
      final threadId = ctrl.activeThread!.id;
      MarkdownFolioView.debugClearParseCache();
      shell.gateway.emit(RunStartedEvent(threadId: threadId, nodeId: 'live'));
      for (var turn = 0; turn < 500; turn++) {
        shell.gateway
          ..emit(
            ToolExecutionUpdatedEvent(
              threadId: threadId,
              runId: 'run-1',
              callId: 'call_$turn',
              toolName: 'shell',
              summary: 'step $turn',
              status: 'completed',
              riskTier: 'tier2_external_side_effect',
              outputText: 'line of output\n' * 2000,
              durationMs: 1,
            ),
          )
          ..emit(
            DeltaBatchEvent(
              threadId: threadId,
              nodeId: 'live',
              textDelta: 'Step $turn done. ',
            ),
          );
        if (turn % 25 == 0) await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 16));
      final rows = ctrl.toolActivities;
      expect(rows.length, lessThanOrEqualTo(kMaxToolActivitiesPerThread));
      expect(
        rows.every((r) => r.outputText.length <= kMaxToolActivityOutputChars),
        isTrue,
      );
      expect(
        MarkdownFolioView.debugParseCacheChars,
        lessThanOrEqualTo(MarkdownFolioView.parseCacheMaxChars),
      );

      shell.gateway.emit(
        RunFinishedEvent(threadId: threadId, nodeId: 'live', cancelled: false),
      );
      await tester.pumpAndSettle();
      expect(
        tester.binding.hasScheduledFrame,
        isFalse,
        reason: 'idle after the run',
      );
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
