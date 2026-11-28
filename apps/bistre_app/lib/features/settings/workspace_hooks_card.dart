import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// A folder's hooks file for review: each hook's event, tool filter, and command, then
/// Allow. Hooks run only once the user allowed exactly this file (core checks its digest).
/// Settings > Agent shows the app folder's hooks; Settings > Projects a project folder's.
class WorkspaceHooksCard extends StatelessWidget {
  const WorkspaceHooksCard({
    super.key,
    required this.hooks,
    required this.onAllow,
  });

  final EngineWorkspaceHooksStatus hooks;
  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return BistreSettingsSection(
      title: l10n.t(L10nKey.settingsAgentHooksTitle),
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 4),
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
                  onPressed: onAllow,
                ),
        ),
      ],
    );
  }
}
