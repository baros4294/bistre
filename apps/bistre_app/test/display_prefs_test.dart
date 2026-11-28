import 'dart:io';
import 'dart:typed_data';

import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/label_control_layout.dart';
import 'package:bistre_app/design/math_font_gate.dart';
import 'package:bistre_app/features/chat/reasoning_block.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/sidebar/folio_sidebar.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Every Settings > Appearance display toggle changes what
/// the chat and the chat list show. Before each one was saved and never read.
const _thinking = 'Plan the answer first';
const _code = 'final area = side * side;';

Future<ShellHarness> _chat(
  WidgetTester tester,
  UiDisplayPrefs prefs, {
  ShellLayout layout = ShellLayout.desktop,
  String locale = 'en',
}) async {
  // A fresh tree each time, so no widget keeps state from the previous settings.
  await tester.pumpWidget(const SizedBox());
  // The math face registers lazily in production; register it from disk up front so its
  // font-change relayout never lands after a test tears the tree down.
  await tester.runAsync(() async {
    await MathFontGate.ensureLoaded(
      source: Future<ByteData>.value(
        ByteData.sublistView(
          File('assets/fonts/noto-sans-math-regular.ttf').readAsBytesSync(),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final thread = gateway.seedThread(title: 'Squares', updatedAtMs: 2000);
  final user = gateway.seedNode(
    threadId: thread.id,
    role: 'user',
    content: 'What is **side** squared?',
  );
  gateway.seedNode(
    threadId: thread.id,
    parentId: user.id,
    role: 'assistant',
    content: 'The area is \$x^2\$.\n\n```dart\n$_code\n```',
    meta: <String, Object?>{
      'model_id': 'gpt-4.1',
      'provider_name': 'OpenAI',
      'thinking_text': _thinking,
    },
  );
  final shell = await ShellHarness.pump(
    tester,
    gateway: gateway,
    layout: layout,
    locale: locale,
  );
  await shell.controller.saveUiPrefs(prefs, quiet: true);
  await shell.controller.selectThread(thread.id);
  await tester.pumpAndSettle();
  return shell;
}

Finder _iconButton(String label) => find.byWidgetPredicate(
  (w) => w is BistreIconButton && w.semanticsLabel == label,
);

Finder _rich(String text) => find.textContaining(text, findRichText: true);

void main() {
  for (final layout in <ShellLayout>[ShellLayout.desktop, ShellLayout.phone]) {
    testWidgets('thinking and tool cards can be hidden ($layout)', (
      tester,
    ) async {
      await _chat(tester, const UiDisplayPrefs(), layout: layout);
      expect(find.byType(ReasoningBlock), findsOneWidget);
      await _chat(
        tester,
        const UiDisplayPrefs(showThinkingCards: false),
        layout: layout,
      );
      expect(find.byType(ReasoningBlock), findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('a reply names its model, and its provider when asked '
        '($layout)', (tester) async {
      final shell = await _chat(
        tester,
        const UiDisplayPrefs(showModelName: false),
        layout: layout,
      );
      final withProvider = shell.t(
        L10nKey.shellModelOnProvider,
        <String, Object?>{
          'model': shell.l10n.isolate('gpt-4.1'),
          'provider': shell.l10n.isolate('OpenAI'),
        },
      );
      final base = tester.widgetList(_rich(withProvider)).length;
      final bare = tester.widgetList(_rich('gpt-4.1')).length;

      await _chat(tester, const UiDisplayPrefs(), layout: layout);
      expect(tester.widgetList(_rich(withProvider)).length, base + 1);

      await _chat(
        tester,
        const UiDisplayPrefs(showProviderAfterModel: false),
        layout: layout,
      );
      expect(tester.widgetList(_rich(withProvider)).length, base);
      expect(tester.widgetList(_rich('gpt-4.1')).length, bare + 1);

      // The reply's actions sit at the end of its header row, with no gap after them.
      final more = _iconButton(shell.t(L10nKey.chatActionMore)).last;
      final header = find
          .ancestor(of: more, matching: find.byType(LabelControlLayout))
          .first;
      expect(
        tester.getTopRight(more).dx,
        closeTo(tester.getTopRight(header).dx, 1),
      );
    });
  }

  testWidgets('your messages show Markdown as typed when that is off', (
    tester,
  ) async {
    await _chat(tester, const UiDisplayPrefs());
    expect(_rich('**side**'), findsNothing);
    await _chat(tester, const UiDisplayPrefs(renderUserMarkdown: false));
    expect(_rich('What is **side** squared?'), findsOneWidget);
  });

  testWidgets('math shows as typed when math rendering is off', (tester) async {
    await _chat(tester, const UiDisplayPrefs());
    expect(_rich(r'$x^2$'), findsNothing);
    await _chat(tester, const UiDisplayPrefs(renderMathFormulas: false));
    expect(_rich(r'$x^2$'), findsOneWidget);
  });

  testWidgets('code blocks start folded when auto-collapse is on', (
    tester,
  ) async {
    await _chat(tester, const UiDisplayPrefs());
    expect(_rich(_code).hitTestable(), findsOneWidget);
    await _chat(tester, const UiDisplayPrefs(autoCollapseCodeBlocks: true));
    expect(_rich(_code).hitTestable(), findsNothing);
  });

  testWidgets('thinking stays open when auto-collapse is off', (tester) async {
    await _chat(tester, const UiDisplayPrefs());
    expect(_rich(_thinking), findsNothing);
    await _chat(tester, const UiDisplayPrefs(autoCollapseThinking: false));
    expect(_rich(_thinking), findsOneWidget);
  });

  testWidgets('the chat list can hide its date headings', (tester) async {
    final shell = await _chat(tester, const UiDisplayPrefs());
    final today = shell.t(L10nKey.sidebarGroupToday);
    expect(find.text(today), findsOneWidget);
    await _chat(tester, const UiDisplayPrefs(showChatListDates: false));
    expect(find.text(today), findsNothing);
  });

  testWidgets('delete asks a second click only when confirm is on', (
    tester,
  ) async {
    // A mouse user: hover shows the row's actions.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    Future<void> clickDelete(ShellHarness shell) async {
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      await mouse.moveTo(
        tester.getCenter(
          find.descendant(
            of: find.byType(FolioSidebar),
            matching: find.text('Squares'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(_iconButton(shell.t(L10nKey.threadDelete)));
      await tester.pump();
    }

    var shell = await _chat(
      tester,
      const UiDisplayPrefs(confirmBeforeDeletingChat: true),
    );
    await clickDelete(shell);
    expect(find.text('Squares'), findsWidgets, reason: 'first click only asks');
    expect(_iconButton(shell.t(L10nKey.threadConfirmDelete)), findsOneWidget);

    shell = await _chat(tester, const UiDisplayPrefs());
    await clickDelete(shell);
    expect(
      _iconButton(shell.t(L10nKey.threadConfirmDelete)),
      findsNothing,
      reason: 'off: one click deletes, with Undo',
    );
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('in Arabic the name stays at the start, before the model label', (
    tester,
  ) async {
    final shell = await _chat(tester, const UiDisplayPrefs(), locale: 'ar');
    final speaker = shell.controller.activeAssistant!.name;
    // The reply header: one line holding both the name and the model label.
    final header = tester.renderObject<RenderParagraph>(
      find.byWidgetPredicate((w) {
        if (w is! RichText) return false;
        final text = w.text.toPlainText();
        return text.contains(speaker) && text.contains('gpt-4.1');
      }),
    );
    final plain = header.text.toPlainText();
    TextBox boxOf(String part) {
      final start = plain.indexOf(part);
      expect(start, isNonNegative, reason: '$part in "$plain"');
      return header
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + part.length),
          )
          .first;
    }

    expect(
      boxOf('gpt-4.1').right,
      lessThan(boxOf(speaker).left),
      reason: 'RTL: the model label reads after the name, to its left',
    );
    expect(
      boxOf('OpenAI').right,
      lessThan(boxOf('gpt-4.1').left),
      reason: 'RTL: "{model} on {provider}" reads model first, from the right',
    );
  });
}
