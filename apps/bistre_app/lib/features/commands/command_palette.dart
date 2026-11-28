import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Instant keyboard-driven Command Menu across Actions, Chats, and Assistants.
class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.controller,
    required this.onTriggerSearch,
  });

  final FolioController controller;
  final VoidCallback onTriggerSearch;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  String _query = '';
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _queryFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  List<_PaletteEntry> _buildEntries(
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final actionsSection = l10n.t(L10nKey.paletteSectionActions);
    final chatsSection = l10n.t(L10nKey.paletteSectionFolios);
    final assistantsSection = l10n.t(L10nKey.paletteSectionAssistants);

    final all = <_PaletteEntry>[
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.key,
        label: l10n.t(L10nKey.settingsTabProviders),
        shortcut: ctrl.shortcutFor('settings'),
        isKeyCombo: true,
        onRun: ctrl.openSettings,
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.newChat,
        label: l10n.t(L10nKey.shortcutNewFolio),
        shortcut: ctrl.shortcutFor('new_chat'),
        isKeyCombo: true,
        onRun: () => unawaited(ctrl.createNewFolio()),
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.sliders,
        label: l10n.t(L10nKey.chatInspectorTitle),
        shortcut: '',
        isKeyCombo: false,
        onRun: ctrl.toggleInspector,
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.sidebar,
        label: l10n.t(L10nKey.shortcutSidebar),
        shortcut: ctrl.shortcutFor('sidebar'),
        isKeyCombo: true,
        onRun: ctrl.toggleSidebar,
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: ctrl.isDark ? BistreUiIcon.sun : BistreUiIcon.moon,
        label: l10n.t(L10nKey.shortcutTheme),
        shortcut: ctrl.shortcutFor('theme'),
        isKeyCombo: true,
        onRun: ctrl.toggleTheme,
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: ctrl.layoutMode == FolioLayoutMode.openFolio
            ? BistreUiIcon.bubbles
            : BistreUiIcon.document,
        label: l10n.t(L10nKey.shortcutLayout),
        shortcut: ctrl.shortcutFor('layout'),
        isKeyCombo: true,
        onRun: ctrl.toggleLayoutMode,
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.search,
        label: l10n.t(L10nKey.shortcutSearch),
        shortcut: ctrl.shortcutFor('search'),
        isKeyCombo: true,
        onRun: widget.onTriggerSearch,
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.think,
        label: l10n.t(L10nKey.settingsTabDefaultModels),
        shortcut: '',
        isKeyCombo: false,
        onRun: () => ctrl.openSettings(SettingsTab.defaultModels),
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.document,
        label: l10n.t(L10nKey.settingsTabWorldBook),
        shortcut: '',
        isKeyCombo: false,
        onRun: () => ctrl.openSettings(SettingsTab.worldBook),
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.server,
        label: l10n.t(L10nKey.studioTitle),
        shortcut: '',
        isKeyCombo: false,
        onRun: ctrl.toggleStudioPane,
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.sidebar,
        label: l10n.t(L10nKey.paletteSplitView),
        shortcut: '',
        isKeyCombo: false,
        onRun: ctrl.toggleSplitView,
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.download,
        label: l10n.t(L10nKey.settingsTabUpdates),
        shortcut: '',
        isKeyCombo: false,
        onRun: () => ctrl.openSettings(SettingsTab.updates),
      ),
      _PaletteEntry(
        section: actionsSection,
        icon: BistreUiIcon.keyboard,
        label: l10n.t(L10nKey.shortcutShortcuts),
        shortcut: ctrl.shortcutFor('shortcuts'),
        isKeyCombo: true,
        onRun: () => ctrl.openSettings(SettingsTab.shortcuts),
      ),
      for (final thread in ctrl.threads)
        _PaletteEntry(
          section: chatsSection,
          icon: thread.isPinned ? BistreUiIcon.pinFilled : BistreUiIcon.chat,
          label: thread.title,
          shortcut: '',
          isKeyCombo: false,
          onRun: () => unawaited(ctrl.selectThread(thread.id)),
        ),
      for (final assistant in ctrl.assistants)
        _PaletteEntry(
          section: assistantsSection,
          icon: BistreUiIcon.assistant,
          label: assistant.name,
          shortcut: assistant.roleSubtitle,
          isKeyCombo: false,
          onRun: () => unawaited(ctrl.selectAssistant(assistant.id)),
        ),
    ];

    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where(
          (e) =>
              e.label.toLowerCase().contains(q) ||
              e.section.toLowerCase().contains(q) ||
              e.shortcut.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  void _runEntry(_PaletteEntry entry) {
    widget.controller.closeCommandPalette();
    entry.onRun();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final entries = _buildEntries(l10n, ctrl);
    final clampedIndex = entries.isEmpty
        ? 0
        : _selectedIndex.clamp(0, entries.length - 1);

    return FolioModalBackdrop(
      onDismiss: ctrl.closeCommandPalette,
      reduceMotionOverride: ctrl.reduceMotionOverride,
      alignment: AlignmentDirectional.topCenter,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          BistreSpacing.s16,
          68,
          BistreSpacing.s16,
          BistreSpacing.s16,
        ),
        child: Focus(
          onKeyEvent: (_, event) {
            // Arrows and Enter belong to the IME while it composes.
            if (event is! KeyDownEvent ||
                _queryController.value.composing.isValid) {
              return KeyEventResult.ignored;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
                entries.isNotEmpty) {
              setState(
                () => _selectedIndex = (clampedIndex + 1) % entries.length,
              );
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                entries.isNotEmpty) {
              setState(
                () => _selectedIndex =
                    (clampedIndex - 1 + entries.length) % entries.length,
              );
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.enter &&
                entries.isNotEmpty) {
              _runEntry(entries[clampedIndex]);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580, maxHeight: 460),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                boxShadow: theme.floatingShadow,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: FolioSurface(
                  tone: FolioTone.elevated,
                  padding: EdgeInsetsDirectional.zero,
                  borderRadius: 14,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          16,
                          13,
                          12,
                          13,
                        ),
                        child: Row(
                          children: [
                            BistreIcon(
                              BistreUiIcon.search,
                              size: 16,
                              color: theme.accentBrass,
                            ),
                            const SizedBox(width: BistreSpacing.s12),
                            Expanded(
                              child: QuillInput(
                                controller: _queryController,
                                focusNode: _queryFocus,
                                placeholder: l10n.t(L10nKey.palettePlaceholder),
                                maxLines: 1,
                                submitOnEnter: false,
                                frameless: true,
                                onSubmitted: () {
                                  if (entries.isNotEmpty) {
                                    _runEntry(entries[clampedIndex]);
                                  }
                                },
                                onChanged: (q) => setState(() {
                                  _query = q;
                                  _selectedIndex = 0;
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const FolioDivider(),
                      Flexible(
                        child: entries.isEmpty
                            ? Padding(
                                padding: const EdgeInsetsDirectional.all(
                                  BistreSpacing.s24,
                                ),
                                child: InkText(
                                  l10n.t(L10nKey.paletteEmpty),
                                  role: InkTextRole.bodyCompact,
                                  color: theme.inkMuted,
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ClipRect(
                                child: SmoothScrollable(
                                  builder: (_, scroll) => ListView.builder(
                                    controller: scroll,
                                    shrinkWrap: true,
                                    padding:
                                        const EdgeInsetsDirectional.fromSTEB(
                                          8,
                                          6,
                                          8,
                                          10,
                                        ),
                                    itemCount: entries.length,
                                    itemBuilder: (context, index) {
                                      final entry = entries[index];
                                      final showHeader =
                                          index == 0 ||
                                          entries[index - 1].section !=
                                              entry.section;
                                      final isSelected = index == clampedIndex;

                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          if (showHeader)
                                            Padding(
                                              padding:
                                                  EdgeInsetsDirectional.fromSTEB(
                                                    10,
                                                    index == 0 ? 4 : 10,
                                                    10,
                                                    4,
                                                  ),
                                              child: InkText(
                                                entry.section,
                                                role: InkTextRole.captionMeta,
                                                color: theme.inkMuted,
                                              ),
                                            ),
                                          MouseRegion(
                                            cursor: SystemMouseCursors.click,
                                            onEnter: (_) => setState(
                                              () => _selectedIndex = index,
                                            ),
                                            child: PressFeedback(
                                              pressScale: kRowPressScale,
                                              hoverScale: 1,
                                              child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: () => _runEntry(entry),
                                                child: DecoratedBox(
                                                  decoration: BoxDecoration(
                                                    color: isSelected
                                                        ? theme.bgSurface
                                                        : null,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                    border: isSelected
                                                        ? Border.all(
                                                            color: theme
                                                                .borderHairline,
                                                          )
                                                        : null,
                                                  ),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsetsDirectional.symmetric(
                                                          horizontal: 10,
                                                          vertical: 7,
                                                        ),
                                                    child: Row(
                                                      children: [
                                                        BistreIcon(
                                                          entry.icon,
                                                          size: 14,
                                                          color: isSelected
                                                              ? theme
                                                                    .accentBrass
                                                              : theme
                                                                    .inkSecondary,
                                                        ),
                                                        const SizedBox(
                                                          width: 10,
                                                        ),
                                                        Expanded(
                                                          child: InkText(
                                                            entry.label,
                                                            role: isSelected
                                                                ? InkTextRole
                                                                      .labelStrong
                                                                : InkTextRole
                                                                      .bodyCompact,
                                                            color: theme
                                                                .inkPrimary,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ),
                                                        if (entry
                                                            .shortcut
                                                            .isNotEmpty) ...[
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                          // No keycaps on a touch screen.
                                                          if (entry
                                                                  .isKeyCombo &&
                                                              isTouchPlatform)
                                                            const SizedBox.shrink()
                                                          else if (entry
                                                              .isKeyCombo)
                                                            _PaletteKeycaps(
                                                              combo: entry
                                                                  .shortcut,
                                                            )
                                                          else
                                                            InkText(
                                                              entry.shortcut,
                                                              role: InkTextRole
                                                                  .captionMeta,
                                                              color: theme
                                                                  .inkMuted,
                                                            ),
                                                        ],
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                      ),
                      if (!isTouchPlatform) ...[
                        const FolioDivider(),
                        ColoredBox(
                          color: theme.bgSurface,
                          child: const Padding(
                            padding: EdgeInsetsDirectional.symmetric(
                              horizontal: 14,
                              vertical: 7,
                            ),
                            child: Row(
                              children: [
                                _PaletteKeycaps(combo: _kArrowsKey),
                                SizedBox(width: 10),
                                _PaletteKeycaps(combo: _kEnterKey),
                                Spacer(),
                                _PaletteKeycaps(combo: _kEscKey),
                              ],
                            ),
                          ),
                        ),
                      ],
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

  static const String _kArrowsKey = '↑+↓';
  static const String _kEnterKey = 'Enter';
  static const String _kEscKey = 'Esc';
}

class _PaletteKeycaps extends StatelessWidget {
  const _PaletteKeycaps({required this.combo});

  final String combo;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final keys = combo.split('+');
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < keys.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.bgSurface,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: theme.borderHairline),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                child: Text(
                  keys[i],
                  style: BistreTypography.codeBlock(
                    theme.inkMuted,
                    config: theme.typography,
                  ).copyWith(fontSize: 11, height: 14 / 11),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PaletteEntry {
  const _PaletteEntry({
    required this.section,
    required this.icon,
    required this.label,
    required this.shortcut,
    required this.isKeyCombo,
    required this.onRun,
  });

  final String section;
  final BistreUiIcon icon;
  final String label;
  final String shortcut;
  final bool isKeyCombo;
  final VoidCallback onRun;
}
