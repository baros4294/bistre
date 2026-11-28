import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/folio_composer.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/story/manuscript_canvas.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// The Writing Studio tools: a rewrite replaces the prose in place, Plan scene adds a
/// brief to the beats, Write summary fills the chapter summary, and Draft my reply fills the
/// composer. None of them sends a chat message.
const String _prose = 'She opened the door slowly and walked out.';

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is EngravedButton && w.label == label);

/// The canvas's fields in order: chapter summary, beats, prose.
EditableText _field(WidgetTester tester, int index) => tester.widget(
  find
      .descendant(
        of: find.byType(ManuscriptCanvas),
        matching: find.byType(EditableText),
      )
      .at(index),
);

Future<ShellHarness> _manuscript(
  WidgetTester tester, {
  ShellLayout layout = ShellLayout.desktop,
}) async {
  final shell = await ShellHarness.pump(
    tester,
    gateway: FakeEngineGateway(seedConnectedOpenAi: true),
    layout: layout,
  );
  final ctrl = shell.controller;
  await ctrl.setActiveThreadMode('write');
  await ctrl.addStoryChapter('Shore');
  await ctrl.addStoryScene(ctrl.storyChapters.first.id, 'Door');
  final scene = ctrl.activeScene!;
  await ctrl.saveStoryScene(
    EngineStoryScene(
      id: scene.id,
      chapterId: scene.chapterId,
      orderIndex: scene.orderIndex,
      title: scene.title,
      beatsText: 'Lyra leaves.',
      proseText: _prose,
    ),
  );
  ctrl.toggleManuscriptView(true);
  await tester.pumpAndSettle();
  // The save toasts time out before the tools run.
  await tester.pump(const Duration(seconds: 3));
  return shell;
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  for (final layout in ShellLayout.values) {
    testWidgets('Shorten replaces the whole scene in place, unsaved '
        '(${layout.name})', (tester) async {
      final shell = await _manuscript(tester, layout: layout);
      shell.gateway.rewrittenPassage = 'She left.';
      await _tap(tester, _button(shell.t(L10nKey.storyLaserShorten)));
      final call = shell.gateway.callsTo('rewritePassage').single.args;
      expect(call['mode'], 'shorten');
      expect(call['excerpt'], _prose);
      expect(_field(tester, 2).controller.text, 'She left.');
      expect(
        shell.gateway.callsTo('sendAndStreamReply'),
        isEmpty,
        reason: 'a rewrite sends no chat message',
      );
    });
  }

  testWidgets('Rewrite on a selection replaces only the selected words', (
    tester,
  ) async {
    final shell = await _manuscript(tester);
    shell.gateway.rewrittenPassage = 'She eased';
    _field(tester, 2).controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 'She opened'.length,
    );
    await tester.pump();
    await _tap(tester, _button(shell.t(L10nKey.storyLaserRewrite)));
    expect(
      shell.gateway.callsTo('rewritePassage').single.args['context'],
      _prose,
    );
    expect(
      _field(tester, 2).controller.text,
      'She eased the door slowly and walked out.',
    );
  });

  testWidgets('a rewrite that lands after the text changed replaces nothing', (
    tester,
  ) async {
    final shell = await _manuscript(tester);
    shell.gateway.gate('rewritePassage');
    await tester.ensureVisible(_button(shell.t(L10nKey.storyLaserPolish)));
    await tester.tap(_button(shell.t(L10nKey.storyLaserPolish)));
    await tester.pump();
    _field(tester, 2).controller.text = 'Lyra stayed.';
    await tester.pump();
    shell.gateway.release('rewritePassage');
    await tester.pumpAndSettle();
    expect(_field(tester, 2).controller.text, 'Lyra stayed.');
    expect(find.text(shell.t(L10nKey.storyRewriteStale)), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Plan scene adds the brief after the beats', (tester) async {
    final shell = await _manuscript(tester);
    await _tap(tester, _button(shell.t(L10nKey.storyPlanScene)));
    expect(_field(tester, 1).controller.text, 'Lyra leaves.\n\n1. Scene brief');
  });

  testWidgets(
    'Write summary fills the chapter summary and lists contradictions',
    (tester) async {
      final shell = await _manuscript(tester);
      await _tap(tester, _button(shell.t(L10nKey.storyWriteSummary)));
      expect(_field(tester, 0).controller.text, '- Chapter summary');
      expect(find.text('An earlier chapter disagrees.'), findsOneWidget);
      await _tap(tester, _button(shell.t(L10nKey.threadSave)).first);
      expect(
        shell.controller.storyChapters.first.eraSummary,
        '- Chapter summary',
      );
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('Draft my reply adds the draft after what is typed', (
    tester,
  ) async {
    final shell = await _manuscript(tester);
    shell.controller.toggleManuscriptView(false);
    await tester.pumpAndSettle();
    final composer = find.descendant(
      of: find.byType(FolioComposer),
      matching: find.byType(EditableText),
    );
    await tester.enterText(composer, 'I wave.');
    await tester.pump();
    await _tap(tester, _button(shell.t(L10nKey.storyActionImpersonate)));
    expect(
      tester.widget<EditableText>(composer).controller.text,
      'I wave.\n\nDrafted message',
    );
    expect(shell.gateway.callsTo('draftNextMessage'), hasLength(1));
  });
}
