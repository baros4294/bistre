import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../../platform/power_guard_host.dart';
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
    // After the first frame: a refresh can notify the controller, which must never happen
    // while this view is still being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.refreshWorkspaceHooks());
    });
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

  // MCP transport names are protocol identifiers, not prose copy.
  static const String _kMcpTransportHttp = 'Streamable HTTP';
  static const String _kMcpTransportStdio = 'Stdio';
  static const String _kMcpCommandPlaceholder =
      'npx -y @modelcontextprotocol/server';
  static const List<String> _kPermissionTools = <String>[
    'read_file',
    'edit_file',
    'grep',
    'glob',
    'shell',
    'web_fetch',
    'mcp',
  ];

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

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Workspace Folders (native OS folder picker + Git branch indicator)
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
                      if (ctrl.activeGitBranch.isNotEmpty)
                        WaxSealBadge(label: ctrl.activeGitBranch),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (ctrl.workspaceFolders.isEmpty)
                    InkText(
                      l10n.t(L10nKey.settingsAgentNoFolders),
                      role: InkTextRole.bodyCompact,
                      color: theme.inkMuted,
                    )
                  else
                    for (final folder in ctrl.workspaceFolders) ...[
                      FolioSurface(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          10,
                          6,
                          6,
                          6,
                        ),
                        borderRadius: 8,
                        child: Row(
                          children: [
                            BistreIcon(
                              BistreUiIcon.folder,
                              size: 13,
                              color: theme.accentBrass,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: InkText(
                                folder,
                                role: InkTextRole.codeBlock,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            BistreIconButton(
                              icon: BistreUiIcon.close,
                              size: 12,
                              dimension: 26,
                              semanticsLabel: l10n.t(L10nKey.threadDelete),
                              onPressed: () =>
                                  unawaited(ctrl.removeWorkspaceFolder(folder)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      EngravedButton(
                        label: ctrl.workspaceFolders.isEmpty
                            ? l10n.t(L10nKey.settingsAgentChooseFolder)
                            : l10n.t(L10nKey.settingsAgentAddFolder),
                        primary: true,
                        compact: true,
                        leading: BistreIcon(
                          BistreUiIcon.folder,
                          size: 13,
                          color: theme.onAccentWax,
                        ),
                        onPressed: () async {
                          final picked =
                              await BistreDesktopHost.pickLocalFolder(
                                title: l10n.t(
                                  L10nKey.settingsAgentWorkspaceDir,
                                ),
                              );
                          if (picked != null && picked.isNotEmpty) {
                            await ctrl.addWorkspaceFolder(picked);
                            if (mounted) {
                              _workspaceCtrl.text = picked;
                            }
                          }
                        },
                      ),
                      if (ctrl.workspaceFolders.isNotEmpty)
                        EngravedButton(
                          label: l10n.t(L10nKey.settingsProfileAvatarClear),
                          compact: true,
                          onPressed: () =>
                              unawaited(ctrl.clearWorkspaceFolders()),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 1b. Per-tool permissions (Ask / Allow / Off)
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsAgentPermissionsTitle),
              children: [
                for (final tool in _kPermissionTools)
                  BistreSettingRow(
                    label: tool,
                    trailing: BistreSegmentedControl<String>(
                      selected: ctrl.toolPermissionFor(tool),
                      onSelected: (v) =>
                          unawaited(ctrl.setToolPermission(tool, v)),
                      options: <BistreSegmentedOption<String>>[
                        BistreSegmentedOption<String>(
                          value: 'ask',
                          label: l10n.t(L10nKey.settingsAgentPermAsk),
                        ),
                        BistreSegmentedOption<String>(
                          value: 'allow',
                          label: l10n.t(L10nKey.settingsAgentPermAllow),
                        ),
                        BistreSegmentedOption<String>(
                          value: 'off',
                          label: l10n.t(L10nKey.settingsAgentPermOff),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // 1c. Workspace hooks (A-S5): shown for review, run only once allowed.
            if (ctrl.workspaceHooks case final hooks?) ...[
              BistreSettingsSection(
                title: l10n.t(L10nKey.settingsAgentHooksTitle),
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      16,
                      12,
                      16,
                      4,
                    ),
                    child: InkText(
                      l10n.t(L10nKey.settingsAgentHooksBody),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                  ),
                  for (final hook in hooks.hooks)
                    BistreSettingRow(
                      label: l10n.joinMeta(<String>[
                        hook.event,
                        if (hook.toolFilter case final f? when f.isNotEmpty) f,
                      ]),
                      description: hook.command,
                    ),
                  BistreSettingRow(
                    label: l10n.t(
                      hooks.approved
                          ? L10nKey.settingsAgentHooksAllowed
                          : L10nKey.settingsAgentHooksPending,
                    ),
                    trailing: hooks.approved
                        ? null
                        : EngravedButton(
                            label: l10n.t(L10nKey.settingsAgentHooksAllow),
                            primary: true,
                            compact: true,
                            onPressed: () =>
                                unawaited(ctrl.approveWorkspaceHooks()),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],

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
                  // Wraps below 720 dp so the import button never overflows a phone.
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          InkChip(
                            label: _kMcpTransportHttp,
                            selected: _mcpTransport == 'http',
                            onSelected: () =>
                                setState(() => _mcpTransport = 'http'),
                          ),
                          InkChip(
                            label: _kMcpTransportStdio,
                            selected: _mcpTransport == 'stdio',
                            onSelected: () =>
                                setState(() => _mcpTransport = 'stdio'),
                          ),
                        ],
                      ),
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsAgentImportMcpJson),
                        compact: true,
                        onPressed: () async {
                          final picked = await BistreDesktopHost.pickLocalFile(
                            title: l10n.t(L10nKey.settingsAgentImportMcpJson),
                            filterLabel: 'MCP JSON (*.json)',
                            filterSpec: '*.json',
                          );
                          if (picked != null && picked.isNotEmpty) {
                            await ctrl.importMcpJsonFile(picked);
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkText(
                              l10n.t(L10nKey.settingsAgentMcpNameLabel),
                              role: InkTextRole.captionMeta,
                              color: theme.inkMuted,
                            ),
                            const SizedBox(height: 4),
                            QuillInput(
                              controller: _mcpNameCtrl,
                              focusNode: _mcpNameFocus,
                              placeholder: l10n.t(
                                L10nKey.settingsAgentMcpServerPlaceholder,
                              ),
                              maxLines: 1,
                              onSubmitted: () => unawaited(_addMcpServer()),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkText(
                              _mcpTransport == 'http'
                                  ? l10n.t(L10nKey.settingsAgentMcpUrlLabel)
                                  : l10n.t(L10nKey.settingsAgentMcpCmdLabel),
                              role: InkTextRole.captionMeta,
                              color: theme.inkMuted,
                            ),
                            const SizedBox(height: 4),
                            QuillInput(
                              controller: _mcpUrlCtrl,
                              focusNode: _mcpUrlFocus,
                              placeholder: _mcpTransport == 'http'
                                  ? l10n.t(L10nKey.providerFieldBaseUrl)
                                  : _kMcpCommandPlaceholder,
                              maxLines: 1,
                              onSubmitted: () => unawaited(_addMcpServer()),
                            ),
                          ],
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

            // 2b. Workspace Skills (`SKILL.md` discovery)
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
                        BistreUiIcon.bookOpen,
                        size: 16,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.settingsAgentSkillsTitle),
                          role: InkTextRole.titleMedium,
                        ),
                      ),
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsAgentSkillsScan),
                        compact: true,
                        onPressed: ctrl.workspaceRootPath.isEmpty
                            ? null
                            : () =>
                                  unawaited(ctrl.refreshMemorySkillsAndCron()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (ctrl.discoveredSkills.isEmpty)
                    InkText(
                      l10n.t(L10nKey.settingsAgentSkillsEmpty),
                      role: InkTextRole.bodyCompact,
                      color: theme.inkMuted,
                    )
                  else
                    for (final sk in ctrl.discoveredSkills) ...[
                      Padding(
                        padding: const EdgeInsetsDirectional.only(bottom: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  InkText(
                                    sk.name,
                                    role: InkTextRole.labelStrong,
                                  ),
                                  if (sk.description.isNotEmpty)
                                    InkText(
                                      sk.description,
                                      role: InkTextRole.captionMeta,
                                      color: theme.inkMuted,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 3. Web Search (Off | DuckDuckGo | Custom URL)
            FolioSurface(
              tone: FolioTone.elevated,
              padding: const EdgeInsetsDirectional.all(18),
              boxShadow: theme.cardShadow,
              child: Builder(
                builder: (context) {
                  final ep = ctrl.webSearchEndpoint.trim();
                  final mode = ep.isEmpty
                      ? 'off'
                      : (ep == 'duckduckgo' ? 'duckduckgo' : 'custom');
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Wraps below 720 dp so the mode switch never overflows a phone.
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              BistreIcon(
                                BistreUiIcon.globe,
                                size: 16,
                                color: theme.accentBrass,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: InkText(
                                  l10n.t(L10nKey.settingsAgentWebSearch),
                                  role: InkTextRole.titleMedium,
                                ),
                              ),
                            ],
                          ),
                          BistreSegmentedControl<String>(
                            selected: mode,
                            onSelected: (next) {
                              if (next == 'off') {
                                _webSearchCtrl.clear();
                                unawaited(ctrl.setWebSearchEndpoint(''));
                              } else if (next == 'duckduckgo') {
                                _webSearchCtrl.text = 'duckduckgo';
                                unawaited(
                                  ctrl.setWebSearchEndpoint('duckduckgo'),
                                );
                              } else {
                                if (_webSearchCtrl.text.trim() ==
                                        'duckduckgo' ||
                                    _webSearchCtrl.text.trim().isEmpty) {
                                  _webSearchCtrl.text = 'https://';
                                }
                                unawaited(
                                  ctrl.setWebSearchEndpoint(
                                    _webSearchCtrl.text.trim(),
                                  ),
                                );
                              }
                            },
                            options: <BistreSegmentedOption<String>>[
                              BistreSegmentedOption<String>(
                                value: 'off',
                                label: l10n.t(L10nKey.settingsAppearanceOff),
                              ),
                              BistreSegmentedOption<String>(
                                value: 'duckduckgo',
                                label: l10n.t(L10nKey.settingsAgentWebDdg),
                              ),
                              BistreSegmentedOption<String>(
                                value: 'custom',
                                label: l10n.t(L10nKey.settingsAgentWebCustom),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (mode == 'custom') ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: QuillInput(
                                controller: _webSearchCtrl,
                                focusNode: _webSearchFocus,
                                placeholder: l10n.t(
                                  L10nKey.providerFieldBaseUrl,
                                ),
                                maxLines: 1,
                                onSubmitted: () => unawaited(
                                  ctrl.setWebSearchEndpoint(
                                    _webSearchCtrl.text,
                                  ),
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
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            // 4. Background & Sleep Survival + Unattended Approval Policy
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsSleepSectionTitle),
              subtitle: l10n.t(L10nKey.settingsSleepSectionSubtitle),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsSleepKeepAwake),
                  trailing: BistreSwitch(
                    value: ctrl.settings.keepAwakeWhileRunning,
                    semanticsLabel: l10n.t(L10nKey.settingsSleepKeepAwake),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) => unawaited(
                      ctrl.updateSettings(
                        ctrl.settings.copyWith(keepAwakeWhileRunning: v),
                      ),
                    ),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsSleepDaemonActive),
                  description: l10n.t(L10nKey.settingsSleepDaemonActiveDesc),
                  trailing: BistreSwitch(
                    value: ctrl.settings.daemonKeepAliveWhenActive,
                    semanticsLabel: l10n.t(L10nKey.settingsSleepDaemonActive),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) => unawaited(
                      ctrl.updateSettings(
                        ctrl.settings.copyWith(daemonKeepAliveWhenActive: v),
                      ),
                    ),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsSleepWindowsBattery),
                  description: l10n.t(L10nKey.settingsSleepWindowsBatteryDesc),
                  trailing: BistreSwitch(
                    value: ctrl.settings.windowsKeepAwakeOnBattery,
                    semanticsLabel: l10n.t(L10nKey.settingsSleepWindowsBattery),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) => unawaited(
                      ctrl.updateSettings(
                        ctrl.settings.copyWith(windowsKeepAwakeOnBattery: v),
                      ),
                    ),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsSleepUnattendedPolicy),
                  trailing: BistreSegmentedControl<String>(
                    selected: ctrl.settings.unattendedPolicy,
                    onSelected: (v) => unawaited(
                      ctrl.updateSettings(
                        ctrl.settings.copyWith(unattendedPolicy: v),
                      ),
                    ),
                    options: <BistreSegmentedOption<String>>[
                      BistreSegmentedOption<String>(
                        value: 'pause_and_notify',
                        label: l10n.t(L10nKey.settingsSleepPolicyPause),
                      ),
                      BistreSegmentedOption<String>(
                        value: 'deny_tier2_and_continue',
                        label: l10n.t(L10nKey.settingsSleepPolicyDeny),
                      ),
                      BistreSegmentedOption<String>(
                        value: 'sandbox_worktree_auto',
                        label: l10n.t(L10nKey.settingsSleepPolicySandbox),
                      ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAgentComputerUse),
                  description: l10n.t(L10nKey.settingsAgentComputerUseHint),
                  trailing: BistreSwitch(
                    value: ctrl.uiPrefs.computerUseEnabled,
                    semanticsLabel: l10n.t(L10nKey.settingsAgentComputerUse),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) => unawaited(
                      ctrl.saveUiPrefs(
                        ctrl.uiPrefs.copyWith(computerUseEnabled: v),
                        quiet: true,
                      ),
                    ),
                  ),
                ),
                if (BistrePowerGuardHost.isAndroid)
                  BistreSettingRow(
                    label: l10n.t(L10nKey.settingsSleepAndroidBattery),
                    trailing: ctrl.powerStatus.androidBatteryUnrestricted
                        ? WaxSealBadge(
                            label: l10n.t(
                              L10nKey.settingsSleepAndroidBatteryOk,
                            ),
                          )
                        : EngravedButton(
                            label: l10n.t(
                              L10nKey.settingsSleepAndroidBatteryAllow,
                            ),
                            compact: true,
                            onPressed: () => unawaited(
                              ctrl.requestAndroidBatteryUnrestricted(),
                            ),
                          ),
                  ),
              ],
            ),
            // 5. Optional Android Termux Bridge (hidden on Windows/Linux desktops)
            if (BistrePowerGuardHost.isAndroid) ...[
              const SizedBox(height: 16),
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
          ],
        ),
      ),
    );
  }
}
