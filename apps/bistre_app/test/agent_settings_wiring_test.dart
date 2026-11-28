import 'dart:convert';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  testWidgets(
    'agent settings exposes web_search permission, MCP server toggle, and Refresh tools label',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;

      await ctrl.addMcpServer(
        const EngineMcpServerConfig(
          id: 'mcp_stdio_1',
          name: 'Local Files',
          transport: 'stdio',
          command: 'npx -y @modelcontextprotocol/server-filesystem',
        ),
      );
      ctrl.openSettings(SettingsTab.agent);
      await tester.pumpAndSettle();

      // 1. Both stdio and http MCP servers expose Refresh tools (not Load models).
      expect(
        find.text(shell.t(L10nKey.settingsAgentMcpDiscover)),
        findsOneWidget,
      );
      expect(
        find.text(shell.t(L10nKey.providerActionLoadModels)),
        findsNothing,
      );

      // 2. Per-MCP-server enable switch toggles enabled in kv_meta.
      final mcpSwitch = find.byKey(
        const ValueKey<String>('mcp_enabled_mcp_stdio_1'),
      );
      expect(mcpSwitch, findsOneWidget);
      await tester.ensureVisible(mcpSwitch);
      await tester.pumpAndSettle();
      await tester.tap(mcpSwitch);
      await tester.pumpAndSettle();

      expect(ctrl.mcpServers.single.enabled, isFalse);
      final stored = await shell.gateway.getKvMeta('agent.mcp_servers');
      final decoded = jsonDecode(stored!) as List<dynamic>;
      expect((decoded.single as Map<String, dynamic>)['enabled'], isFalse);

      // 3. Per-tool permissions list includes web_search and persists its state.
      final webSearchPermRow = find.byKey(
        const ValueKey<String>('tool_perm_row_web_search'),
      );
      expect(webSearchPermRow, findsOneWidget);
      await tester.ensureVisible(webSearchPermRow);
      await tester.pumpAndSettle();
      final offChip = find.descendant(
        of: webSearchPermRow,
        matching: find.text(shell.t(L10nKey.settingsAgentPermOff)),
      );
      await tester.tap(offChip);
      await tester.pumpAndSettle();

      expect(ctrl.toolPermissions['web_search'], 'off');

      await tester.pump(const Duration(seconds: 9));
    },
  );
}
