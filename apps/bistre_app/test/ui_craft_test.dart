import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/design/bistre_decorations.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/label_control_layout.dart';
import 'package:bistre_app/design/popover_placement.dart';
import 'package:bistre_app/features/chat/content_direction.dart';
import 'package:bistre_app/features/chat/folio_message_feed.dart';
import 'package:bistre_app/features/chat/plain_preview.dart';
import 'package:bistre_app/features/chat/thinking_control.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:bistre_app/features/settings/schedule_words.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/story/prompt_inspector_panel.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// UI behaviour required by DESIGN §1.2 (UX craft).
void main() {
  test('a cut by length never splits an emoji', () {
    expect(clipText('Trip \u{1F600}\u{1F600}\u{1F600}', 6), 'Trip \u{1F600}…');
    expect(clipText('short', 6), 'short');
    // 'a' then one emoji (two UTF-16 units): a cut after one unit takes the whole emoji.
    expect(wholeUnits('a\u{1F600}b', 2), 3);
    expect(wholeUnits('abc', 2), 2);
    expect(
      middleEllipsis(
        '\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}.png',
        max: 9,
      ),
      '\u{1F600}\u{1F600}\u{1F600}…\u{1F600}.png',
    );
  });

  test('only a real o-series model id gets the OpenAI mark', () {
    expect(LabIconCatalog.resolve(modelId: 'o3-mini')?.slug, 'openai');
    expect(LabIconCatalog.resolve(modelId: 'openai/o4')?.slug, 'openai');
    expect(LabIconCatalog.resolve(modelId: 'solo1-chat'), isNull);
    expect(LabIconCatalog.resolve(modelId: 'pro3-local'), isNull);
  });

  group('settings rows', () {
    Future<bool> stacked(
      WidgetTester tester, {
      required double controlWidth,
      double textScale = 1,
    }) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 358,
                child: LabelControlLayout(
                  label: const Text('Enabled'),
                  control: SizedBox(width: controlWidth, height: 28),
                ),
              ),
            ),
          ),
        ),
      );
      return tester
          .renderObject<RenderLabelControlLayout>(
            find.byType(LabelControlLayout),
          )
          .isStacked;
    }

    testWidgets('a switch stays beside its label on a phone, even at 200%', (
      tester,
    ) async {
      expect(await stacked(tester, controlWidth: 48), isFalse);
      expect(await stacked(tester, controlWidth: 48, textScale: 2), isFalse);
    });

    testWidgets('a control too wide to fit drops below its label', (
      tester,
    ) async {
      expect(await stacked(tester, controlWidth: 300), isTrue);
    });
  });

  test('an approval is titled with the tool and what it acts on', () {
    expect(
      approvalSummary('edit_file', '{"path":"wal.rs"}'),
      'edit_file wal.rs',
    );
    expect(
      approvalSummary('shell', '{"command":"cargo test\\ncargo fmt"}'),
      'shell cargo test',
    );
    expect(approvalSummary('mcp_call', '{"x":1}'), 'mcp_call');
    expect(approvalSummary('shell', 'not json'), 'shell');
  });

  test('previews drop Markdown marks', () {
    expect(
      plainPreview('## Plan\n- **ship** `v2` [notes](https://x.test)'),
      'Plan ship v2 notes',
    );
    expect(plainPreview('a' * 200).length, 109);
  });

  test('a long file name keeps its extension', () {
    final short = middleEllipsis('quarterly-report-final-version-2.pdf');
    expect(short.length, lessThanOrEqualTo(28));
    expect(short, contains('…'));
    expect(short, endsWith('.pdf'));
    expect(middleEllipsis('notes.txt'), 'notes.txt');
    expect(attachmentIconFor('text/csv', 'a.csv'), BistreUiIcon.tableGrid);
  });

  test('each tool row has its own icon', () {
    expect(toolIconFor('read_file'), BistreUiIcon.document);
    expect(toolIconFor('grep'), BistreUiIcon.search);
    expect(toolIconFor('web_fetch'), BistreUiIcon.globe);
    expect(toolIconFor('mcp_github'), BistreUiIcon.mcpPlug);
    expect(toolIconFor('shell'), BistreUiIcon.terminal);
    expect(toolIconFor('fs_delete'), BistreUiIcon.trash);
    expect(toolIconFor('fs_list'), BistreUiIcon.folder);
    expect(toolIconFor('fs_move'), BistreUiIcon.edit);
    expect(toolIconFor('agent_delegate'), BistreUiIcon.branchTree);
  });

  group('words, not codes', () {
    final l10n = loadShellCatalogs();

    test('schedules read as words', () {
      expect(
        scheduleInWords(l10n, 'every 30m'),
        l10n.t(L10nKey.automationsEveryMinutes, <String, Object?>{'count': 30}),
      );
      expect(
        scheduleInWords(l10n, '0 9 * * *'),
        l10n.t(L10nKey.automationsDailyAt, <String, Object?>{'time': '09:00'}),
      );
      expect(
        scheduleInWords(l10n, '*/15 * * * *'),
        l10n.t(L10nKey.automationsEveryMinutes, <String, Object?>{'count': 15}),
      );
      expect(scheduleInWords(l10n, '0 9 * * 1'), '0 9 * * 1');
      expect(scheduleStatusInWords(l10n, 'idle'), isNull);
      expect(
        scheduleStatusInWords(l10n, 'diag.provider.auth_failed'),
        l10n.t(L10nKey.automationsLastFailed),
      );
    });

    test('lore reasons and prompt parts read as words', () {
      expect(
        loreReason(l10n, 'no_keyword_match'),
        l10n.t(L10nKey.storyLoreReasonNotTriggered),
      );
      expect(
        loreReason(l10n, 'recursive_depth_2'),
        l10n.t(L10nKey.storyLoreReasonRecursive),
      );
      const block = EnginePromptBlock(
        id: 'char_7',
        label: 'Character · Lyra',
        role: 'system',
        content: '',
        estimatedTokens: 0,
        isStaticPrefix: true,
      );
      expect(
        promptBlockTitle(l10n, block),
        l10n.t(L10nKey.storyBlockCharacter, <String, Object?>{
          'name': l10n.isolate('Lyra'),
        }),
      );
    });
  });

  testWidgets('icons grow with text, up to 1.5x', (tester) async {
    late double scale;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(3)),
        child: Builder(
          builder: (context) {
            scale = iconScaleOf(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(scale, kMaxIconScale);
  });

  testWidgets('a title follows its own text direction', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: OwnDirection(
          text: 'مرحبا بالعالم',
          child: Text('مرحبا بالعالم'),
        ),
      ),
    );
    final inner = tester.widget<Directionality>(
      find
          .ancestor(
            of: find.byType(Text),
            matching: find.byType(Directionality),
          )
          .first,
    );
    expect(inner.textDirection, TextDirection.rtl);
  });

  testWidgets('a popover is never wider than the window', (tester) async {
    late double width;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(300, 600)),
        child: Builder(
          builder: (context) {
            width = PopoverPlacement.popoverWidthFor(context, 392);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(width, 300 - 2 * PopoverPlacement.margin);
  });

  testWidgets('Thinking shows no level on the slider while on Auto', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    await shell.controller.setReasoningEffort('default');
    await tester.tap(find.byType(ThinkingControl));
    await tester.pumpAndSettle();
    BistreSlider slider() => tester.widget<BistreSlider>(
      find.descendant(
        of: find.byType(ThinkingEffortPicker),
        matching: find.byType(BistreSlider),
      ),
    );
    expect(slider().unset, isTrue);
    await shell.controller.setReasoningEffort('high');
    await tester.pumpAndSettle();
    expect(slider().unset, isFalse);
    expect(slider().valueLabel, shell.t(L10nKey.chatEffortHigh));
    // Let the toast from saving the setting run out before the test ends.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Delete all chats lives in Settings, not the chat list', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final label = shell.t(L10nKey.settingsStorageDeleteAllChats);
    expect(find.text(label), findsNothing);
    shell.controller.openSettings(SettingsTab.updates);
    await tester.pumpAndSettle();
    expect(find.text(label), findsOneWidget);
  });

  testWidgets('tool permissions use plain names', (tester) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.openSettings(SettingsTab.agent);
    await tester.pumpAndSettle();
    expect(
      find.text(
        shell.t(L10nKey.settingsAgentToolReadFile),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(find.text('read_file', skipOffstage: false), findsNothing);
  });

  testWidgets('the chat filter shows its words in the search field', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.setSidebarFilter('zebra');
    await tester.pumpAndSettle();
    expect(find.text('zebra'), findsOneWidget);
  });

  testWidgets('a new chat is named in the language showing', (tester) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.defaultThreadTitle = 'محادثة جديدة';
    await shell.controller.createNewFolio();
    await tester.pumpAndSettle();
    expect(shell.controller.activeThread?.title, 'محادثة جديدة');
  });
}
