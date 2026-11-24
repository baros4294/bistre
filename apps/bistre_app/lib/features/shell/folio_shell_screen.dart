import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app/shell_notifiers.dart';
import '../../bridge/bistre_engine.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../chat/folio_composer.dart';
import '../chat/folio_message_feed.dart';
import '../chat/session_tree_overlay.dart';
import '../commands/command_palette.dart';
import '../inspector/chat_inspector_drawer.dart';
import '../settings/settings_workspace.dart';
import '../sidebar/folio_sidebar.dart';
import '../story/manuscript_canvas.dart';
import '../story/prompt_inspector_panel.dart';
import '../story/roleplay_controls.dart';
import '../story/story_bible_panel.dart';
import '../studio/runs_dock_panel.dart';
import 'chat_tab_strip.dart';
import 'folio_controller.dart';

class _TogglePaletteIntent extends Intent {
  const _TogglePaletteIntent();
}

class _NewFolioIntent extends Intent {
  const _NewFolioIntent();
}

class _ToggleSidebarIntent extends Intent {
  const _ToggleSidebarIntent();
}

class _OpenSettingsIntent extends Intent {
  const _OpenSettingsIntent();
}

class _OpenShortcutsIntent extends Intent {
  const _OpenShortcutsIntent();
}

class _ToggleSearchIntent extends Intent {
  const _ToggleSearchIntent();
}

class _ToggleThemeIntent extends Intent {
  const _ToggleThemeIntent();
}

class _ToggleLayoutIntent extends Intent {
  const _ToggleLayoutIntent();
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

class _JumpPromptIntent extends Intent {
  const _JumpPromptIntent();
}

/// Studio Atelier native desktop & mobile workspace:
/// - Workspace Mode: Left `FolioSidebar` (`268px`) + Minimal `44px` Header +
///   `FolioMessageFeed` + `FolioComposer` + collapsible right `ChatInspectorDrawer` (`312px`)
/// - Settings Mode: Full-window `SettingsWorkspace` (`← Back to chat` / `Esc`)
/// - Zero duplicate "Add API Key" header pills when unconfigured
/// - User-customizable global keyboard shortcuts persisted in SQLite
class FolioShellScreen extends StatefulWidget {
  const FolioShellScreen({super.key, required this.controller});

  final FolioController controller;

  @override
  State<FolioShellScreen> createState() => _FolioShellScreenState();
}

class _FolioShellScreenState extends State<FolioShellScreen> {
  final FocusNode _composerFocus = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final TextEditingController _titleRenameCtrl = TextEditingController();
  final FocusNode _titleRenameFocus = FocusNode();
  final FolioOverlayController _providerPopoverCtrl = FolioOverlayController();
  final LayerLink _providerPillLink = LayerLink();
  bool _narrowDrawerOpen = false;
  bool _isWideViewport = true;
  bool _renamingTitle = false;

  @override
  void dispose() {
    _composerFocus.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _titleRenameCtrl.dispose();
    _titleRenameFocus.dispose();
    super.dispose();
  }

  void _toggleSidebarAdaptive() {
    if (_isWideViewport) {
      widget.controller.toggleSidebar();
    } else {
      setState(() => _narrowDrawerOpen = !_narrowDrawerOpen);
    }
  }

  void _openSearchAndFocus() {
    final ctrl = widget.controller;
    if (!ctrl.searchPanelOpen) {
      ctrl.toggleSearchPanel();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _toggleSearch() {
    final ctrl = widget.controller;
    ctrl.toggleSearchPanel();
    if (ctrl.searchPanelOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    } else {
      _searchController.clear();
    }
  }

  void _startInlineTitleRename(EngineThread thread) {
    _titleRenameCtrl.text = thread.title;
    setState(() => _renamingTitle = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _titleRenameFocus.requestFocus();
    });
  }

  void _commitInlineTitleRename(EngineThread thread) {
    final next = _titleRenameCtrl.text.trim();
    setState(() => _renamingTitle = false);
    if (next.isNotEmpty && next != thread.title) {
      unawaited(widget.controller.renameThread(thread.id, next));
    }
  }

  void _handleEscape() {
    if (_renamingTitle) {
      setState(() => _renamingTitle = false);
      return;
    }
    if (_narrowDrawerOpen) {
      setState(() => _narrowDrawerOpen = false);
      return;
    }
    if (widget.controller.searchPanelOpen) {
      _searchController.clear();
    }
    widget.controller.handleEscape();
  }

  static Map<ShortcutActivator, Intent> _buildShortcutMap(
    FolioController ctrl,
  ) {
    final map = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.escape): const _EscapeIntent(),
    };
    void bind(String actionId, Intent intent) {
      final activator = _parseCombo(ctrl.shortcutFor(actionId));
      if (activator != null) {
        map[activator] = intent;
      }
    }

    bind('palette', const _TogglePaletteIntent());
    bind('new_chat', const _NewFolioIntent());
    bind('sidebar', const _ToggleSidebarIntent());
    bind('settings', const _OpenSettingsIntent());
    bind('shortcuts', const _OpenShortcutsIntent());
    bind('search', const _ToggleSearchIntent());
    bind('theme', const _ToggleThemeIntent());
    bind('layout', const _ToggleLayoutIntent());
    bind('jump_prompt', const _JumpPromptIntent());
    return map;
  }

  static SingleActivator? _parseCombo(String combo) {
    final parts = combo
        .split('+')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    var control = false;
    var meta = false;
    var alt = false;
    var shift = false;
    LogicalKeyboardKey? trigger;
    for (final p in parts) {
      final low = p.toLowerCase();
      if (low == 'ctrl' || low == 'control') {
        control = true;
      } else if (low == 'meta' || low == 'cmd') {
        meta = true;
      } else if (low == 'alt') {
        alt = true;
      } else if (low == 'shift') {
        shift = true;
      } else {
        trigger = _keyFromToken(p);
      }
    }
    if (trigger == null) return null;
    return SingleActivator(
      trigger,
      control: control,
      meta: meta,
      alt: alt,
      shift: shift,
    );
  }

  static LogicalKeyboardKey? _keyFromToken(String token) {
    if (token == ',') return LogicalKeyboardKey.comma;
    if (token == '/') return LogicalKeyboardKey.slash;
    if (token == '.') return LogicalKeyboardKey.period;
    if (token == ';') return LogicalKeyboardKey.semicolon;
    final up = token.toUpperCase();
    return switch (up) {
      'A' => LogicalKeyboardKey.keyA,
      'B' => LogicalKeyboardKey.keyB,
      'C' => LogicalKeyboardKey.keyC,
      'D' => LogicalKeyboardKey.keyD,
      'E' => LogicalKeyboardKey.keyE,
      'F' => LogicalKeyboardKey.keyF,
      'G' => LogicalKeyboardKey.keyG,
      'H' => LogicalKeyboardKey.keyH,
      'I' => LogicalKeyboardKey.keyI,
      'J' => LogicalKeyboardKey.keyJ,
      'K' => LogicalKeyboardKey.keyK,
      'L' => LogicalKeyboardKey.keyL,
      'M' => LogicalKeyboardKey.keyM,
      'N' => LogicalKeyboardKey.keyN,
      'O' => LogicalKeyboardKey.keyO,
      'P' => LogicalKeyboardKey.keyP,
      'Q' => LogicalKeyboardKey.keyQ,
      'R' => LogicalKeyboardKey.keyR,
      'S' => LogicalKeyboardKey.keyS,
      'T' => LogicalKeyboardKey.keyT,
      'U' => LogicalKeyboardKey.keyU,
      'V' => LogicalKeyboardKey.keyV,
      'W' => LogicalKeyboardKey.keyW,
      'X' => LogicalKeyboardKey.keyX,
      'Y' => LogicalKeyboardKey.keyY,
      'Z' => LogicalKeyboardKey.keyZ,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    final theme = BistreTheme.of(context);
    final ctrl = widget.controller;

    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        switch (ctrl.bootState) {
          case BootState.loading:
            // A plain page until settings load, so default theme and the setup screen never
            // flash before the user's own state appears.
            return ColoredBox(color: theme.bgCanvas);
          case BootState.failed:
            return _BootFailedPage(
              onRetry: () => unawaited(ctrl.retryBootstrap()),
            );
          case BootState.ready:
            break;
        }
        return Shortcuts(
          shortcuts: _buildShortcutMap(ctrl),
          child: Actions(
            actions: <Type, Action<Intent>>{
              _TogglePaletteIntent: CallbackAction<_TogglePaletteIntent>(
                onInvoke: (_) {
                  ctrl.toggleCommandPalette();
                  return null;
                },
              ),
              _NewFolioIntent: CallbackAction<_NewFolioIntent>(
                onInvoke: (_) {
                  unawaited(ctrl.createNewFolio());
                  return null;
                },
              ),
              _ToggleSidebarIntent: CallbackAction<_ToggleSidebarIntent>(
                onInvoke: (_) {
                  _toggleSidebarAdaptive();
                  return null;
                },
              ),
              _OpenSettingsIntent: CallbackAction<_OpenSettingsIntent>(
                onInvoke: (_) {
                  ctrl.openSettings();
                  return null;
                },
              ),
              _OpenShortcutsIntent: CallbackAction<_OpenShortcutsIntent>(
                onInvoke: (_) {
                  ctrl.openSettings(SettingsTab.shortcuts);
                  return null;
                },
              ),
              _ToggleSearchIntent: CallbackAction<_ToggleSearchIntent>(
                onInvoke: (_) {
                  _toggleSearch();
                  return null;
                },
              ),
              _JumpPromptIntent: CallbackAction<_JumpPromptIntent>(
                onInvoke: (_) {
                  ctrl.openSessionTree(onlyUserPrompts: true);
                  return null;
                },
              ),
              _ToggleThemeIntent: CallbackAction<_ToggleThemeIntent>(
                onInvoke: (_) {
                  ctrl.toggleTheme();
                  return null;
                },
              ),
              _ToggleLayoutIntent: CallbackAction<_ToggleLayoutIntent>(
                onInvoke: (_) {
                  ctrl.toggleLayoutMode();
                  return null;
                },
              ),
              _EscapeIntent: CallbackAction<_EscapeIntent>(
                onInvoke: (_) {
                  _handleEscape();
                  return null;
                },
              ),
            },
            child: FocusScope(
              autofocus: true,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 740;
                  final canDockInspector = constraints.maxWidth >= 1060;
                  _isWideViewport = isWide;

                  final messageFeed = FolioMessageFeed(
                    controller: ctrl,
                    onReplyToPassage: (content) {
                      ctrl.replyToPassage(content);
                      _composerFocus.requestFocus();
                    },
                    onSubmitStarterPrompt: (prompt) =>
                        unawaited(ctrl.submitPassage(prompt)),
                    onSelectSearchHit: (hit) {
                      _searchController.clear();
                      if (ctrl.searchPanelOpen) {
                        ctrl.toggleSearchPanel();
                      }
                      unawaited(ctrl.selectThread(hit.threadId));
                    },
                  );
                  final isWriteMode = ctrl.activeThreadMode == 'write';
                  final workspaceBody = isWriteMode
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            RoleplayControlsBar(controller: ctrl),
                            Expanded(
                              child: ctrl.manuscriptViewActive
                                  ? ManuscriptCanvas(controller: ctrl)
                                  : messageFeed,
                            ),
                          ],
                        )
                      : messageFeed;

                  final workspace = ParchmentScaffold(
                    header: _buildHeader(theme, l10n, ctrl, isWide: isWide),
                    body: workspaceBody,
                    footer: isWriteMode && ctrl.manuscriptViewActive
                        ? const SizedBox.shrink()
                        : FolioComposer(
                            controller: ctrl,
                            focusNode: _composerFocus,
                          ),
                  );

                  final runsDock = RunsDockPanel(
                    controller: ctrl,
                    storyTabBuilder: (_) => StoryBiblePanel(controller: ctrl),
                    promptTabBuilder: (_) =>
                        PromptInspectorPanel(controller: ctrl),
                  );

                  final baseLayout = ColoredBox(
                    color: theme.bgCanvas,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (isWide && ctrl.sidebarOpen) ...[
                          FolioSidebar(
                            controller: ctrl,
                            onSelectThreadComplete: () {},
                          ),
                          const FolioDivider(vertical: true),
                        ],
                        Expanded(child: workspace),
                        if (canDockInspector && ctrl.inspectorOpen) ...[
                          const FolioDivider(vertical: true),
                          ChatInspectorDrawer(controller: ctrl),
                        ],
                        if (canDockInspector && ctrl.studioPaneOpen) ...[
                          const FolioDivider(vertical: true),
                          runsDock,
                        ],
                      ],
                    ),
                  );

                  // Modals and drawers hide the occluded background from screen readers.
                  final modalOpen =
                      !ctrl.settingsOpen &&
                      ((!isWide && _narrowDrawerOpen) ||
                          (!canDockInspector &&
                              (ctrl.inspectorOpen || ctrl.studioPaneOpen)) ||
                          ctrl.commandPaletteOpen ||
                          ctrl.sessionTreeOpen);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (ctrl.settingsOpen)
                        SettingsWorkspace(controller: ctrl)
                      else
                        ExcludeSemantics(
                          excluding: modalOpen,
                          child: baseLayout,
                        ),
                      if (!ctrl.settingsOpen && !isWide && _narrowDrawerOpen)
                        FolioDrawerFrame(
                          onDismiss: () =>
                              setState(() => _narrowDrawerOpen = false),
                          reduceMotionOverride: ctrl.reduceMotionOverride,
                          child: FolioSidebar(
                            controller: ctrl,
                            onSelectThreadComplete: () =>
                                setState(() => _narrowDrawerOpen = false),
                            onCloseSidebar: () =>
                                setState(() => _narrowDrawerOpen = false),
                          ),
                        ),
                      if (!ctrl.settingsOpen &&
                          !canDockInspector &&
                          ctrl.inspectorOpen)
                        FolioModalBackdrop(
                          onDismiss: ctrl.toggleInspector,
                          reduceMotionOverride: ctrl.reduceMotionOverride,
                          alignment: AlignmentDirectional.centerEnd,
                          child: ChatInspectorDrawer(controller: ctrl),
                        ),
                      if (!ctrl.settingsOpen &&
                          !canDockInspector &&
                          ctrl.studioPaneOpen)
                        FolioModalBackdrop(
                          onDismiss: ctrl.toggleStudioPane,
                          reduceMotionOverride: ctrl.reduceMotionOverride,
                          alignment: AlignmentDirectional.centerEnd,
                          child: runsDock,
                        ),
                      if (ctrl.commandPaletteOpen)
                        CommandPalette(
                          controller: ctrl,
                          onTriggerSearch: _openSearchAndFocus,
                        ),
                      if (ctrl.sessionTreeOpen)
                        SessionTreeOverlay(
                          controller: ctrl,
                          onlyUserPrompts: ctrl.sessionTreePromptsOnly,
                          onClose: ctrl.closeSessionTree,
                        ),
                      // Only the toast rebuilds when a notice shows or hides.
                      ValueListenableBuilder<ToastMessage?>(
                        valueListenable: ctrl.toast,
                        builder: (context, toast, _) => toast == null
                            ? const SizedBox.shrink()
                            : FolioToastBanner(
                                key: ValueKey<L10nKey>(toast.key),
                                message: l10n.t(toast.key),
                                reduceMotionOverride: ctrl.reduceMotionOverride,
                                actionLabel: toast.actionKey == null
                                    ? null
                                    : l10n.t(toast.actionKey!),
                                onAction: toast.onAction,
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl, {
    required bool isWide,
  }) {
    final active = ctrl.activeThread;
    final showSidebarButton = !isWide || !ctrl.sidebarOpen;
    final modelDisplay = ctrl.activeProviderModelDisplay;
    final hasProvider = ctrl.hasConfiguredProvider;
    final activeProv = ctrl.activeProvider;

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: BistreSpacing.s16,
        vertical: 8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, headerConstraints) {
              // At >= 135% text in a narrow effective width (width / text scale < 600 px),
              // secondary actions stack below a full-width title.
              final scale = textScaleOf(context);
              final headerW = headerConstraints.maxWidth;
              final stackActions =
                  scale >= kHeaderStackTextScale && headerW / scale < 600;
              // One bar (DESIGN §10, Parchment v2.6.0): title with the model as an interactive
              // subtitle; trailing new chat, Studio, and settings. Mode, branches, inspector,
              // search, and the palette live in the composer, Ctrl+K, and shortcuts.
              final leading = <Widget>[
                if (showSidebarButton) ...[
                  BistreIconButton(
                    icon: BistreUiIcon.sidebar,
                    semanticsLabel: l10n.t(L10nKey.sidebarToggle),
                    onPressed: _toggleSidebarAdaptive,
                  ),
                  const SizedBox(width: BistreSpacing.s8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (_renamingTitle && active != null)
                            Expanded(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 320,
                                ),
                                child: QuillInput(
                                  controller: _titleRenameCtrl,
                                  focusNode: _titleRenameFocus,
                                  placeholder: l10n.t(
                                    L10nKey.threadRenamePlaceholder,
                                  ),
                                  maxLines: 1,
                                  submitOnEnter: false,
                                  onSubmitted: () =>
                                      _commitInlineTitleRename(active),
                                ),
                              ),
                            )
                          else
                            Flexible(
                              child: _HeaderPressable(
                                semanticsLabel: l10n.t(
                                  L10nKey.threadRenamePlaceholder,
                                ),
                                cursor: SystemMouseCursors.text,
                                onPressed: active != null
                                    ? () => _startInlineTitleRename(active)
                                    : null,
                                child: InkText(
                                  active?.title ??
                                      l10n.t(L10nKey.shellThreadDefaultTitle),
                                  role: InkTextRole.titleMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          if (active != null && !_renamingTitle) ...[
                            const SizedBox(width: 4),
                            BistreIconButton(
                              icon: active.isPinned
                                  ? BistreUiIcon.pinFilled
                                  : BistreUiIcon.pin,
                              size: 15,
                              color: active.isPinned
                                  ? theme.accentBrass
                                  : theme.inkMuted,
                              semanticsLabel: active.isPinned
                                  ? l10n.t(L10nKey.threadUnpin)
                                  : l10n.t(L10nKey.threadPin),
                              onPressed: () =>
                                  unawaited(ctrl.togglePinThread(active.id)),
                            ),
                          ],
                        ],
                      ),
                      // The one model picker: `model on Provider ▾` under the title.
                      if (hasProvider && activeProv != null)
                        FolioOverlay(
                          controller: _providerPopoverCtrl,
                          overlayBuilder: (ctx) => _buildProviderQuickSwitcher(
                            ctx,
                            theme,
                            l10n,
                            ctrl,
                          ),
                          child: CompositedTransformTarget(
                            link: _providerPillLink,
                            child: _HeaderPressable(
                              semanticsLabel: l10n.t(
                                L10nKey.shellModelOnProvider,
                                <String, Object?>{
                                  'model': modelDisplay,
                                  'provider': activeProv.name,
                                },
                              ),
                              onPressed: _providerPopoverCtrl.toggle,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: InkText(
                                      l10n.t(
                                        L10nKey.shellModelOnProvider,
                                        <String, Object?>{
                                          'model': modelDisplay,
                                          'provider': activeProv.name,
                                        },
                                      ),
                                      role: InkTextRole.captionMeta,
                                      color: theme.inkSecondary,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  BistreIcon(
                                    BistreUiIcon.chevronDown,
                                    size: 11,
                                    color: theme.inkMuted,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ];
              final trailing = <Widget>[
                BistreIconButton(
                  icon: BistreUiIcon.newChat,
                  semanticsLabel: l10n.t(L10nKey.sidebarNewFolio),
                  onPressed: () => unawaited(ctrl.createNewFolio()),
                ),
                BistreIconButton(
                  icon: BistreUiIcon.server,
                  active: ctrl.studioPaneOpen,
                  semanticsLabel: l10n.t(L10nKey.studioTitle),
                  onPressed: ctrl.toggleStudioPane,
                ),
                BistreIconButton(
                  icon: BistreUiIcon.settings,
                  semanticsLabel: l10n.t(L10nKey.sidebarSettings),
                  onPressed: ctrl.openSettings,
                ),
              ];
              if (stackActions) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: leading),
                    const SizedBox(height: BistreSpacing.s4),
                    // Wrap (not Row) so very large text never overflows; flex wrappers only
                    // matter inside the single-row layout.
                    Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      runSpacing: BistreSpacing.s4,
                      children: <Widget>[
                        for (final w in trailing) w is Flexible ? w.child : w,
                      ],
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  ...leading,
                  const SizedBox(width: BistreSpacing.s8),
                  ...trailing,
                ],
              );
            },
          ),
          if (isWide) ...[
            const SizedBox(height: BistreSpacing.s4),
            ChatTabStrip(controller: ctrl),
          ],
          if (ctrl.searchPanelOpen)
            Padding(
              padding: const EdgeInsetsDirectional.only(top: BistreSpacing.s8),
              child: FolioFadeSlide(
                beginOffset: const Offset(0, -0.15),
                reduceMotionOverride: ctrl.reduceMotionOverride,
                child: ListenableBuilder(
                  // Search keystrokes and results rebuild only this bar (and the feed).
                  listenable: ctrl.search,
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: QuillInput(
                              controller: _searchController,
                              focusNode: _searchFocus,
                              placeholder: l10n.t(
                                L10nKey.shellSearchPlaceholder,
                              ),
                              maxLines: 1,
                              submitOnEnter: false,
                              onSubmitted: () {},
                              onChanged: (q) => unawaited(ctrl.updateSearch(q)),
                            ),
                          ),
                          const SizedBox(width: BistreSpacing.s8),
                          InkChip(
                            label: l10n.t(L10nKey.chatSearchThreadScope),
                            selected: !ctrl.searchAllThreads,
                            onSelected: () => ctrl.setSearchAllThreads(false),
                          ),
                          const SizedBox(width: 6),
                          InkChip(
                            label: l10n.t(L10nKey.chatSearchAllScope),
                            selected: ctrl.searchAllThreads,
                            onSelected: () => ctrl.setSearchAllThreads(true),
                          ),
                          const SizedBox(width: 4),
                          BistreIconButton(
                            icon: BistreUiIcon.close,
                            size: 14,
                            dimension: 30,
                            semanticsLabel: l10n.t(L10nKey.threadCancel),
                            onPressed: _toggleSearch,
                          ),
                        ],
                      ),
                      if (ctrl.searchQuery.isNotEmpty)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(top: 6),
                          child: InkText(
                            l10n.t(
                              L10nKey.shellSearchResults,
                              <String, Object?>{
                                'count': ctrl.searchHits.length,
                              },
                            ),
                            role: InkTextRole.captionMeta,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProviderQuickSwitcher(
    BuildContext context,
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final dir = Directionality.of(context);
    final activeProvider = ctrl.activeProvider;
    final loadedModels = activeProvider != null
        ? ctrl.modelsForProvider(activeProvider.id)
        : const <EngineProviderModel>[];

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _providerPopoverCtrl.hide,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _providerPillLink,
          showWhenUnlinked: false,
          targetAnchor: AlignmentDirectional.bottomEnd.resolve(dir),
          followerAnchor: AlignmentDirectional.topEnd.resolve(dir),
          offset: const Offset(0, 8),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, -0.04),
            reduceMotionOverride: ctrl.reduceMotionOverride,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: FolioSurface(
                  tone: FolioTone.elevated,
                  padding: EdgeInsetsDirectional.zero,
                  borderRadius: 14,
                  boxShadow: theme.floatingShadow,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 4),
                      for (final p in ctrl.providers)
                        _QuickProviderOption(
                          provider: p,
                          subtitle: p.defaultModel.isNotEmpty
                              ? p.defaultModel
                              : (p.isReady
                                    ? l10n.t(L10nKey.providerStatusConnected)
                                    : l10n.t(
                                        L10nKey.providerStatusNotConnected,
                                      )),
                          selected: activeProvider?.id == p.id,
                          onTap: () {
                            _providerPopoverCtrl.hide();
                            if (p.isReady) {
                              unawaited(
                                ctrl.setActiveProviderAndModel(
                                  p.id,
                                  p.defaultModel,
                                ),
                              );
                            } else {
                              ctrl.openSettings();
                            }
                          },
                        ),
                      const SizedBox(height: 4),
                      if (activeProvider != null &&
                          loadedModels.isNotEmpty) ...[
                        const FolioDivider(),
                        Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                            14,
                            8,
                            14,
                            4,
                          ),
                          child: InkText(
                            l10n.t(L10nKey.providerFieldModel),
                            role: InkTextRole.captionMeta,
                            color: theme.inkMuted,
                          ),
                        ),
                        for (final m in loadedModels.take(4))
                          _QuickModelOption(
                            modelId: m.id,
                            selected: ctrl.activeModelId == m.id,
                            onTap: () {
                              _providerPopoverCtrl.hide();
                              unawaited(
                                ctrl.setActiveProviderAndModel(
                                  activeProvider.id,
                                  m.id,
                                ),
                              );
                            },
                          ),
                      ],
                      const FolioDivider(),
                      _QuickActionFooterRow(
                        label: l10n.t(L10nKey.settingsTabProviders),
                        onTap: () {
                          _providerPopoverCtrl.hide();
                          ctrl.openSettings();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _QuickProviderOption extends StatefulWidget {
  const _QuickProviderOption({
    required this.provider,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final EngineProvider provider;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_QuickProviderOption> createState() => _QuickProviderOptionState();
}

class _QuickProviderOptionState extends State<_QuickProviderOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final p = widget.provider;
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
              color: _hovered || widget.selected ? theme.hoverTint : null,
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              child: Row(
                children: [
                  LabIcon(
                    iconSlug: p.iconSlug,
                    customIconPath: p.customIconPath,
                    dialect: p.dialect,
                    providerName: p.name,
                    size: 17,
                    framed: true,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkText(
                          p.name,
                          role: InkTextRole.labelStrong,
                          color: theme.inkPrimary,
                        ),
                        InkText(
                          widget.subtitle,
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
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

class _QuickModelOption extends StatefulWidget {
  const _QuickModelOption({
    required this.modelId,
    required this.selected,
    required this.onTap,
  });

  final String modelId;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_QuickModelOption> createState() => _QuickModelOptionState();
}

class _QuickModelOptionState extends State<_QuickModelOption> {
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
              color: _hovered || widget.selected ? theme.hoverTint : null,
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 14,
                vertical: 6,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkText(
                      widget.modelId,
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
                      size: 12,
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

class _QuickActionFooterRow extends StatefulWidget {
  const _QuickActionFooterRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_QuickActionFooterRow> createState() => _QuickActionFooterRowState();
}

class _QuickActionFooterRowState extends State<_QuickActionFooterRow> {
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
            decoration: BoxDecoration(color: _hovered ? theme.hoverTint : null),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              child: Row(
                children: [
                  BistreIcon(
                    BistreUiIcon.settings,
                    size: 14,
                    color: theme.accentBrass,
                  ),
                  const SizedBox(width: 8),
                  InkText(
                    widget.label,
                    role: InkTextRole.labelStrong,
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

class _BootFailedPage extends StatelessWidget {
  const _BootFailedPage({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return ColoredBox(
      color: theme.bgCanvas,
      child: Center(
        child: Padding(
          padding: const EdgeInsetsDirectional.all(BistreSpacing.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: true,
                child: InkText(
                  l10n.t(L10nKey.bootFailed),
                  role: InkTextRole.titleMedium,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: BistreSpacing.s16),
              EngravedButton(
                label: l10n.t(L10nKey.bootTryAgain),
                primary: true,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A focusable, labelled header control (title rename, model picker): keyboard Enter/Space
/// activates it, and a 2 px focus ring appears only for keyboard focus.
class _HeaderPressable extends StatefulWidget {
  const _HeaderPressable({
    required this.child,
    required this.semanticsLabel,
    required this.onPressed,
    this.cursor = SystemMouseCursors.click,
  });

  final Widget child;
  final String semanticsLabel;
  final VoidCallback? onPressed;
  final MouseCursor cursor;

  @override
  State<_HeaderPressable> createState() => _HeaderPressableState();
}

class _HeaderPressableState extends State<_HeaderPressable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final onPressed = widget.onPressed;
    return Semantics(
      button: onPressed != null,
      label: widget.semanticsLabel,
      child: FocusableActionDetector(
        enabled: onPressed != null,
        mouseCursor: onPressed != null ? widget.cursor : MouseCursor.defer,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onPressed?.call();
              return null;
            },
          ),
        },
        child: PressFeedback(
          pressScale: kRowPressScale,
          hoverScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: _focused
                    ? Border.all(color: theme.accentBrass, width: 2)
                    : null,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 24),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
