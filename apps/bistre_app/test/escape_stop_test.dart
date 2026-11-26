import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// A chat with a reply streaming.
Future<ShellHarness> _streaming(WidgetTester tester) async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final chat = gateway.seedThread(title: 'Busy', updatedAtMs: 1000);
  final shell = await ShellHarness.pump(tester, gateway: gateway);
  gateway.emit(RunStartedEvent(threadId: chat.id, nodeId: 'live'));
  await tester.pump();
  expect(shell.controller.isStreaming, isTrue);
  return shell;
}

Finder _composer() => find.byType(EditableText).last;

Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 300));

void main() {
  testWidgets('Esc in an empty composer stops the reply (D3)', (tester) async {
    final shell = await _streaming(tester);
    await tester.tap(_composer());
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(shell.gateway.callsTo('cancelActiveRun'), hasLength(1));
  });

  testWidgets('Esc in a composer with text never stops the reply (D3)', (
    tester,
  ) async {
    final shell = await _streaming(tester);
    await tester.enterText(_composer(), 'a follow-up');
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(shell.gateway.callsTo('cancelActiveRun'), isEmpty);
  });

  testWidgets('Esc in search closes search and never stops the reply (U6)', (
    tester,
  ) async {
    final shell = await _streaming(tester);
    shell.controller.toggleSearchPanel();
    await _settle(tester);
    final search = find.byType(EditableText).first;
    await tester.enterText(search, 'notes');
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(shell.gateway.callsTo('cancelActiveRun'), isEmpty);
  });

  testWidgets('Ctrl+. stops the reply from anywhere (D3)', (tester) async {
    final shell = await _streaming(tester);
    await tester.enterText(_composer(), 'typing');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);
    expect(shell.gateway.callsTo('cancelActiveRun'), hasLength(1));
  });
}
