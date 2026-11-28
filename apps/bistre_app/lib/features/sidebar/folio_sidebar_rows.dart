part of 'folio_sidebar.dart';

class _AssistantListTile extends StatefulWidget {
  const _AssistantListTile({
    required this.assistant,
    required this.isSelected,
    required this.canDelete,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final EngineAssistant assistant;
  final bool isSelected;
  final bool canDelete;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  @override
  State<_AssistantListTile> createState() => _AssistantListTileState();
}

class _AssistantListTileState extends State<_AssistantListTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final showActions =
        _hovered || _focused || (isTouchPlatform && widget.isSelected);
    final preview = widget.assistant.roleSubtitle.isNotEmpty
        ? widget.assistant.roleSubtitle
        : widget.assistant.systemPrompt;
    final hasLabIcon =
        widget.assistant.iconSlug.isNotEmpty &&
        LabIconCatalog.resolve(iconSlug: widget.assistant.iconSlug) != null;

    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 3),
      child: FocusableActionDetector(
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
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
                  color: widget.isSelected
                      ? theme.bgElevated
                      : (_hovered ? theme.hoverTint : null),
                  borderRadius: BorderRadius.circular(9),
                  border: _focused
                      ? Border.all(color: theme.accentBrass, width: 1.4)
                      : null,
                  boxShadow: widget.isSelected ? theme.cardShadow : null,
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 8, 8),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 28,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: widget.isSelected
                                ? theme.bgSurface
                                : theme.bgCanvas.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            child: hasLabIcon
                                ? LabIcon(
                                    iconSlug: widget.assistant.iconSlug,
                                    size: 16,
                                  )
                                : BistreIcon(
                                    BistreUiIcon.assistant,
                                    size: 14,
                                    color: widget.isSelected
                                        ? theme.accentBrass
                                        : theme.inkSecondary,
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkText(
                              widget.assistant.name,
                              role: widget.isSelected
                                  ? InkTextRole.labelStrong
                                  : InkTextRole.bodyCompact,
                              color: theme.inkPrimary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (preview.isNotEmpty)
                              InkText(
                                preview,
                                role: InkTextRole.captionMeta,
                                color: theme.inkMuted,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      if (showActions) ...[
                        BistreIconButton(
                          icon: BistreUiIcon.edit,
                          size: 13,
                          dimension: 24,
                          semanticsLabel: l10n.t(
                            L10nKey.settingsAssistantsEditTitle,
                          ),
                          onPressed: widget.onEdit,
                        ),
                        if (widget.canDelete && widget.onDelete != null)
                          BistreIconButton(
                            icon: BistreUiIcon.trash,
                            size: 13,
                            dimension: 24,
                            color: theme.inkMuted,
                            semanticsLabel: l10n.t(
                              L10nKey.settingsAssistantsDeleteAction,
                            ),
                            onPressed: widget.onDelete,
                          ),
                      ] else if (widget.isSelected)
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
        ),
      ),
    );
  }
}

class _ThreadListTile extends StatefulWidget {
  const _ThreadListTile({
    required this.thread,
    required this.runState,
    required this.isSelected,
    required this.isConfirmingDelete,
    required this.subtitle,
    required this.onTap,
    required this.onTogglePin,
    required this.onRename,
    required this.onRegenerateTitle,
    required this.onRequestDelete,
  });

  final EngineThread thread;

  /// What the chat's run is doing: a small labelled mark at the row's end.
  final ThreadRunState runState;
  final bool isSelected;
  final bool isConfirmingDelete;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;
  final VoidCallback onRename;
  final VoidCallback onRegenerateTitle;
  final VoidCallback onRequestDelete;

  @override
  State<_ThreadListTile> createState() => _ThreadListTileState();
}

class _ThreadListTileState extends State<_ThreadListTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    // Touch has no hover: the open chat shows its actions.
    final showActions =
        _hovered ||
        _focused ||
        widget.isConfirmingDelete ||
        (isTouchPlatform && widget.isSelected);

    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 2),
      child: FocusableActionDetector(
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: ContextMenuRegion(
          entries: <ContextMenuEntry>[
            ContextMenuEntry(
              label: widget.thread.isPinned
                  ? l10n.t(L10nKey.threadUnpin)
                  : l10n.t(L10nKey.threadPin),
              icon: widget.thread.isPinned
                  ? BistreUiIcon.pinFilled
                  : BistreUiIcon.pin,
              onSelected: widget.onTogglePin,
            ),
            ContextMenuEntry(
              label: l10n.t(L10nKey.threadRename),
              icon: BistreUiIcon.edit,
              onSelected: widget.onRename,
            ),
            ContextMenuEntry(
              label: l10n.t(L10nKey.threadRegenerateTitle),
              icon: BistreUiIcon.refresh,
              onSelected: widget.onRegenerateTitle,
            ),
            ContextMenuEntry(
              label: l10n.t(L10nKey.threadDelete),
              icon: BistreUiIcon.trash,
              onSelected: widget.onRequestDelete,
              destructive: true,
            ),
          ],
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
                    color: widget.isSelected
                        ? theme.bgElevated
                        : (_hovered ? theme.hoverTint : null),
                    borderRadius: BorderRadius.circular(9),
                    border: _focused
                        ? Border.all(color: theme.accentBrass, width: 1.4)
                        : null,
                    boxShadow: widget.isSelected ? theme.cardShadow : null,
                  ),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 6, 8),
                    child: Row(
                      children: [
                        // The single bold rubric mark (`docs/design/design.md` §1.1).
                        if (widget.isSelected)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(end: 8),
                            child: SizedBox(
                              width: kRubricMarkWidth,
                              height: 18,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: theme.accentWax,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              OwnDirection(
                                text: widget.thread.title,
                                child: InkText(
                                  widget.thread.title,
                                  role: widget.isSelected
                                      ? InkTextRole.labelStrong
                                      : InkTextRole.bodyCompact,
                                  color: theme.inkPrimary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (widget.subtitle != null &&
                                  widget.subtitle!.isNotEmpty)
                                InkText(
                                  widget.subtitle!,
                                  role: InkTextRole.captionMeta,
                                  color: theme.inkMuted,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                        if (widget.runState != ThreadRunState.idle)
                          _RunStateMark(state: widget.runState),
                        if (showActions) ...[
                          BistreIconButton(
                            icon: widget.thread.isPinned
                                ? BistreUiIcon.pinFilled
                                : BistreUiIcon.pin,
                            size: 13,
                            dimension: 24,
                            color: widget.thread.isPinned
                                ? theme.accentBrass
                                : theme.inkMuted,
                            semanticsLabel: widget.thread.isPinned
                                ? l10n.t(L10nKey.threadUnpin)
                                : l10n.t(L10nKey.threadPin),
                            onPressed: widget.onTogglePin,
                          ),
                          BistreIconButton(
                            icon: BistreUiIcon.edit,
                            size: 13,
                            dimension: 24,
                            semanticsLabel: l10n.t(L10nKey.threadRename),
                            onPressed: widget.onRename,
                          ),
                          BistreIconButton(
                            icon: BistreUiIcon.trash,
                            size: 13,
                            dimension: 24,
                            color: widget.isConfirmingDelete
                                ? theme.statusErr
                                : theme.inkMuted,
                            semanticsLabel: widget.isConfirmingDelete
                                ? l10n.t(L10nKey.threadConfirmDelete)
                                : l10n.t(L10nKey.threadDelete),
                            onPressed: widget.onRequestDelete,
                          ),
                        ] else if (widget.thread.isPinned)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(end: 4),
                            child: BistreIcon(
                              BistreUiIcon.pinFilled,
                              size: 12,
                              color: theme.accentBrass.withValues(alpha: 0.78),
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
      ),
    );
  }
}

class _QuietSidebarAction extends StatefulWidget {
  const _QuietSidebarAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.accentIcon = false,
  });

  final BistreUiIcon icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool accentIcon;

  @override
  State<_QuietSidebarAction> createState() => _QuietSidebarActionState();
}

class _QuietSidebarActionState extends State<_QuietSidebarAction> {
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
                  borderRadius: BorderRadius.circular(8),
                  border: _focused
                      ? Border.all(color: theme.accentBrass, width: 1.4)
                      : null,
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      BistreIcon(
                        widget.icon,
                        size: 15,
                        color: widget.accentIcon || widget.selected
                            ? theme.accentBrass
                            : theme.inkSecondary,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: InkText(
                          widget.label,
                          role: InkTextRole.bodyCompact,
                          color: theme.inkPrimary,
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

const EdgeInsetsDirectional _kListPadding = EdgeInsetsDirectional.fromSTEB(
  10,
  2,
  10,
  12,
);

sealed class _ChatListEntry {
  const _ChatListEntry();
}

final class _ChatListHeader extends _ChatListEntry {
  const _ChatListHeader(this.labelKey, {required this.isFirst});
  final L10nKey labelKey;
  final bool isFirst;
}

final class _ChatListThread extends _ChatListEntry {
  const _ChatListThread(this.thread, {this.inProject = false});
  final EngineThread thread;

  /// Listed under its project's row, indented one step.
  final bool inProject;
}

sealed class _PinnedSidebarEntry {
  const _PinnedSidebarEntry();
}

final class _PinnedSidebarHeader extends _PinnedSidebarEntry {
  const _PinnedSidebarHeader({required this.isReplies, required this.isFirst});
  final bool isReplies;
  final bool isFirst;
}

final class _PinnedSidebarThread extends _PinnedSidebarEntry {
  const _PinnedSidebarThread(this.thread);
  final EngineThread thread;
}

final class _PinnedSidebarNode extends _PinnedSidebarEntry {
  const _PinnedSidebarNode(this.node);
  final EngineNode node;
}

/// The sidebar's run mark: a 7 px dot whose colour and spoken label say whether the
/// chat is replying, waiting for an approval, has a new reply, or stopped with a problem.
class _RunStateMark extends StatelessWidget {
  const _RunStateMark({required this.state});

  final ThreadRunState state;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final (color, label) = switch (state) {
      ThreadRunState.running => (
        theme.accentBrass,
        l10n.t(L10nKey.sidebarRunRunning),
      ),
      ThreadRunState.awaitingApproval => (
        theme.statusWarn,
        l10n.t(L10nKey.sidebarRunAwaiting),
      ),
      ThreadRunState.doneUnread => (
        theme.accentWax,
        l10n.t(L10nKey.sidebarRunDoneUnread),
      ),
      ThreadRunState.failed => (
        theme.statusErr,
        l10n.t(L10nKey.sidebarRunFailed),
      ),
      ThreadRunState.idle => (theme.inkMuted, ''),
    };
    return Semantics(
      label: label,
      container: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 6),
        child: SizedBox.square(
          dimension: 7,
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

/// The assistant under a chat's title, only when it is not the default one (a subtitle that
/// repeats the default on every row says nothing).
String? _assistantSubtitle(FolioController ctrl, EngineThread thread) {
  if (ctrl.assistants.length < 2) return null;
  final assistant = ctrl.assistants
      .where((a) => a.id == thread.assistantId)
      .firstOrNull;
  if (assistant == null || assistant.isBuiltin) return null;
  return assistant.name;
}
