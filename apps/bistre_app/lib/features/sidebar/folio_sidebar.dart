import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/context_menu.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../design/user_avatar_thumb.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../chat/content_direction.dart';
import '../chat/plain_preview.dart';
import '../shell/folio_controller.dart';

part 'folio_sidebar_projects.dart';
part 'folio_sidebar_rows.dart';

/// Calm `268px` Warm Studio Atelier left rail:
/// - Clean Brand header + `New chat` button + sidebar collapse
/// - Clean 3-tab switch: `Assistants | Chats | Pinned`
/// - Projects with their chats, then the other chats in date groups (`Today`, `Yesterday`,
///   `Previous 7 days`, `Older`)
/// - Quiet single-row footer (`Settings` + Theme toggle): ZERO duplicate `Add API Key` CTAs!
class FolioSidebar extends StatefulWidget {
  const FolioSidebar({
    super.key,
    required this.controller,
    required this.onSelectThreadComplete,
    this.onCloseSidebar,
  });

  final FolioController controller;
  final VoidCallback onSelectThreadComplete;
  final VoidCallback? onCloseSidebar;

  @override
  State<FolioSidebar> createState() => _FolioSidebarState();
}

class _FolioSidebarState extends State<FolioSidebar> {
  final TextEditingController _filterController = TextEditingController();
  final FocusNode _filterFocus = FocusNode();
  final TextEditingController _renameController = TextEditingController();
  final FocusNode _renameFocus = FocusNode();
  bool _filterFocused = false;
  bool _hasFilter = false;
  String? _renamingThreadId;
  String? _pendingDeleteThreadId;

  /// Projects whose chats are hidden; for this sidebar's life only.
  final Set<String> _collapsedProjects = <String>{};

  @override
  void initState() {
    super.initState();
    _filterFocus.addListener(_onFilterFocus);
    // A filter that is on shows its words in the field (a reopened drawer included).
    _filterController.text = widget.controller.sidebarFilter;
    _hasFilter = _filterController.text.isNotEmpty;
    widget.controller.sidebarFilterQuery.addListener(_onFilterQuery);
  }

  @override
  void dispose() {
    widget.controller.sidebarFilterQuery.removeListener(_onFilterQuery);
    _filterFocus.removeListener(_onFilterFocus);
    _filterController.dispose();
    _filterFocus.dispose();
    _renameController.dispose();
    _renameFocus.dispose();
    super.dispose();
  }

  /// A filter set or cleared elsewhere reaches the field; typing in it is never overwritten.
  void _onFilterQuery() {
    final q = widget.controller.sidebarFilter;
    if (!_filterFocus.hasFocus && _filterController.text != q) {
      _filterController.text = q;
    }
    // Only the clear button depends on it: rebuild when it appears or goes, not per key.
    if (_hasFilter != q.isNotEmpty) setState(() => _hasFilter = q.isNotEmpty);
  }

  void _clearFilter() {
    _filterController.clear();
    widget.controller.setSidebarFilter('');
  }

  void _onFilterFocus() {
    if (_filterFocused != _filterFocus.hasFocus) {
      setState(() => _filterFocused = _filterFocus.hasFocus);
    }
  }

  void _beginRename(EngineThread thread) {
    setState(() {
      _pendingDeleteThreadId = null;
      _renamingThreadId = thread.id;
      _renameController.text = thread.title;
    });
    _renameFocus.requestFocus();
  }

  void _commitRename(String threadId) {
    final text = _renameController.text.trim();
    setState(() => _renamingThreadId = null);
    if (text.isNotEmpty) {
      unawaited(widget.controller.renameThread(threadId, text));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;

    return SizedBox(
      width: textScaledWidth(context, BistreSpacing.sidebarWidth),
      child: ColoredBox(
        color: theme.bgSurface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildBrandHeader(theme, l10n, ctrl),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 10),
              child: BistreSegmentedControl<SidebarTab>(
                expand: true,
                selected: ctrl.sidebarTab,
                onSelected: ctrl.setSidebarTab,
                options: <BistreSegmentedOption<SidebarTab>>[
                  BistreSegmentedOption<SidebarTab>(
                    value: SidebarTab.assistant,
                    label: l10n.t(L10nKey.sidebarTabAssistant),
                  ),
                  BistreSegmentedOption<SidebarTab>(
                    value: SidebarTab.chat,
                    label: l10n.t(L10nKey.sidebarTabChat),
                  ),
                  BistreSegmentedOption<SidebarTab>(
                    value: SidebarTab.pinned,
                    label: l10n.t(L10nKey.sidebarTabPinned),
                  ),
                ],
              ),
            ),
            if (ctrl.sidebarTab != SidebarTab.assistant)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.bgCanvas.withValues(
                      alpha: theme.isDark ? 0.55 : 0.65,
                    ),
                    borderRadius: BorderRadius.circular(9),
                    border: _filterFocused
                        ? Border.all(color: theme.accentBrass, width: 1.4)
                        : Border.all(
                            color: theme.borderHairline.withValues(alpha: 0.6),
                          ),
                  ),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 10, 6),
                    child: Row(
                      children: [
                        BistreIcon(
                          BistreUiIcon.search,
                          size: 13,
                          color: theme.inkMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: QuillInput(
                            controller: _filterController,
                            focusNode: _filterFocus,
                            placeholder: l10n.t(
                              L10nKey.sidebarFilterPlaceholder,
                            ),
                            maxLines: 1,
                            submitOnEnter: false,
                            frameless: true,
                            onSubmitted: () {},
                            onChanged: ctrl.setSidebarFilter,
                          ),
                        ),
                        if (_hasFilter)
                          BistreIconButton(
                            icon: BistreUiIcon.close,
                            size: 12,
                            dimension: 24,
                            semanticsLabel: l10n.t(L10nKey.settingsClearSearch),
                            onPressed: _clearFilter,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              // Filter keystrokes rebuild only this list.
              child: ListenableBuilder(
                listenable: ctrl.sidebarFilterQuery,
                builder: (context, _) => switch (ctrl.sidebarTab) {
                  SidebarTab.assistant => SmoothScrollable(
                    builder: (_, scroll) => SingleChildScrollView(
                      controller: scroll,
                      padding: _kListPadding,
                      child: _buildAssistantsList(theme, l10n, ctrl),
                    ),
                  ),
                  SidebarTab.chat => _buildGroupedChatsList(
                    theme,
                    l10n,
                    ctrl,
                    ctrl.filteredThreads,
                    emptyText: l10n.t(L10nKey.sidebarEmptyFiltered),
                    withProjects: true,
                  ),
                  SidebarTab.pinned => _buildPinnedCombinedList(
                    theme,
                    l10n,
                    ctrl,
                  ),
                },
              ),
            ),
            const FolioDivider(),
            _buildQuietFooter(theme, l10n, ctrl),
          ],
        ),
      ),
    );
  }

  Widget _buildBrandHeader(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 8, 10),
      child: Row(
        children: [
          EngravedIcon(
            assetPath: 'assets/icons/bistre_icon.vec',
            semanticsLabel: l10n.t(L10nKey.appTitle),
            size: 22,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: InkText(
              l10n.t(L10nKey.appTitle),
              role: InkTextRole.titleMedium,
            ),
          ),
          BistreIconButton(
            icon: BistreUiIcon.newChat,
            size: 16,
            dimension: 30,
            color: theme.inkPrimary,
            semanticsLabel: l10n.t(L10nKey.sidebarNewFolio),
            onPressed: () {
              ctrl.setSidebarTab(SidebarTab.chat);
              unawaited(ctrl.createNewFolio());
              widget.onSelectThreadComplete();
            },
          ),
          // The phone drawer has no header behind it, so it keeps its own close button; the
          // docked sidebar is toggled only from the chat header.
          if (widget.onCloseSidebar case final close?)
            BistreIconButton(
              icon: BistreUiIcon.sidebar,
              size: 15,
              dimension: 30,
              semanticsLabel: l10n.t(L10nKey.sidebarToggle),
              onPressed: close,
            ),
        ],
      ),
    );
  }

  Widget _buildAssistantsList(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final canDelete = ctrl.assistants.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final assistant in ctrl.assistants)
          _AssistantListTile(
            assistant: assistant,
            isSelected: ctrl.activeAssistantId == assistant.id,
            canDelete: canDelete,
            onTap: () {
              unawaited(ctrl.selectAssistant(assistant.id));
              widget.onSelectThreadComplete();
            },
            onEdit: () => ctrl.openAssistantEditor(assistant.id),
            onDelete: canDelete
                ? () => unawaited(ctrl.deleteAssistant(assistant.id))
                : null,
          ),
        const SizedBox(height: 8),
        _QuietSidebarAction(
          icon: BistreUiIcon.plus,
          label: l10n.t(L10nKey.sidebarAssistantNew),
          accentIcon: true,
          onTap: ctrl.openAssistantEditor,
        ),
      ],
    );
  }

  Widget _buildPinnedCombinedList(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final pinnedThreads = ctrl.pinnedThreads;
    final pinnedNodes = ctrl.pinnedNodes;
    if (pinnedThreads.isEmpty && pinnedNodes.isEmpty) {
      return _buildGroupedChatsList(
        theme,
        l10n,
        ctrl,
        const <EngineThread>[],
        emptyText: l10n.t(L10nKey.sidebarPinnedEmpty),
        isPinnedEmpty: true,
        groupByDate: false,
      );
    }
    final items = <_PinnedSidebarEntry>[];
    if (pinnedThreads.isNotEmpty) {
      items.add(const _PinnedSidebarHeader(isReplies: false, isFirst: true));
      for (final t in pinnedThreads) {
        items.add(_PinnedSidebarThread(t));
      }
    }
    if (pinnedNodes.isNotEmpty) {
      items.add(
        _PinnedSidebarHeader(isReplies: true, isFirst: pinnedThreads.isEmpty),
      );
      for (final n in pinnedNodes) {
        items.add(_PinnedSidebarNode(n));
      }
    }
    return SmoothScrollable(
      builder: (_, scroll) => ListView.builder(
        controller: scroll,
        padding: _kListPadding,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return switch (item) {
            _PinnedSidebarHeader(isReplies: false) => Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(10, 4, 10, 4),
              child: InkText(
                l10n.t(L10nKey.sidebarTabChat),
                role: InkTextRole.captionMeta,
                color: theme.inkMuted,
              ),
            ),
            _PinnedSidebarHeader(isReplies: true) => Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                10,
                item.isFirst ? 4 : 12,
                10,
                4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkText(
                      l10n.t(L10nKey.chatPinnedRepliesTitle),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                  ),
                  EngravedButton(
                    label: l10n.t(L10nKey.chatPinnedRepliesOpen),
                    compact: true,
                    onPressed: ctrl.togglePinnedPanel,
                  ),
                ],
              ),
            ),
            _PinnedSidebarThread(:final thread) => _buildThreadRow(
              theme,
              l10n,
              ctrl,
              thread,
              subtitle: _assistantSubtitle(ctrl, thread),
            ),
            _PinnedSidebarNode(:final node) => Padding(
              padding: const EdgeInsetsDirectional.only(bottom: 4),
              child: PressFeedback(
                pressScale: kRowPressScale,
                hoverScale: 1,
                // A pinned reply opens at that exact message.
                child: PressableArea(
                  label: plainPreview(node.content),
                  onPressed: () =>
                      unawaited(ctrl.revealNode(node.threadId, node.id)),
                  child: FolioSurface(
                    tone: FolioTone.canvas,
                    padding: const EdgeInsetsDirectional.fromSTEB(10, 7, 10, 7),
                    borderRadius: 8,
                    child: Row(
                      children: [
                        BistreIcon(
                          BistreUiIcon.pinFilled,
                          size: 11,
                          color: theme.accentBrass,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: InkText(
                            node.content.replaceAll('\n', ' ').trim(),
                            role: InkTextRole.captionMeta,
                            color: theme.inkPrimary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          };
        },
      ),
    );
  }

  Widget _buildGroupedChatsList(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
    List<EngineThread> threads, {
    required String emptyText,
    bool isPinnedEmpty = false,
    bool groupByDate = true,
    bool withProjects = false,
  }) {
    final projectEntries = withProjects
        ? _projectEntries(ctrl, threads, _collapsedProjects)
        : const <_ChatListEntry>[];
    final projectIds = <String>{
      if (withProjects)
        for (final p in ctrl.projects) p.id,
    };
    final loose = projectIds.isEmpty
        ? threads
        : threads.where((t) => !projectIds.contains(t.workspaceId)).toList();
    if (loose.isEmpty && projectEntries.isEmpty) {
      return SmoothScrollable(
        builder: (_, scroll) => SingleChildScrollView(
          controller: scroll,
          padding: _kListPadding,
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 14,
              vertical: 36,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                BistreIcon(
                  isPinnedEmpty ? BistreUiIcon.pin : BistreUiIcon.chat,
                  size: 20,
                  color: theme.inkMuted.withValues(alpha: 0.6),
                ),
                const SizedBox(height: 8),
                InkText(
                  emptyText,
                  role: InkTextRole.captionMeta,
                  color: theme.inkMuted,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Virtualized: with 300+ chats only the ~14 rows inside the viewport are built.
    if (!groupByDate) {
      return SmoothScrollable(
        builder: (_, scroll) => ListView.builder(
          controller: scroll,
          padding: _kListPadding,
          itemCount: threads.length,
          itemBuilder: (context, index) {
            final t = threads[index];
            return _buildThreadRow(
              theme,
              l10n,
              ctrl,
              t,
              subtitle: _assistantSubtitle(ctrl, t),
            );
          },
        ),
      );
    }

    final now = ctrl.now();
    final startToday = DateTime(now.year, now.month, now.day);
    final startYesterday = startToday.subtract(const Duration(days: 1));
    final startWeek = startToday.subtract(const Duration(days: 7));

    L10nKey bucketFor(EngineThread t) {
      if (t.updatedAtMs < 1000000000) return L10nKey.sidebarGroupToday;
      final dt = DateTime.fromMillisecondsSinceEpoch(t.updatedAtMs);
      if (!dt.isBefore(startToday)) return L10nKey.sidebarGroupToday;
      if (!dt.isBefore(startYesterday)) return L10nKey.sidebarGroupYesterday;
      if (!dt.isBefore(startWeek)) return L10nKey.sidebarGroupWeek;
      return L10nKey.sidebarGroupOlder;
    }

    final entries = <_ChatListEntry>[...projectEntries];
    L10nKey? lastBucket;
    final showDates = ctrl.uiPrefs.showChatListDates;
    for (final t in loose) {
      final bucket = bucketFor(t);
      if (showDates && bucket != lastBucket) {
        lastBucket = bucket;
        entries.add(_ChatListHeader(bucket, isFirst: entries.isEmpty));
      }
      entries.add(_ChatListThread(t));
    }

    return SmoothScrollable(
      builder: (_, scroll) => ListView.builder(
        controller: scroll,
        padding: _kListPadding,
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return switch (entry) {
            _ChatListHeader(:final labelKey, :final isFirst) => Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                10,
                isFirst ? 4 : 12,
                10,
                4,
              ),
              child: InkText(
                l10n.t(labelKey),
                role: InkTextRole.captionMeta,
                color: theme.inkMuted,
              ),
            ),
            _ChatListProjectsHeader() => Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(10, 4, 0, 2),
              child: Row(
                children: [
                  Expanded(
                    child: InkText(
                      l10n.t(L10nKey.settingsTabProjects),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                  ),
                  BistreIconButton(
                    icon: BistreUiIcon.plus,
                    size: 12,
                    dimension: 24,
                    semanticsLabel: l10n.t(L10nKey.settingsProjectsNew),
                    onPressed: () => ctrl.openProjectEditor(''),
                  ),
                ],
              ),
            ),
            _ChatListProject(:final project, :final isCollapsed) =>
              _ProjectHeaderRow(
                project: project,
                isCollapsed: isCollapsed,
                onToggle: () => setState(() {
                  if (!_collapsedProjects.remove(project.id)) {
                    _collapsedProjects.add(project.id);
                  }
                }),
                onNewChat: () {
                  unawaited(ctrl.createChatInProject(project.id));
                  widget.onSelectThreadComplete();
                },
                onEdit: () => ctrl.openProjectEditor(project.id),
              ),
            _ChatListThread(:final thread, :final inProject) => Padding(
              padding: EdgeInsetsDirectional.only(start: inProject ? 14 : 0),
              child: _buildThreadRow(
                theme,
                l10n,
                ctrl,
                thread,
                subtitle: _assistantSubtitle(ctrl, thread),
              ),
            ),
          };
        },
      ),
    );
  }

  Widget _buildThreadRow(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
    EngineThread thread, {
    String? subtitle,
  }) {
    final isSelected = ctrl.activeThread?.id == thread.id;
    final isRenaming = _renamingThreadId == thread.id;
    final isConfirmingDelete = _pendingDeleteThreadId == thread.id;

    if (isRenaming) {
      return Padding(
        padding: const EdgeInsetsDirectional.only(bottom: 4),
        child: Row(
          children: [
            Expanded(
              child: QuillInput(
                controller: _renameController,
                focusNode: _renameFocus,
                placeholder: l10n.t(L10nKey.threadRenamePlaceholder),
                maxLines: 1,
                compact: true,
                onSubmitted: () => _commitRename(thread.id),
              ),
            ),
            const SizedBox(width: 4),
            BistreIconButton(
              icon: BistreUiIcon.check,
              size: 14,
              dimension: 28,
              color: theme.statusOk,
              semanticsLabel: l10n.t(L10nKey.threadSave),
              onPressed: () => _commitRename(thread.id),
            ),
            BistreIconButton(
              icon: BistreUiIcon.close,
              size: 14,
              dimension: 28,
              semanticsLabel: l10n.t(L10nKey.threadCancel),
              onPressed: () => setState(() => _renamingThreadId = null),
            ),
          ],
        ),
      );
    }

    return _ThreadListTile(
      thread: thread,
      runState: ctrl.threadRunState(thread.id),
      isSelected: isSelected,
      isConfirmingDelete: isConfirmingDelete,
      subtitle: subtitle,
      onTap: () {
        setState(() => _pendingDeleteThreadId = null);
        unawaited(ctrl.selectThread(thread.id));
        widget.onSelectThreadComplete();
      },
      onTogglePin: () => unawaited(ctrl.togglePinThread(thread.id)),
      onRename: () => _beginRename(thread),
      onRegenerateTitle: () => unawaited(ctrl.regenerateThreadTitle(thread.id)),
      // Off (default): delete at once, restorable from the 8 s Undo toast. On (Settings >
      // Appearance): the first click asks, the second deletes.
      onRequestDelete: () {
        if (ctrl.uiPrefs.confirmBeforeDeletingChat && !isConfirmingDelete) {
          setState(() => _pendingDeleteThreadId = thread.id);
          return;
        }
        setState(() => _pendingDeleteThreadId = null);
        unawaited(ctrl.deleteThread(thread.id));
      },
    );
  }

  /// Minimal, calm single-row footer: zero repeated `Add API Key` clutter.
  Widget _buildQuietFooter(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final themeIcon = ctrl.isDark ? BistreUiIcon.sun : BistreUiIcon.moon;

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 10, 10),
      child: Row(
        children: [
          if (ctrl.profileAvatarPath.isNotEmpty) ...[
            UserAvatarThumb(path: ctrl.profileAvatarPath, size: 24),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: _QuietSidebarAction(
              icon: BistreUiIcon.settings,
              label: l10n.t(L10nKey.sidebarSettings),
              selected: ctrl.settingsOpen,
              onTap: ctrl.openSettings,
            ),
          ),
          const SizedBox(width: 4),
          BistreIconButton(
            icon: themeIcon,
            size: 15,
            dimension: 32,
            semanticsLabel: ctrl.isDark
                ? l10n.t(L10nKey.shellThemeDay)
                : l10n.t(L10nKey.shellThemeNight),
            onPressed: ctrl.toggleTheme,
          ),
        ],
      ),
    );
  }
}
