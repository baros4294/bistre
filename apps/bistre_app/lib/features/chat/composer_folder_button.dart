import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../shell/folio_controller.dart';

/// Picks a folder for the open chat: [add] adds one more, otherwise it replaces the folder.
/// A chat in a project with its own folder works only there, so this opens that project's
/// settings, where the folder is changed, instead of picking an app folder it never uses.
Future<void> chooseChatFolder(
  FolioController ctrl,
  String title, {
  required bool add,
}) async {
  if (ctrl.folderProject case final project?) {
    ctrl.openProjectEditor(project.id);
    return;
  }
  final picked = await BistreDesktopHost.pickLocalFolder(title: title);
  if (picked == null || picked.isEmpty) return;
  if (add) {
    await ctrl.addWorkspaceFolder(picked);
  } else {
    await ctrl.setWorkspaceRootPath(picked);
  }
}

/// The composer's folder button: lit while the chat can read a folder; a pick adds one
/// more. In a project chat with its own folder it is named for that project's settings.
class ComposerFolderButton extends StatelessWidget {
  const ComposerFolderButton({super.key, required this.controller});

  final FolioController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    final project = controller.folderProject;
    return BistreIconButton(
      icon: BistreUiIcon.folder,
      size: 15,
      dimension: 30,
      active: controller.workspaceRootPath.isNotEmpty,
      semanticsLabel: project == null
          ? l10n.t(L10nKey.settingsAgentAddFolder)
          : l10n.t(L10nKey.sidebarProjectSettings, <String, Object?>{
              'name': project.name,
            }),
      onPressed: () => unawaited(
        chooseChatFolder(
          controller,
          l10n.t(L10nKey.settingsAgentWorkspaceDir),
          add: true,
        ),
      ),
    );
  }
}
