import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../shell/folio_controller.dart';

/// Settings > Memory & Skills > Bistre's skills: the skills offered in every chat with tools
/// on, installed from a GitHub link, a folder, or a zip or `SKILL.md` file (a reinstall
/// replaces the skill of the same name), or saved from a reply; each can be removed.
class AppSkillsSection extends StatefulWidget {
  const AppSkillsSection({super.key, required this.controller});

  final FolioController controller;

  @override
  State<AppSkillsSection> createState() => _AppSkillsSectionState();
}

class _AppSkillsSectionState extends State<AppSkillsSection> {
  final TextEditingController _linkCtrl = TextEditingController();
  final FocusNode _linkFocus = FocusNode();

  @override
  void dispose() {
    _linkCtrl.dispose();
    _linkFocus.dispose();
    super.dispose();
  }

  Future<void> _installLink() async {
    final ok = await widget.controller.installSkill(_linkCtrl.text);
    if (ok && mounted) _linkCtrl.clear();
  }

  Future<void> _installFolder(String title) async {
    final picked = await BistreDesktopHost.pickLocalFolder(title: title);
    if (picked != null && picked.isNotEmpty) {
      await widget.controller.installSkill(picked);
    }
  }

  Future<void> _installFile(String title) async {
    final picked = await BistreDesktopHost.pickLocalFile(
      title: title,
      filterLabel: 'Skill (*.zip, SKILL.md)',
      filterSpec: '*.zip;SKILL.md',
    );
    if (picked != null && picked.isNotEmpty) {
      await widget.controller.installSkill(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final busy = ctrl.installingSkill;
    return FolioSurface(
      tone: FolioTone.elevated,
      padding: const EdgeInsetsDirectional.all(18),
      boxShadow: theme.cardShadow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  l10n.t(L10nKey.skillsAppTitle),
                  role: InkTextRole.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          InkText(
            l10n.t(L10nKey.skillsAppHint),
            role: InkTextRole.captionMeta,
            color: theme.inkMuted,
          ),
          const SizedBox(height: 10),
          QuillInput(
            controller: _linkCtrl,
            focusNode: _linkFocus,
            placeholder: l10n.t(L10nKey.skillsLinkPlaceholder),
            onSubmitted: () => unawaited(_installLink()),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: BistreSpacing.s8,
            runSpacing: BistreSpacing.s8,
            children: [
              EngravedButton(
                label: l10n.t(L10nKey.skillsInstallLink),
                compact: true,
                primary: true,
                onPressed: busy ? null : () => unawaited(_installLink()),
              ),
              EngravedButton(
                label: l10n.t(L10nKey.skillsInstallFolder),
                compact: true,
                leading: BistreIcon(
                  BistreUiIcon.folder,
                  size: 12,
                  color: theme.inkSecondary,
                ),
                onPressed: busy
                    ? null
                    : () => unawaited(
                        _installFolder(l10n.t(L10nKey.skillsInstallFolder)),
                      ),
              ),
              EngravedButton(
                label: l10n.t(L10nKey.skillsInstallFile),
                compact: true,
                leading: BistreIcon(
                  BistreUiIcon.paperclip,
                  size: 12,
                  color: theme.inkSecondary,
                ),
                onPressed: busy
                    ? null
                    : () => unawaited(
                        _installFile(l10n.t(L10nKey.skillsInstallFile)),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (ctrl.appSkills.isEmpty)
            InkText(
              l10n.t(L10nKey.skillsAppEmpty),
              role: InkTextRole.bodyCompact,
              color: theme.inkMuted,
            ),
          for (final sk in ctrl.appSkills) ...[
            FolioSurface(
              padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkText(sk.name, role: InkTextRole.labelStrong),
                        if (sk.description.isNotEmpty)
                          InkText(
                            sk.description,
                            role: InkTextRole.captionMeta,
                            color: theme.inkSecondary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  BistreIconButton(
                    icon: BistreUiIcon.trash,
                    size: 13,
                    semanticsLabel: l10n.t(
                      L10nKey.skillsRemove,
                      <String, Object?>{'name': sk.name},
                    ),
                    onPressed: () => unawaited(ctrl.removeAppSkill(sk)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}
