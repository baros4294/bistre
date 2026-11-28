import 'dart:io';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/platform/desktop_host.dart';
import 'package:flutter/services.dart';
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

const MethodChannel _host = MethodChannel('bistre/desktop_host');

/// Answers the host's `openWebLink` with [opens] and records each link asked.
List<String> _mockBrowser(WidgetTester tester, {required bool opens}) {
  final links = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_host, (call) async {
    if (call.method != 'openWebLink') throw MissingPluginException();
    links.add((call.arguments as Map<Object?, Object?>)['url']! as String);
    return opens;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_host, null));
  return links;
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

  testWidgets(
    'Open in browser hands the source link to the host',
    (tester) async {
      final (shell, _) = await _chatWithSources(tester);
      final links = _mockBrowser(tester, opens: true);
      shell.controller.toggleStudioPane();
      shell.controller.setStudioTab(StudioTab.sources);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel(shell.t(L10nKey.chatSourceOpen)));
      await tester.pumpAndSettle();
      expect(links, <String>['https://weather.example/today']);
      expect(find.text(shell.t(L10nKey.chatSourceOpenFailed)), findsNothing);
    },
    // The Windows runner's channel; Linux opens links through core.
    skip: !Platform.isWindows,
  );

  testWidgets('A source no browser opened says so', (tester) async {
    final (shell, reply) = await _chatWithSources(tester);
    _mockBrowser(tester, opens: false);
    shell.controller.openTurnDetails(reply);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(shell.t(L10nKey.chatSourceOpen)));
    await tester.pumpAndSettle();
    expect(find.text(shell.t(L10nKey.chatSourceOpenFailed)), findsOneWidget);
    // Let the notice time out so no timer outlives the test.
    await tester.pump(const Duration(seconds: 9));
  }, skip: !Platform.isWindows);

  test('only http(s) links with a host and no login reach a browser', () {
    expect(
      BistreDesktopHost.webLink(' HTTPS://Weather.example/a?b=1 '),
      'https://weather.example/a?b=1',
    );
    for (final bad in <String>[
      'javascript:alert(1)',
      'file:///etc/passwd',
      'ftp://weather.example',
      'https://user:pass@weather.example',
      'weather.example',
      '',
    ]) {
      expect(BistreDesktopHost.webLink(bad), isNull, reason: bad);
    }
  });
}
