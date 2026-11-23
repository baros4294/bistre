import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Clean vertical Language selector supporting live runtime ICU switching (EN / VI / AR RTL).
class LanguageSettingsView extends StatelessWidget {
  const LanguageSettingsView({super.key, required this.controller});

  final FolioController controller;

  static const List<(String, String, String)> _locales =
      <(String, String, String)>[
        ('en', 'English', 'LTR'),
        ('vi', 'Tiếng Việt', 'LTR'),
        ('ar', 'العربية', 'RTL'),
      ];

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    final currentLocale = controller.settings.locale;

    return SingleChildScrollView(
      padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 40),
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: BistreSettingsSection(
            title: l10n.t(L10nKey.settingsLanguageHeading),
            subtitle: l10n.t(L10nKey.settingsLanguageNote),
            children: [
              for (final loc in _locales)
                _LanguageChoiceRow(
                  name: loc.$2,
                  codeBadge: l10n.joinMeta(<String>[
                    loc.$1.toUpperCase(),
                    loc.$3,
                  ]),
                  selected: currentLocale == loc.$1,
                  onTap: () => controller.syncLocale(loc.$1),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageChoiceRow extends StatefulWidget {
  const _LanguageChoiceRow({
    required this.name,
    required this.codeBadge,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String codeBadge;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_LanguageChoiceRow> createState() => _LanguageChoiceRowState();
}

class _LanguageChoiceRowState extends State<_LanguageChoiceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: ColoredBox(
          color: widget.selected || _hovered
              ? theme.hoverTint
              : theme.bgElevated,
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: BistreSpacing.s16,
              vertical: 14,
            ),
            child: Row(
              children: [
                BistreIcon(
                  BistreUiIcon.globe,
                  size: 16,
                  color: widget.selected
                      ? theme.accentBrass
                      : theme.inkSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkText(
                    widget.name,
                    role: widget.selected
                        ? InkTextRole.labelStrong
                        : InkTextRole.bodyCompact,
                    color: theme.inkPrimary,
                  ),
                ),
                WaxSealBadge(
                  label: widget.codeBadge,
                  status: widget.selected
                      ? WaxSealStatus.ok
                      : WaxSealStatus.neutral,
                ),
                if (widget.selected) ...[
                  const SizedBox(width: 10),
                  BistreIcon(
                    BistreUiIcon.check,
                    size: 14,
                    color: theme.accentBrass,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
