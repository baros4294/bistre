import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../../platform/font_manager.dart';
import '../shell/folio_controller.dart';

/// End-user Appearance & Typography Studio — ZERO forced presets:
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
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
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
      filterLabel: 'Fonts',
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
            // Live Typography & Theme Preview Card
            _buildPreviewCard(theme, l10n),
            const SizedBox(height: BistreSpacing.s16),

            // Section 1: Typography & Local Custom Fonts (directly under Live Preview)
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsAppearanceTypographySection),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceProseFont),
                  description: s.proseFontFamily.isNotEmpty
                      ? s.proseFontFamily
                      : '${l10n.t(L10nKey.settingsAppearanceFontDefault)} (Inter)',
                  trailing: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 6,
                    children: [
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsAppearanceFontBrowse),
                        compact: true,
                        leading: BistreIcon(
                          BistreUiIcon.font,
                          size: 13,
                          color: theme.accentBrass,
                        ),
                        onPressed: () =>
                            unawaited(_browseLocalFont(isMono: false)),
                      ),
                      if (s.proseFontFamily.isNotEmpty ||
                          s.proseFontPath.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        EngravedButton(
                          label: l10n.t(L10nKey.settingsAppearanceFontReset),
                          compact: true,
                          onPressed: () => unawaited(ctrl.resetProseFont()),
                        ),
                      ],
                      const SizedBox(width: 6),
                      BistreIconButton(
                        icon: _prosePickerOpen
                            ? BistreUiIcon.chevronUp
                            : BistreUiIcon.chevronDown,
                        semanticsLabel: l10n.t(
                          L10nKey.settingsAppearanceProseFont,
                        ),
                        onPressed: () => setState(
                          () => _prosePickerOpen = !_prosePickerOpen,
                        ),
                      ),
                    ],
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
                  description: s.monoFontFamily.isNotEmpty
                      ? s.monoFontFamily
                      : '${l10n.t(L10nKey.settingsAppearanceFontDefault)} (JetBrainsMono)',
                  trailing: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 6,
                    children: [
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsAppearanceFontBrowse),
                        compact: true,
                        leading: BistreIcon(
                          BistreUiIcon.code,
                          size: 13,
                          color: theme.accentBrass,
                        ),
                        onPressed: () =>
                            unawaited(_browseLocalFont(isMono: true)),
                      ),
                      if (s.monoFontFamily.isNotEmpty ||
                          s.monoFontPath.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        EngravedButton(
                          label: l10n.t(L10nKey.settingsAppearanceFontReset),
                          compact: true,
                          onPressed: () => unawaited(ctrl.resetMonoFont()),
                        ),
                      ],
                      const SizedBox(width: 6),
                      BistreIconButton(
                        icon: _monoPickerOpen
                            ? BistreUiIcon.chevronUp
                            : BistreUiIcon.chevronDown,
                        semanticsLabel: l10n.t(
                          L10nKey.settingsAppearanceMonoFont,
                        ),
                        onPressed: () =>
                            setState(() => _monoPickerOpen = !_monoPickerOpen),
                      ),
                    ],
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
                  label: l10n.t(
                    L10nKey.settingsAppearanceFontSizePx,
                    <String, Object?>{'px': s.fontSizePx},
                  ),
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
                      const SizedBox(width: 8),
                      if (s.fontSizePx != 15)
                        EngravedButton(
                          label: l10n.t(L10nKey.settingsAppearanceFontReset),
                          compact: true,
                          onPressed: () => _commitFontSizePx(15),
                        ),
                    ],
                  ),
                  bottom: BistreSlider(
                    value: s.fontSizePx.clamp(12, 28).toDouble(),
                    min: 12,
                    max: 28,
                    step: 1,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsAppearanceFontSizePx,
                      <String, Object?>{'px': s.fontSizePx},
                    ),
                    onChanged: (v) => _commitFontSizePx(v.round()),
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(
                    L10nKey.settingsAppearanceLineHeight,
                    <String, Object?>{
                      'value': lineHeightVal.toStringAsFixed(2),
                    },
                  ),
                  trailing: s.lineHeightBps != 16000
                      ? EngravedButton(
                          label: l10n.t(L10nKey.settingsAppearanceFontReset),
                          compact: true,
                          onPressed: () => unawaited(
                            ctrl.updateSettings(
                              s.copyWith(lineHeightBps: 16000),
                              quiet: true,
                            ),
                          ),
                        )
                      : null,
                  bottom: BistreSlider(
                    value: lineHeightVal,
                    min: 1.30,
                    max: 2.00,
                    step: 0.05,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsAppearanceLineHeight,
                      <String, Object?>{
                        'value': lineHeightVal.toStringAsFixed(2),
                      },
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
                  label: l10n.t(
                    L10nKey.settingsAppearanceReadingWidth,
                    <String, Object?>{'px': s.readingWidthPx},
                  ),
                  trailing: s.readingWidthPx != 760
                      ? EngravedButton(
                          label: l10n.t(L10nKey.settingsAppearanceFontReset),
                          compact: true,
                          onPressed: () => unawaited(
                            ctrl.updateSettings(
                              s.copyWith(readingWidthPx: 760),
                              quiet: true,
                            ),
                          ),
                        )
                      : null,
                  bottom: BistreSlider(
                    value: s.readingWidthPx.clamp(600, 1120).toDouble(),
                    min: 600,
                    max: 1120,
                    step: 20,
                    semanticsLabel: l10n.t(
                      L10nKey.settingsAppearanceReadingWidth,
                      <String, Object?>{'px': s.readingWidthPx},
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
                    selected: s.theme,
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
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsAppearanceSendEnter),
                  trailing: BistreSwitch(
                    value: s.sendOnEnter,
                    semanticsLabel: l10n.t(L10nKey.settingsAppearanceSendEnter),
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
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewCard(
    BistreThemeData theme,
    BistreLocalizationController l10n,
  ) {
    final fontSpecBadge = l10n.joinMeta(<String>[
      theme.typography.proseFontFamily,
      '${theme.typography.baseFontSizePx.round()}px',
    ]);
    return FolioSurface(
      tone: FolioTone.elevated,
      padding: const EdgeInsetsDirectional.all(20),
      borderRadius: 14,
      boxShadow: theme.cardShadow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: BistreSpacing.s8,
            runSpacing: BistreSpacing.s4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InkText(
                l10n.t(L10nKey.settingsAppearancePreviewTitle),
                role: InkTextRole.captionMeta,
                color: theme.accentBrass,
              ),
              WaxSealBadge(label: fontSpecBadge, status: WaxSealStatus.neutral),
            ],
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
        QuillInput(
          controller: filterCtrl,
          focusNode: filterFocus,
          placeholder: l10n.t(L10nKey.sidebarFilterPlaceholder),
          maxLines: 1,
          submitOnEnter: false,
          onSubmitted: () {},
          onChanged: onFilterChanged,
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 176),
          child: SmoothScrollable(
            builder: (_, scroll) => SingleChildScrollView(
              controller: scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _FontListRow(
                    label: l10n.t(L10nKey.settingsAppearanceFontDefault),
                    selected: selectedFamily.isEmpty,
                    onTap: onReset,
                  ),
                  for (final f in visible.take(60))
                    _FontListRow(
                      label: f.familyName,
                      selected: selectedFamily == f.familyName,
                      onTap: () => onPickFont(f),
                    ),
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
                  InkText(
                    widget.label,
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
