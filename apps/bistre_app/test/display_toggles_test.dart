import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/chat/folio_message_feed.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Show your name and Show files you sent (Settings > Appearance): your messages can hide
/// your name and the files you sent; a reply's own files always show.
const EngineNodeAttachment _sent = EngineNodeAttachment(
  name: 'notes.pdf',
  mimeType: 'application/pdf',
  sizeBytes: 900,
  blobRelPath: 'attachments/def.pdf',
);
const EngineNodeAttachment _made = EngineNodeAttachment(
  name: 'summary.pdf',
  mimeType: 'application/pdf',
  sizeBytes: 700,
  blobRelPath: 'attachments/ghi.pdf',
);

Future<ShellHarness> _chat(
  WidgetTester tester,
  UiDisplayPrefs prefs, {
  ShellLayout layout = ShellLayout.desktop,
  String locale = 'en',
}) async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final chat = gateway.seedThread(title: 'Files', updatedAtMs: 1000);
  final ask = await gateway.appendNode(
    threadId: chat.id,
    role: 'user',
    content: 'Sum this up',
    attachments: const <EngineNodeAttachment>[_sent],
  );
  await gateway.appendNode(
    threadId: chat.id,
    parentId: ask.id,
    role: 'assistant',
    content: 'Here it is.',
    attachments: const <EngineNodeAttachment>[_made],
  );
  final shell = await ShellHarness.pump(
    tester,
    gateway: gateway,
    layout: layout,
    locale: locale,
  );
  await shell.controller.saveUiPrefs(prefs, quiet: true);
  await tester.pumpAndSettle();
  return shell;
}

Finder _inFeed(Finder f) =>
    find.descendant(of: find.byType(FolioMessageFeed), matching: f);

void main() {
  for (final (layout, locale) in [
    (ShellLayout.desktop, 'en'),
    (ShellLayout.phone, 'ar'),
  ]) {
    testWidgets('your name and sent files can be hidden '
        '(${layout.name}, $locale)', (tester) async {
      final shown = await _chat(
        tester,
        const UiDisplayPrefs(),
        layout: layout,
        locale: locale,
      );
      final you = shown.t(L10nKey.shellRoleUser);
      expect(
        _inFeed(find.textContaining(you, findRichText: true)),
        findsWidgets,
      );
      expect(_inFeed(find.textContaining('notes.pdf')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await _chat(
        tester,
        const UiDisplayPrefs(showUserName: false, showSentFiles: false),
        layout: layout,
        locale: locale,
      );
      expect(
        _inFeed(find.textContaining(you, findRichText: true)),
        findsNothing,
      );
      expect(_inFeed(find.textContaining('notes.pdf')), findsNothing);
      expect(
        _inFeed(find.textContaining('summary.pdf')),
        findsOneWidget,
        reason: 'a reply keeps its own files',
      );
      expect(_inFeed(find.text('Sum this up')), findsOneWidget);
    });
  }
}
