import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// A chat of four messages, condensed by one summary.
Future<(FakeEngineGateway, String, String)> _condensedChat() async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final chat = gateway.seedThread(title: 'Long talk', updatedAtMs: 1000);
  for (final (role, text) in const <(String, String)>[
    ('user', 'Which parser?'),
    ('assistant', 'The strict one.'),
    ('user', 'And the tests?'),
    ('assistant', 'Red first.'),
  ]) {
    await gateway.appendNode(threadId: chat.id, role: role, content: text);
  }
  final summary = await gateway.compactThread(
    threadId: chat.id,
    customSummary: 'They chose the strict parser.',
  );
  return (gateway, chat.id, summary.id);
}

Finder _button(ShellHarness shell, L10nKey key) =>
    find.widgetWithText(EngravedButton, shell.t(key));

/// Taps [finder] after scrolling it into view (a phone at 200% text shows little).
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The open summary editor: the field that started with the summary's text.
Finder _summaryField(WidgetTester tester) {
  final start = tester.widget<EditableText>(
    find.byWidgetPredicate(
      (w) =>
          w is EditableText &&
          w.controller.text == 'They chose the strict parser.',
    ),
  );
  return find.byWidgetPredicate(
    (w) => w is EditableText && w.controller == start.controller,
  );
}

void main() {
  for (final (layout, scale, locale) in <(ShellLayout, double, String)>[
    (ShellLayout.desktop, 1, 'en'),
    (ShellLayout.phone, 2, 'en'),
    (ShellLayout.phone, 1, 'ar'),
    (ShellLayout.desktop, 2, 'ar'),
  ]) {
    testWidgets(
      'a summary can be edited and saved ($layout, $scale, $locale)',
      (tester) async {
        final (gateway, chatId, summaryId) = await _condensedChat();
        final shell = await ShellHarness.pump(
          tester,
          layout: layout,
          textScale: scale,
          locale: locale,
          gateway: gateway,
        );
        await shell.controller.selectThread(chatId);
        await tester.pumpAndSettle();
        expect(find.text('They chose the strict parser.'), findsOneWidget);

        await _tap(tester, _button(shell, L10nKey.chatActionEdit));
        expect(tester.takeException(), isNull);
        final field = _summaryField(tester);
        expect(field, findsOneWidget);

        // An empty summary cannot be saved.
        await tester.enterText(field, '   ');
        await tester.pump();
        final save = _button(shell, L10nKey.threadSave);
        expect(tester.widget<EngravedButton>(save).onPressed, isNull);

        await tester.enterText(field, 'Strict parser; tests first.');
        await tester.pump();
        await _tap(tester, save);
        final saved = gateway.callsTo('rewriteCompactionSummary').single;
        expect(saved.args['nodeId'], summaryId);
        expect(saved.args['content'], 'Strict parser; tests first.');
        expect(find.text('Strict parser; tests first.'), findsOneWidget);
        expect(_button(shell, L10nKey.threadSave), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 9));
      },
    );
  }

  testWidgets('Cancel keeps the summary as it was', (tester) async {
    final (gateway, chatId, _) = await _condensedChat();
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    await shell.controller.selectThread(chatId);
    await tester.pumpAndSettle();
    await _tap(tester, _button(shell, L10nKey.chatActionEdit));
    await tester.enterText(_summaryField(tester), 'Thrown away');
    await _tap(tester, _button(shell, L10nKey.threadCancel));
    expect(find.text('They chose the strict parser.'), findsOneWidget);
    expect(gateway.callsTo('rewriteCompactionSummary'), isEmpty);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('/compact with words says what to keep and sends no message', (
    tester,
  ) async {
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
    final chat = gateway.seedThread(title: 'Long talk', updatedAtMs: 1000);
    await gateway.appendNode(threadId: chat.id, role: 'user', content: 'Hi');
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    await shell.controller.selectThread(chat.id);
    await tester.pumpAndSettle();

    final composer = find.byType(EditableText).last;
    await tester.enterText(composer, '/compact keep the parser decision');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final compacted = gateway.callsTo('compactThread').single;
    expect(compacted.args['instructions'], 'keep the parser decision');
    expect(gateway.callsTo('sendAndStreamReply'), isEmpty);
    expect(tester.widget<EditableText>(composer).controller.text, isEmpty);
    await tester.pump(const Duration(seconds: 9));
  });
}
