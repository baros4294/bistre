part of 'appearance_settings_view.dart';

class _AccentSwatchPill extends StatefulWidget {
  const _AccentSwatchPill({
    required this.label,
    required this.swatch,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color swatch;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_AccentSwatchPill> createState() => _AccentSwatchPillState();
}

class _AccentSwatchPillState extends State<_AccentSwatchPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: PressFeedback(
        pressScale: kRowPressScale,
        hoverScale: 1,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.selected
                  ? theme.bgSurface
                  : (_hovered ? theme.hoverTint : theme.bgCanvas),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: widget.selected ? widget.swatch : theme.borderHairline,
                width: widget.selected ? 1.5 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: widget.swatch,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: InkText(
                      widget.label,
                      role: InkTextRole.captionMeta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      color: widget.selected
                          ? theme.inkPrimary
                          : theme.inkSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FontListRow extends StatefulWidget {
  const _FontListRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_FontListRow> createState() => _FontListRowState();
}

class _FontListRowState extends State<_FontListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: PressFeedback(
        pressScale: kRowPressScale,
        hoverScale: 1,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.selected || _hovered ? theme.hoverTint : null,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 10,
                vertical: 7,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkText(
                      widget.label,
                      role: InkTextRole.bodyCompact,
                      color: widget.selected
                          ? theme.inkPrimary
                          : theme.inkSecondary,
                    ),
                  ),
                  if (widget.selected)
                    BistreIcon(
                      BistreUiIcon.check,
                      size: 13,
                      color: theme.accentBrass,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Visual gallery of the color theme presets.
class _ThemePresetChoices extends StatelessWidget {
  const _ThemePresetChoices({
    required this.activePresetId,
    required this.l10n,
    required this.onSelectPreset,
  });

  final String activePresetId;
  final BistreLocalizationController l10n;
  final ValueChanged<String> onSelectPreset;

  static String _presetLabel(BistreLocalizationController l10n, String id) =>
      switch (id) {
        'day' => l10n.t(L10nKey.settingsAppearancePresetWarmSepia),
        'blue_cream' => l10n.t(L10nKey.settingsAppearancePresetBlueCream),
        'night_blue' => l10n.t(L10nKey.settingsAppearancePresetNightBlue),
        'warm_ivory' => l10n.t(L10nKey.settingsAppearancePresetWarmIvory),
        'deep_sepia' => l10n.t(L10nKey.settingsAppearancePresetDeepSepia),
        'night' => l10n.t(L10nKey.settingsAppearancePresetWarmDark),
        'pure_black' => l10n.t(L10nKey.settingsAppearancePresetPureBlack),
        'clean_paper' => l10n.t(L10nKey.settingsAppearancePresetCleanPaper),
        'dark_slate' => l10n.t(L10nKey.settingsAppearancePresetDarkSlate),
        _ => l10n.t(L10nKey.settingsAppearancePresetWarmSepia),
      };

  @override
  Widget build(BuildContext context) {
    final scale = textScaleOf(context);
    final sampleAa = l10n.t(L10nKey.settingsAppearanceThemeSampleAa);
    return LayoutBuilder(
      builder: (context, constraints) {
        final desired = (132.0 * scale).clamp(132.0, 210.0);
        final cardWidth =
            constraints.hasBoundedWidth && constraints.maxWidth < desired
            ? constraints.maxWidth
            : desired;
        return Wrap(
          spacing: BistreSpacing.s8,
          runSpacing: BistreSpacing.s8,
          children: [
            for (final preset in BistreThemePreset.presets)
              _ThemePreviewCard(
                preset: preset,
                label: _presetLabel(l10n, preset.id),
                sampleAa: sampleAa,
                width: cardWidth,
                selected: activePresetId == preset.id,
                onTap: () => onSelectPreset(preset.id),
              ),
          ],
        );
      },
    );
  }
}

/// Miniature preview of the app in [preset]: sidebar strip, page, sample letters, and accent rule.
class _ThemePreviewCard extends StatefulWidget {
  const _ThemePreviewCard({
    required this.preset,
    required this.label,
    required this.sampleAa,
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final BistreThemePreset preset;
  final String label;
  final String sampleAa;
  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ThemePreviewCard> createState() => _ThemePreviewCardState();
}

class _ThemePreviewCardState extends State<_ThemePreviewCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final preview = widget.preset.theme;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (f) {
          if (_focused != f) setState(() => _focused = f);
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: PressFeedback(
          pressScale: 0.97,
          hoverScale: 1.01,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: SizedBox(
              width: widget.width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.bgElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: widget.selected || _focused
                        ? theme.accentWax
                        : theme.borderHairline,
                    width: widget.selected || _focused ? 1.5 : 1,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: ColoredBox(
                          color: preview.bgCanvas,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 56),
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    width: 24,
                                    child: ColoredBox(color: preview.bgSurface),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsetsDirectional.all(
                                        8,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          InkText(
                                            widget.sampleAa,
                                            role: InkTextRole.labelStrong,
                                            color: preview.inkPrimary,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 5),
                                          SizedBox(
                                            width: 40,
                                            height: 4,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                color: preview.accentWax,
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsetsDirectional.symmetric(
                          horizontal: 2,
                        ),
                        child: InkText(
                          widget.label,
                          role: InkTextRole.captionMeta,
                          color: widget.selected
                              ? theme.accentWax
                              : theme.inkPrimary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
