import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/folio_message_feed.dart';
import 'package:bistre_app/features/chat/plain_preview.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Message actions beyond Copy, Edit, and Delete: copy as plain text, branch into a new
/// chat, `/rewind`, clear messages, and long messages you sent folding behind Show more.
Finder _iconButton(String label) => find.byWidgetPredicate(
  (w) => w is BistreIconButton && w.semanticsLabel == label,
);

/// A chat with two turns; [longQuestion] makes the second question long.
FakeEngineGateway _chat({String? longQuestion}) {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final thread = gateway.seedThread(title: 'Trip', updatedAtMs: 2000);
  var parent = '';
  for (final (role, text) in <(String, String)>[
    ('user', 'Where to?'),
    ('assistant', 'Lisbon.'),
    ('user', longQuestion ?? 'And then?'),
    ('assistant', 'Porto.'),
  ]) {
    parent = gateway
        .seedNode(
          threadId: thread.id,
          parentId: parent.isEmpty ? null : parent,
          role: role,
          content: text,
        )
        .id;
  }
  return gateway;
}

Future<ShellHarness> _open(WidgetTester tester, FakeEngineGateway g) async {
  final shell = await ShellHarness.pump(
    tester,
    gateway: g,
    layout: ShellLayout.phone,
  );
  await shell.controller.selectThread(shell.controller.threads.first.id);
  await tester.pumpAndSettle();
  return shell;
}

List<String> _contents(ShellHarness shell) => <String>[
  for (final n in shell.controller.visibleBranchNodes) n.content,
];

void main() {
  test('plain text drops Markdown marks and keeps lines, lists, and code', () {
    expect(
      markdownToPlainText(
        '# Plan\n> **Bold** and *soft* with `code`\n- see [docs](https://x.y)\n'
        '```dart\nfinal a_b = 2 * 3;\n```\nsnake_case_name stays, `__init__` too',
      ),
      'Plan\nBold and soft with code\n- see docs\nfinal a_b = 2 * 3;\n'
      'snake_case_name stays, __init__ too',
    );
  });

  testWidgets('a reply branches into a new chat that holds the talk so far', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    final source = shell.controller.activeThread?.id;
    await tester.tap(_iconButton(shell.t(L10nKey.chatActionMore)).last);
    await tester.pumpAndSettle();
    await tester.tap(_iconButton(shell.t(L10nKey.chatActionBranchNewChat)));
    await tester.pumpAndSettle();
    final fork = gateway.calls.where((c) => c.method == 'forkThread').single;
    expect(fork.args['threadId'], source);
    expect(shell.controller.activeThread?.id, isNot(source));
    expect(_contents(shell), <String>[
      'Where to?',
      'Lisbon.',
      'And then?',
      'Porto.',
    ]);
    expect(shell.controller.toastKey, L10nKey.toastBranched);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('/rewind removes the last question with its reply', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    await shell.controller.rewindLastTurn();
    await tester.pumpAndSettle();
    expect(_contents(shell), <String>['Where to?', 'Lisbon.']);
    await shell.controller.clearActiveMessages();
    await tester.pumpAndSettle();
    expect(_contents(shell), isEmpty);
    expect(shell.controller.activeThread?.title, 'Trip');
    expect(shell.controller.toastKey, L10nKey.toastMessagesCleared);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a long message you sent opens with Show more', (tester) async {
    final long = List<String>.generate(400, (i) => 'line $i').join('\n');
    final shell = await _open(tester, _chat(longQuestion: long));
    final more = find.widgetWithText(
      EngravedButton,
      shell.t(L10nKey.chatActionShowMore),
    );
    expect(more, findsOneWidget);
    expect(find.textContaining('line 399', findRichText: true), findsOneWidget);
    final text = find.textContaining('line 0', findRichText: true);
    final clip = find.ancestor(of: text, matching: find.byType(ClipRect)).first;
    expect(
      tester.getSize(clip).height,
      lessThanOrEqualTo(kCollapsedMessageHeight + 1),
    );
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(EngravedButton, shell.t(L10nKey.chatActionShowLess)),
      findsOneWidget,
    );
    expect(
      tester.getSize(text).height,
      greaterThan(kCollapsedMessageHeight * 4),
    );
    await tester.pump(const Duration(seconds: 9));
  });
}
