part of 'settings_workspace.dart';

/// Compact phone Settings layout:
/// - one compact header: Settings and a quiet Chat button at the root; on a page, a
///   Settings back button, the page icon, and its name;
/// - the root is a search field and a vertical list of page cards (tinted icon box, name, a
///   one-line summary, chevron), never a sideways tab strip;
/// - Android back and a start-edge swipe step back: search, then page, then close;
/// - root and pages cross-fade, keeping matching setting labels under each card while searching.
mixin _MobileSettings on State<SettingsWorkspace> {
  final TextEditingController _mobileQuery = TextEditingController();
  final FocusNode _mobileQueryFocus = FocusNode();

  /// The open page, or null at the root list. A general "open Settings" lands on the list;
  /// a link to a specific page (Prices, Shortcuts, Updates) opens that page.
  late SettingsTab? _mobilePage =
      widget.controller.settingsTab == SettingsTab.providers
      ? null
      : widget.controller.settingsTab;
  double _dragDx = 0;

  /// Set by the workspace on every layout; back steps only apply to the phone layout.
  bool wideLayout = true;

  void disposeMobile() {
    _mobileQuery.dispose();
    _mobileQueryFocus.dispose();
  }

  /// One step back (search, then page); false when already at the root.
  bool stepBack() {
    if (wideLayout) return false;
    if (_mobileQuery.text.isNotEmpty) {
      setState(_mobileQuery.clear);
      return true;
    }
    if (_mobilePage != null) {
      setState(() => _mobilePage = null);
      return true;
    }
    return false;
  }

  void _openMobilePage(SettingsTab tab, [String? matchLabel]) {
    widget.controller.openSettingsAt(tab, matchLabel);
    setState(() {
      _mobilePage = tab;
      _mobileQuery.clear();
    });
  }

  String _summary(BistreLocalizationController l10n, SettingsTab tab) {
    final ctrl = widget.controller;
    return switch (tab) {
      SettingsTab.providers => l10n.t(
        L10nKey.settingsSubProviders,
        <String, Object?>{
          'provider': ctrl.activeProvider?.name ?? '',
          'count': ctrl.providers.length,
        },
      ),
      SettingsTab.defaultModels => l10n.t(L10nKey.settingsSubDefaultModels),
      SettingsTab.assistants => l10n.t(
        L10nKey.settingsSubAssistants,
        <String, Object?>{'count': ctrl.assistants.length},
      ),
      SettingsTab.appearance => l10n.t(L10nKey.settingsSubAppearance),
      SettingsTab.trust => l10n.t(L10nKey.settingsSubTrust),
      SettingsTab.agent => l10n.t(L10nKey.settingsSubAgent),
      SettingsTab.memory => l10n.t(L10nKey.settingsSubMemory),
      SettingsTab.worldBook => l10n.t(L10nKey.settingsSubWorldBook),
      SettingsTab.updates => l10n.t(L10nKey.settingsSubUpdates),
      SettingsTab.language => l10n.t(L10nKey.settingsSubLanguage),
      SettingsTab.shortcuts => l10n.t(L10nKey.settingsSubShortcuts),
    };
  }

  Widget buildMobile(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final page = _mobilePage;
    final q = _mobileQuery.text.trim().toLowerCase();
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // At large text scales the page name gets its own row instead of ellipsizing beside buttons.
    final stackTitle = MediaQuery.textScalerOf(context).scale(1) >= 1.3;
    final pageEntry = page == null
        ? null
        : _kSettingsTabs.firstWhere((t) => t.$1 == page);

    final header = ColoredBox(
      color: theme.bgSurface,
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: BistreSpacing.s12,
          vertical: 10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pageEntry != null && stackTitle)
              Wrap(
                spacing: BistreSpacing.s8,
                runSpacing: BistreSpacing.s8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  EngravedButton(
                    label: l10n.t(L10nKey.settingsTitle),
                    compact: true,
                    leading: BistreIcon(
                      BistreUiIcon.chevronStart,
                      size: 13,
                      color: theme.inkSecondary,
                    ),
                    onPressed: () => setState(() => _mobilePage = null),
                  ),
                  EngravedButton(
                    label: l10n.t(L10nKey.settingsChat),
                    compact: true,
                    onPressed: ctrl.closeSettings,
                  ),
                ],
              )
            else
              Row(
                children: [
                  if (pageEntry != null) ...[
                    EngravedButton(
                      label: l10n.t(L10nKey.settingsTitle),
                      compact: true,
                      leading: BistreIcon(
                        BistreUiIcon.chevronStart,
                        size: 13,
                        color: theme.inkSecondary,
                      ),
                      onPressed: () => setState(() => _mobilePage = null),
                    ),
                    const SizedBox(width: BistreSpacing.s8),
                    Expanded(child: _pageTitle(theme, l10n, pageEntry)),
                  ] else ...[
                    BistreIcon(
                      BistreUiIcon.settings,
                      size: 17,
                      color: theme.accentBrass,
                    ),
                    const SizedBox(width: BistreSpacing.s8),
                    Expanded(
                      child: InkText(
                        l10n.t(L10nKey.settingsTitle),
                        role: InkTextRole.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  const SizedBox(width: BistreSpacing.s8),
                  EngravedButton(
                    label: l10n.t(L10nKey.settingsChat),
                    compact: true,
                    onPressed: ctrl.closeSettings,
                  ),
                ],
              ),
            if (pageEntry != null && stackTitle) ...[
              const SizedBox(height: BistreSpacing.s8),
              _pageTitle(theme, l10n, pageEntry),
            ],
            if (page == null) ...[
              const SizedBox(height: BistreSpacing.s8),
              Row(
                children: [
                  Expanded(
                    child: QuillInput(
                      controller: _mobileQuery,
                      focusNode: _mobileQueryFocus,
                      placeholder: l10n.t(L10nKey.settingsSearchPlaceholder),
                      maxLines: 1,
                      compact: true,
                      submitOnEnter: false,
                      onSubmitted: () {},
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  if (_mobileQuery.text.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    BistreIconButton(
                      icon: BistreUiIcon.close,
                      semanticsLabel: l10n.t(L10nKey.settingsClearSearch),
                      onPressed: () => setState(_mobileQuery.clear),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );

    final Widget body;
    if (page != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ctrl.highlightedSettingKey != null &&
              ctrl.highlightedSettingKey!.isNotEmpty)
            _HighlightedSettingBanner(
              label: ctrl.highlightedSettingKey!,
              onDismiss: ctrl.clearHighlightedSetting,
            ),
          Expanded(child: _buildActivePage(ctrl, page)),
        ],
      );
    } else {
      final visible = [
        for (final t in _kSettingsTabs)
          if (_tabMatches(l10n, t, q)) t,
      ];
      body = SmoothScrollable(
        builder: (_, scroll) => SingleChildScrollView(
          controller: scroll,
          padding: const EdgeInsetsDirectional.all(BistreSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final t in visible) ...[
                _MobileSettingsCard(
                  icon: t.$3,
                  label: l10n.t(t.$2),
                  summary: _summary(l10n, t.$1),
                  matches: _matchingLabels(l10n, t.$1, q),
                  onTap: () {
                    final m = _matchingLabels(l10n, t.$1, q);
                    _openMobilePage(t.$1, m.isEmpty ? null : m.first);
                  },
                ),
                const SizedBox(height: 10),
              ],
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.all(BistreSpacing.s8),
                  child: InkText(
                    l10n.t(L10nKey.settingsSearchEmpty),
                    role: InkTextRole.captionMeta,
                    color: theme.inkMuted,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const FolioDivider(),
        Expanded(
          // A 72 dp swipe from the start edge toward the end steps back.
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => _dragDx = 0,
            onHorizontalDragUpdate: (d) =>
                _dragDx += rtl ? -d.delta.dx : d.delta.dx,
            onHorizontalDragEnd: (_) {
              if (_dragDx > 72 && !stepBack()) ctrl.closeSettings();
              _dragDx = 0;
            },
            child: FolioFadeSlide(
              key: ValueKey<SettingsTab?>(page),
              beginOffset: Offset.zero,
              reduceMotionOverride: ctrl.reduceMotionOverride,
              child: body,
            ),
          ),
        ),
      ],
    );
  }

  Widget _pageTitle(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    (SettingsTab, L10nKey, BistreUiIcon) entry,
  ) => Row(
    children: [
      BistreIcon(entry.$3, size: 17, color: theme.accentBrass),
      const SizedBox(width: BistreSpacing.s8),
      Expanded(
        child: InkText(
          l10n.t(entry.$2),
          role: InkTextRole.labelStrong,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );

  Widget _buildActivePage(FolioController ctrl, SettingsTab tab) {
    return switch (tab) {
      SettingsTab.providers => ProvidersSettingsView(controller: ctrl),
      SettingsTab.defaultModels => DefaultModelsSettingsView(controller: ctrl),
      SettingsTab.assistants => AssistantsSettingsView(controller: ctrl),
      SettingsTab.appearance => AppearanceSettingsView(controller: ctrl),
      SettingsTab.trust => BudgetSafetySettingsView(controller: ctrl),
      SettingsTab.agent => AgentToolsSettingsView(controller: ctrl),
      SettingsTab.memory => MemorySkillsSettingsView(controller: ctrl),
      SettingsTab.worldBook => WorldbookCardsSettingsView(controller: ctrl),
      SettingsTab.updates => UpdatesStorageSettingsView(controller: ctrl),
      SettingsTab.language => LanguageSettingsView(controller: ctrl),
      SettingsTab.shortcuts => ShortcutsSettingsView(controller: ctrl),
    };
  }
}

/// One page in the phone list: tinted icon box, name, summary, chevron.
class _MobileSettingsCard extends StatelessWidget {
  const _MobileSettingsCard({
    required this.icon,
    required this.label,
    required this.summary,
    required this.matches,
    required this.onTap,
  });

  final BistreUiIcon icon;
  final String label;
  final String summary;
  final List<String> matches;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Semantics(
      button: true,
      label: label,
      hint: summary,
      excludeSemantics: true,
      child: FocusableActionDetector(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        mouseCursor: SystemMouseCursors.click,
        child: PressFeedback(
          pressScale: kRowPressScale,
          hoverScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.bgElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.borderHairline),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 36,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.accentBrass.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: theme.accentBrass.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Center(
                          child: BistreIcon(
                            icon,
                            size: 18,
                            color: theme.accentBrass,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: BistreSpacing.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkText(label, role: InkTextRole.labelStrong),
                          const SizedBox(height: 2),
                          InkText(
                            summary,
                            role: InkTextRole.captionMeta,
                            color: theme.inkSecondary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          for (final m in matches)
                            InkText(
                              m,
                              role: InkTextRole.captionMeta,
                              color: theme.accentBrass,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    BistreIcon(
                      BistreUiIcon.chevronEnd,
                      size: 16,
                      color: theme.inkMuted,
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
