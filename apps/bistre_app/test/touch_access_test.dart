import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/context_menu.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/design/press_feedback.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Touch screens have no hover: every action has a visible path, and a control that is not
/// shown never takes a tap. Tests run as Android, a touch platform.
Finder _iconButton(String label) => find.byWidgetPredicate(
  (w) => w is BistreIconButton && w.semanticsLabel == label,
);

Future<ShellHarness> _chatWithReplies(WidgetTester tester, int pairs) async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final thread = gateway.seedThread(title: 'Long chat', updatedAtMs: 2000);
  String? parent;
  for (var i = 0; i < pairs; i++) {
    final user = gateway.seedNode(
      threadId: thread.id,
      parentId: parent,
      role: 'user',
      content: 'Question $i',
    );
    parent = gateway
        .seedNode(
          threadId: thread.id,
          parentId: user.id,
          role: 'assistant',
          content: 'Answer $i',
        )
        .id;
  }
  final shell = await ShellHarness.pump(
    tester,
    gateway: gateway,
    layout: ShellLayout.phone,
  );
  await shell.controller.selectThread(thread.id);
  await tester.pumpAndSettle();
  return shell;
}

void main() {
  testWidgets(
    'a hidden reply action takes no tap; tapping the reply shows it',
    (tester) async {
      final shell = await _chatWithReplies(tester, 3);
      final regenerate = _iconButton(shell.t(L10nKey.chatActionRegenerate));
      // Only the latest replies show their actions at rest; the first one hides them.
      final hidden = regenerate.first;
      await tester.ensureVisible(hidden);
      await tester.pumpAndSettle();
      await tester.tap(hidden, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(
        shell.gateway.callsTo('regenerateReply'),
        isEmpty,
        reason: 'an invisible Regenerate (a paid call) must not run',
      );

      await tester.tap(find.text('Answer 0'));
      await tester.pumpAndSettle();
      await tester.tap(regenerate.first);
      await tester.pumpAndSettle();
      expect(shell.gateway.callsTo('regenerateReply'), hasLength(1));
      // Let the Regenerated toast run out.
      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets('the open chat shows its rename and delete actions on touch', (
    tester,
  ) async {
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
    final chat = gateway.seedThread(title: 'Trip notes', updatedAtMs: 2000);
    gateway.seedThread(title: 'Other', updatedAtMs: 1000);
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    await shell.controller.selectThread(chat.id);
    await tester.pumpAndSettle();
    expect(_iconButton(shell.t(L10nKey.threadRename)), findsOneWidget);
    expect(_iconButton(shell.t(L10nKey.threadDelete)), findsOneWidget);
  });

  testWidgets('a tap inside a small icon button never goes to its neighbour', (
    tester,
  ) async {
    final taps = <String>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: BistreTheme(
          data: BistreThemeData.warmSepia,
          child: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) => Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final name in const ['first', 'second']) ...[
                        if (name == 'second') const SizedBox(width: 8),
                        BistreIconButton(
                          key: ValueKey(name),
                          icon: BistreUiIcon.edit,
                          size: 13,
                          dimension: 24,
                          semanticsLabel: name,
                          onPressed: () => taps.add(name),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final first = tester.getRect(find.byKey(const ValueKey('first')));
    final second = tester.getRect(find.byKey(const ValueKey('second')));
    // Inside the first button's box, within the second one's widened target.
    await tester.tapAt(first.centerRight - const Offset(2, 0));
    await tester.pump(const Duration(seconds: 1));
    // In the gap, the nearer button takes the tap.
    await tester.tapAt(second.centerLeft - const Offset(2, 0));
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(first.centerRight + const Offset(2, 0));
    await tester.pump(const Duration(seconds: 1));
    expect(taps, <String>['first', 'second', 'first']);
  });

  testWidgets('menu rows are full tap targets and the menu stays on screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 600),
          textScaler: TextScaler.linear(2),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: BistreTheme(
            data: BistreThemeData.warmSepia,
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (_) => Align(
                    alignment: Alignment.bottomRight,
                    child: ContextMenuRegion(
                      entries: [
                        for (final label in const ['Pin', 'Rename', 'Delete'])
                          ContextMenuEntry(
                            label: label,
                            icon: BistreUiIcon.edit,
                            onSelected: () {},
                          ),
                      ],
                      child: const SizedBox.square(dimension: 40),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tapAt(const Offset(385, 595), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    final window = Offset.zero & const Size(390, 600);
    for (final label in const ['Pin', 'Rename', 'Delete']) {
      final text = tester.getRect(find.widgetWithText(InkText, label));
      expect(window.contains(text.topLeft), isTrue, reason: label);
      expect(window.contains(text.bottomRight), isTrue, reason: label);
    }
    final row = find.ancestor(
      of: find.text('Pin'),
      matching: find.byType(FocusableActionDetector),
    );
    expect(
      tester.getSize(row.first).height,
      greaterThanOrEqualTo(minTapTarget),
      reason: 'each row is a full tap target',
    );
  });

  testWidgets('a waiting attachment opens from the keyboard and is named', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.addAttachment(
      const ComposerAttachment(
        id: 'a1',
        name: 'notes.txt',
        mimeType: 'text/plain',
        path: '/tmp/notes.txt',
        sizeBytes: 120,
      ),
    );
    await tester.pumpAndSettle();
    final chip = find.byWidgetPredicate(
      (w) => w is PressableArea && w.label == 'notes.txt',
    );
    expect(chip, findsOneWidget);
    Focus.of(
      tester.element(find.descendant(of: chip, matching: find.byType(Row))),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(shell.controller.previewingAttachment?.id, 'a1');
  });
}
