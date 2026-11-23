import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../shell/folio_controller.dart';
import 'provider_presets.dart';

/// Full-window Providers & Keys Studio:
/// - Every provider (including starter OpenAI/Gemini/Anthropic) is freely editable & deletable.
/// - Authentic full-color offline LabIcon catalog + custom local PNG/WebP icon upload.
/// - Unified "+ Add provider" templates + custom OpenAI-compatible endpoints.
class ProvidersSettingsView extends StatefulWidget {
  const ProvidersSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<ProvidersSettingsView> createState() => _ProvidersSettingsViewState();
}

class _ProvidersSettingsViewState extends State<ProvidersSettingsView> {
  String? _selectedId;
  bool _creating = false;
  bool _showKey = false;
  bool _iconPickerOpen = false;
  bool _confirmDelete = false;

  // Edit form controllers.
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _baseUrlCtrl = TextEditingController();
  final TextEditingController _modelCtrl = TextEditingController();
  final TextEditingController _modelFilterCtrl = TextEditingController();
  final TextEditingController _headersCtrl = TextEditingController();
  final TextEditingController _bodyCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  final FocusNode _apiKeyFocus = FocusNode();
  final FocusNode _baseUrlFocus = FocusNode();
  final FocusNode _modelFocus = FocusNode();
  final FocusNode _modelFilterFocus = FocusNode();
  final FocusNode _headersFocus = FocusNode();
  final FocusNode _bodyFocus = FocusNode();
  String _modelFilter = '';
  bool _scannedLocal = false;

  // Add-provider form controllers.
  final TextEditingController _newNameCtrl = TextEditingController();
  final TextEditingController _newUrlCtrl = TextEditingController();
  final TextEditingController _newModelCtrl = TextEditingController();
  final TextEditingController _newKeyCtrl = TextEditingController();
  final FocusNode _newNameFocus = FocusNode();
  final FocusNode _newUrlFocus = FocusNode();
  final FocusNode _newModelFocus = FocusNode();
  final FocusNode _newKeyFocus = FocusNode();
  String _newDialect = 'custom_openai';
  String _newIconSlug = 'openai';

  @override
  void initState() {
    super.initState();
    _syncSelection();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    _modelFilterCtrl.dispose();
    _headersCtrl.dispose();
    _bodyCtrl.dispose();
    _nameFocus.dispose();
    _apiKeyFocus.dispose();
    _baseUrlFocus.dispose();
    _modelFocus.dispose();
    _modelFilterFocus.dispose();
    _headersFocus.dispose();
    _bodyFocus.dispose();
    _newNameCtrl.dispose();
    _newUrlCtrl.dispose();
    _newModelCtrl.dispose();
    _newKeyCtrl.dispose();
    _newNameFocus.dispose();
    _newUrlFocus.dispose();
    _newModelFocus.dispose();
    _newKeyFocus.dispose();
    super.dispose();
  }

  void _syncSelection() {
    final providers = widget.controller.providers;
    if (providers.isEmpty) {
      _selectedId = null;
      return;
    }
    if (_selectedId != null && providers.any((p) => p.id == _selectedId)) {
      return;
    }
    final active = widget.controller.activeProvider ?? providers.first;
    _loadProviderIntoForm(active);
  }

  void _loadProviderIntoForm(EngineProvider p) {
    _selectedId = p.id;
    _creating = false;
    _confirmDelete = false;
    _iconPickerOpen = false;
    _showKey = false;
    _nameCtrl.text = p.name;
    _baseUrlCtrl.text = p.baseUrl;
    _modelCtrl.text = p.defaultModel;
    _apiKeyCtrl.clear();
    _modelFilterCtrl.clear();
    _modelFilter = '';
    _headersCtrl.clear();
    _bodyCtrl.clear();
    unawaited(
      widget.controller.loadProviderOverrides(p.id).then((pair) {
        if (!mounted || _selectedId != p.id) return;
        _headersCtrl.text = pair.$1;
        _bodyCtrl.text = pair.$2;
      }),
    );
  }

  void _openCreateFlow([ProviderPreset? tpl]) {
    setState(() {
      _creating = true;
      _confirmDelete = false;
      _newNameCtrl.text = tpl?.name ?? '';
      _newDialect = tpl?.dialect ?? 'custom_openai';
      _newUrlCtrl.text = tpl?.baseUrl ?? 'http://127.0.0.1:11434/v1';
      _newModelCtrl.text = tpl?.defaultModel ?? '';
      _newIconSlug = tpl?.iconSlug ?? 'server';
      _newKeyCtrl.clear();
    });
  }

  Future<void> _pickCustomProviderIcon(EngineProvider p) async {
    final l10n = BistreLocalizations.of(context);
    final chosen = await BistreDesktopHost.pickLocalFile(
      title: l10n.t(L10nKey.providerIconCustomUpload),
      filterLabel: 'Images',
      filterSpec: '*.png;*.webp;*.jpg;*.jpeg',
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.controller.saveProviderConfig(
      providerId: p.id,
      customIconPath: chosen,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    _syncSelection();

    final selected = ctrl.providers
        .where((p) => p.id == _selectedId)
        .firstOrNull;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 680;
        final listPane = _buildProviderList(theme, l10n, ctrl);
        final detailPane = _creating
            ? _buildCreatePanel(theme, l10n, ctrl)
            : (selected != null
                  ? _buildDetailPanel(theme, l10n, ctrl, selected)
                  : _buildEmptyState(theme, l10n));

        if (!wide) {
          return SingleChildScrollView(
            padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                listPane,
                const SizedBox(height: BistreSpacing.s16),
                const FolioDivider(),
                const SizedBox(height: BistreSpacing.s16),
                detailPane,
              ],
            ),
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 264,
              child: SingleChildScrollView(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 18, 12, 24),
                child: listPane,
              ),
            ),
            const FolioDivider(vertical: true),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 36),
                child: detailPane,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProviderList(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final activeId = ctrl.activeProvider?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EngravedButton(
          label: l10n.t(L10nKey.providerAddButton),
          primary: _creating || ctrl.providers.isEmpty,
          leading: BistreIcon(
            BistreUiIcon.plus,
            size: 14,
            color: (_creating || ctrl.providers.isEmpty)
                ? theme.onAccentWax
                : theme.accentBrass,
          ),
          onPressed: () => _openCreateFlow(kProviderPresets.first),
        ),
        const SizedBox(height: 6),
        EngravedButton(
          label: l10n.t(L10nKey.providerDetectLocal),
          compact: true,
          leading: BistreIcon(
            BistreUiIcon.server,
            size: 13,
            color: theme.accentBrass,
          ),
          onPressed: ctrl.detectingLocalServers
              ? null
              : () async {
                  await ctrl.discoverLocalServers();
                  if (mounted) setState(() => _scannedLocal = true);
                },
        ),
        if (_scannedLocal) ...[
          const SizedBox(height: 8),
          if (ctrl.discoveredLocalServers.isEmpty)
            InkText(
              l10n.t(L10nKey.providerLocalNone),
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            )
          else
            for (final srv in ctrl.discoveredLocalServers) ...[
              FolioSurface(
                padding: const EdgeInsetsDirectional.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: InkText(
                        srv.name,
                        role: InkTextRole.captionMeta,
                        color: theme.inkPrimary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    EngravedButton(
                      label: l10n.t(L10nKey.providerAddButton),
                      compact: true,
                      onPressed: () => unawaited(
                        ctrl.createProvider(
                          name: srv.name,
                          dialect: 'custom_openai',
                          baseUrl: srv.baseUrl,
                          defaultModel: srv.models.isNotEmpty
                              ? srv.models.first
                              : '',
                          iconSlug: srv.kind == 'ollama' ? 'ollama' : 'server',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
        ],
        const SizedBox(height: BistreSpacing.s12),
        for (final p in ctrl.providers) ...[
          _ProviderListRow(
            provider: p,
            selected: !_creating && _selectedId == p.id,
            isActiveGlobal: activeId == p.id && p.isReady,
            onTap: () => setState(() => _loadProviderIntoForm(p)),
          ),
          const SizedBox(height: 4),
        ],
      ],
    );
  }

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
                    _newIconSlug == tpl.iconSlug &&
                    _newUrlCtrl.text == tpl.baseUrl,
                onTap: () => _openCreateFlow(tpl),
              ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s16),
        BistreSettingsSection(
          title: l10n.t(L10nKey.providerAddButton),
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
                    ('gemini', L10nKey.providerDialectGemini),
                    ('anthropic', L10nKey.providerDialectAnthropic),
                    ('custom_openai', L10nKey.providerDialectCustom),
                  ])
                    InkChip(
                      label: l10n.t(entry.$2),
                      selected: _newDialect == entry.$1,
                      onSelected: () => setState(() => _newDialect = entry.$1),
                    ),
                ],
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerFieldBaseUrl),
              bottom: QuillInput(
                controller: _newUrlCtrl,
                focusNode: _newUrlFocus,
                placeholder: kExampleBaseUrl,
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
                        setState(() => _loadProviderIntoForm(created));
                      }
                    },
                  ),
                  const SizedBox(width: 10),
                  if (ctrl.providers.isNotEmpty)
                    EngravedButton(
                      label: l10n.t(L10nKey.threadCancel),
                      onPressed: () => setState(() => _creating = false),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDetailPanel(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
    EngineProvider p,
  ) {
    final isActiveGlobal = ctrl.activeProvider?.id == p.id && p.isReady;
    final loadedModels = ctrl.modelsForProvider(p.id);
    final loadingModels = ctrl.loadingModelsProviderId == p.id;
    final filteredModels = _modelFilter.isEmpty
        ? loadedModels
        : loadedModels
              .where(
                (m) =>
                    m.id.toLowerCase().contains(_modelFilter) ||
                    m.displayName.toLowerCase().contains(_modelFilter),
              )
              .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top Identity Card
        FolioSurface(
          tone: FolioTone.elevated,
          padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
          borderRadius: 12,
          boxShadow: theme.cardShadow,
          child: Row(
            children: [
              LabIcon(
                iconSlug: p.iconSlug,
                customIconPath: p.customIconPath,
                dialect: p.dialect,
                providerName: p.name,
                size: 24,
                framed: true,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: InkText(
                            p.name,
                            role: InkTextRole.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        WaxSealBadge(
                          label: isActiveGlobal
                              ? l10n.t(L10nKey.providerStatusActive)
                              : (p.isReady
                                    ? l10n.t(L10nKey.providerStatusConnected)
                                    : l10n.t(
                                        L10nKey.providerStatusNotConnected,
                                      )),
                          status: p.isReady
                              ? WaxSealStatus.ok
                              : WaxSealStatus.warn,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    InkText(
                      p.baseUrl,
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (p.isReady && !isActiveGlobal)
                EngravedButton(
                  label: l10n.t(L10nKey.providerActionUseProvider),
                  primary: true,
                  compact: true,
                  onPressed: () => unawaited(
                    ctrl.setActiveProviderAndModel(p.id, _modelCtrl.text),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: BistreSpacing.s16),

        // API Key Vault Card
        BistreSettingsSection(
          title: l10n.t(L10nKey.providerFieldApiKey),
          subtitle: l10n.t(L10nKey.providerVaultNote),
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: QuillInput(
                          key: const Key('provider_api_key_input'),
                          controller: _apiKeyCtrl,
                          focusNode: _apiKeyFocus,
                          placeholder: p.hasApiKey
                              ? '••••••••••••••••••••'
                              : l10n.t(L10nKey.providerFieldApiKeyPlaceholder),
                          maxLines: 1,
                          obscureText: !_showKey,
                          submitOnEnter: false,
                          onSubmitted: () {},
                        ),
                      ),
                      const SizedBox(width: 6),
                      BistreIconButton(
                        icon: _showKey ? BistreUiIcon.eyeOff : BistreUiIcon.eye,
                        semanticsLabel: _showKey
                            ? l10n.t(L10nKey.providerActionHideKey)
                            : l10n.t(L10nKey.providerActionShowKey),
                        onPressed: () => setState(() => _showKey = !_showKey),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      EngravedButton(
                        label: l10n.t(L10nKey.providerActionSaveKey),
                        primary: !p.hasApiKey,
                        compact: true,
                        onPressed: () async {
                          final ok = await ctrl.saveProviderApiKey(
                            p.id,
                            _apiKeyCtrl.text,
                          );
                          if (ok && mounted) {
                            _apiKeyCtrl.clear();
                          }
                        },
                      ),
                      if (p.hasApiKey) ...[
                        const SizedBox(width: 8),
                        EngravedButton(
                          label: l10n.t(L10nKey.providerActionClearKey),
                          compact: true,
                          onPressed: () =>
                              unawaited(ctrl.clearProviderApiKey(p.id)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s16),

        // Connection, Model & Icon Settings
        BistreSettingsSection(
          title: l10n.t(L10nKey.providerFieldModel),
          children: [
            BistreSettingRow(
              label: l10n.t(L10nKey.providerEnabledToggle),
              trailing: BistreSwitch(
                value: p.isEnabled,
                semanticsLabel: l10n.t(L10nKey.providerEnabledToggle),
                reduceMotionOverride: ctrl.reduceMotionOverride,
                onChanged: (v) => unawaited(
                  ctrl.saveProviderConfig(providerId: p.id, isEnabled: v),
                ),
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerIconLabel),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EngravedButton(
                    label: l10n.t(L10nKey.providerIconCustomUpload),
                    compact: true,
                    onPressed: () => unawaited(_pickCustomProviderIcon(p)),
                  ),
                  if (p.customIconPath.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    EngravedButton(
                      label: l10n.t(L10nKey.providerIconClearCustom),
                      compact: true,
                      onPressed: () => unawaited(
                        ctrl.saveProviderConfig(
                          providerId: p.id,
                          customIconPath: '',
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  BistreIconButton(
                    icon: _iconPickerOpen
                        ? BistreUiIcon.chevronUp
                        : BistreUiIcon.chevronDown,
                    semanticsLabel: l10n.t(L10nKey.providerIconLabel),
                    onPressed: () =>
                        setState(() => _iconPickerOpen = !_iconPickerOpen),
                  ),
                ],
              ),
              bottom: _iconPickerOpen
                  ? Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final entry in LabIconCatalog.all)
                          _LabIconChoiceTile(
                            entry: entry,
                            selected:
                                p.customIconPath.isEmpty &&
                                p.iconSlug == entry.slug,
                            onTap: () => unawaited(
                              ctrl.saveProviderConfig(
                                providerId: p.id,
                                iconSlug: entry.slug,
                                customIconPath: '',
                              ),
                            ),
                          ),
                      ],
                    )
                  : null,
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerFieldName),
              bottom: QuillInput(
                controller: _nameCtrl,
                focusNode: _nameFocus,
                placeholder: l10n.t(L10nKey.providerFieldNamePlaceholder),
                maxLines: 1,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerFieldBaseUrl),
              bottom: QuillInput(
                controller: _baseUrlCtrl,
                focusNode: _baseUrlFocus,
                placeholder: kExampleBaseUrl,
                maxLines: 1,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerFieldModel),
              trailing: EngravedButton(
                label: loadingModels
                    ? l10n.t(L10nKey.providerActionLoadingModels)
                    : l10n.t(L10nKey.providerActionLoadModels),
                compact: true,
                onPressed: loadingModels
                    ? null
                    : () => unawaited(ctrl.fetchModelsForProvider(p.id)),
              ),
              bottom: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  QuillInput(
                    controller: _modelCtrl,
                    focusNode: _modelFocus,
                    placeholder: l10n.t(L10nKey.providerFieldModelPlaceholder),
                    maxLines: 1,
                    submitOnEnter: false,
                    onSubmitted: () {},
                  ),
                  if (loadedModels.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    QuillInput(
                      controller: _modelFilterCtrl,
                      focusNode: _modelFilterFocus,
                      placeholder: l10n.t(L10nKey.sidebarFilterPlaceholder),
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () {},
                      onChanged: (q) =>
                          setState(() => _modelFilter = q.trim().toLowerCase()),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 168),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final m in filteredModels.take(40))
                              _SelectableModelRow(
                                model: m,
                                selected: _modelCtrl.text.trim() == m.id,
                                onTap: () {
                                  setState(() => _modelCtrl.text = m.id);
                                  unawaited(
                                    ctrl.setActiveProviderAndModel(p.id, m.id),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (p.dialect == 'openai' || p.dialect == 'anthropic')
              BistreSettingRow(
                label: l10n.t(L10nKey.providerFieldServerCache),
                trailing: BistreSwitch(
                  value: p.useServerStateCache,
                  semanticsLabel: l10n.t(L10nKey.providerFieldServerCache),
                  reduceMotionOverride: ctrl.reduceMotionOverride,
                  onChanged: (v) => unawaited(
                    ctrl.saveProviderConfig(
                      providerId: p.id,
                      useServerStateCache: v,
                    ),
                  ),
                ),
              ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerCustomHeaders),
              bottom: QuillInput(
                controller: _headersCtrl,
                focusNode: _headersFocus,
                placeholder: kExampleHeadersJson,
                maxLines: 2,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerCustomBody),
              bottom: QuillInput(
                controller: _bodyCtrl,
                focusNode: _bodyFocus,
                placeholder: kExampleBodyJson,
                maxLines: 2,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  EngravedButton(
                    label: l10n.t(L10nKey.providerActionSaveConfig),
                    primary: true,
                    onPressed: () async {
                      await ctrl.saveProviderConfig(
                        providerId: p.id,
                        name: _nameCtrl.text.trim(),
                        baseUrl: _baseUrlCtrl.text.trim(),
                        defaultModel: _modelCtrl.text.trim(),
                      );
                      await ctrl.saveProviderOverrides(
                        providerId: p.id,
                        headersJson: _headersCtrl.text,
                        bodyJson: _bodyCtrl.text,
                      );
                    },
                  ),
                  EngravedButton(
                    label: l10n.t(L10nKey.providerShareConfig),
                    leading: BistreIcon(
                      BistreUiIcon.copy,
                      size: 13,
                      color: theme.inkSecondary,
                    ),
                    onPressed: () => unawaited(
                      ctrl.copyText(ctrl.exportProviderShareJson(p)),
                    ),
                  ),
                  EngravedButton(
                    label: _confirmDelete
                        ? l10n.t(L10nKey.providerDeleteConfirm)
                        : l10n.t(L10nKey.providerDeleteButton),
                    leading: BistreIcon(
                      BistreUiIcon.trash,
                      size: 13,
                      color: theme.statusErr,
                    ),
                    onPressed: () async {
                      if (!_confirmDelete) {
                        setState(() => _confirmDelete = true);
                        return;
                      }
                      await ctrl.deleteProvider(p.id);
                      if (mounted) {
                        setState(() {
                          _confirmDelete = false;
                          _selectedId = null;
                          _syncSelection();
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

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
                if (widget.selected)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: SizedBox(
                      width: 2.5,
                      height: 18,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.accentBrass,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
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
                        color: p.isEnabled ? theme.inkPrimary : theme.inkMuted,
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
                          : (p.isReady ? theme.statusOk : theme.borderHairline),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
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
              color: widget.selected ? theme.accentBrass : theme.borderHairline,
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
    );
  }
}

class _SelectableModelRow extends StatefulWidget {
  const _SelectableModelRow({
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final EngineProviderModel model;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SelectableModelRow> createState() => _SelectableModelRowState();
}

class _SelectableModelRowState extends State<_SelectableModelRow> {
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
    );
  }
}
