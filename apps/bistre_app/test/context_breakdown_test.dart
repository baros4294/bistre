import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/chat/context_gauge_ring.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

const _breakdown = EngineContextBreakdown(
  categories: <EngineContextCategory>[
    EngineContextCategory(kind: 'messages', tokens: 39800, count: 12),
    EngineContextCategory(kind: 'built_in_tools', tokens: 4000, count: 6),
    EngineContextCategory(kind: 'mcp_tools', tokens: 2000, count: 6),
    EngineContextCategory(kind: 'system_prompt', tokens: 4200),
    EngineContextCategory(
      kind: 'deferred_mcp_tools',
      tokens: 3000,
      count: 4,
      sent: false,
    ),
  ],
  totalSent: 50000,
  limitTokens: 100000,
  reserveTokens: 15000,
  mcp: <EngineMcpServerUsage>[
    EngineMcpServerUsage(
      serverId: 's1',
      label: 'Files server',
      tools: <EngineMcpToolUsage>[
        EngineMcpToolUsage(name: 'list_dir', tokens: 300, deferred: false),
        EngineMcpToolUsage(name: 'stat', tokens: 200, deferred: true),
      ],
    ),
  ],
);

void main() {
  testWidgets(
    'the breakdown shows each share, what is not sent, and MCP tools (A-SE)',
    (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
        ..contextBreakdownFixture = _breakdown;
      final chat = gateway.seedThread(title: 'Busy', updatedAtMs: 1000);
      await gateway.appendNode(threadId: chat.id, role: 'user', content: 'hi');
      final shell = await ShellHarness.pump(tester, gateway: gateway);
      await tester.tap(find.byType(ContextGaugeRing));
      await tester.pumpAndSettle();

      expect(
        find.text(shell.t(L10nKey.chatContextPercentUsed, {'percent': '50.0'})),
        findsOneWidget,
      );
      expect(
        find.text(shell.t(L10nKey.chatContextPercent, {'percent': '39.8'})),
        findsOneWidget,
        reason: 'messages are 39.8 % of the window',
      );
      expect(find.text(shell.t(L10nKey.chatContextCatReserve)), findsOneWidget);
      expect(find.text(shell.t(L10nKey.chatContextNotSent)), findsOneWidget);

      await tester.tap(
        find.text(shell.t(L10nKey.chatContextCatMcpTools, {'count': 6})),
      );
      await tester.pumpAndSettle();
      expect(find.text('Files server'), findsOneWidget);
      expect(
        find.text(shell.t(L10nKey.chatContextToolOnDemand, {'name': 'stat'})),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Files server'), findsNothing, reason: 'Esc goes back');
      expect(find.text(shell.t(L10nKey.chatContextNotSent)), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text(shell.t(L10nKey.chatContextNotSent)), findsNothing);
    },
  );
}
