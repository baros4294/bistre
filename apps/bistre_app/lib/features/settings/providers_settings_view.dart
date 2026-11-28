import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/label_control_layout.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../shell/folio_controller.dart';
import 'provider_presets.dart';
import 'provider_share_import.dart';
import 'provider_subpages.dart';

part 'providers_settings_rows.dart';

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
  bool _shareWithKey = false;
  String _subpage = 'main'; // main | advanced | model
  String? _editingModelId;
  ProviderAdvancedConfig _advConfig = const ProviderAdvancedConfig();
  List<String> _storedKeys = const <String>[];
  final Set<int> _revealedKeyIndices = <int>{};

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

  /// `setState` for the page's parts in `providers_settings_rows.dart`.
  void _rebuild(VoidCallback fn) => setState(fn);

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
    _shareWithKey = false;
    _iconPickerOpen = false;
    _showKey = false;
    _subpage = 'main';
    _editingModelId = null;
    _nameCtrl.text = p.name;
    _baseUrlCtrl.text = p.baseUrl;
    _modelCtrl.text = p.defaultModel;
    _apiKeyCtrl.clear();
    _modelFilterCtrl.clear();
    _modelFilter = '';
    _headersCtrl.clear();
    _bodyCtrl.clear();
    _storedKeys = const <String>[];
    _revealedKeyIndices.clear();
    unawaited(widget.controller.ensureHiddenModelsLoaded(p.id));
    unawaited(_reloadStoredKeys(p.id));
    unawaited(
      widget.controller.loadProviderAdvanced(p.id).then((cfg) {
        if (mounted && _selectedId == p.id) {
          setState(() => _advConfig = cfg);
        }
      }),
    );
    unawaited(
      widget.controller.loadProviderOverrides(p.id).then((pair) {
        if (!mounted || _selectedId != p.id) return;
        _headersCtrl.text = pair.$1;
        _bodyCtrl.text = pair.$2;
      }),
    );
  }

  Future<void> _reloadStoredKeys(String providerId) async {
    final keys = await widget.controller.loadProviderApiKeys(providerId);
    if (mounted && _selectedId == providerId) {
      setState(() {
        _storedKeys = keys;
        _revealedKeyIndices.removeWhere((i) => i >= keys.length);
      });
    }
  }

  static String _keyIndexBadge(int oneBased) => '#$oneBased';

  static String _maskKey(String raw) {
    if (raw.length <= 8) return '••••••••';
    return '${raw.substring(0, 4)}••••${raw.substring(raw.length - 4)}';
  }

  /// Core's default server URL for an API format.
  String _defaultBaseUrl(String dialect) =>
      widget.controller.dialectDescriptor(dialect)?.defaultBaseUrl ?? '';

  void _openCreateFlow([ProviderPreset? tpl]) {
    setState(() {
      _creating = true;
      _confirmDelete = false;
      _newNameCtrl.text = tpl?.name ?? '';
      _newDialect = tpl?.dialect ?? 'custom_openai';
      _newUrlCtrl.text = _defaultBaseUrl(_newDialect);
      _newModelCtrl.text = tpl?.defaultModel ?? '';
      _newIconSlug = tpl?.iconSlug ?? 'server';
      _newKeyCtrl.clear();
    });
  }

  Future<void> _pickCustomProviderIcon(EngineProvider p) async {
    final l10n = BistreLocalizations.of(context);
    final chosen = await BistreDesktopHost.pickLocalFile(
      title: l10n.t(L10nKey.providerIconCustomUpload),
      filterLabel: l10n.t(L10nKey.settingsProvidersFileFilterImages),
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

    Widget buildRightPane() {
      if (_creating) return _buildCreatePanel(theme, l10n, ctrl);
      if (selected == null) return _buildEmptyState(theme, l10n);
      if (_subpage == 'advanced') {
        return ProviderAdvancedSubpage(
          controller: ctrl,
          provider: selected,
          initialConfig: _advConfig,
          headersCtrl: _headersCtrl,
          headersFocus: _headersFocus,
          bodyCtrl: _bodyCtrl,
          bodyFocus: _bodyFocus,
          onBack: () => setState(() => _subpage = 'main'),
          onSaved: (next) => setState(() => _advConfig = next),
        );
      }
      if (_subpage == 'model' && _editingModelId != null) {
        final mid = _editingModelId!;
        return ProviderModelConfigSubpage(
          controller: ctrl,
          provider: selected,
          modelId: mid,
          config: _advConfig.modelOverrides[mid] ?? const ModelConfigOverride(),
          onBack: () => setState(() => _subpage = 'main'),
          onSaveOverride: (ov) {
            final nextMap = Map<String, ModelConfigOverride>.from(
              _advConfig.modelOverrides,
            )..[mid] = ov;
            final nextCfg = _advConfig.copyWith(modelOverrides: nextMap);
            setState(() {
              _advConfig = nextCfg;
              _subpage = 'main';
            });
            unawaited(ctrl.saveProviderAdvanced(selected.id, nextCfg));
          },
        );
      }
      return _buildDetailPanel(theme, l10n, ctrl, selected);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 680;
        final listPane = _buildProviderList(theme, l10n, ctrl);
        final detailPane = buildRightPane();

        if (!wide) {
          return SmoothScrollable(
            builder: (_, scroll) => SingleChildScrollView(
              controller: scroll,
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
            ),
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 264,
              child: SmoothScrollable(
                builder: (_, scroll) => SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsetsDirectional.fromSTEB(16, 18, 12, 24),
                  child: listPane,
                ),
              ),
            ),
            const FolioDivider(vertical: true),
            Expanded(
              child: SmoothScrollable(
                builder: (_, scroll) => SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 36),
                  child: detailPane,
                ),
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

  Widget _buildDetailPanel(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
    EngineProvider p,
  ) {
    final isActiveGlobal = ctrl.activeProvider?.id == p.id && p.isReady;
    final hiddenModels = ctrl.hiddenModelIdsFor(p.id);
    final loadedModels = ctrl
        .modelsForProvider(p.id)
        .where((m) => !hiddenModels.contains(m.id))
        .toList(growable: false);
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
          // The name and address keep the room they need; the actions sit beside them when
          // they fit and drop below on a narrow screen (never squeezing the name).
          child: LabelControlLayout(
            minLabelWidth: 220,
            stackGap: BistreSpacing.s12,
            label: Row(
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
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            control: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Testing needs a key: without one it could only fail.
                EngravedButton(
                  label: l10n.t(L10nKey.settingsProviderTestAction),
                  compact: true,
                  onPressed: loadingModels || !p.hasApiKey
                      ? null
                      : () => unawaited(ctrl.testProviderConnection(p.id)),
                ),
                EngravedButton(
                  label: l10n.t(L10nKey.settingsProviderAdvancedTitle),
                  compact: true,
                  onPressed: () => setState(() => _subpage = 'advanced'),
                ),
                if (p.isReady && !isActiveGlobal)
                  EngravedButton(
                    label: l10n.t(L10nKey.providerActionUseProvider),
                    compact: true,
                    onPressed: () => unawaited(
                      ctrl.setActiveProviderAndModel(p.id, _modelCtrl.text),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: BistreSpacing.s16),

        // API Key Vault Card (per-key list with reveal, promote to primary, remove, and + Add key)
        BistreSettingsSection(
          title: _storedKeys.length > 1
              ? '${l10n.t(L10nKey.providerFieldApiKey)} (${_storedKeys.length})'
              : l10n.t(L10nKey.providerFieldApiKey),
          subtitle: l10n.t(L10nKey.providerMultiKeyHint),
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_storedKeys.isNotEmpty) ...[
                    for (var i = 0; i < _storedKeys.length; i++) ...[
                      FolioSurface(
                        borderRadius: 8,
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          10,
                          6,
                          6,
                          6,
                        ),
                        child: Row(
                          children: [
                            WaxSealBadge(
                              label: i == 0
                                  ? l10n.t(L10nKey.providerKeyPrimaryBadge)
                                  : _keyIndexBadge(i + 1),
                              status: i == 0
                                  ? WaxSealStatus.ok
                                  : WaxSealStatus.neutral,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: InkText(
                                _revealedKeyIndices.contains(i)
                                    ? _storedKeys[i]
                                    : _maskKey(_storedKeys[i]),
                                role: InkTextRole.codeBlock,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            BistreIconButton(
                              icon: _revealedKeyIndices.contains(i)
                                  ? BistreUiIcon.eyeOff
                                  : BistreUiIcon.eye,
                              size: 13,
                              dimension: 28,
                              semanticsLabel: _revealedKeyIndices.contains(i)
                                  ? l10n.t(L10nKey.providerActionHideKey)
                                  : l10n.t(L10nKey.providerActionShowKey),
                              onPressed: () => setState(() {
                                if (!_revealedKeyIndices.add(i)) {
                                  _revealedKeyIndices.remove(i);
                                }
                              }),
                            ),
                            if (i > 0)
                              EngravedButton(
                                label: l10n.t(L10nKey.providerKeyMakePrimary),
                                compact: true,
                                onPressed: () async {
                                  await ctrl.promoteProviderApiKey(p.id, i);
                                  await _reloadStoredKeys(p.id);
                                },
                              ),
                            BistreIconButton(
                              icon: BistreUiIcon.trash,
                              size: 13,
                              dimension: 28,
                              semanticsLabel: l10n.t(L10nKey.threadDelete),
                              onPressed: () async {
                                await ctrl.removeProviderApiKeyAt(p.id, i);
                                await _reloadStoredKeys(p.id);
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    const SizedBox(height: 6),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: QuillInput(
                          key: const Key('provider_api_key_input'),
                          controller: _apiKeyCtrl,
                          focusNode: _apiKeyFocus,
                          placeholder: _storedKeys.isEmpty
                              ? l10n.t(L10nKey.providerFieldApiKeyPlaceholder)
                              : l10n.t(L10nKey.providerKeyAddPlaceholder),
                          maxLines: _showKey ? 3 : 1,
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
                  // Wraps: both labels side by side do not fit a phone at 200% text.
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      EngravedButton(
                        label: _storedKeys.isEmpty
                            ? l10n.t(L10nKey.providerActionSaveKey)
                            : l10n.t(L10nKey.providerKeyAddAction),
                        primary: _storedKeys.isEmpty,
                        compact: true,
                        onPressed: () async {
                          final ok = _storedKeys.isEmpty
                              ? await ctrl.saveProviderApiKey(
                                  p.id,
                                  _apiKeyCtrl.text,
                                )
                              : await ctrl.addProviderApiKey(
                                  p.id,
                                  _apiKeyCtrl.text,
                                );
                          if (ok && mounted) {
                            _apiKeyCtrl.clear();
                            await _reloadStoredKeys(p.id);
                            if (_advConfig.autoFetchModels) {
                              unawaited(ctrl.fetchModelsForProvider(p.id));
                            }
                          }
                        },
                      ),
                      if (p.hasApiKey)
                        EngravedButton(
                          label: l10n.t(L10nKey.providerActionClearKey),
                          compact: true,
                          onPressed: () async {
                            await ctrl.clearProviderApiKey(p.id);
                            await _reloadStoredKeys(p.id);
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s16),

        // The provider itself: on or off, icon, name, address.
        BistreSettingsSection(
          title: l10n.t(L10nKey.providerSectionTitle),
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
              // One picker: the current icon opens the choices, a local image among them.
              trailing: EngravedButton(
                label: l10n.t(L10nKey.providerIconChange),
                compact: true,
                leading: LabIcon(
                  iconSlug: p.iconSlug,
                  customIconPath: p.customIconPath,
                  dialect: p.dialect,
                  providerName: p.name,
                  size: 15,
                ),
                trailing: BistreIcon(
                  _iconPickerOpen
                      ? BistreUiIcon.chevronUp
                      : BistreUiIcon.chevronDown,
                  size: 12,
                  color: theme.inkMuted,
                ),
                onPressed: () =>
                    setState(() => _iconPickerOpen = !_iconPickerOpen),
              ),
              bottom: _iconPickerOpen
                  ? Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        EngravedButton(
                          label: l10n.t(L10nKey.providerIconCustomUpload),
                          compact: true,
                          onPressed: () =>
                              unawaited(_pickCustomProviderIcon(p)),
                        ),
                        if (p.customIconPath.isNotEmpty)
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
                        for (final entry in LabIconCatalog.all)
                          _LabIconChoiceTile(
                            entry: entry,
                            selected:
                                p.customIconPath.isEmpty &&
                                p.iconSlug == entry.slug,
                            onTap: () {
                              setState(() => _iconPickerOpen = false);
                              unawaited(
                                ctrl.saveProviderConfig(
                                  providerId: p.id,
                                  iconSlug: entry.slug,
                                  customIconPath: '',
                                ),
                              );
                            },
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
              trailing: EngravedButton(
                label: l10n.t(L10nKey.settingsAppearanceFontReset),
                compact: true,
                onPressed: () {
                  final def = _defaultBaseUrl(p.dialect);
                  setState(() => _baseUrlCtrl.text = def);
                  unawaited(
                    ctrl.saveProviderConfig(providerId: p.id, baseUrl: def),
                  );
                },
              ),
              bottom: QuillInput(
                controller: _baseUrlCtrl,
                focusNode: _baseUrlFocus,
                placeholder: _defaultBaseUrl(p.dialect),
                maxLines: 1,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerFieldModel),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hiddenModels.isNotEmpty) ...[
                    EngravedButton(
                      label: l10n.t(
                        L10nKey.settingsProviderRestoreHidden,
                        <String, Object?>{'count': hiddenModels.length},
                      ),
                      compact: true,
                      onPressed: () =>
                          unawaited(ctrl.restoreHiddenModelsForProvider(p.id)),
                    ),
                    const SizedBox(width: 6),
                  ],
                  EngravedButton(
                    label: loadingModels
                        ? l10n.t(L10nKey.providerActionLoadingModels)
                        : l10n.t(L10nKey.providerActionLoadModels),
                    compact: true,
                    onPressed: loadingModels
                        ? null
                        : () => unawaited(ctrl.fetchModelsForProvider(p.id)),
                  ),
                ],
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
                      placeholder: l10n.t(L10nKey.settingsProviderFilterModels),
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () {},
                      onChanged: (q) =>
                          setState(() => _modelFilter = q.trim().toLowerCase()),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 168),
                      child: SmoothScrollable(
                        // Lazy, so every model is reachable (the old list stopped at 60).
                        builder: (_, scroll) => ListView.builder(
                          controller: scroll,
                          shrinkWrap: true,
                          itemCount: filteredModels.length,
                          itemBuilder: (_, index) {
                            final m = filteredModels[index];
                            return _SelectableModelRow(
                              model: m,
                              selected: _modelCtrl.text.trim() == m.id,
                              onTap: () {
                                setState(() => _modelCtrl.text = m.id);
                                unawaited(
                                  ctrl.setActiveProviderAndModel(p.id, m.id),
                                );
                              },
                              onConfigure: () => setState(() {
                                _editingModelId = m.id;
                                _subpage = 'model';
                              }),
                              onHide: () => unawaited(
                                ctrl.hideModelForProvider(p.id, m.id),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (p.hasApiKey)
              BistreSettingRow(
                label: l10n.t(L10nKey.providerShareWithKey),
                description: l10n.t(L10nKey.providerShareWithKeyHint),
                trailing: BistreSwitch(
                  value: _shareWithKey,
                  semanticsLabel: l10n.t(L10nKey.providerShareWithKey),
                  reduceMotionOverride: ctrl.reduceMotionOverride,
                  onChanged: (v) => setState(() => _shareWithKey = v),
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
                      ctrl.copyProviderShareCode(
                        p,
                        includeApiKey: _shareWithKey && p.hasApiKey,
                      ),
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
