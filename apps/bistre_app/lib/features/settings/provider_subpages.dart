import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../chat/thinking_control.dart';
import '../shell/folio_controller.dart';

/// Providers → Advanced sub-page:
/// - API format / custom dialect, endpoint path override, auth header mode
/// - Auto-fetch models toggle
/// - Dialect-specific server storage, chaining, background polling, and legacy fallback toggles
///   (shown cleanly for OpenAI & Gemini; omitted for Anthropic)
/// - Default thinking effort smooth VSYNC slider + Adaptive / Automatic
/// - Custom headers & extra JSON body
class ProviderAdvancedSubpage extends StatefulWidget {
  const ProviderAdvancedSubpage({
    super.key,
    required this.controller,
    required this.provider,
    required this.initialConfig,
    required this.headersCtrl,
    required this.headersFocus,
    required this.bodyCtrl,
    required this.bodyFocus,
    required this.onBack,
    required this.onSaved,
  });

  final FolioController controller;
  final EngineProvider provider;
  final ProviderAdvancedConfig initialConfig;
  final TextEditingController headersCtrl;
  final FocusNode headersFocus;
  final TextEditingController bodyCtrl;
  final FocusNode bodyFocus;
  final VoidCallback onBack;
  final ValueChanged<ProviderAdvancedConfig> onSaved;

  @override
  State<ProviderAdvancedSubpage> createState() =>
      _ProviderAdvancedSubpageState();
}

class _ProviderAdvancedSubpageState extends State<ProviderAdvancedSubpage> {
  late ProviderAdvancedConfig _cfg;
  final TextEditingController _endpointCtrl = TextEditingController();
  final FocusNode _endpointFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _cfg = widget.initialConfig;
    _endpointCtrl.text = _cfg.endpointPathOverride;
  }

  @override
  void dispose() {
    _endpointCtrl.dispose();
    _endpointFocus.dispose();
    super.dispose();
  }

  Future<void> _persist(ProviderAdvancedConfig next) async {
    setState(() => _cfg = next);
    await widget.controller.saveProviderAdvanced(widget.provider.id, next);
    widget.onSaved(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final p = widget.provider;
    final isAnthropic = p.dialect == 'anthropic';
    final isGemini = p.dialect == 'google_gemini';
    final isCustom = p.dialect == 'custom_openai';
    final effortIdx = thinkingStopIndex(_cfg.defaultThinkingEffort);
    final pageTitle = l10n.t(
      L10nKey.settingsProviderAdvancedPageTitle,
      <String, Object?>{'name': p.name},
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            EngravedButton(
              label: l10n.t(L10nKey.settingsBack),
              compact: true,
              leading: BistreIcon(
                BistreUiIcon.arrowBack,
                size: 13,
                color: theme.inkPrimary,
              ),
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkText(
                pageTitle,
                role: InkTextRole.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s16),
        BistreSettingsSection(
          title: l10n.t(L10nKey.settingsProviderProtocolHeading),
          children: [
            if (isCustom)
              BistreSettingRow(
                label: l10n.t(L10nKey.settingsProviderApiFormat),
                bottom: BistreSegmentedControl<String>(
                  selected: _cfg.customDialect,
                  onSelected: (v) =>
                      unawaited(_persist(_cfg.copyWith(customDialect: v))),
                  options: <BistreSegmentedOption<String>>[
                    BistreSegmentedOption<String>(
                      value: 'openai_chat',
                      label: l10n.t(L10nKey.settingsProviderFormatChat),
                    ),
                    BistreSegmentedOption<String>(
                      value: 'openai_responses',
                      label: l10n.t(L10nKey.settingsProviderFormatResponses),
                    ),
                    BistreSegmentedOption<String>(
                      value: 'anthropic_messages',
                      label: l10n.t(L10nKey.settingsProviderFormatAnthropic),
                    ),
                    BistreSegmentedOption<String>(
                      value: 'gemini_interactions',
                      label: l10n.t(L10nKey.settingsProviderFormatGemini),
                    ),
                  ],
                ),
              ),
            BistreSettingRow(
              label: l10n.t(
                L10nKey.settingsProviderRequestsGoTo,
                <String, Object?>{
                  'url': ctrl
                      .resolveProviderEndpoint(p.dialect, p.baseUrl)
                      .chatUrl,
                },
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.settingsProviderEndpointOverride),
              bottom: Row(
                children: [
                  Expanded(
                    child: QuillInput(
                      controller: _endpointCtrl,
                      focusNode: _endpointFocus,
                      placeholder:
                          ctrl.dialectDescriptor(p.dialect)?.endpointPath ?? '',
                      maxLines: 1,
                      submitOnEnter: false,
                      onSubmitted: () => unawaited(
                        _persist(
                          _cfg.copyWith(
                            endpointPathOverride: _endpointCtrl.text.trim(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  EngravedButton(
                    label: l10n.t(L10nKey.threadSave),
                    compact: true,
                    onPressed: () => unawaited(
                      _persist(
                        _cfg.copyWith(
                          endpointPathOverride: _endpointCtrl.text.trim(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.settingsProviderAuthMode),
              trailing: BistreSegmentedControl<String>(
                selected: _cfg.authHeaderMode,
                onSelected: (v) =>
                    unawaited(_persist(_cfg.copyWith(authHeaderMode: v))),
                options: <BistreSegmentedOption<String>>[
                  BistreSegmentedOption<String>(
                    value: 'native',
                    label: l10n.t(L10nKey.settingsProviderAuthNative),
                  ),
                  BistreSegmentedOption<String>(
                    value: 'bearer_only',
                    label: l10n.t(L10nKey.settingsProviderAuthBearer),
                  ),
                  BistreSegmentedOption<String>(
                    value: 'query_param',
                    label: l10n.t(L10nKey.settingsProviderAuthQuery),
                  ),
                ],
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.settingsProviderAutoFetch),
              trailing: BistreSwitch(
                value: _cfg.autoFetchModels,
                semanticsLabel: l10n.t(L10nKey.settingsProviderAutoFetch),
                reduceMotionOverride: ctrl.reduceMotionOverride,
                onChanged: (v) =>
                    unawaited(_persist(_cfg.copyWith(autoFetchModels: v))),
              ),
            ),
          ],
        ),
        if (!isAnthropic) ...[
          const SizedBox(height: BistreSpacing.s16),
          BistreSettingsSection(
            title: l10n.t(L10nKey.settingsTrustStateless),
            children: [
              BistreSettingRow(
                label: l10n.t(L10nKey.settingsProviderStoreServer),
                description: l10n.t(L10nKey.settingsProviderStoreServerHint),
                trailing: BistreSwitch(
                  value: _cfg.storeServerSide,
                  semanticsLabel: l10n.t(L10nKey.settingsProviderStoreServer),
                  reduceMotionOverride: ctrl.reduceMotionOverride,
                  onChanged: (v) =>
                      unawaited(_persist(_cfg.copyWith(storeServerSide: v))),
                ),
              ),
              BistreSettingRow(
                label: l10n.t(L10nKey.settingsProviderStatefulChain),
                trailing: BistreSwitch(
                  value: _cfg.useStatefulChaining,
                  semanticsLabel: l10n.t(L10nKey.settingsProviderStatefulChain),
                  reduceMotionOverride: ctrl.reduceMotionOverride,
                  onChanged: (v) => unawaited(
                    _persist(_cfg.copyWith(useStatefulChaining: v)),
                  ),
                ),
              ),
              if (isGemini) ...[
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsProviderBgPoll),
                  trailing: BistreSwitch(
                    value: _cfg.useBackgroundPolling,
                    semanticsLabel: l10n.t(L10nKey.settingsProviderBgPoll),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) => unawaited(
                      _persist(_cfg.copyWith(useBackgroundPolling: v)),
                    ),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsProviderLegacyFallback),
                  trailing: BistreSwitch(
                    value: _cfg.useLegacyFallback,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsProviderLegacyFallback,
                    ),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) => unawaited(
                      _persist(_cfg.copyWith(useLegacyFallback: v)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: BistreSpacing.s16),
        BistreSettingsSection(
          title: l10n.t(L10nKey.chatReasoningEffort),
          children: [
            BistreSettingRow(
              label: l10n.t(L10nKey.chatReasoningEffort),
              trailing: InkText(
                l10n.t(kThinkingStops[effortIdx].$2),
                role: InkTextRole.captionMeta,
                color: theme.accentBrass,
              ),
              bottom: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  BistreSlider(
                    value: effortIdx.toDouble(),
                    min: 0,
                    max: (kThinkingStops.length - 1).toDouble(),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    semanticsLabel: l10n.t(L10nKey.chatReasoningEffort),
                    onChanged: (v) {
                      final idx = v.round().clamp(0, kThinkingStops.length - 1);
                      unawaited(
                        _persist(
                          _cfg.copyWith(
                            defaultThinkingEffort: kThinkingStops[idx].$1,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      InkChip(
                        label: l10n.t(L10nKey.chatEffortAdaptive),
                        selected: _cfg.defaultThinkingEffort == 'adaptive',
                        onSelected: () => unawaited(
                          _persist(
                            _cfg.copyWith(defaultThinkingEffort: 'adaptive'),
                          ),
                        ),
                      ),
                      InkChip(
                        label: l10n.t(L10nKey.chatEffortAuto),
                        selected: _cfg.defaultThinkingEffort == 'default',
                        onSelected: () => unawaited(
                          _persist(
                            _cfg.copyWith(defaultThinkingEffort: 'default'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerHeadersLabel),
              bottom: QuillInput(
                controller: widget.headersCtrl,
                focusNode: widget.headersFocus,
                placeholder: l10n.t(L10nKey.providerHeadersPlaceholder),
                maxLines: 3,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.providerExtraBodyLabel),
              bottom: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  QuillInput(
                    controller: widget.bodyCtrl,
                    focusNode: widget.bodyFocus,
                    placeholder: l10n.t(L10nKey.providerExtraBodyPlaceholder),
                    maxLines: 3,
                    submitOnEnter: false,
                    onSubmitted: () {},
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: EngravedButton(
                      label: l10n.t(L10nKey.threadSave),
                      primary: true,
                      compact: true,
                      onPressed: () => unawaited(
                        ctrl.saveProviderOverrides(
                          providerId: p.id,
                          headersJson: widget.headersCtrl.text,
                          bodyJson: widget.bodyCtrl.text,
                        ),
                      ),
                    ),
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

/// Providers → Per-Model Settings sub-page:
/// Conversation limit, Reply limit, and 6 USD/1M pricing overrides + Fill in from catalog.
class ProviderModelConfigSubpage extends StatefulWidget {
  const ProviderModelConfigSubpage({
    super.key,
    required this.controller,
    required this.provider,
    required this.modelId,
    required this.config,
    required this.onBack,
    required this.onSaveOverride,
  });

  final FolioController controller;
  final EngineProvider provider;
  final String modelId;
  final ModelConfigOverride config;
  final VoidCallback onBack;
  final ValueChanged<ModelConfigOverride> onSaveOverride;

  @override
  State<ProviderModelConfigSubpage> createState() =>
      _ProviderModelConfigSubpageState();
}

class _ProviderModelConfigSubpageState
    extends State<ProviderModelConfigSubpage> {
  final TextEditingController _ctxCtrl = TextEditingController();
  final TextEditingController _outCtrl = TextEditingController();
  final TextEditingController _inPriceCtrl = TextEditingController();
  final TextEditingController _outPriceCtrl = TextEditingController();
  final TextEditingController _cacheReadCtrl = TextEditingController();
  final TextEditingController _cacheWriteCtrl = TextEditingController();
  final TextEditingController _cacheLongCtrl = TextEditingController();
  final TextEditingController _reasonCtrl = TextEditingController();
  final FocusNode _ctxFocus = FocusNode();
  final FocusNode _outFocus = FocusNode();
  final FocusNode _inPriceFocus = FocusNode();
  final FocusNode _outPriceFocus = FocusNode();
  final FocusNode _cacheReadFocus = FocusNode();
  final FocusNode _cacheWriteFocus = FocusNode();
  final FocusNode _cacheLongFocus = FocusNode();
  final FocusNode _reasonFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _ctxCtrl.text = '${c.contextLimit}';
    _outCtrl.text = '${c.maxOutputTokens}';
    _inPriceCtrl.text = c.inputPerMillion;
    _outPriceCtrl.text = c.outputPerMillion;
    _cacheReadCtrl.text = c.cacheReadPerMillion;
    _cacheWriteCtrl.text = c.cacheWritePerMillion;
    _cacheLongCtrl.text = c.cacheWriteLongPerMillion;
    _reasonCtrl.text = c.reasoningPerMillion;
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[
      _ctxCtrl,
      _outCtrl,
      _inPriceCtrl,
      _outPriceCtrl,
      _cacheReadCtrl,
      _cacheWriteCtrl,
      _cacheLongCtrl,
      _reasonCtrl,
    ]) {
      c.dispose();
    }
    for (final f in <FocusNode>[
      _ctxFocus,
      _outFocus,
      _inPriceFocus,
      _outPriceFocus,
      _cacheReadFocus,
      _cacheWriteFocus,
      _cacheLongFocus,
      _reasonFocus,
    ]) {
      f.dispose();
    }
    super.dispose();
  }

  bool _fillingCatalog = false;

  String _formatMicrosUsd(int micros) =>
      (micros / 1000000.0).toStringAsFixed(2);

  Future<void> _fillFromCatalog() async {
    if (_fillingCatalog) return;
    setState(() => _fillingCatalog = true);
    try {
      final info = await widget.controller.lookupModelCatalogInfo(
        widget.modelId,
      );
      if (!mounted) return;
      if (info == null) {
        widget.controller.showToast(L10nKey.toastCatalogNotFound);
        return;
      }
      setState(() {
        if (info.contextWindow != null && info.contextWindow! > 0) {
          _ctxCtrl.text = '${info.contextWindow}';
        }
        if (info.maxOutputTokens != null && info.maxOutputTokens! > 0) {
          _outCtrl.text = '${info.maxOutputTokens}';
        }
        if (info.inputPerMtokMicros != null) {
          _inPriceCtrl.text = _formatMicrosUsd(info.inputPerMtokMicros!);
        }
        if (info.outputPerMtokMicros != null) {
          _outPriceCtrl.text = _formatMicrosUsd(info.outputPerMtokMicros!);
        }
        if (info.cachedInputPerMtokMicros != null) {
          _cacheReadCtrl.text = _formatMicrosUsd(
            info.cachedInputPerMtokMicros!,
          );
        }
      });
      widget.controller.showToast(L10nKey.toastCatalogFilled);
    } finally {
      if (mounted) setState(() => _fillingCatalog = false);
    }
  }

  void _save() {
    widget.onSaveOverride(
      ModelConfigOverride(
        contextLimit: int.tryParse(_ctxCtrl.text.trim()) ?? 128000,
        maxOutputTokens: int.tryParse(_outCtrl.text.trim()) ?? 8192,
        inputPerMillion: _inPriceCtrl.text.trim(),
        outputPerMillion: _outPriceCtrl.text.trim(),
        cacheReadPerMillion: _cacheReadCtrl.text.trim(),
        cacheWritePerMillion: _cacheWriteCtrl.text.trim(),
        cacheWriteLongPerMillion: _cacheLongCtrl.text.trim(),
        reasoningPerMillion: _reasonCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            EngravedButton(
              label: l10n.t(L10nKey.settingsBack),
              compact: true,
              leading: BistreIcon(
                BistreUiIcon.arrowBack,
                size: 13,
                color: theme.inkPrimary,
              ),
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: InkText(
                widget.modelId,
                role: InkTextRole.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            EngravedButton(
              label: l10n.t(L10nKey.settingsModelFillCatalog),
              compact: true,
              onPressed: _fillingCatalog
                  ? null
                  : () => unawaited(_fillFromCatalog()),
            ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s16),
        BistreSettingsSection(
          title: l10n.t(L10nKey.settingsModelLimitsHeading),
          children: [
            _FieldRow(
              label: l10n.t(L10nKey.settingsModelContextLimit),
              ctrl: _ctxCtrl,
              focus: _ctxFocus,
              placeholder: '128000',
            ),
            _FieldRow(
              label: l10n.t(L10nKey.settingsModelReplyLimit),
              ctrl: _outCtrl,
              focus: _outFocus,
              placeholder: '8192',
            ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s16),
        BistreSettingsSection(
          title: l10n.t(L10nKey.settingsModelPricingHeading),
          children: [
            _FieldRow(
              label: l10n.t(L10nKey.settingsModelPriceInput),
              ctrl: _inPriceCtrl,
              focus: _inPriceFocus,
              placeholder: '0.00',
            ),
            _FieldRow(
              label: l10n.t(L10nKey.settingsModelPriceOutput),
              ctrl: _outPriceCtrl,
              focus: _outPriceFocus,
              placeholder: '0.00',
            ),
            _FieldRow(
              label: l10n.t(L10nKey.settingsModelPriceReused),
              ctrl: _cacheReadCtrl,
              focus: _cacheReadFocus,
              placeholder: '0.00',
            ),
            _FieldRow(
              label: l10n.t(L10nKey.settingsModelPriceSaved),
              ctrl: _cacheWriteCtrl,
              focus: _cacheWriteFocus,
              placeholder: '0.00',
            ),
            _FieldRow(
              label: l10n.t(L10nKey.settingsModelPriceSavedLong),
              ctrl: _cacheLongCtrl,
              focus: _cacheLongFocus,
              placeholder: '0.00',
            ),
            _FieldRow(
              label: l10n.t(L10nKey.settingsModelPriceReasoning),
              ctrl: _reasonCtrl,
              focus: _reasonFocus,
              placeholder: '0.00',
            ),
            Padding(
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: EngravedButton(
                  label: l10n.t(L10nKey.threadSave),
                  primary: true,
                  compact: true,
                  onPressed: _save,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.ctrl,
    required this.focus,
    required this.placeholder,
  });

  final String label;
  final TextEditingController ctrl;
  final FocusNode focus;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    return BistreSettingRow(
      label: label,
      trailing: SizedBox(
        width: 140,
        child: QuillInput(
          controller: ctrl,
          focusNode: focus,
          placeholder: placeholder,
          maxLines: 1,
          compact: true,
          submitOnEnter: false,
          onSubmitted: () {},
        ),
      ),
    );
  }
}
