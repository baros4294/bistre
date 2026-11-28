import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/committed_tool_steps.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// A finished reply shows its tool steps as one folded checklist, never as messages
/// from the user, and a question the assistant asked can be answered in one tap.
FakeEngineGateway _gateway({required bool asked}) {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final thread = gateway.seedThread(title: 'Notes', updatedAtMs: 2000);
  final user = gateway.seedNode(
    threadId: thread.id,
    role: 'user',
    content: 'What does the note say?',
  );
  final calls = gateway.seedNode(
    threadId: thread.id,
    parentId: user.id,
    role: 'assistant',
    content: '',
    meta: <String, Object?>{
      'tool_calls': <Object?>[
        <String, Object?>{
          'call_id': 'c1',
          'name': 'read',
          'arguments_json': '{"path":"note.txt"}',
        },
        <String, Object?>{
          'call_id': 'c2',
          'name': 'grep',
          'arguments_json': '{"pattern":"hello"}',
        },
        if (asked)
          <String, Object?>{
            'call_id': 'c3',
            'name': 'ask_user',
            'arguments_json': '{"question":"Which file next?","options":["todo.txt","plan.txt"]}',
          },
      ],
    },
  );
  var parent = calls.id;
  for (final (id, name, out) in <(String, String, String)>[
    ('c1', 'read', 'SECRET-NOTE-BODY'),
    ('c2', 'grep', '1 match'),
    if (asked) ('c3', 'ask_user', 'The user sees your question.'),
  ]) {
    parent = gateway
        .seedNode(
          threadId: thread.id,
          parentId: parent,
          role: 'tool',
          content: out,
          meta: <String, Object?>{
            'tool_result': <String, Object?>{'call_id': id, 'name': name},
            'risk_tier': 'tier0_read_only',
            'duration_ms': 1200,
          },
        )
        .id;
  }
  if (!asked) {
    gateway.seedNode(
      threadId: thread.id,
      parentId: parent,
      role: 'assistant',
      content: 'It says hello.',
    );
  }
  return gateway;
}

/// Two tool steps, each with its own thinking, then the answer.
FakeEngineGateway _twoSteps() {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final thread = gateway.seedThread(title: 'Notes', updatedAtMs: 2000);
  var parent = gateway
      .seedNode(threadId: thread.id, role: 'user', content: 'Find hello.')
      .id;
  // A shell step never folds, so the read keeps its own row beside it.
  for (final (id, name, args, thought) in <(String, String, String, String)>[
    ('c1', 'read', '{"path":"note.txt"}', 'Open the note first.\nMore detail.'),
    ('c2', 'shell', '{"command":"grep hello"}', 'Now search for hello.'),
  ]) {
    parent = gateway
        .seedNode(
          threadId: thread.id,
          parentId: parent,
          role: 'assistant',
          content: '',
          meta: <String, Object?>{
            'thinking_text': thought,
            'thinking_duration_ms': 1500,
            'tool_calls': <Object?>[
              <String, Object?>{
                'call_id': id,
                'name': name,
                'arguments_json': args,
              },
            ],
          },
        )
        .id;
    parent = gateway
        .seedNode(
          threadId: thread.id,
          parentId: parent,
          role: 'tool',
          content: 'out',
          meta: <String, Object?>{
            'tool_result': <String, Object?>{'call_id': id, 'name': name},
          },
        )
        .id;
  }
  gateway.seedNode(
    threadId: thread.id,
    parentId: parent,
    role: 'assistant',
    content: 'Found it.',
  );
  return gateway;
}

/// Every timeline row the feed shows with [summary], across all checklists.
List<List<ToolActivityEntry>> _viewsWith(WidgetTester tester, String summary) =>
    <List<ToolActivityEntry>>[
      for (final v in tester.widgetList<ToolTimelineView>(
        find.byType(ToolTimelineView),
      ))
        if (v.entries.any((e) => e.summary == summary)) v.entries,
    ];

Future<ShellHarness> _open(
  WidgetTester tester,
  FakeEngineGateway gateway,
  ShellLayout layout, {
  double textScale = 1,
  String locale = 'en',
}) async {
  final shell = await ShellHarness.pump(
    tester,
    gateway: gateway,
    layout: layout,
    textScale: textScale,
    locale: locale,
  );
  await shell.controller.selectThread(shell.controller.threads.first.id);
  await tester.pumpAndSettle();
  return shell;
}

void main() {
  for (final layout in <ShellLayout>[ShellLayout.desktop, ShellLayout.phone]) {
    testWidgets('tool steps fold into one checklist ($layout)', (tester) async {
      await _open(tester, _gateway(asked: false), layout);
      expect(find.byType(ToolTimelineView), findsOneWidget);
      // Folded: the tool output is not shown as a message (it used to read as the user's).
      expect(
        find.textContaining('SECRET-NOTE-BODY', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('It says hello.', findRichText: true),
        findsOne,
      );
      await tester.tap(find.textContaining('2/2', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('read note.txt'), findsOneWidget);
      expect(find.textContaining('grep hello'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
    });
  }

  for (final (layout, scale, locale) in <(ShellLayout, double, String)>[
    (ShellLayout.desktop, 1, 'en'),
    (ShellLayout.phone, 2, 'en'),
    (ShellLayout.phone, 1, 'ar'),
  ]) {
    testWidgets('a question is answered with one tap '
        '($layout, $scale, $locale)', (tester) async {
      final gateway = _gateway(asked: true);
      await _open(tester, gateway, layout, textScale: scale, locale: locale);
      expect(find.byType(AskUserCard), findsOneWidget);
      expect(find.textContaining('Which file next?'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(EngravedButton, 'plan.txt'));
      await tester.pumpAndSettle();
      final sent = gateway.calls.where((c) => c.method == 'sendAndStreamReply');
      expect(sent.single.args['userContent'], 'plan.txt');
      // Answered: the options stay visible but no longer send.
      final button = tester.widget<EngravedButton>(
        find.widgetWithText(EngravedButton, 'todo.txt', skipOffstage: false),
      );
      expect(button.onPressed, isNull);
      await tester.pump(const Duration(seconds: 9));
    });
  }

  for (final layout in <ShellLayout>[ShellLayout.desktop, ShellLayout.phone]) {
    testWidgets('each step shows its thinking before its own tools ($layout)', (
      tester,
    ) async {
      await _open(tester, _twoSteps(), layout);
      expect(find.byType(ToolTimelineView), findsOneWidget);
      // Thinking rows are not counted as steps.
      await tester.tap(find.textContaining('2/2', findRichText: true));
      await tester.pumpAndSettle();
      final ys = <double>[
        for (final text in <String>[
          'Open the note first.',
          'read note.txt',
          'Now search for hello.',
          'shell grep hello',
        ])
          tester.getTopLeft(find.text(text)).dy,
      ];
      expect(ys, List<double>.of(ys)..sort());
      expect(ys.toSet(), hasLength(4));
      // A thinking row opens to its full text.
      expect(find.textContaining('More detail.'), findsNothing);
      await tester.tap(find.text('Open the note first.'));
      await tester.pumpAndSettle();
      expect(find.textContaining('More detail.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
    });
  }

  testWidgets('the live reply keeps only the step still running', (
    tester,
  ) async {
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
    final thread = gateway.seedThread(title: 'Live', updatedAtMs: 2000);
    final user = gateway.seedNode(
      threadId: thread.id,
      role: 'user',
      content: 'Read it.',
    );
    final shell = await _open(tester, gateway, ShellLayout.desktop);
    final ctrl = shell.controller;
    gateway
      ..emit(RunStartedEvent(threadId: thread.id, nodeId: 'live-1'))
      ..emit(
        ThinkingDeltaEvent(
          threadId: thread.id,
          nodeId: 'live-1',
          delta: 'Read the file.',
        ),
      );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // Thinking reveals at a reading pace; some of it is live.
    expect(ctrl.liveTurn.value?.thinking, isNotEmpty);

    // The step's reply is committed: the live card drops its copy of the thinking.
    final step = gateway.seedNode(
      threadId: thread.id,
      parentId: user.id,
      role: 'assistant',
      content: '',
      meta: <String, Object?>{
        'thinking_text': 'Read the file.',
        'tool_calls': <Object?>[
          <String, Object?>{
            'call_id': 'c9',
            'name': 'read',
            'arguments_json': '{"path":"live.txt"}',
          },
        ],
      },
    );
    gateway.emit(NodeCommittedEvent(step));
    ctrl.recordToolActivity(
      ToolActivityEntry(
        id: 'c9',
        toolName: 'read',
        summary: 'read live.txt',
        status: 'running',
        threadId: thread.id,
        runId: 'run-1',
      ),
    );
    await tester.pump();
    expect(ctrl.liveTurn.value?.thinking, isEmpty);
    final running = _viewsWith(tester, 'read live.txt');
    expect(running, hasLength(1));
    expect(running.single.single.status, 'running');

    // The result is committed: the row moves into the feed's checklist, shown once.
    gateway.emit(
      NodeCommittedEvent(
        gateway.seedNode(
          threadId: thread.id,
          parentId: step.id,
          role: 'tool',
          content: 'file body',
          meta: <String, Object?>{
            'tool_result': <String, Object?>{'call_id': 'c9', 'name': 'read'},
          },
        ),
      ),
    );
    ctrl.recordToolActivity(
      ToolActivityEntry(
        id: 'c9',
        toolName: 'read',
        summary: 'read live.txt',
        status: 'completed',
        threadId: thread.id,
        runId: 'run-1',
      ),
    );
    await tester.pump();
    final done = _viewsWith(tester, 'read live.txt');
    expect(done, hasLength(1));
    expect(done.single.map((e) => e.toolName), <String>[kThinkingRow, 'read']);
    gateway.emit(
      RunFinishedEvent(threadId: thread.id, nodeId: 'live-1', cancelled: false),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
  });
}
