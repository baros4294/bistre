import 'package:bistre_app/bridge/engine_models.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/settings/mcp_registry_browser.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

EngineMcpRegistryEntry _entry(String name) => EngineMcpRegistryEntry(
  name: 'io.github.acme/$name',
  description: 'The $name server.',
  version: '1.0.0',
  server: EngineMcpServerConfig(
    id: 'mcp_$name',
    name: name,
    transport: 'http',
    url: 'https://$name.acme.example/mcp',
    enabled: false,
  ),
);

/// Agent settings search the MCP Registry, page through it, and add a server turned off.
void main() {
  for (final (layout, scale, locale) in <(ShellLayout, double, String)>[
    (ShellLayout.desktop, 1, 'en'),
    (ShellLayout.phone, 2, 'en'),
    (ShellLayout.phone, 1, 'ar'),
  ]) {
    testWidgets('the MCP Registry is searched and a server added '
        '($layout, $scale, $locale)', (tester) async {
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
        ..registryPages = (query, cursor) => cursor == null
            ? EngineMcpRegistryPage(
                entries: <EngineMcpRegistryEntry>[_entry('notes$query')],
                nextCursor: 'page2',
              )
            : EngineMcpRegistryPage(
                entries: <EngineMcpRegistryEntry>[_entry('files')],
              );
      final shell = await ShellHarness.pump(
        tester,
        layout: layout,
        textScale: scale,
        locale: locale,
        gateway: gateway,
      );
      final ctrl = shell.controller;
      await ctrl.updateSettings(
        ctrl.settings.copyWith(locale: locale),
        quiet: true,
      );
      ctrl.openSettings(SettingsTab.agent);
      await tester.pumpAndSettle();
      final l10n = shell.l10n;
      final open = find.widgetWithText(
        InkChip,
        l10n.t(L10nKey.settingsAgentMcpRegistryOpen),
      );
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      expect(find.byType(McpRegistryBrowser), findsNothing);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<InkChip>(open).selected, isTrue);
      final browser = find.byType(McpRegistryBrowser);
      expect(
        find.descendant(of: browser, matching: find.text('notes')),
        findsOneWidget,
      );

      // A search replaces the list; More results adds the next page below it.
      await tester.enterText(
        find.descendant(of: browser, matching: find.byType(EditableText)),
        'x',
      );
      await tester.tap(find.text(l10n.t(L10nKey.settingsAgentMcpRegistryFind)));
      await tester.pumpAndSettle();
      expect(find.text('notes'), findsNothing);
      expect(find.text('notesx'), findsOneWidget);
      final more = find.text(l10n.t(L10nKey.settingsAgentMcpRegistryMore));
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('files'), findsOneWidget);
      expect(more, findsNothing);

      final add = find.text(l10n.t(L10nKey.settingsAgentMcpRegistryAdd));
      expect(add, findsNWidgets(2));
      await tester.ensureVisible(add.first);
      await tester.tap(add.first);
      await tester.pumpAndSettle();
      expect(ctrl.mcpServers.map((s) => (s.name, s.enabled)), <(String, bool)>[
        ('notesx', false),
      ]);
      expect(
        find.text(l10n.t(L10nKey.settingsAgentMcpRegistryAdded)),
        findsOneWidget,
      );
      expect(add, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 9));
    });
  }

  testWidgets('an unreachable registry says so', (tester) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.openSettings(SettingsTab.agent);
    await tester.pumpAndSettle();
    final open = find.widgetWithText(
      InkChip,
      shell.l10n.t(L10nKey.settingsAgentMcpRegistryOpen),
    );
    await tester.ensureVisible(open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(
      find.text(shell.l10n.t(L10nKey.settingsAgentMcpRegistryFailed)),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 9));
  });
}
