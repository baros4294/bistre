import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Clean vertical Language selector supporting live runtime ICU switching (EN / VI / AR RTL).
class LanguageSettingsView extends StatelessWidget {
  const LanguageSettingsView({super.key, required this.controller});

  final FolioController controller;

  /// Each language named in itself; the selected one carries a check.
  static const List<(String, String)> _locales = <(String, String)>[
    ('en', 'English'),
    ('vi', 'Tiếng Việt'),
    ('ar', 'العربية'),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    final currentLocale = controller.settings.locale;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 40),
        child: BistreSettingsSection(
          title: l10n.t(L10nKey.settingsLanguageHeading),
          children: [
            for (final (code, name) in _locales)
              _LanguageChoiceRow(
                name: name,
                selected: currentLocale == code,
                onTap: () => controller.syncLocale(code),
              ),
          ],
        ),
      ),
    );
  }
}

class _LanguageChoiceRow extends StatefulWidget {
  const _LanguageChoiceRow({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_LanguageChoiceRow> createState() => _LanguageChoiceRowState();
}

class _LanguageChoiceRowState extends State<_LanguageChoiceRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.name,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: PressFeedback(
          pressScale: kRowPressScale,
          hoverScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _hovered ? theme.hoverTint : theme.bgElevated,
                border: _focused
                    ? Border.all(color: theme.accentBrass, width: 1.6)
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: BistreSpacing.s16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: ExcludeSemantics(
                        child: InkText(
                          widget.name,
                          role: InkTextRole.bodyCompact,
                          color: theme.inkPrimary,
                        ),
                      ),
                    ),
                    // Space is kept for the check, so the names never shift.
                    SizedBox.square(
                      dimension: 16,
                      child: widget.selected
                          ? BistreIcon(
                              BistreUiIcon.check,
                              size: 14,
                              color: theme.accentBrass,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
