import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets(
    'a slow upward drag during a reply is never pulled back down (U12)',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
      final chat = gateway.seedThread(title: 'Long', updatedAtMs: 1000);
      String? parent;
      for (var i = 0; i < 12; i++) {
        final node = await gateway.appendNode(
          threadId: chat.id,
          parentId: parent,
          role: i.isEven ? 'user' : 'assistant',
          content: 'message $i\n\n${'Line of text. ' * 40}',
        );
        parent = node.id;
      }
      await ShellHarness.pump(tester, gateway: gateway);
      gateway.emit(RunStartedEvent(threadId: chat.id, nodeId: 'live'));
      await tester.pump(const Duration(milliseconds: 100));
      final feed = find.byType(CustomScrollView).last;
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: feed, matching: find.byType(Scrollable)).first,
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 100));

      // A two-finger trackpad drag (touch drags select text on desktop).
      final drag = await tester.startGesture(
        tester.getCenter(feed),
        kind: PointerDeviceKind.trackpad,
      );
      for (var i = 0; i < 12; i++) {
        await drag.moveBy(const Offset(0, 4));
        gateway.emit(
          DeltaBatchEvent(
            threadId: chat.id,
            nodeId: 'live',
            textDelta: 'more $i ',
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      final away = position.maxScrollExtent - position.pixels;
      await drag.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        away,
        greaterThan(30),
        reason: 'the reader kept scrolling up while the reply grew',
      );
      // End the reply so its paced reveal stops.
      gateway.emit(
        RunFinishedEvent(threadId: chat.id, nodeId: 'live', cancelled: false),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'the feed follows tool rows and thinking too, not only text (P22)',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
      final chat = gateway.seedThread(title: 'Long', updatedAtMs: 1000);
      String? parent;
      for (var i = 0; i < 12; i++) {
        final node = await gateway.appendNode(
          threadId: chat.id,
          parentId: parent,
          role: i.isEven ? 'user' : 'assistant',
          content: 'message $i\n\n${'Line of text. ' * 40}',
        );
        parent = node.id;
      }
      await ShellHarness.pump(tester, gateway: gateway);
      gateway.emit(RunStartedEvent(threadId: chat.id, nodeId: 'live'));
      await tester.pump(const Duration(milliseconds: 100));
      final feed = find.byType(CustomScrollView).last;
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: feed, matching: find.byType(Scrollable)).first,
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 6; i++) {
        gateway.emit(
          ToolExecutionUpdatedEvent(
            threadId: chat.id,
            runId: 'run-1',
            callId: 'call_$i',
            toolName: 'read',
            summary: 'read file $i',
            status: 'completed',
            riskTier: 'tier0_read_only',
            outputText: 'ok',
            durationMs: 2,
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        position.maxScrollExtent - position.pixels,
        lessThan(2),
        reason: 'the new tool rows stay in view',
      );
      gateway.emit(
        RunFinishedEvent(threadId: chat.id, nodeId: 'live', cancelled: false),
      );
      await tester.pumpAndSettle();
    },
  );
}
