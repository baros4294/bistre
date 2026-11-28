import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

Finder _titleEditor() => find.byWidgetPredicate(
  (w) =>
      w is EditableText &&
      w.focusNode.debugLabel != 'composer' &&
      w.controller.text.startsWith('Trip'),
);

Future<(ShellHarness, EngineThread, EngineThread)> _open(
  WidgetTester tester, {
  ShellLayout layout = ShellLayout.desktop,
}) async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final b = gateway.seedThread(title: 'Other chat', updatedAtMs: 1000);
  final a = gateway.seedThread(title: 'Trip', updatedAtMs: 2000);
  final shell = await ShellHarness.pump(
    tester,
    layout: layout,
    gateway: gateway,
  );
  // The header title (the sidebar and tabs show it too).
  await tester.tap(
    find
        .descendant(
          of: find.byType(BistreScaffold).first,
          matching: find.text('Trip'),
        )
        .first,
  );
  await tester.pumpAndSettle();
  expect(_titleEditor(), findsOneWidget, reason: 'tapping the title edits it');
  return (shell, a, b);
}

Future<String> _storedTitle(ShellHarness shell, String id) async =>
    (await shell.gateway.listThreads()).firstWhere((t) => t.id == id).title;

void main() {
  for (final layout in ShellLayout.values) {
    testWidgets('Enter saves the new title ($layout)', (tester) async {
      final (shell, a, _) = await _open(tester, layout: layout);
      await tester.enterText(_titleEditor(), 'Trip to Hue');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(await _storedTitle(shell, a.id), 'Trip to Hue');
      expect(find.text('Trip to Hue'), findsWidgets);
    });
  }

  testWidgets('clicking elsewhere saves the title', (tester) async {
    final (shell, a, _) = await _open(tester);
    await tester.enterText(_titleEditor(), 'Trip plans');
    await tester.tapAt(const Offset(640, 400));
    await tester.pumpAndSettle();
    expect(await _storedTitle(shell, a.id), 'Trip plans');
  });

  testWidgets('Esc cancels the rename only and never stops a reply', (
    tester,
  ) async {
    final (shell, a, _) = await _open(tester);
    shell.gateway.emit(RunStartedEvent(threadId: a.id, nodeId: 'live'));
    await tester.pump();
    await tester.enterText(_titleEditor(), 'Trip typo');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    // A reply is streaming, so the page never settles; pump a few frames instead.
    await tester.pump(const Duration(milliseconds: 300));
    expect(await _storedTitle(shell, a.id), 'Trip');
    expect(shell.gateway.callsTo('cancelActiveRun'), isEmpty);
    expect(_titleEditor(), findsNothing);
  });

  testWidgets('switching chats ends the edit without saving it elsewhere', (
    tester,
  ) async {
    final (shell, a, b) = await _open(tester);
    await tester.enterText(_titleEditor(), 'Trip half typed');
    await shell.controller.selectThread(b.id);
    await tester.pumpAndSettle();
    expect(_titleEditor(), findsNothing);
    expect(await _storedTitle(shell, b.id), 'Other chat');
    expect(shell.t(L10nKey.threadRenamePlaceholder), isNotEmpty);
  });

  testWidgets('the rename box fits the title, not the whole header', (
    tester,
  ) async {
    await _open(tester);
    expect(tester.getSize(_titleEditor()).width, lessThanOrEqualTo(420));
  });
}
