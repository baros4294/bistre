part of 'folio_sidebar.dart';

/// The Chats tab's project groups: a `Projects` caption with New project, then each project
/// with its chats. With a filter on, the caption goes and so does a project none of whose
/// chats match.
List<_ChatListEntry> _projectEntries(
  FolioController ctrl,
  List<EngineThread> threads,
  Set<String> collapsed,
) {
  final filtering = ctrl.sidebarFilter.trim().isNotEmpty;
  final entries = <_ChatListEntry>[
    if (!filtering) const _ChatListProjectsHeader(),
  ];
  for (final p in ctrl.projects) {
    final chats = threads.where((t) => t.workspaceId == p.id).toList();
    if (filtering && chats.isEmpty) continue;
    final isCollapsed = collapsed.contains(p.id) && !filtering;
    entries.add(_ChatListProject(p, isCollapsed: isCollapsed));
    if (!isCollapsed) {
      for (final t in chats) {
        entries.add(_ChatListThread(t, inProject: true));
      }
    }
  }
  return entries;
}

final class _ChatListProjectsHeader extends _ChatListEntry {
  const _ChatListProjectsHeader();
}

final class _ChatListProject extends _ChatListEntry {
  const _ChatListProject(this.project, {required this.isCollapsed});
  final EngineProject project;
  final bool isCollapsed;
}

/// A project's row: tapping it shows or hides its chats; its buttons start a chat in it and
/// open its settings.
class _ProjectHeaderRow extends StatefulWidget {
  const _ProjectHeaderRow({
    required this.project,
    required this.isCollapsed,
    required this.onToggle,
    required this.onNewChat,
    required this.onEdit,
  });

  final EngineProject project;
  final bool isCollapsed;
  final VoidCallback onToggle;
  final VoidCallback onNewChat;
  final VoidCallback onEdit;

  @override
  State<_ProjectHeaderRow> createState() => _ProjectHeaderRowState();
}

class _ProjectHeaderRowState extends State<_ProjectHeaderRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final name = widget.project.name;
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 2, bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              expanded: !widget.isCollapsed,
              label: name,
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
                      widget.onToggle();
                      return null;
                    },
                  ),
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onToggle,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: minTapTarget),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: _hovered ? theme.hoverTint : null,
                          borderRadius: BorderRadius.circular(9),
                          border: _focused
                              ? Border.all(color: theme.accentBrass, width: 1.4)
                              : null,
                        ),
                        child: Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                            8,
                            6,
                            6,
                            6,
                          ),
                          child: Row(
                            children: [
                              BistreIcon(
                                widget.isCollapsed
                                    ? BistreUiIcon.chevronEnd
                                    : BistreUiIcon.chevronDown,
                                size: 11,
                                color: theme.inkMuted,
                              ),
                              const SizedBox(width: 6),
                              BistreIcon(
                                BistreUiIcon.folder,
                                size: 14,
                                color: theme.accentBrass,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OwnDirection(
                                  text: name,
                                  child: InkText(
                                    name,
                                    role: InkTextRole.labelStrong,
                                    color: theme.inkPrimary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
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
          ),
          BistreIconButton(
            icon: BistreUiIcon.plus,
            size: 13,
            dimension: 26,
            semanticsLabel: l10n.t(
              L10nKey.sidebarProjectNewChatIn,
              <String, Object?>{'name': name},
            ),
            onPressed: widget.onNewChat,
          ),
          BistreIconButton(
            icon: BistreUiIcon.settings,
            size: 13,
            dimension: 26,
            semanticsLabel: l10n.t(
              L10nKey.sidebarProjectSettings,
              <String, Object?>{'name': name},
            ),
            onPressed: widget.onEdit,
          ),
        ],
      ),
    );
  }
}
