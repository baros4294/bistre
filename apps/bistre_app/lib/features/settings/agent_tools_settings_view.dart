import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/power_guard_host.dart';
import '../chat/reasoning_block.dart';
import '../shell/folio_controller.dart';

/// Dedicated Agent, Workspace Tools, MCP Server Manager, and Android Termux Bridge settings tab.
class AgentToolsSettingsView extends StatefulWidget {
  const AgentToolsSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<AgentToolsSettingsView> createState() => _AgentToolsSettingsViewState();
}

class _AgentToolsSettingsViewState extends State<AgentToolsSettingsView> {
  final TextEditingController _workspaceCtrl = TextEditingController();
  final FocusNode _workspaceFocus = FocusNode();
  final TextEditingController _mcpNameCtrl = TextEditingController();
  final FocusNode _mcpNameFocus = FocusNode();
  final TextEditingController _mcpUrlCtrl = TextEditingController();
  final FocusNode _mcpUrlFocus = FocusNode();
  final TextEditingController _webSearchCtrl = TextEditingController();
  final FocusNode _webSearchFocus = FocusNode();

  String _mcpTransport = 'http';
  bool _discoveringIdBusy = false;
  final Map<String, EngineMcpDiscoveryReport> _mcpReports =
      <String, EngineMcpDiscoveryReport>{};
  AndroidTermuxStatus? _termuxStatus;

  @override
  void initState() {
    super.initState();
    _workspaceCtrl.text = widget.controller.workspaceRootPath;
    _webSearchCtrl.text = widget.controller.webSearchEndpoint;
    unawaited(_probeTermux());
  }

  @override
  void dispose() {
    _workspaceCtrl.dispose();
    _workspaceFocus.dispose();
    _mcpNameCtrl.dispose();
    _mcpNameFocus.dispose();
    _mcpUrlCtrl.dispose();
    _mcpUrlFocus.dispose();
    _webSearchCtrl.dispose();
    _webSearchFocus.dispose();
    super.dispose();
  }

  Future<void> _probeTermux() async {
    final status = await BistrePowerGuardHost.getTermuxStatus();
    if (mounted) {
      setState(() => _termuxStatus = status);
    }
  }

  Future<void> _addMcpServer() async {
    final name = _mcpNameCtrl.text.trim();
    final endpoint = _mcpUrlCtrl.text.trim();
    if (name.isEmpty || endpoint.isEmpty) return;
    final id = 'mcp_${DateTime.now().millisecondsSinceEpoch}';
    final cfg = EngineMcpServerConfig(
      id: id,
      name: name,
      transport: _mcpTransport,
      command: _mcpTransport == 'stdio' ? endpoint : '',
      url: _mcpTransport == 'http' ? endpoint : '',
    );
    await widget.controller.addMcpServer(cfg);
    if (mounted) {
      _mcpNameCtrl.clear();
      _mcpUrlCtrl.clear();
    }
  }

  Future<void> _discoverServer(EngineMcpServerConfig server) async {
    setState(() => _discoveringIdBusy = true);
    final report = await widget.controller.discoverMcpServer(server);
    if (mounted) {
      setState(() {
        _discoveringIdBusy = false;
        if (report != null) {
          _mcpReports[server.id] = report;
        }
      });
    }
  }

  // MCP transport names are protocol terms from the MCP specification, not translatable copy.
  static const String _kMcpTransportHttp = 'Streamable HTTP';
  static const String _kMcpTransportStdio = 'Stdio';
  static const String _kMcpCommandPlaceholder =
      'npx -y @modelcontextprotocol/server';

  static String _formatMcpMeta(
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

  static String _formatTermuxBadge(
    BistreLocalizationController l10n,
    AndroidTermuxStatus status,
  ) {
    if (!status.installed) return l10n.t(L10nKey.settingsAgentTermuxMissing);
    if (!status.permissionGranted) {
      return l10n.t(L10nKey.settingsAgentTermuxPermission);
    }
    return l10n.t(L10nKey.settingsAgentTermuxReady);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final servers = ctrl.mcpServers;

    return SingleChildScrollView(
      padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Workspace Folder Binding
          FolioSurface(
            tone: FolioTone.elevated,
            padding: const EdgeInsetsDirectional.all(18),
            boxShadow: theme.cardShadow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BistreIcon(
                      BistreUiIcon.folder,
                      size: 16,
                      color: theme.accentBrass,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkText(
                        l10n.t(L10nKey.settingsAgentWorkspaceDir),
                        role: InkTextRole.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: QuillInput(
                        controller: _workspaceCtrl,
                        focusNode: _workspaceFocus,
                        placeholder: l10n.t(L10nKey.settingsAgentWorkspacePick),
                        maxLines: 1,
                        onSubmitted: () => unawaited(
                          ctrl.setWorkspaceRootPath(_workspaceCtrl.text),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    EngravedButton(
                      label: l10n.t(L10nKey.threadSave),
                      primary: true,
                      compact: true,
                      onPressed: () => unawaited(
                        ctrl.setWorkspaceRootPath(_workspaceCtrl.text),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const FolioDivider(),
                const SizedBox(height: 14),
                InkText(
                  l10n.t(L10nKey.chatReasoningEffort),
                  role: InkTextRole.labelStrong,
                ),
                const SizedBox(height: 8),
                ReasoningEffortSelector(
                  value: ctrl.settings.reasoningEffort,
                  onChanged: (effort) =>
                      unawaited(ctrl.setReasoningEffort(effort)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. MCP Server Manager (2026-07-28 + 2025-11-25 fallback)
          FolioSurface(
            tone: FolioTone.elevated,
            padding: const EdgeInsetsDirectional.all(18),
            boxShadow: theme.cardShadow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BistreIcon(
                      BistreUiIcon.server,
                      size: 16,
                      color: theme.accentBrass,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkText(
                        l10n.t(L10nKey.settingsAgentMcpTitle),
                        role: InkTextRole.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (servers.isNotEmpty) ...[
                  for (final srv in servers) ...[
                    FolioSurface(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                InkText(
                                  srv.name,
                                  role: InkTextRole.labelStrong,
                                ),
                                const SizedBox(height: 2),
                                InkText(
                                  _formatMcpMeta(
                                    l10n,
                                    srv,
                                    _mcpReports[srv.id],
                                  ),
                                  role: InkTextRole.captionMeta,
                                  color: theme.inkMuted,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (srv.transport == 'http')
                            EngravedButton(
                              label: l10n.t(L10nKey.providerActionLoadModels),
                              compact: true,
                              onPressed: _discoveringIdBusy
                                  ? null
                                  : () => unawaited(_discoverServer(srv)),
                            ),
                          const SizedBox(width: 6),
                          BistreIconButton(
                            icon: BistreUiIcon.trash,
                            size: 14,
                            dimension: 28,
                            semanticsLabel: l10n.t(L10nKey.threadDelete),
                            onPressed: () =>
                                unawaited(ctrl.removeMcpServer(srv.id)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 6),
                ],
                Row(
                  children: [
                    InkChip(
                      label: _kMcpTransportHttp,
                      selected: _mcpTransport == 'http',
                      onSelected: () => setState(() => _mcpTransport = 'http'),
                    ),
                    const SizedBox(width: 6),
                    InkChip(
                      label: _kMcpTransportStdio,
                      selected: _mcpTransport == 'stdio',
                      onSelected: () => setState(() => _mcpTransport = 'stdio'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: QuillInput(
                        controller: _mcpNameCtrl,
                        focusNode: _mcpNameFocus,
                        placeholder: l10n.t(
                          L10nKey.settingsAgentMcpServerPlaceholder,
                        ),
                        maxLines: 1,
                        onSubmitted: () => unawaited(_addMcpServer()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: QuillInput(
                        controller: _mcpUrlCtrl,
                        focusNode: _mcpUrlFocus,
                        placeholder: _mcpTransport == 'http'
                            ? l10n.t(L10nKey.providerFieldBaseUrl)
                            : _kMcpCommandPlaceholder,
                        maxLines: 1,
                        onSubmitted: () => unawaited(_addMcpServer()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    EngravedButton(
                      label: l10n.t(L10nKey.settingsAgentMcpAdd),
                      primary: true,
                      compact: true,
                      onPressed: () => unawaited(_addMcpServer()),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 3. Web Search Endpoint
          FolioSurface(
            tone: FolioTone.elevated,
            padding: const EdgeInsetsDirectional.all(18),
            boxShadow: theme.cardShadow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BistreIcon(
                      BistreUiIcon.globe,
                      size: 16,
                      color: theme.accentBrass,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkText(
                        l10n.t(L10nKey.settingsAgentWebSearch),
                        role: InkTextRole.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: QuillInput(
                        controller: _webSearchCtrl,
                        focusNode: _webSearchFocus,
                        placeholder: l10n.t(L10nKey.providerFieldBaseUrl),
                        maxLines: 1,
                        onSubmitted: () => unawaited(
                          ctrl.setWebSearchEndpoint(_webSearchCtrl.text),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    EngravedButton(
                      label: l10n.t(L10nKey.threadSave),
                      compact: true,
                      onPressed: () => unawaited(
                        ctrl.setWebSearchEndpoint(_webSearchCtrl.text),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 4. Optional Android Termux Bridge
          FolioSurface(
            tone: FolioTone.elevated,
            padding: const EdgeInsetsDirectional.all(18),
            boxShadow: theme.cardShadow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BistreIcon(
                      BistreUiIcon.code,
                      size: 16,
                      color: theme.accentBrass,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkText(
                        l10n.t(L10nKey.settingsAgentTermuxTitle),
                        role: InkTextRole.titleMedium,
                      ),
                    ),
                    if (_termuxStatus case final status?)
                      WaxSealBadge(
                        label: _formatTermuxBadge(l10n, status),
                        status: status.installed && status.permissionGranted
                            ? WaxSealStatus.ok
                            : WaxSealStatus.neutral,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                InkText(
                  l10n.t(L10nKey.settingsAgentTermuxDesc),
                  role: InkTextRole.bodyCompact,
                  color: theme.inkSecondary,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    InkChip(
                      label: l10n.t(L10nKey.settingsAppearanceOn),
                      selected: ctrl.settings.termuxBridgeEnabled,
                      onSelected: () =>
                          unawaited(ctrl.setTermuxBridgeEnabled(true)),
                    ),
                    const SizedBox(width: 6),
                    InkChip(
                      label: l10n.t(L10nKey.settingsAppearanceOff),
                      selected: !ctrl.settings.termuxBridgeEnabled,
                      onSelected: () =>
                          unawaited(ctrl.setTermuxBridgeEnabled(false)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
