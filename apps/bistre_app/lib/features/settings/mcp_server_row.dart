import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/label_control_layout.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import 'mcp_token_row.dart';

/// One MCP server in Settings > Agent: its name and what was found, on or off, Refresh
/// tools, and remove; an HTTP server's token sits below. The controls drop below the name
/// when they do not fit beside it (a phone, a long translation).
class McpServerRow extends StatelessWidget {
  const McpServerRow({
    super.key,
    required this.controller,
    required this.server,
    required this.report,
    required this.onDiscover,
  });

  final FolioController controller;
  final EngineMcpServerConfig server;

  /// The last discovery of this server, or null before one.
  final EngineMcpDiscoveryReport? report;

  /// Refresh tools; null while a discovery runs.
  final VoidCallback? onDiscover;

  static String _meta(
    BistreLocalizationController l10n,
    EngineMcpServerConfig server,
    EngineMcpDiscoveryReport? report,
  ) {
    final target = server.transport == 'http' ? server.url : server.command;
    if (report == null) {
      return l10n.joinMeta(<String>[server.transport.toUpperCase(), target]);
    }
    final tools = l10n.t(L10nKey.settingsAgentMcpToolsCount, <String, Object?>{
      'count': report.toolNames.length,
    });
    return l10n.joinMeta(<String>[
      server.transport.toUpperCase(),
      'MCP ${report.negotiatedProtocol}',
      tools,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = controller;
    return FolioSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabelControlLayout(
            label: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkText(server.name, role: InkTextRole.labelStrong),
                const SizedBox(height: 2),
                InkText(
                  _meta(l10n, server, report),
                  role: InkTextRole.captionMeta,
                  color: theme.inkMuted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            control: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                BistreSwitch(
                  key: ValueKey<String>('mcp_enabled_${server.id}'),
                  value: server.enabled,
                  semanticsLabel: server.name,
                  reduceMotionOverride: ctrl.reduceMotionOverride,
                  onChanged: (v) =>
                      unawaited(ctrl.setMcpServerEnabled(server.id, v)),
                ),
                EngravedButton(
                  label: l10n.t(L10nKey.settingsAgentMcpDiscover),
                  compact: true,
                  onPressed: onDiscover,
                ),
                BistreIconButton(
                  icon: BistreUiIcon.trash,
                  size: 14,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.threadDelete),
                  onPressed: () => unawaited(ctrl.removeMcpServer(server.id)),
                ),
              ],
            ),
          ),
          if (server.transport != 'stdio') ...[
            const SizedBox(height: 8),
            McpTokenRow(controller: ctrl, serverId: server.id),
          ],
        ],
      ),
    );
  }
}
