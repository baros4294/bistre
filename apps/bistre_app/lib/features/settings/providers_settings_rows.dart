part of 'providers_settings_view.dart';

class _ProviderListRow extends StatefulWidget {
  const _ProviderListRow({
    required this.provider,
    required this.selected,
    required this.isActiveGlobal,
    required this.onTap,
  });

  final EngineProvider provider;
  final bool selected;
  final bool isActiveGlobal;
  final VoidCallback onTap;

  @override
  State<_ProviderListRow> createState() => _ProviderListRowState();
}

class _ProviderListRowState extends State<_ProviderListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final p = widget.provider;

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
                  ? theme.bgElevated
                  : (_hovered ? theme.hoverTint : null),
              borderRadius: BorderRadius.circular(10),
              border: widget.selected
                  ? Border.all(color: theme.borderHairline)
                  : null,
              boxShadow: widget.selected ? theme.cardShadow : null,
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              child: Row(
                children: [
                  LabIcon(
                    iconSlug: p.iconSlug,
                    customIconPath: p.customIconPath,
                    dialect: p.dialect,
                    providerName: p.name,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkText(
                          p.name,
                          role: widget.selected
                              ? InkTextRole.labelStrong
                              : InkTextRole.bodyCompact,
                          color: p.isEnabled
                              ? theme.inkPrimary
                              : theme.inkMuted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (p.defaultModel.isNotEmpty)
                          InkText(
                            p.defaultModel,
                            role: InkTextRole.captionMeta,
                            color: theme.inkMuted,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox.square(
                    dimension: 7,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: widget.isActiveGlobal
                            ? theme.accentWax
                            : (p.isReady
                                  ? theme.statusOk
                                  : theme.borderHairline),
                        shape: BoxShape.circle,
                      ),
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

class _TemplateChip extends StatefulWidget {
  const _TemplateChip({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  final ProviderPreset template;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_TemplateChip> createState() => _TemplateChipState();
}

class _TemplateChipState extends State<_TemplateChip> {
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
                  ? theme.bgElevated
                  : (_hovered ? theme.hoverTint : theme.bgSurface),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: widget.selected
                    ? theme.accentBrass
                    : theme.borderHairline,
              ),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 10,
                vertical: 7,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LabIcon(iconSlug: widget.template.iconSlug, size: 16),
                  const SizedBox(width: 7),
                  InkText(
                    widget.template.name,
                    role: InkTextRole.captionMeta,
                    color: widget.selected
                        ? theme.inkPrimary
                        : theme.inkSecondary,
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

class _LabIconChoiceTile extends StatefulWidget {
  const _LabIconChoiceTile({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final LabIconEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_LabIconChoiceTile> createState() => _LabIconChoiceTileState();
}

class _LabIconChoiceTileState extends State<_LabIconChoiceTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.entry.displayName,
      child: MouseRegion(
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
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: widget.selected
                      ? theme.accentBrass
                      : theme.borderHairline,
                  width: widget.selected ? 1.5 : 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LabIcon(iconSlug: widget.entry.slug, size: 16),
                    const SizedBox(width: 6),
                    InkText(
                      widget.entry.displayName,
                      role: InkTextRole.captionMeta,
                      color: widget.selected
                          ? theme.inkPrimary
                          : theme.inkSecondary,
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

class _SelectableModelRow extends StatefulWidget {
  const _SelectableModelRow({
    required this.model,
    required this.selected,
    required this.onTap,
    required this.onConfigure,
    required this.onHide,
  });

  final EngineProviderModel model;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onConfigure;
  final VoidCallback onHide;

  @override
  State<_SelectableModelRow> createState() => _SelectableModelRowState();
}

class _SelectableModelRowState extends State<_SelectableModelRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
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
                vertical: 6,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkText(
                      widget.model.id,
                      role: InkTextRole.captionMeta,
                      color: widget.selected
                          ? theme.inkPrimary
                          : theme.inkSecondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.selected) ...[
                    BistreIcon(
                      BistreUiIcon.check,
                      size: 13,
                      color: theme.accentBrass,
                    ),
                    const SizedBox(width: 4),
                  ],
                  BistreIconButton(
                    icon: BistreUiIcon.settings,
                    size: 12,
                    dimension: 24,
                    semanticsLabel: l10n.t(L10nKey.settingsTitle),
                    onPressed: widget.onConfigure,
                  ),
                  BistreIconButton(
                    icon: BistreUiIcon.trash,
                    size: 12,
                    dimension: 24,
                    semanticsLabel: l10n.t(L10nKey.threadDelete),
                    onPressed: widget.onHide,
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

/// The empty state and the add-a-provider panel of the Providers page.
extension _ProviderCreateFlow on _ProvidersSettingsViewState {
  Widget _buildEmptyState(
    BistreThemeData theme,
    BistreLocalizationController l10n,
  ) {
    return FolioSurface(
      tone: FolioTone.elevated,
      padding: const EdgeInsetsDirectional.all(BistreSpacing.s24),
      borderRadius: 14,
      boxShadow: theme.cardShadow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkText(
            l10n.t(L10nKey.providerEmptyTitle),
            role: InkTextRole.titleMedium,
          ),
          const SizedBox(height: 6),
          InkText(
            l10n.t(L10nKey.providerEmptyBody),
            role: InkTextRole.bodyCompact,
            color: theme.inkSecondary,
          ),
          const SizedBox(height: BistreSpacing.s16),
          EngravedButton(
            label: l10n.t(L10nKey.providerAddButton),
            primary: true,
            leading: BistreIcon(
              BistreUiIcon.plus,
              size: 14,
              color: theme.onAccentWax,
            ),
            onPressed: () => _openCreateFlow(kProviderPresets.first),
          ),
        ],
      ),
    );
  }

  Widget _buildCreatePanel(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkText(l10n.t(L10nKey.providerAddTitle), role: InkTextRole.titleLarge),
        const SizedBox(height: 4),
        InkText(
          l10n.t(L10nKey.providerAddSubtitle),
          role: InkTextRole.bodyCompact,
          color: theme.inkSecondary,
        ),
        const SizedBox(height: BistreSpacing.s16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tpl in kProviderPresets)
              _TemplateChip(
                template: tpl,
                selected:
                    _newIconSlug == tpl.iconSlug && _newDialect == tpl.dialect,
                onTap: () => _openCreateFlow(tpl),
              ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s16),
        BistreSettingsSection(
          children: [
            BistreSettingRow(
              label: l10n.t(L10nKey.providerFieldName),
              bottom: QuillInput(
                controller: _newNameCtrl,
                focusNode: _newNameFocus,
                placeholder: l10n.t(L10nKey.providerFieldNamePlaceholder),
                maxLines: 1,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerDialectLabel),
              bottom: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in <(String, L10nKey)>[
                    ('openai', L10nKey.providerDialectOpenai),
                    ('google_gemini', L10nKey.providerDialectGemini),
                    ('anthropic', L10nKey.providerDialectAnthropic),
                    ('custom_openai', L10nKey.providerDialectCustom),
                  ])
                    InkChip(
                      label: l10n.t(entry.$2),
                      selected: _newDialect == entry.$1,
                      onSelected: () => _rebuild(() => _newDialect = entry.$1),
                    ),
                ],
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerFieldBaseUrl),
              bottom: QuillInput(
                controller: _newUrlCtrl,
                focusNode: _newUrlFocus,
                placeholder: _defaultBaseUrl(_newDialect),
                maxLines: 1,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerFieldModel),
              bottom: QuillInput(
                controller: _newModelCtrl,
                focusNode: _newModelFocus,
                placeholder: l10n.t(L10nKey.providerFieldModelPlaceholder),
                maxLines: 1,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerFieldApiKey),
              description: l10n.t(L10nKey.providerVaultNote),
              bottom: QuillInput(
                controller: _newKeyCtrl,
                focusNode: _newKeyFocus,
                placeholder: l10n.t(L10nKey.providerFieldApiKeyPlaceholder),
                maxLines: 1,
                obscureText: true,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              child: Row(
                children: [
                  EngravedButton(
                    label: l10n.t(L10nKey.providerAddButton),
                    primary: true,
                    onPressed: () async {
                      final created = await ctrl.createProvider(
                        name: _newNameCtrl.text,
                        dialect: _newDialect,
                        baseUrl: _newUrlCtrl.text,
                        defaultModel: _newModelCtrl.text,
                        iconSlug: _newIconSlug,
                        apiKey: _newKeyCtrl.text,
                      );
                      if (created != null && mounted) {
                        _rebuild(() => _loadProviderIntoForm(created));
                      }
                    },
                  ),
                  const SizedBox(width: 10),
                  if (ctrl.providers.isNotEmpty)
                    EngravedButton(
                      label: l10n.t(L10nKey.threadCancel),
                      onPressed: () => _rebuild(() => _creating = false),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s16),
        ProviderShareImportCard(
          controller: ctrl,
          onImported: (created) =>
              _rebuild(() => _loadProviderIntoForm(created)),
        ),
      ],
    );
  }
}
