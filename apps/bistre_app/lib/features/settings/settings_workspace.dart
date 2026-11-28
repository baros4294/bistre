import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import 'agent_tools_settings_view.dart';
import 'appearance_settings_view.dart';
import 'assistants_settings_view.dart';
import 'budget_safety_settings_view.dart';
import 'default_models_settings_view.dart';
import 'language_settings_view.dart';
import 'memory_skills_settings_view.dart';
import 'projects_settings_view.dart';
import 'providers_settings_view.dart';
import 'shortcuts_settings_view.dart';
import 'updates_storage_settings_view.dart';
import 'worldbook_cards_settings_view.dart';

part 'settings_mobile.dart';

/// Settings pages in list order (wide nav and phone list).
const List<(SettingsTab, L10nKey, BistreUiIcon)>
_kSettingsTabs = <(SettingsTab, L10nKey, BistreUiIcon)>[
  (SettingsTab.providers, L10nKey.settingsTabProviders, BistreUiIcon.key),
  (
    SettingsTab.defaultModels,
    L10nKey.settingsTabDefaultModels,
    BistreUiIcon.think,
  ),
  (
    SettingsTab.assistants,
    L10nKey.settingsTabAssistants,
    BistreUiIcon.assistant,
  ),
  (SettingsTab.projects, L10nKey.settingsTabProjects, BistreUiIcon.folder),
  (SettingsTab.appearance, L10nKey.settingsTabAppearance, BistreUiIcon.palette),
  (SettingsTab.trust, L10nKey.settingsTabTrust, BistreUiIcon.shield),
  (SettingsTab.agent, L10nKey.settingsTabAgent, BistreUiIcon.code),
  (SettingsTab.memory, L10nKey.settingsTabMemory, BistreUiIcon.memory),
  (SettingsTab.worldBook, L10nKey.settingsTabWorldBook, BistreUiIcon.document),
  (SettingsTab.updates, L10nKey.settingsTabUpdates, BistreUiIcon.download),
  (SettingsTab.language, L10nKey.settingsTabLanguage, BistreUiIcon.globe),
  (SettingsTab.shortcuts, L10nKey.settingsTabShortcuts, BistreUiIcon.keyboard),
];

/// Full-window Studio Atelier Settings Workspace replacing the cramped modal popup.
/// Provides generous breathing room for Providers & Keys, Assistants, Appearance/Fonts,
/// Safety & Unlimited Budget, Updates & Local Storage, Language, and Custom Shortcuts.
///
/// At 720 px and wider the page list sits beside the page. Narrower windows (phones, large
/// text) use the compact phone layout (`settings_mobile.dart`): a card list of pages,
/// one page at a time, with Android back and a start-edge swipe stepping back.
class SettingsWorkspace extends StatefulWidget {
  const SettingsWorkspace({super.key, required this.controller});

  final FolioController controller;

  @override
  State<SettingsWorkspace> createState() => _SettingsWorkspaceState();
}

class _SettingsWorkspaceState extends State<SettingsWorkspace>
    with WidgetsBindingObserver, _MobileSettings {
  FolioController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    disposeMobile();
    super.dispose();
  }

  /// Android back order: clear the search, then leave the page, then close Settings.
  @override
  Future<bool> didPopRoute() async {
    if (!mounted) return false;
    if (stepBack()) return true;
    controller.closeSettings();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = controller;

    return ColoredBox(
      color: theme.bgCanvas,
      child: FolioFadeSlide(
        beginOffset: const Offset(0, 0.015),
        reduceMotionOverride: ctrl.reduceMotionOverride,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 720;
            wideLayout = isWide;
            if (!isWide) return buildMobile(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsTopBar(
                  title: l10n.t(L10nKey.settingsTitle),
                  backLabel: l10n.t(L10nKey.settingsBackToChat),
                  onBack: ctrl.closeSettings,
                ),
                const FolioDivider(),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ...[
                        SizedBox(
                          width: textScaledWidth(context, 232),
                          child: ColoredBox(
                            color: theme.bgSurface.withValues(
                              alpha: theme.isDark ? 0.55 : 0.65,
                            ),
                            child: _SearchableSettingsNav(
                              tabs: _kSettingsTabs,
                              selected: ctrl.settingsTab,
                              onSelected: ctrl.openSettingsAt,
                            ),
                          ),
                        ),
                        const FolioDivider(vertical: true),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (ctrl.highlightedSettingKey != null &&
                                ctrl.highlightedSettingKey!.isNotEmpty)
                              _HighlightedSettingBanner(
                                label: ctrl.highlightedSettingKey!,
                                onDismiss: ctrl.clearHighlightedSetting,
                              ),
                            Expanded(
                              child: FolioFadeSlide(
                                key: ValueKey<SettingsTab>(ctrl.settingsTab),
                                beginOffset: const Offset(0, 0.012),
                                reduceMotionOverride: ctrl.reduceMotionOverride,
                                child: _buildActiveView(ctrl),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildActiveView(FolioController ctrl) {
    return switch (ctrl.settingsTab) {
      SettingsTab.providers => ProvidersSettingsView(controller: ctrl),
      SettingsTab.defaultModels => DefaultModelsSettingsView(controller: ctrl),
      SettingsTab.assistants => AssistantsSettingsView(controller: ctrl),
      SettingsTab.projects => ProjectsSettingsView(controller: ctrl),
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

class _SettingsTopBar extends StatelessWidget {
  const _SettingsTopBar({
    required this.title,
    required this.backLabel,
    required this.onBack,
  });

  final String title;
  final String backLabel;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return ColoredBox(
      color: theme.bgCanvas,
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: BistreSpacing.s16,
          vertical: 10,
        ),
        child: Row(
          children: [
            EngravedButton(
              label: backLabel,
              compact: true,
              leading: BistreIcon(
                BistreUiIcon.arrowBack,
                size: 14,
                color: theme.inkPrimary,
              ),
              onPressed: onBack,
            ),
            const SizedBox(width: 14),
            SizedBox(
              height: 18,
              width: 1,
              child: ColoredBox(color: theme.borderHairline),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: InkText(
                title,
                role: InkTextRole.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsNavTile extends StatefulWidget {
  const _SettingsNavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final BistreUiIcon icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SettingsNavTile> createState() => _SettingsNavTileState();
}

class _SettingsNavTileState extends State<_SettingsNavTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: FocusableActionDetector(
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
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
                  border: _focused
                      ? Border.all(color: theme.accentBrass, width: 1.5)
                      : (widget.selected
                            ? Border.all(color: theme.borderHairline)
                            : null),
                  boxShadow: widget.selected ? theme.cardShadow : null,
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 11,
                    vertical: 9,
                  ),
                  child: Row(
                    children: [
                      // Active category: the single bold rubric mark.
                      if (widget.selected)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8),
                          child: SizedBox(
                            width: kRubricMarkWidth,
                            height: 16,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.accentWax,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      BistreIcon(
                        widget.icon,
                        size: 15,
                        color: widget.selected
                            ? theme.accentBrass
                            : theme.inkSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: InkText(
                          widget.label,
                          role: widget.selected
                              ? InkTextRole.labelStrong
                              : InkTextRole.bodyCompact,
                          color: widget.selected
                              ? theme.inkPrimary
                              : theme.inkSecondary,
                          maxLines: 1,
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

/// Catalog key prefixes whose text belongs to each settings page; searching matches the page
/// name and every label on it.
const Map<SettingsTab, List<String>> settingsSearchPrefixes =
    <SettingsTab, List<String>>{
      SettingsTab.providers: <String>[
        'provider.',
        'settings.provider',
        'settings.model',
        'settings.tab.providers',
      ],
      SettingsTab.defaultModels: <String>['settings.default_models'],
      SettingsTab.assistants: <String>['settings.assistants', 'assistant.'],
      SettingsTab.appearance: <String>[
        'settings.appearance',
        'settings.prefs',
        'settings.desktop',
        'settings.profile',
      ],
      SettingsTab.trust: <String>[
        'settings.trust',
        'settings.budget',
        'settings.prices',
      ],
      SettingsTab.agent: <String>[
        'settings.agent',
        'settings.sleep',
        'settings.engine',
      ],
      SettingsTab.memory: <String>[
        'memory.',
        'automations.',
        'skills.',
        'settings.tab.memory',
      ],
      SettingsTab.worldBook: <String>['settings.world_book'],
      SettingsTab.projects: <String>['settings.projects'],
      SettingsTab.updates: <String>['settings.ota', 'settings.storage'],
      SettingsTab.language: <String>['settings.language'],
      SettingsTab.shortcuts: <String>['shortcut.', 'shortcuts.'],
    };

/// Whether [tab] matches the lower-cased query by its name or any label on it.
bool _tabMatches(
  BistreLocalizationController l10n,
  (SettingsTab, L10nKey, BistreUiIcon) tab,
  String q,
) {
  if (q.isEmpty || l10n.t(tab.$2).toLowerCase().contains(q)) return true;
  final prefixes = settingsSearchPrefixes[tab.$1] ?? const <String>[];
  return L10nKey.values.any(
    (k) =>
        prefixes.any(k.key.startsWith) && l10n.t(k).toLowerCase().contains(q),
  );
}

/// The settings on [tab] whose label matches [q] (short labels only, not hints), so the
/// results say which setting matched.
List<String> _matchingLabels(
  BistreLocalizationController l10n,
  SettingsTab tab,
  String q,
) {
  if (q.isEmpty) return const <String>[];
  final prefixes = settingsSearchPrefixes[tab] ?? const <String>[];
  final out = <String>{};
  for (final k in L10nKey.values) {
    if (!prefixes.any(k.key.startsWith)) continue;
    final text = l10n.t(k);
    if (text.length > 48 || text.contains('{')) continue;
    if (text.toLowerCase().contains(q)) out.add(text);
    if (out.length == 3) break;
  }
  return out.toList();
}

class _SearchableSettingsNav extends StatefulWidget {
  const _SearchableSettingsNav({
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  final List<(SettingsTab, L10nKey, BistreUiIcon)> tabs;
  final SettingsTab selected;
  final void Function(SettingsTab tab, [String? matchLabel]) onSelected;

  @override
  State<_SearchableSettingsNav> createState() => _SearchableSettingsNavState();
}

class _SearchableSettingsNavState extends State<_SearchableSettingsNav> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    final theme = BistreTheme.of(context);
    final q = _query.text.trim().toLowerCase();
    final visible = widget.tabs.where((t) => _tabMatches(l10n, t, q)).toList();
    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.fromSTEB(12, 16, 12, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            QuillInput(
              controller: _query,
              focusNode: _focus,
              placeholder: l10n.t(L10nKey.settingsSearchPlaceholder),
              maxLines: 1,
              submitOnEnter: false,
              onSubmitted: () {
                if (visible.isNotEmpty) widget.onSelected(visible.first.$1);
              },
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: BistreSpacing.s12),
            for (final t in visible) ...[
              _SettingsNavTile(
                icon: t.$3,
                label: l10n.t(t.$2),
                selected: widget.selected == t.$1,
                onTap: () => widget.onSelected(t.$1),
              ),
              const SizedBox(height: 3),
              for (final label in _matchingLabels(l10n, t.$1, q))
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 36,
                    bottom: 3,
                  ),
                  child: PressFeedback(
                    pressScale: kRowPressScale,
                    hoverScale: 1,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.onSelected(t.$1, label),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.symmetric(
                          vertical: 4,
                        ),
                        child: InkText(
                          label,
                          role: InkTextRole.captionMeta,
                          color: theme.inkSecondary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
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
}

class _HighlightedSettingBanner extends StatelessWidget {
  const _HighlightedSettingBanner({
    required this.label,
    required this.onDismiss,
  });

  final String label;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.accentBrass.withValues(alpha: theme.isDark ? 0.18 : 0.12),
        border: Border(bottom: BorderSide(color: theme.borderHairline)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 18,
          vertical: 8,
        ),
        child: Row(
          children: [
            BistreIcon(BistreUiIcon.search, size: 14, color: theme.accentBrass),
            const SizedBox(width: 8),
            Expanded(
              child: InkText(
                label,
                role: InkTextRole.labelStrong,
                color: theme.inkPrimary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            BistreIconButton(
              icon: BistreUiIcon.close,
              size: 13,
              dimension: 28,
              semanticsLabel: l10n.t(L10nKey.settingsClearSearch),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
