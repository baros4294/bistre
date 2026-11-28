import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

Future<(ShellHarness, EngineNode)> _chatWithSources(WidgetTester tester) async {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final chat = gateway.seedThread(title: 'Weather', updatedAtMs: 1000);
  final user = await gateway.appendNode(
    threadId: chat.id,
    role: 'user',
    content: 'Will it rain?',
  );
  // The reply text names no URL: sources come from the engine, not from scraping text.
  final reply = await gateway.appendNode(
    threadId: chat.id,
    parentId: user.id,
    role: 'assistant',
    content: 'Yes, from noon.',
  );
  gateway.grounding[chat.id] = <EngineGroundingSource>[
    EngineGroundingSource(
      nodeId: reply.id,
      url: 'https://weather.example/today',
      title: 'Hourly forecast',
      citedText: 'Rain from 12:00',
    ),
  ];
  final shell = await ShellHarness.pump(tester, gateway: gateway);
  await tester.pumpAndSettle();
  return (shell, reply);
}

void main() {
  testWidgets('Studio lists the web sources replies used', (tester) async {
    final (shell, _) = await _chatWithSources(tester);
    shell.controller.toggleStudioPane();
    shell.controller.setStudioTab(StudioTab.sources);
    await tester.pumpAndSettle();
    expect(find.text('Hourly forecast'), findsOneWidget);
    expect(find.text('weather.example'), findsOneWidget);
    expect(find.text('Rain from 12:00'), findsOneWidget);
    expect(find.text(shell.t(L10nKey.studioSourcesEmpty)), findsNothing);
  });

  testWidgets('Turn details show the reply\'s sources from the engine', (
    tester,
  ) async {
    final (shell, reply) = await _chatWithSources(tester);
    shell.controller.openTurnDetails(reply);
    await tester.pumpAndSettle();
    expect(find.text('Hourly forecast'), findsOneWidget);
  });
}
