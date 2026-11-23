import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import 'agent_tools_settings_view.dart';
import 'appearance_settings_view.dart';
import 'assistants_settings_view.dart';
import 'budget_safety_settings_view.dart';
import 'language_settings_view.dart';
import 'memory_skills_settings_view.dart';
import 'providers_settings_view.dart';
import 'shortcuts_settings_view.dart';
import 'updates_storage_settings_view.dart';

/// Full-window Studio Atelier Settings Workspace replacing the cramped modal popup.
/// Provides generous breathing room for Providers & Keys, Assistants, Appearance/Fonts,
/// Safety & Unlimited Budget, Updates & Local Storage, Language, and Custom Shortcuts.
class SettingsWorkspace extends StatelessWidget {
  const SettingsWorkspace({super.key, required this.controller});

  final FolioController controller;

  static const List<(SettingsTab, L10nKey, BistreUiIcon)> _tabs =
      <(SettingsTab, L10nKey, BistreUiIcon)>[
        (SettingsTab.providers, L10nKey.settingsTabProviders, BistreUiIcon.key),
        (
          SettingsTab.assistants,
          L10nKey.settingsTabAssistants,
          BistreUiIcon.assistant,
        ),
        (
          SettingsTab.appearance,
          L10nKey.settingsTabAppearance,
          BistreUiIcon.palette,
        ),
        (SettingsTab.trust, L10nKey.settingsTabTrust, BistreUiIcon.shield),
        (SettingsTab.agent, L10nKey.settingsTabAgent, BistreUiIcon.code),
        (SettingsTab.memory, L10nKey.settingsTabMemory, BistreUiIcon.memory),
        (
          SettingsTab.updates,
          L10nKey.settingsTabUpdates,
          BistreUiIcon.download,
        ),
        (SettingsTab.language, L10nKey.settingsTabLanguage, BistreUiIcon.globe),
        (
          SettingsTab.shortcuts,
          L10nKey.settingsTabShortcuts,
          BistreUiIcon.keyboard,
        ),
      ];

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
            final isWide = constraints.maxWidth >= 780;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SettingsTopBar(
                  title: l10n.t(L10nKey.settingsTitle),
                  backLabel: l10n.t(L10nKey.settingsBackToChat),
                  onBack: ctrl.closeSettings,
                ),
                const FolioDivider(),
                if (!isWide) ...[
                  _NarrowTabStrip(
                    tabs: _tabs,
                    selected: ctrl.settingsTab,
                    onSelected: ctrl.setSettingsTab,
                  ),
                  const FolioDivider(),
                ],
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (isWide) ...[
                        SizedBox(
                          width: textScaledWidth(context, 232),
                          child: ColoredBox(
                            color: theme.bgSurface.withValues(
                              alpha: theme.isDark ? 0.55 : 0.65,
                            ),
                            child: _SearchableSettingsNav(
                              tabs: _tabs,
                              selected: ctrl.settingsTab,
                              onSelected: ctrl.setSettingsTab,
                            ),
                          ),
                        ),
                        const FolioDivider(vertical: true),
                      ],
                      Expanded(child: _buildActiveView(ctrl)),
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
      SettingsTab.assistants => AssistantsSettingsView(controller: ctrl),
      SettingsTab.appearance => AppearanceSettingsView(controller: ctrl),
      SettingsTab.trust => BudgetSafetySettingsView(controller: ctrl),
      SettingsTab.agent => AgentToolsSettingsView(controller: ctrl),
      SettingsTab.memory => MemorySkillsSettingsView(controller: ctrl),
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
            BistreIconButton(
              icon: BistreUiIcon.close,
              semanticsLabel: backLabel,
              onPressed: onBack,
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
    );
  }
}

class _NarrowTabStrip extends StatelessWidget {
  const _NarrowTabStrip({
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  final List<(SettingsTab, L10nKey, BistreUiIcon)> tabs;
  final SettingsTab selected;
  final ValueChanged<SettingsTab> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    final theme = BistreTheme.of(context);
    return ColoredBox(
      color: theme.bgSurface.withValues(alpha: 0.65),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              InkChip(
                label: l10n.t(tabs[i].$2),
                selected: selected == tabs[i].$1,
                onSelected: () => onSelected(tabs[i].$1),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Catalog key prefixes whose text belongs to each settings page; searching matches the page
/// name and every label on it ("Search all settings", Parchment v2.6.0).
const Map<SettingsTab, List<String>> _searchPrefixes =
    <SettingsTab, List<String>>{
      SettingsTab.providers: <String>['provider.', 'settings.tab.providers'],
      SettingsTab.assistants: <String>['settings.assistants', 'assistant.'],
      SettingsTab.appearance: <String>['settings.appearance'],
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
      SettingsTab.memory: <String>['memory.', 'cron.', 'settings.tab.memory'],
      SettingsTab.updates: <String>['settings.ota', 'settings.storage'],
      SettingsTab.language: <String>['settings.language'],
      SettingsTab.shortcuts: <String>['shortcut.'],
    };

class _SearchableSettingsNav extends StatefulWidget {
  const _SearchableSettingsNav({
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  final List<(SettingsTab, L10nKey, BistreUiIcon)> tabs;
  final SettingsTab selected;
  final ValueChanged<SettingsTab> onSelected;

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

  bool _matches(
    BistreLocalizationController l10n,
    (SettingsTab, L10nKey, BistreUiIcon) tab,
    String q,
  ) {
    if (q.isEmpty || l10n.t(tab.$2).toLowerCase().contains(q)) return true;
    final prefixes = _searchPrefixes[tab.$1] ?? const <String>[];
    return L10nKey.values.any(
      (k) =>
          prefixes.any(k.key.startsWith) && l10n.t(k).toLowerCase().contains(q),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    final theme = BistreTheme.of(context);
    final q = _query.text.trim().toLowerCase();
    final visible = widget.tabs.where((t) => _matches(l10n, t, q)).toList();
    return SingleChildScrollView(
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
    );
  }
}
