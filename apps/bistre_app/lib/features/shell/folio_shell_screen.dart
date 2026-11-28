import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app/shell_notifiers.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/hover_hint.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/sidebar_slide_reveal.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../chat/chat_overlays.dart';
import '../chat/content_direction.dart';
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
import 'inline_title_editor.dart';
import 'model_picker_popover.dart';
import 'shortcut_combo.dart';
import 'split_secondary_pane.dart';
import 'tab_switcher_modal.dart';

part 'folio_shell_parts.dart';

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

class _StopReplyIntent extends Intent {
  const _StopReplyIntent();
}

class _NextTabIntent extends Intent {
  const _NextTabIntent();
}

class _PrevTabIntent extends Intent {
  const _PrevTabIntent();
}

/// Studio Atelier native desktop & mobile workspace:
/// - Workspace Mode: Left `FolioSidebar` (`268px`) + Minimal `44px` Header +
///   `FolioMessageFeed` + `FolioComposer` + collapsible end `ChatInspectorDrawer` (`312px`) under the header
/// - Settings Mode: Full-window `SettingsWorkspace` (`← Back to chat` / `Esc`)
/// - Zero duplicate "Add API Key" header pills when unconfigured
/// - User-customizable global keyboard shortcuts persisted in SQLite
class FolioShellScreen extends StatefulWidget {
  const FolioShellScreen({super.key, required this.controller});

  final FolioController controller;

  @override
  State<FolioShellScreen> createState() => _FolioShellScreenState();
}

class _FolioShellScreenState extends State<FolioShellScreen>
    with WidgetsBindingObserver {
  final FocusNode _composerFocus = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FolioOverlayController _providerPopoverCtrl = FolioOverlayController();
  final LayerLink _providerPillLink = LayerLink();

  /// The model pill, so the picker can keep itself inside the window on a phone.
  final GlobalKey _providerPillKey = GlobalKey();
  bool _narrowDrawerOpen = false;
  bool _isWideViewport = true;
  String? _cachedShortcutJson;
  Map<ShortcutActivator, Intent>? _cachedShortcutMap;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    BistreDesktopHost.attachQuickEntryListener(_onQuickEntry);
  }

  /// The quick entry shortcut: the window is already in front; a new chat (the open one
  /// when it has no messages yet) waits with the composer focused.
  Future<void> _onQuickEntry() async {
    final ctrl = widget.controller;
    ctrl.closeSettings();
    if (ctrl.visibleBranchNodes.isNotEmpty) await ctrl.createNewFolio();
    if (mounted) _composerFocus.requestFocus();
  }

  /// Android back: the innermost open layer closes first; with nothing open, the app exits
  /// as usual. Settings runs its own back steps (`settings_workspace.dart`), so it is left to them.
  @override
  Future<bool> didPopRoute() async {
    final ctrl = widget.controller;
    if (!mounted || ctrl.settingsOpen) return false;
    if (ctrl.previewingAttachment != null) {
      ctrl.closeAttachmentPreview();
    } else if (ctrl.inspectingTurnNode != null) {
      ctrl.closeTurnDetails();
    } else if (ctrl.pinnedPanelOpen) {
      ctrl.closePinnedPanel();
    } else if (ctrl.commandPaletteOpen) {
      ctrl.closeCommandPalette();
    } else if (ctrl.tabSwitcherOpen) {
      ctrl.closeTabSwitcher();
    } else if (ctrl.sessionTreeOpen) {
      ctrl.closeSessionTree();
    } else if (_providerPopoverCtrl.isShowing) {
      _providerPopoverCtrl.hide();
    } else if (ctrl.studioPaneOpen) {
      ctrl.toggleStudioPane();
    } else if (ctrl.inspectorOpen) {
      ctrl.toggleInspector();
    } else if (ctrl.searchPanelOpen) {
      ctrl.toggleSearchPanel();
    } else if (!_isWideViewport && _narrowDrawerOpen) {
      setState(() => _narrowDrawerOpen = false);
    } else {
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BistreDesktopHost.detachQuickEntryListener(_onQuickEntry);
    _composerFocus.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
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

  void _handleEscape() {
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
      const SingleActivator(LogicalKeyboardKey.tab, control: true):
          const _NextTabIntent(),
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
          const _PrevTabIntent(),
    };
    void bind(String actionId, Intent intent) {
      final activator = ShortcutCombo.parse(ctrl.shortcutFor(actionId));
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
    bind('stop_reply', const _StopReplyIntent());
    return map;
  }

  Map<ShortcutActivator, Intent> _shortcutsFor(FolioController ctrl) {
    final json = ctrl.settings.customShortcutsJson;
    final cached = _cachedShortcutMap;
    if (cached != null && _cachedShortcutJson == json) return cached;
    _cachedShortcutJson = json;
    return _cachedShortcutMap = _buildShortcutMap(ctrl);
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
              diagnosticKey: ctrl.lastDiagnosticKey,
              onRetry: () => unawaited(ctrl.retryBootstrap()),
            );
          case BootState.ready:
            break;
        }
        return Shortcuts(
          shortcuts: _shortcutsFor(ctrl),
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
              _StopReplyIntent: CallbackAction<_StopReplyIntent>(
                onInvoke: (_) {
                  if (ctrl.isStreaming) unawaited(ctrl.cancelStreaming());
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
              _NextTabIntent: CallbackAction<_NextTabIntent>(
                onInvoke: (_) {
                  unawaited(ctrl.cycleTab(1));
                  return null;
                },
              ),
              _PrevTabIntent: CallbackAction<_PrevTabIntent>(
                onInvoke: (_) {
                  unawaited(ctrl.cycleTab(-1));
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
                      unawaited(ctrl.revealNode(hit.threadId, hit.nodeId));
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

                  final updateCheck = ctrl.updateCheck;
                  final topBanner = FolioTopBanner(
                    visible: ctrl.showUpdateBanner && updateCheck != null,
                    icon: BistreUiIcon.download,
                    message: updateCheck == null
                        ? ''
                        : l10n.t(
                            L10nKey.settingsUpdatesAvailable,
                            <String, Object?>{
                              'version': updateCheck.latestVersion,
                            },
                          ),
                    actionLabel: l10n.t(L10nKey.settingsUpdatesStage),
                    onAction: () => unawaited(ctrl.stageAvailableUpdate()),
                    dismissLabel: l10n.t(L10nKey.shellDismiss),
                    onDismiss: ctrl.dismissUpdateBanner,
                  );

                  final crashBanner = FolioTopBanner(
                    visible: ctrl.pendingCrashReport != null,
                    icon: BistreUiIcon.info,
                    message: l10n.t(L10nKey.shellCrashBanner),
                    actionLabel: l10n.t(L10nKey.shellCrashCopy),
                    onAction: () => unawaited(ctrl.copyCrashReport()),
                    dismissLabel: l10n.t(L10nKey.shellDismiss),
                    onDismiss: ctrl.dismissCrashReport,
                  );

                  final workspace = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: workspaceBody),
                      if (!(isWriteMode && ctrl.manuscriptViewActive))
                        FolioComposer(
                          controller: ctrl,
                          focusNode: _composerFocus,
                        ),
                    ],
                  );

                  final runsDock = RunsDockPanel(
                    controller: ctrl,
                    storyTabBuilder: (_) => StoryBiblePanel(controller: ctrl),
                    promptTabBuilder: (_) =>
                        PromptInspectorPanel(controller: ctrl),
                  );

                  // The header spans the chat and its side panes, so opening the inspector or
                  // Studio never moves New chat, Studio and Settings (DESIGN §6).
                  // The inspector and Studio slide in like the sidebar: the chat takes its
                  // final width once per toggle instead of re-laying out every frame.
                  Widget trailingDock(bool open, Widget pane, Widget child) =>
                      SidebarDock(
                        open: open,
                        trailing: true,
                        reduceMotionOverride: ctrl.reduceMotionOverride,
                        sidebar: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [const FolioDivider(vertical: true), pane],
                        ),
                        child: child,
                      );
                  final chatPanes = Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: workspace),
                      if (canDockInspector && ctrl.splitViewOpen) ...[
                        const FolioDivider(vertical: true),
                        Expanded(child: SplitSecondaryPane(controller: ctrl)),
                      ],
                    ],
                  );
                  final panes = canDockInspector
                      ? trailingDock(
                          ctrl.studioPaneOpen,
                          runsDock,
                          trailingDock(
                            ctrl.inspectorOpen,
                            ChatInspectorDrawer(controller: ctrl),
                            chatPanes,
                          ),
                        )
                      : chatPanes;
                  final mainArea = BistreScaffold(
                    header: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeader(theme, l10n, ctrl, isWide: isWide),
                        crashBanner,
                        topBanner,
                      ],
                    ),
                    body: panes,
                    footer: const SizedBox.shrink(),
                  );
                  // The docked sidebar slides without re-laying out the chat.
                  final baseLayout = ColoredBox(
                    color: theme.bgCanvas,
                    child: isWide
                        ? SidebarDock(
                            open: ctrl.sidebarOpen,
                            reduceMotionOverride: ctrl.reduceMotionOverride,
                            sidebar: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                FolioSidebar(
                                  controller: ctrl,
                                  onSelectThreadComplete: () {},
                                ),
                                const FolioDivider(vertical: true),
                              ],
                            ),
                            child: mainArea,
                          )
                        : mainArea,
                  );

                  // Modals and drawers hide the occluded background from screen readers.
                  final modalOpen =
                      !ctrl.settingsOpen &&
                      ((!isWide && _narrowDrawerOpen) ||
                          (!canDockInspector &&
                              (ctrl.inspectorOpen || ctrl.studioPaneOpen)) ||
                          ctrl.commandPaletteOpen ||
                          ctrl.tabSwitcherOpen ||
                          ctrl.sessionTreeOpen ||
                          ctrl.pinnedPanelOpen ||
                          ctrl.inspectingTurnNode != null ||
                          ctrl.previewingAttachment != null);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (ctrl.settingsOpen)
                        SettingsWorkspace(controller: ctrl)
                      else
                        // DESIGN §7: what a modal covers is hidden from screen readers and Tab.
                        ExcludeSemantics(
                          excluding: modalOpen,
                          child: ExcludeFocus(
                            excluding: modalOpen,
                            child: baseLayout,
                          ),
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
                      if (ctrl.tabSwitcherOpen)
                        TabSwitcherModal(
                          controller: ctrl,
                          isWide: isWide,
                          onClose: ctrl.closeTabSwitcher,
                        ),
                      if (ctrl.sessionTreeOpen)
                        SessionTreeOverlay(
                          controller: ctrl,
                          onlyUserPrompts: ctrl.sessionTreePromptsOnly,
                          onClose: ctrl.closeSessionTree,
                        ),
                      if (ctrl.pinnedPanelOpen)
                        PinnedRepliesModal(
                          controller: ctrl,
                          onClose: ctrl.closePinnedPanel,
                        ),
                      if (ctrl.inspectingTurnNode case final inspected?)
                        TurnDetailsModal(
                          node: inspected,
                          controller: ctrl,
                          onClose: ctrl.closeTurnDetails,
                        ),
                      if (ctrl.previewingAttachment case final previewAtt?)
                        AttachmentViewerModal(
                          attachment: previewAtt,
                          reduceMotionOverride: ctrl.reduceMotionOverride,
                          onClose: ctrl.closeAttachmentPreview,
                          onOpenFolder: ctrl.canOpenFolderOf(previewAtt)
                              ? () => unawaited(ctrl.openFolderOf(previewAtt))
                              : null,
                          onOpenInApp: ctrl.canOpenInAppOf(previewAtt)
                              ? () => unawaited(ctrl.openInAppOf(previewAtt))
                              : null,
                          onSaveCopy: ctrl.canSaveCopyOf(previewAtt)
                              ? () => unawaited(
                                  ctrl.saveCopyOf(
                                    previewAtt,
                                    l10n.t(L10nKey.viewerSaveCopy),
                                  ),
                                )
                              : null,
                          onCopyPicture: ctrl.canCopyPictureOf(previewAtt)
                              ? () => unawaited(ctrl.copyPictureOf(previewAtt))
                              : null,
                          onPlay: ctrl.canPlayOf(previewAtt)
                              ? () => unawaited(ctrl.playOf(previewAtt))
                              : null,
                          onStop: ctrl.canPlayOf(previewAtt)
                              ? () => unawaited(ctrl.stopPlayback())
                              : null,
                          onCopied: () => ctrl.showToast(L10nKey.toastCopied),
                        ),
                      // Only the toast rebuilds when a notice shows or hides.
                      ValueListenableBuilder<ToastMessage?>(
                        valueListenable: ctrl.toast,
                        builder: (context, toast, _) => toast == null
                            ? const SizedBox.shrink()
                            : FolioToastBanner(
                                key: ValueKey<Object>(
                                  Object.hash(toast.key, toast.args?.length),
                                ),
                                message: l10n.t(
                                  toast.key,
                                  toast.args ?? const <String, Object?>{},
                                ),
                                dotColor: switch (toast.tone) {
                                  ToastTone.ok => theme.statusOk,
                                  ToastTone.error => theme.statusErr,
                                  ToastTone.info => theme.accentBrass,
                                },
                                reduceMotionOverride: ctrl.reduceMotionOverride,
                                actionLabel: toast.actionKey == null
                                    ? null
                                    : l10n.t(toast.actionKey!),
                                onAction: toast.onAction,
                                dismissLabel: l10n.t(L10nKey.shellDismiss),
                                onDismiss: ctrl.dismissToast,
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
              // Single top bar (DESIGN §10): title with the model as an interactive
              // subtitle; trailing new chat, Studio, and settings. Mode, branches, inspector,
              // search, and the palette live in the composer, Ctrl+K, and shortcuts.
              final leading = <Widget>[
                // The one sidebar toggle, always first in the header, open or closed.
                BistreIconButton(
                  icon: BistreUiIcon.sidebar,
                  active: isWide && ctrl.sidebarOpen,
                  semanticsLabel: l10n.t(L10nKey.sidebarToggle),
                  onPressed: _toggleSidebarAdaptive,
                ),
                const SizedBox(width: BistreSpacing.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          InlineTitleEditor(
                            // One editor per chat (and per Settings visit): switching ends
                            // an edit without saving it into the next chat.
                            key: ValueKey<String>(
                              '${active?.id}|${ctrl.settingsOpen}',
                            ),
                            title: active?.title ?? '',
                            placeholder: l10n.t(
                              L10nKey.threadRenamePlaceholder,
                            ),
                            onRename: (next) {
                              if (active != null) {
                                unawaited(ctrl.renameThread(active.id, next));
                              }
                            },
                            displayBuilder: (context, startEditing) => Flexible(
                              child: _HeaderPressable(
                                semanticsLabel: l10n.t(
                                  L10nKey.threadRenamePlaceholder,
                                ),
                                cursor: SystemMouseCursors.text,
                                onPressed: active != null ? startEditing : null,
                                child: OwnDirection(
                                  text: active?.title ?? '',
                                  child: InkText(
                                    active?.title ??
                                        l10n.t(L10nKey.shellThreadDefaultTitle),
                                    role: InkTextRole.titleMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (active != null) ...[
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
                          overlayBuilder: (_) => ModelPickerPopover(
                            controller: ctrl,
                            link: _providerPillLink,
                            anchorKey: _providerPillKey,
                            onDismiss: _providerPopoverCtrl.hide,
                          ),
                          child: CompositedTransformTarget(
                            key: _providerPillKey,
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
              final openTabCount = ctrl.openTabs.length;
              final bgStreaming = ctrl.backgroundStreamingCount;
              final trailing = <Widget>[
                // Compact tab badge in the top bar:
                // shown on narrow screens once >1 tab is open or any background chat is streaming.
                if (!isWide && (openTabCount > 1 || bgStreaming > 0)) ...[
                  _CompactTabBadge(
                    count: openTabCount,
                    backgroundStreaming: bgStreaming > 0,
                    reduceMotionOverride: ctrl.reduceMotionOverride,
                    semanticsLabel: l10n.t(
                      L10nKey.shellTabsCount,
                      <String, Object?>{'count': openTabCount},
                    ),
                    onPressed: ctrl.openTabSwitcher,
                  ),
                  const SizedBox(width: 4),
                ],
                BistreIconButton(
                  icon: BistreUiIcon.newChat,
                  semanticsLabel: l10n.t(L10nKey.sidebarNewFolio),
                  onPressed: () => unawaited(ctrl.createNewFolio()),
                ),
                // Studio is always reachable, not only during a run.
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
                            semanticsLabel: l10n.t(L10nKey.shellClose),
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
}
