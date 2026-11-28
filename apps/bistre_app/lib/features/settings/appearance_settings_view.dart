import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../design/user_avatar_thumb.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../../platform/font_manager.dart';
import '../shell/folio_controller.dart';
import 'appearance_preferences_extra.dart';

part 'appearance_settings_rows.dart';

/// End-user Appearance & Typography Studio: ZERO forced presets:
/// - Live Typography & Accent Preview Card
/// - System | Light | Dark theme + Accent swatches & Custom Hex (#RRGGBB)
/// - Local OS Font Browser & Native `.ttf`/`.otf` Font Picker (Prose & Code)
/// - Continuous Font Size (`12..28px`), Line Spacing (`1.30..2.00`), Reading Width (`600..1120px`)
class AppearanceSettingsView extends StatefulWidget {
  const AppearanceSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<AppearanceSettingsView> createState() => _AppearanceSettingsViewState();
}

class _AppearanceSettingsViewState extends State<AppearanceSettingsView> {
  final TextEditingController _hexCtrl = TextEditingController();
  final TextEditingController _nameCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  final TextEditingController _fontSizeCtrl = TextEditingController();
  final TextEditingController _proseFilterCtrl = TextEditingController();
  final TextEditingController _monoFilterCtrl = TextEditingController();
  final FocusNode _hexFocus = FocusNode();
  final FocusNode _fontSizeFocus = FocusNode();
  final FocusNode _proseFilterFocus = FocusNode();
  final FocusNode _monoFilterFocus = FocusNode();

  bool _prosePickerOpen = false;
  bool _monoPickerOpen = false;
  String _proseFilter = '';
  String _monoFilter = '';

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.ensureSystemFontsLoaded());
    _hexCtrl.text = widget.controller.settings.customAccentHex.isNotEmpty
        ? widget.controller.settings.customAccentHex
        : '#A83625';
    _fontSizeCtrl.text = widget.controller.settings.fontSizePx.toString();
    _nameCtrl.text = widget.controller.settings.userDisplayName;
    // The name saves when the field loses focus, like the other text settings.
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) _commitName();
    });
  }

  void _commitName() {
    final name = _nameCtrl.text.trim();
    if (name == widget.controller.settings.userDisplayName) return;
    unawaited(
      widget.controller.updateSettings(
        widget.controller.settings.copyWith(userDisplayName: name),
      ),
    );
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    _nameCtrl.dispose();
    _nameFocus.dispose();
    _fontSizeCtrl.dispose();
    _proseFilterCtrl.dispose();
    _monoFilterCtrl.dispose();
    _hexFocus.dispose();
    _fontSizeFocus.dispose();
    _proseFilterFocus.dispose();
    _monoFilterFocus.dispose();
    super.dispose();
  }

  Future<void> _browseLocalFont({required bool isMono}) async {
    final l10n = BistreLocalizations.of(context);
    final chosen = await BistreDesktopHost.pickLocalFile(
      title: l10n.t(L10nKey.settingsAppearanceFontBrowse),
      filterLabel: l10n.t(L10nKey.settingsAppearanceFileFilterFonts),
      filterSpec: '*.ttf;*.otf',
    );
    if (chosen == null || chosen.isEmpty) return;
    final stem = chosen.split(Platform.pathSeparator).last;
    final cleanLabel = stem.replaceAll(
      RegExp(r'\.(ttf|otf)$', caseSensitive: false),
      '',
    );
    if (isMono) {
      await widget.controller.applyLocalMonoFont(
        familyLabel: cleanLabel,
        filePath: chosen,
      );
    } else {
      await widget.controller.applyLocalProseFont(
        familyLabel: cleanLabel,
        filePath: chosen,
      );
    }
  }

  void _applyCustomHex() {
    final parsed = BistreAccentOption.tryParseHex(_hexCtrl.text);
    if (parsed == null) return;
    final normalized =
        '#${_hexCtrl.text.trim().replaceFirst('#', '').toUpperCase()}';
    _hexCtrl.text = normalized;
    unawaited(
      widget.controller.updateSettings(
        widget.controller.settings.copyWith(
          accentPreset: 'custom',
          customAccentHex: normalized,
        ),
      ),
    );
  }

  void _commitFontSizePx(int px) {
    final clamped = px.clamp(12, 28);
    _fontSizeCtrl.text = clamped.toString();
    unawaited(
      widget.controller.updateSettings(
        widget.controller.settings.copyWith(fontSizePx: clamped),
        quiet: true,
      ),
    );
  }

  Future<void> _pickProfileAvatar() async {
    final l10n = BistreLocalizations.of(context);
    final chosen = await BistreDesktopHost.pickLocalFile(
      title: l10n.t(L10nKey.settingsProfileAvatar),
      filterLabel: l10n.t(L10nKey.settingsProvidersFileFilterImages),
      filterSpec: '*.png;*.webp;*.jpg;*.jpeg',
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.controller.setProfileAvatarPath(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final s = ctrl.settings;
    final lineHeightVal = (s.lineHeightBps.clamp(13000, 20000)) / 10000.0;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.fromSTEB(28, 18, 28, 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsProfileSection),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsProfileName),
                  description: l10n.t(L10nKey.settingsProfileNameHint),
                  trailing: SizedBox(
                    width: 240,
                    child: QuillInput(
                      controller: _nameCtrl,
                      focusNode: _nameFocus,
                      placeholder: l10n.t(L10nKey.settingsProfileName),
                      maxLines: 1,
                      compact: true,
                      onSubmitted: _commitName,
                    ),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsProfileAvatar),
                  description: ctrl.profileAvatarPath.isNotEmpty
                      ? ctrl.profileAvatarPath
                      : null,
                  trailing: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      UserAvatarThumb(path: ctrl.profileAvatarPath, size: 34),
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsProfileAvatarChoose),
                        compact: true,
                        onPressed: () => unawaited(_pickProfileAvatar()),
                      ),
                      if (ctrl.profileAvatarPath.isNotEmpty)
                        EngravedButton(
                          label: l10n.t(L10nKey.settingsProfileAvatarClear),
                          compact: true,
                          onPressed: () =>
                              unawaited(ctrl.setProfileAvatarPath('')),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s16),
            // Live Typography & Theme Preview Card
            _buildPreviewCard(theme, l10n),
            const SizedBox(height: BistreSpacing.s16),

            // Section 1: Typography & Local Custom Fonts (directly under Live Preview)
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsAppearanceTypographySection),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceProseFont),
                  // The picker names the font in use (state on the control); its list holds
                  // the bundled default, installed fonts, and Choose file.
                  trailing: EngravedButton(
                    label: s.proseFontFamily.isNotEmpty
                        ? s.proseFontFamily
                        : BistreTypography.fontProse,
                    semanticsLabel: l10n.t(L10nKey.settingsAppearanceProseFont),
                    compact: true,
                    trailing: BistreIcon(
                      _prosePickerOpen
                          ? BistreUiIcon.chevronUp
                          : BistreUiIcon.chevronDown,
                      size: 12,
                      color: theme.inkSecondary,
                    ),
                    onPressed: () =>
                        setState(() => _prosePickerOpen = !_prosePickerOpen),
                  ),
                  bottom: _prosePickerOpen
                      ? _buildFontPickerList(
                          theme: theme,
                          l10n: l10n,
                          fonts: ctrl.systemFonts,
                          filterCtrl: _proseFilterCtrl,
                          filterFocus: _proseFilterFocus,
                          filter: _proseFilter,
                          selectedFamily: s.proseFontFamily,
                          onFilterChanged: (q) => setState(
                            () => _proseFilter = q.trim().toLowerCase(),
                          ),
                          onReset: () => unawaited(ctrl.resetProseFont()),
                          onBrowse: () =>
                              unawaited(_browseLocalFont(isMono: false)),
                          onPickFont: (f) => unawaited(
                            ctrl.applyLocalProseFont(
                              familyLabel: f.familyName,
                              filePath: f.filePath,
                            ),
                          ),
                        )
                      : null,
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceMonoFont),
                  // The picker names the font in use (state on the control); its list holds
                  // the bundled default, installed fonts, and Choose file.
                  trailing: EngravedButton(
                    label: s.monoFontFamily.isNotEmpty
                        ? s.monoFontFamily
                        : BistreTypography.fontMono,
                    semanticsLabel: l10n.t(L10nKey.settingsAppearanceMonoFont),
                    compact: true,
                    trailing: BistreIcon(
                      _monoPickerOpen
                          ? BistreUiIcon.chevronUp
                          : BistreUiIcon.chevronDown,
                      size: 12,
                      color: theme.inkSecondary,
                    ),
                    onPressed: () =>
                        setState(() => _monoPickerOpen = !_monoPickerOpen),
                  ),
                  bottom: _monoPickerOpen
                      ? _buildFontPickerList(
                          theme: theme,
                          l10n: l10n,
                          fonts: ctrl.systemFonts
                              .where((f) => f.isMonospaceHint)
                              .toList(growable: false),
                          filterCtrl: _monoFilterCtrl,
                          filterFocus: _monoFilterFocus,
                          filter: _monoFilter,
                          selectedFamily: s.monoFontFamily,
                          onFilterChanged: (q) => setState(
                            () => _monoFilter = q.trim().toLowerCase(),
                          ),
                          onReset: () => unawaited(ctrl.resetMonoFont()),
                          onBrowse: () =>
                              unawaited(_browseLocalFont(isMono: true)),
                          onPickFont: (f) => unawaited(
                            ctrl.applyLocalMonoFont(
                              familyLabel: f.familyName,
                              filePath: f.filePath,
                            ),
                          ),
                        )
                      : null,
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceFontSize),
                  trailing: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 6,
                    children: [
                      SizedBox(
                        width: 68,
                        child: QuillInput(
                          controller: _fontSizeCtrl,
                          focusNode: _fontSizeFocus,
                          placeholder: _kFontSizePlaceholder,
                          maxLines: 1,
                          submitOnEnter: false,
                          onSubmitted: () {
                            final parsed = int.tryParse(
                              _fontSizeCtrl.text.trim(),
                            );
                            if (parsed != null) _commitFontSizePx(parsed);
                          },
                        ),
                      ),
                      if (s.fontSizePx != 15) ...[
                        const SizedBox(width: 8),
                        EngravedButton(
                          label: l10n.t(L10nKey.settingsAppearanceFontReset),
                          compact: true,
                          onPressed: () => _commitFontSizePx(15),
                        ),
                      ],
                    ],
                  ),
                  bottom: BistreSlider(
                    value: s.fontSizePx.clamp(12, 28).toDouble(),
                    min: 12,
                    max: 28,
                    step: 1,
                    semanticsLabel: l10n.t(L10nKey.settingsAppearanceFontSize),
                    onChanged: (v) => _commitFontSizePx(v.round()),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceLineSpacing),
                  trailing: _valueWithReset(
                    theme,
                    l10n,
                    lineHeightVal.toStringAsFixed(2),
                    s.lineHeightBps == 16000
                        ? null
                        : () => unawaited(
                            ctrl.updateSettings(
                              s.copyWith(lineHeightBps: 16000),
                              quiet: true,
                            ),
                          ),
                  ),
                  bottom: BistreSlider(
                    value: lineHeightVal,
                    min: 1.30,
                    max: 2.00,
                    step: 0.05,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsAppearanceLineSpacing,
                    ),
                    onChanged: (v) => unawaited(
                      ctrl.updateSettings(
                        s.copyWith(lineHeightBps: (v * 10000).round()),
                        quiet: true,
                      ),
                    ),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceReadingWidthLabel),
                  trailing: _valueWithReset(
                    theme,
                    l10n,
                    l10n.t(L10nKey.settingsAppearancePixels, <String, Object?>{
                      'px': s.readingWidthPx,
                    }),
                    s.readingWidthPx == BistreSpacing.readingWidthDefault
                        ? null
                        : () => unawaited(
                            ctrl.updateSettings(
                              s.copyWith(
                                readingWidthPx: BistreSpacing
                                    .readingWidthDefault
                                    .toInt(),
                              ),
                              quiet: true,
                            ),
                          ),
                  ),
                  bottom: BistreSlider(
                    value: s.readingWidthPx.toDouble().clamp(
                      BistreSpacing.readingWidthMin,
                      BistreSpacing.readingWidthMax,
                    ),
                    min: BistreSpacing.readingWidthMin,
                    max: BistreSpacing.readingWidthMax,
                    step: 20,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsAppearanceReadingWidthLabel,
                    ),
                    onChanged: (v) => unawaited(
                      ctrl.updateSettings(
                        s.copyWith(readingWidthPx: v.round()),
                        quiet: true,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s24),

            // Section 2: Theme, Accent & Chat Layout
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsAppearanceThemeSection),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceTheme),
                  trailing: BistreSegmentedControl<String>(
                    selected: s.theme == 'system'
                        ? 'system'
                        : (ctrl.isDark ? 'night' : 'day'),
                    onSelected: (v) => unawaited(
                      ctrl.updateSettings(s.copyWith(theme: v), quiet: true),
                    ),
                    options: <BistreSegmentedOption<String>>[
                      BistreSegmentedOption<String>(
                        value: 'system',
                        label: l10n.t(L10nKey.shellThemeSystem),
                        leading: const BistreIcon(
                          BistreUiIcon.systemTheme,
                          size: 13,
                        ),
                      ),
                      BistreSegmentedOption<String>(
                        value: 'day',
                        label: l10n.t(L10nKey.shellThemeDay),
                        leading: const BistreIcon(BistreUiIcon.sun, size: 13),
                      ),
                      BistreSegmentedOption<String>(
                        value: 'night',
                        label: l10n.t(L10nKey.shellThemeNight),
                        leading: const BistreIcon(BistreUiIcon.moon, size: 13),
                      ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceThemePresets),
                  bottom: _ThemePresetChoices(
                    activePresetId: BistreThemePreset.activePresetId(
                      s.theme,
                      isDark: ctrl.isDark,
                    ),
                    l10n: l10n,
                    onSelectPreset: (presetId) => unawaited(
                      ctrl.updateSettings(
                        s.copyWith(theme: presetId, accentPreset: 'preset'),
                        quiet: true,
                      ),
                    ),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceAccent),
                  bottom: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final opt in BistreAccentOption.presets)
                            _AccentSwatchPill(
                              label: _accentLabel(l10n, opt.id),
                              swatch: theme.isDark
                                  ? opt.nightPrimary
                                  : opt.dayPrimary,
                              selected: s.accentPreset == opt.id,
                              onTap: () => unawaited(
                                ctrl.updateSettings(
                                  s.copyWith(accentPreset: opt.id),
                                  quiet: true,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SizedBox.square(
                            dimension: 24,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color:
                                    BistreAccentOption.tryParseHex(
                                      _hexCtrl.text,
                                    ) ??
                                    theme.accentWax,
                                shape: BoxShape.circle,
                                border: Border.all(color: theme.borderHairline),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 152),
                              child: QuillInput(
                                controller: _hexCtrl,
                                focusNode: _hexFocus,
                                placeholder: _kHexPlaceholder,
                                maxLines: 1,
                                submitOnEnter: false,
                                onChanged: (_) => setState(() {}),
                                onSubmitted: _applyCustomHex,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          EngravedButton(
                            label: l10n.t(L10nKey.settingsBudgetApplyAmount),
                            compact: true,
                            onPressed: _applyCustomHex,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceLayout),
                  trailing: BistreSegmentedControl<String>(
                    selected: s.layoutMode,
                    onSelected: (v) => unawaited(
                      ctrl.updateSettings(
                        s.copyWith(layoutMode: v),
                        quiet: true,
                      ),
                    ),
                    options: <BistreSegmentedOption<String>>[
                      BistreSegmentedOption<String>(
                        value: 'open_folio',
                        label: l10n.t(L10nKey.shellLayoutFolio),
                        leading: const BistreIcon(
                          BistreUiIcon.document,
                          size: 13,
                        ),
                      ),
                      BistreSegmentedOption<String>(
                        value: 'bubbles',
                        label: l10n.t(L10nKey.shellLayoutBubbles),
                        leading: const BistreIcon(
                          BistreUiIcon.bubbles,
                          size: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceCodeWrap),
                  description: l10n.t(L10nKey.settingsAppearanceCodeWrapHint),
                  trailing: BistreSegmentedControl<String>(
                    selected: s.codeWrapMode,
                    onSelected: (v) => unawaited(ctrl.setCodeWrapMode(v)),
                    options: <BistreSegmentedOption<String>>[
                      BistreSegmentedOption<String>(
                        value: 'auto',
                        label: l10n.t(L10nKey.settingsAppearanceCodeWrapAuto),
                      ),
                      BistreSegmentedOption<String>(
                        value: 'on',
                        label: l10n.t(L10nKey.settingsAppearanceCodeWrapOn),
                      ),
                      BistreSegmentedOption<String>(
                        value: 'off',
                        label: l10n.t(L10nKey.settingsAppearanceCodeWrapOff),
                      ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceShowTokens),
                  trailing: BistreSwitch(
                    value: s.showTokenMetrics,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsAppearanceShowTokens,
                    ),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) => unawaited(
                      ctrl.updateSettings(
                        s.copyWith(showTokenMetrics: v),
                        quiet: true,
                      ),
                    ),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceMotion),
                  trailing: BistreSegmentedControl<bool>(
                    selected: s.reduceMotionOverride,
                    onSelected: (v) => unawaited(
                      ctrl.updateSettings(
                        s.copyWith(reduceMotionOverride: v),
                        quiet: true,
                      ),
                    ),
                    options: <BistreSegmentedOption<bool>>[
                      BistreSegmentedOption<bool>(
                        value: false,
                        label: l10n.t(L10nKey.settingsAppearanceMotionSmooth),
                      ),
                      BistreSegmentedOption<bool>(
                        value: true,
                        label: l10n.t(L10nKey.settingsAppearanceMotionReduced),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s24),
            BistreSettingsSection(
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceTextSize),
                  bottom: BistreSegmentedControl<int>(
                    selected: ctrl.uiPrefs.textSizePercent,
                    onSelected: (v) => unawaited(
                      ctrl.saveUiPrefs(
                        ctrl.uiPrefs.copyWith(textSizePercent: v),
                        quiet: true,
                      ),
                    ),
                    options: <BistreSegmentedOption<int>>[
                      for (final size in UiDisplayPrefs.textSizes)
                        BistreSegmentedOption<int>(
                          value: size,
                          label: l10n.t(
                            L10nKey.settingsAppearanceTextSizeValue,
                            <String, Object?>{'percent': size},
                          ),
                        ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceCodeSize),
                  bottom: BistreSegmentedControl<int>(
                    selected: ctrl.uiPrefs.codeTextPercent,
                    onSelected: (v) => unawaited(
                      ctrl.saveUiPrefs(
                        ctrl.uiPrefs.copyWith(codeTextPercent: v),
                        quiet: true,
                      ),
                    ),
                    options: <BistreSegmentedOption<int>>[
                      for (final size in UiDisplayPrefs.textSizes)
                        BistreSegmentedOption<int>(
                          value: size,
                          label: l10n.t(
                            L10nKey.settingsAppearanceTextSizeValue,
                            <String, Object?>{'percent': size},
                          ),
                        ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceEnterSends),
                  description: s.sendOnEnter
                      ? null
                      : l10n.t(L10nKey.settingsAppearanceEnterSendsOff),
                  trailing: BistreSwitch(
                    value: s.sendOnEnter,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsAppearanceEnterSends,
                    ),
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    onChanged: (v) => unawaited(
                      ctrl.updateSettings(
                        s.copyWith(sendOnEnter: v),
                        quiet: true,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            AppearancePreferencesExtra(controller: ctrl),
          ],
        ),
      ),
    );
  }

  /// A slider's value, shown once at the row's end, with Reset beside it when changed.
  Widget _valueWithReset(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    String value,
    VoidCallback? onReset,
  ) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      InkText(value, role: InkTextRole.captionMeta, color: theme.inkSecondary),
      if (onReset != null) ...[
        const SizedBox(width: 8),
        EngravedButton(
          label: l10n.t(L10nKey.settingsAppearanceFontReset),
          compact: true,
          onPressed: onReset,
        ),
      ],
    ],
  );

  Widget _buildPreviewCard(
    BistreThemeData theme,
    BistreLocalizationController l10n,
  ) {
    return FolioSurface(
      tone: FolioTone.elevated,
      padding: const EdgeInsetsDirectional.all(20),
      borderRadius: 14,
      boxShadow: theme.cardShadow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkText(
            l10n.t(L10nKey.settingsAppearancePreviewTitle),
            role: InkTextRole.captionMeta,
            color: theme.accentBrass,
          ),
          const SizedBox(height: 10),
          InkText(l10n.t(L10nKey.settingsAppearancePreviewBody)),
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.bgSurface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.borderHairline),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 12,
                vertical: 9,
              ),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: InkText(
                  _kPreviewCode,
                  role: InkTextRole.codeBlock,
                  color: theme.inkPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFontPickerList({
    required BistreThemeData theme,
    required BistreLocalizationController l10n,
    required List<LocalFontEntry> fonts,
    required TextEditingController filterCtrl,
    required FocusNode filterFocus,
    required String filter,
    required String selectedFamily,
    required ValueChanged<String> onFilterChanged,
    required VoidCallback onReset,
    required VoidCallback onBrowse,
    required ValueChanged<LocalFontEntry> onPickFont,
  }) {
    final visible = filter.isEmpty
        ? fonts
        : fonts
              .where((f) => f.familyName.toLowerCase().contains(filter))
              .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: QuillInput(
                controller: filterCtrl,
                focusNode: filterFocus,
                placeholder: l10n.t(L10nKey.settingsAppearanceFontSearch),
                maxLines: 1,
                submitOnEnter: false,
                onSubmitted: () {},
                onChanged: onFilterChanged,
              ),
            ),
            const SizedBox(width: 8),
            EngravedButton(
              label: l10n.t(L10nKey.settingsAppearanceFontBrowse),
              compact: true,
              onPressed: onBrowse,
            ),
          ],
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 204),
          child: SmoothScrollable(
            builder: (_, scroll) => SingleChildScrollView(
              controller: scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(6, 2, 6, 4),
                    child: InkText(
                      l10n.t(L10nKey.settingsAppearanceFontsBundled),
                      role: InkTextRole.captionMeta,
                      color: theme.accentBrass,
                    ),
                  ),
                  _FontListRow(
                    label: l10n.t(L10nKey.settingsAppearanceFontDefault),
                    selected: selectedFamily.isEmpty,
                    onTap: onReset,
                  ),
                  if (visible.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(6, 8, 6, 4),
                      child: InkText(
                        l10n.t(L10nKey.settingsAppearanceFontsSystem),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                    ),
                    for (final f in visible.take(80))
                      _FontListRow(
                        label: f.familyName,
                        selected: selectedFamily == f.familyName,
                        onTap: () => onPickFont(f),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _accentLabel(BistreLocalizationController l10n, String id) =>
      switch (id) {
        'brass' => l10n.t(L10nKey.settingsAppearanceAccentBrass),
        'pine' => l10n.t(L10nKey.settingsAppearanceAccentPine),
        'cobalt' => l10n.t(L10nKey.settingsAppearanceAccentCobalt),
        'plum' => l10n.t(L10nKey.settingsAppearanceAccentPlum),
        _ => l10n.t(L10nKey.settingsAppearanceAccentWax),
      };

  static const String _kHexPlaceholder = '#A83625';
  static const String _kFontSizePlaceholder = '15';
  static const String _kPreviewCode =
      'let total = MoneyMicros(1_000_000); // exact integer USD';
}
