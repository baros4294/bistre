import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/chat/earlier_messages_button.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// A chat of [count] messages in one line, each reply costing 10 micro-USD.
Future<(FakeEngineGateway, String)> _longChat(int count) async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final chat = gateway.seedThread(title: 'Long', updatedAtMs: 1000);
  String? parent;
  for (var i = 0; i < count; i++) {
    final node = await gateway.appendNode(
      threadId: chat.id,
      parentId: parent,
      role: i.isEven ? 'user' : 'assistant',
      content: 'message $i',
    );
    parent = node.id;
  }
  return (gateway, chat.id);
}

/// A long chat opens on its newest page and loads older pages on request or when a message
/// that is not loaded is needed; a short chat loads whole, as before.
void main() {
  for (final (layout, scale, locale) in <(ShellLayout, double, String)>[
    (ShellLayout.desktop, 1, 'en'),
    (ShellLayout.phone, 2, 'en'),
    (ShellLayout.phone, 1, 'ar'),
  ]) {
    testWidgets('a long chat pages ($layout, $scale, $locale)', (tester) async {
      final (gateway, chatId) = await _longChat(kFeedPage * 2 + 100);
      final shell = await ShellHarness.pump(
        tester,
        layout: layout,
        textScale: scale,
        locale: locale,
        gateway: gateway,
      );
      final ctrl = shell.controller;
      await ctrl.selectThread(chatId);
      await tester.pumpAndSettle();
      expect(ctrl.nodes, hasLength(kFeedPage));
      expect(ctrl.hasEarlierNodes, isTrue);
      // The visible branch starts at the first loaded message and ends at the newest.
      expect(ctrl.visibleBranchNodes, hasLength(kFeedPage));
      expect(
        ctrl.visibleBranchNodes.last.content,
        'message ${kFeedPage * 2 + 99}',
      );
      expect(ctrl.branchInfoFor(ctrl.visibleBranchNodes.first), isNull);

      final button = find.byType(EarlierMessagesButton);
      // Scroll the feed to its top, where the button sits.
      final feed = find.ancestor(
        of: find.text('message ${kFeedPage * 2 + 99}'),
        matching: find.byType(Scrollable),
      );
      tester.state<ScrollableState>(feed.first).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(button, findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.text(shell.l10n.t(L10nKey.chatShowEarlierMessages)),
      );
      await tester.pumpAndSettle();
      expect(ctrl.nodes, hasLength(kFeedPage * 2));
      expect(ctrl.visibleBranchNodes.first.content, 'message 100');

      // A message on an unloaded page is loaded before it is revealed.
      final first = gateway.nodesOf(chatId).first;
      await ctrl.revealNode(chatId, first.id);
      await tester.pumpAndSettle();
      expect(ctrl.hasEarlierNodes, isFalse);
      expect(ctrl.nodes, hasLength(kFeedPage * 2 + 100));
      expect(ctrl.visibleBranchNodes.first.id, first.id);
      expect(button, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 9));
    });
  }

  testWidgets('a short chat loads whole with no button', (tester) async {
    final (gateway, chatId) = await _longChat(kFeedPage);
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    await shell.controller.selectThread(chatId);
    await tester.pumpAndSettle();
    expect(shell.controller.nodes, hasLength(kFeedPage));
    expect(shell.controller.hasEarlierNodes, isFalse);
    expect(find.byType(EarlierMessagesButton), findsNothing);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a partly loaded chat shows its whole cost', (tester) async {
    final (gateway, chatId) = await _longChat(kFeedPage + 10);
    gateway.threadSpendMicros = 123456;
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    await shell.controller.selectThread(chatId);
    await tester.pumpAndSettle();
    expect(shell.controller.hasEarlierNodes, isTrue);
    expect(shell.controller.activeThreadSpendMicros, 123456);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a reload keeps the pages already shown', (tester) async {
    final (gateway, chatId) = await _longChat(kFeedPage * 3);
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    final ctrl = shell.controller;
    await ctrl.selectThread(chatId);
    await tester.pumpAndSettle();
    await ctrl.loadEarlierNodes();
    expect(ctrl.nodes, hasLength(kFeedPage * 2));
    gateway.emit(
      RunFinishedEvent(threadId: chatId, nodeId: 'x', cancelled: false),
    );
    await tester.pumpAndSettle();
    expect(ctrl.nodes, hasLength(kFeedPage * 2));
    expect(ctrl.hasEarlierNodes, isTrue);
    await tester.pump(const Duration(seconds: 9));
  });
}
