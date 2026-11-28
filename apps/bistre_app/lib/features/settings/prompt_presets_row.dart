import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Saved system prompts under an instructions field: Save as preset keeps the field's text
/// (named by its first line), a preset's name puts its text in the field, and its remove
/// button deletes it.
class PromptPresetsRow extends StatelessWidget {
  const PromptPresetsRow({
    super.key,
    required this.controller,
    required this.prompt,
  });

  final FolioController controller;

  /// The instructions field the presets fill and save from.
  final TextEditingController prompt;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final presets = controller.promptPresets;
    return Wrap(
      spacing: BistreSpacing.s8,
      runSpacing: BistreSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ListenableBuilder(
          listenable: prompt,
          builder: (context, _) => EngravedButton(
            label: l10n.t(L10nKey.settingsPresetsSave),
            compact: true,
            leading: BistreIcon(
              BistreUiIcon.plus,
              size: 12,
              color: theme.inkSecondary,
            ),
            onPressed: prompt.text.trim().isEmpty
                ? null
                : () => unawaited(controller.savePromptPreset(prompt.text)),
          ),
        ),
        for (final p in presets)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              EngravedButton(
                label: p.name,
                compact: true,
                semanticsLabel: l10n.t(
                  L10nKey.settingsPresetsUse,
                  <String, Object?>{'name': p.name},
                ),
                onPressed: () => prompt.value = TextEditingValue(
                  text: p.text,
                  selection: TextSelection.collapsed(offset: p.text.length),
                ),
              ),
              BistreIconButton(
                icon: BistreUiIcon.close,
                size: 11,
                semanticsLabel: l10n.t(
                  L10nKey.settingsPresetsRemove,
                  <String, Object?>{'name': p.name},
                ),
                onPressed: () => unawaited(controller.deletePromptPreset(p)),
              ),
            ],
          ),
      ],
    );
  }
}
