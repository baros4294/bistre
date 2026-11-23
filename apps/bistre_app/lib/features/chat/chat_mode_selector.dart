import 'package:flutter/widgets.dart';

import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Chat / Plan / Build / Write for the next message. Lives in the composer because it scopes
/// what the next message does (`docs/design/DESIGN.md` §10). Each option is keyboard-focusable.
class ChatModeSelector extends StatelessWidget {
  const ChatModeSelector({
    super.key,
    required this.activeMode,
    required this.onSelect,
  });

  final String activeMode;
  final ValueChanged<String> onSelect;

  static const List<(String, L10nKey)> modes = <(String, L10nKey)>[
    ('chat', L10nKey.modeChat),
    ('plan', L10nKey.modePlan),
    ('code', L10nKey.modeBuild),
    ('write', L10nKey.modeWrite),
  ];

  /// Below this width (scaled with text size) the four options do not fit; one chip that
  /// steps to the next mode is shown instead.
  static const double _fullWidth = 340;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        if (constraints.maxWidth < _fullWidth * scale) {
          final index = modes.indexWhere((m) => m.$1 == activeMode);
          final current = modes[index < 0 ? 0 : index];
          final next = modes[(modes.indexOf(current) + 1) % modes.length];
          return _ModeOption(
            label: l10n.t(current.$2),
            selected: true,
            onTap: () => onSelect(next.$1),
          );
        }
        return _segmented(theme, l10n);
      },
    );
  }

  Widget _segmented(BistreThemeData theme, BistreLocalizationController l10n) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.bgSurface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.borderHairline),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in modes)
              _ModeOption(
                label: l10n.t(m.$2),
                selected: activeMode == m.$1,
                onTap: () => onSelect(m.$1),
              ),
          ],
        ),
      ),
    );
  }
}

class _ModeOption extends StatefulWidget {
  const _ModeOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ModeOption> createState() => _ModeOptionState();
}

class _ModeOptionState extends State<_ModeOption> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.selected ? theme.bgElevated : null,
              borderRadius: BorderRadius.circular(999),
              border: _focused
                  ? Border.all(color: theme.accentBrass, width: 2)
                  : null,
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 10,
                vertical: 5,
              ),
              child: InkText(
                widget.label,
                role: InkTextRole.captionMeta,
                color: widget.selected ? theme.inkPrimary : theme.inkMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
