import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Dedicated Default Models settings tab:
/// - Global default provider & model
/// - Title generation model (default: Follow global choice) + editable prompt template
/// - Summary / Shorten conversation model (default: Follow global choice)
/// - Translation model (default: Follow global choice) + target language
class DefaultModelsSettingsView extends StatefulWidget {
  const DefaultModelsSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<DefaultModelsSettingsView> createState() =>
      _DefaultModelsSettingsViewState();
}

class _DefaultModelsSettingsViewState extends State<DefaultModelsSettingsView> {
  final TextEditingController _globalModelCtrl = TextEditingController();
  final TextEditingController _titleModelCtrl = TextEditingController();
  final TextEditingController _titlePromptCtrl = TextEditingController();
  final TextEditingController _summaryModelCtrl = TextEditingController();
  final TextEditingController _transModelCtrl = TextEditingController();
  final TextEditingController _transLangCtrl = TextEditingController();
  final FocusNode _globalModelFocus = FocusNode();
  final FocusNode _titleModelFocus = FocusNode();
  final FocusNode _titlePromptFocus = FocusNode();
  final FocusNode _summaryModelFocus = FocusNode();
  final FocusNode _transModelFocus = FocusNode();
  final FocusNode _transLangFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _syncFromController();
  }

  void _syncFromController() {
    final dm = widget.controller.defaultModels;
    _globalModelCtrl.text = dm.globalModelId.isNotEmpty
        ? dm.globalModelId
        : widget.controller.activeModelId;
    _titleModelCtrl.text = dm.titleModelId;
    _titlePromptCtrl.text = dm.titlePromptTemplate;
    _summaryModelCtrl.text = dm.summaryModelId;
    _transModelCtrl.text = dm.translationModelId;
    _transLangCtrl.text = dm.translationTargetLanguage;
  }

  @override
  void dispose() {
    _globalModelCtrl.dispose();
    _titleModelCtrl.dispose();
    _titlePromptCtrl.dispose();
    _summaryModelCtrl.dispose();
    _transModelCtrl.dispose();
    _transLangCtrl.dispose();
    _globalModelFocus.dispose();
    _titleModelFocus.dispose();
    _titlePromptFocus.dispose();
    _summaryModelFocus.dispose();
    _transModelFocus.dispose();
    _transLangFocus.dispose();
    super.dispose();
  }

  Future<void> _save(DefaultModelsConfig next) async {
    await widget.controller.saveDefaultModels(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final dm = ctrl.defaultModels;
    final providers = ctrl.providers;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Global Default
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsDefaultModelsGlobalHeading),
              subtitle: l10n.t(L10nKey.settingsDefaultModelsGlobalHint),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAssistantsDefaultProvider),
                  bottom: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in providers)
                        InkChip(
                          label: p.name,
                          selected:
                              (dm.globalProviderId.isNotEmpty
                                  ? dm.globalProviderId
                                  : ctrl.activeProvider?.id) ==
                              p.id,
                          onSelected: () => unawaited(
                            _save(dm.copyWith(globalProviderId: p.id)),
                          ),
                        ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAssistantsDefaultModel),
                  bottom: Row(
                    children: [
                      Expanded(
                        child: QuillInput(
                          controller: _globalModelCtrl,
                          focusNode: _globalModelFocus,
                          placeholder: l10n.t(
                            L10nKey.settingsAssistantsDefaultModel,
                          ),
                          maxLines: 1,
                          submitOnEnter: false,
                          onSubmitted: () => unawaited(
                            _save(
                              dm.copyWith(
                                globalModelId: _globalModelCtrl.text.trim(),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      EngravedButton(
                        label: l10n.t(L10nKey.threadSave),
                        primary: true,
                        compact: true,
                        onPressed: () => unawaited(
                          _save(
                            dm.copyWith(
                              globalModelId: _globalModelCtrl.text.trim(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s24),

            // 2. Title Generation
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsDefaultModelsTitleHeading),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsDefaultModelsFollowGlobal),
                  trailing: BistreSwitch(
                    value: dm.titleFollowGlobal,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsDefaultModelsFollowGlobal,
                    ),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) =>
                        unawaited(_save(dm.copyWith(titleFollowGlobal: v))),
                  ),
                ),
                if (!dm.titleFollowGlobal)
                  _ModelSlotRow(
                    providers: providers,
                    selectedProviderId: dm.titleProviderId,
                    modelCtrl: _titleModelCtrl,
                    modelFocus: _titleModelFocus,
                    onSelectProvider: (pid) =>
                        unawaited(_save(dm.copyWith(titleProviderId: pid))),
                    onSaveModel: () => unawaited(
                      _save(
                        dm.copyWith(titleModelId: _titleModelCtrl.text.trim()),
                      ),
                    ),
                  ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsDefaultModelsTitlePrompt),
                  trailing: EngravedButton(
                    label: l10n.t(L10nKey.settingsAppearanceFontReset),
                    compact: true,
                    onPressed: () {
                      _titlePromptCtrl.text =
                          DefaultModelsConfig.defaultTitlePrompt;
                      unawaited(
                        _save(
                          dm.copyWith(
                            titlePromptTemplate:
                                DefaultModelsConfig.defaultTitlePrompt,
                          ),
                        ),
                      );
                    },
                  ),
                  bottom: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      QuillInput(
                        controller: _titlePromptCtrl,
                        focusNode: _titlePromptFocus,
                        placeholder: l10n.t(
                          L10nKey.settingsDefaultModelsTitlePrompt,
                        ),
                        maxLines: 3,
                        submitOnEnter: false,
                        onSubmitted: () {},
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: EngravedButton(
                          label: l10n.t(L10nKey.threadSave),
                          compact: true,
                          onPressed: () => unawaited(
                            _save(
                              dm.copyWith(
                                titlePromptTemplate: _titlePromptCtrl.text
                                    .trim(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s24),

            // 3. Summary / Shorten Conversation
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsDefaultModelsSummaryHeading),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsDefaultModelsFollowGlobal),
                  trailing: BistreSwitch(
                    value: dm.summaryFollowGlobal,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsDefaultModelsFollowGlobal,
                    ),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) =>
                        unawaited(_save(dm.copyWith(summaryFollowGlobal: v))),
                  ),
                ),
                if (!dm.summaryFollowGlobal)
                  _ModelSlotRow(
                    providers: providers,
                    selectedProviderId: dm.summaryProviderId,
                    modelCtrl: _summaryModelCtrl,
                    modelFocus: _summaryModelFocus,
                    onSelectProvider: (pid) =>
                        unawaited(_save(dm.copyWith(summaryProviderId: pid))),
                    onSaveModel: () => unawaited(
                      _save(
                        dm.copyWith(
                          summaryModelId: _summaryModelCtrl.text.trim(),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s24),

            // 4. Translation
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsDefaultModelsTranslationHeading),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsDefaultModelsFollowGlobal),
                  trailing: BistreSwitch(
                    value: dm.translationFollowGlobal,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsDefaultModelsFollowGlobal,
                    ),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) => unawaited(
                      _save(dm.copyWith(translationFollowGlobal: v)),
                    ),
                  ),
                ),
                if (!dm.translationFollowGlobal)
                  _ModelSlotRow(
                    providers: providers,
                    selectedProviderId: dm.translationProviderId,
                    modelCtrl: _transModelCtrl,
                    modelFocus: _transModelFocus,
                    onSelectProvider: (pid) => unawaited(
                      _save(dm.copyWith(translationProviderId: pid)),
                    ),
                    onSaveModel: () => unawaited(
                      _save(
                        dm.copyWith(
                          translationModelId: _transModelCtrl.text.trim(),
                        ),
                      ),
                    ),
                  ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsDefaultModelsTargetLang),
                  bottom: Row(
                    children: [
                      Expanded(
                        child: QuillInput(
                          controller: _transLangCtrl,
                          focusNode: _transLangFocus,
                          placeholder: l10n.t(
                            L10nKey.settingsDefaultModelsTargetLang,
                          ),
                          maxLines: 1,
                          submitOnEnter: false,
                          onSubmitted: () => unawaited(
                            _save(
                              dm.copyWith(
                                translationTargetLanguage: _transLangCtrl.text
                                    .trim(),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      EngravedButton(
                        label: l10n.t(L10nKey.threadSave),
                        compact: true,
                        leading: BistreIcon(
                          BistreUiIcon.check,
                          size: 13,
                          color: theme.accentBrass,
                        ),
                        onPressed: () => unawaited(
                          _save(
                            dm.copyWith(
                              translationTargetLanguage: _transLangCtrl.text
                                  .trim(),
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
        ),
      ),
    );
  }
}

class _ModelSlotRow extends StatelessWidget {
  const _ModelSlotRow({
    required this.providers,
    required this.selectedProviderId,
    required this.modelCtrl,
    required this.modelFocus,
    required this.onSelectProvider,
    required this.onSaveModel,
  });

  final List<EngineProvider> providers;
  final String selectedProviderId;
  final TextEditingController modelCtrl;
  final FocusNode modelFocus;
  final ValueChanged<String> onSelectProvider;
  final VoidCallback onSaveModel;

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    return BistreSettingRow(
      label: l10n.t(L10nKey.settingsAssistantsDefaultModel),
      bottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in providers)
                InkChip(
                  label: p.name,
                  selected: selectedProviderId == p.id,
                  onSelected: () => onSelectProvider(p.id),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: QuillInput(
                  controller: modelCtrl,
                  focusNode: modelFocus,
                  placeholder: l10n.t(L10nKey.settingsAssistantsDefaultModel),
                  maxLines: 1,
                  submitOnEnter: false,
                  onSubmitted: onSaveModel,
                ),
              ),
              const SizedBox(width: 8),
              EngravedButton(
                label: l10n.t(L10nKey.threadSave),
                compact: true,
                onPressed: onSaveModel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
