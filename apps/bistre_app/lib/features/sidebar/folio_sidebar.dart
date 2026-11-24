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
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Calm `268px` Warm Studio Atelier left rail:
/// - Clean Brand header + `New chat` button + sidebar collapse
/// - Clean 3-tab switch: `Assistants | Chats | Pinned`
/// - Chronological date groups (`Today`, `Yesterday`, `Previous 7 days`, `Older`)
/// - Quiet single-row footer (`Settings` + Theme toggle) — ZERO duplicate `Add API Key` CTAs!
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
  String? _renamingThreadId;
  String? _pendingDeleteThreadId;
  bool _confirmingClearAll = false;

  @override
  void initState() {
    super.initState();
    _filterFocus.addListener(_onFilterFocus);
  }

  @override
  void dispose() {
    _filterFocus.removeListener(_onFilterFocus);
    _filterController.dispose();
    _filterFocus.dispose();
    _renameController.dispose();
    _renameFocus.dispose();
    super.dispose();
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
                      ],
                    ),
                  ),
                ),
              ),
            if (ctrl.sidebarTab == SidebarTab.chat && ctrl.threads.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 0, 12, 6),
                child: _confirmingClearAll
                    ? Row(
                        children: [
                          Expanded(
                            child: InkText(
                              l10n.t(
                                L10nKey.sidebarClearAllConfirm,
                                <String, Object?>{'count': ctrl.threads.length},
                              ),
                              role: InkTextRole.captionMeta,
                              color: theme.statusErr,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 4),
                          EngravedButton(
                            label: l10n.t(L10nKey.threadDelete),
                            compact: true,
                            leading: BistreIcon(
                              BistreUiIcon.trash,
                              size: 12,
                              color: theme.statusErr,
                            ),
                            onPressed: () {
                              setState(() => _confirmingClearAll = false);
                              unawaited(ctrl.clearAllThreads());
                            },
                          ),
                          const SizedBox(width: 4),
                          EngravedButton(
                            label: l10n.t(L10nKey.threadCancel),
                            compact: true,
                            onPressed: () =>
                                setState(() => _confirmingClearAll = false),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          const Spacer(),
                          EngravedButton(
                            label: l10n.t(L10nKey.sidebarClearAll),
                            compact: true,
                            leading: BistreIcon(
                              BistreUiIcon.trash,
                              size: 12,
                              color: theme.inkMuted,
                            ),
                            onPressed: () =>
                                setState(() => _confirmingClearAll = true),
                          ),
                        ],
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
          BistreIconButton(
            icon: BistreUiIcon.sidebar,
            size: 15,
            dimension: 30,
            semanticsLabel: l10n.t(L10nKey.sidebarToggle),
            onPressed: widget.onCloseSidebar ?? ctrl.toggleSidebar,
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
    final showAssistantSubtitle = ctrl.assistants.length > 1;
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
              subtitle: showAssistantSubtitle
                  ? ctrl.assistantNameFor(thread.assistantId)
                  : null,
            ),
            _PinnedSidebarNode(:final node) => Padding(
              padding: const EdgeInsetsDirectional.only(bottom: 4),
              child: PressFeedback(
                pressScale: kRowPressScale,
                hoverScale: 1,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: ctrl.togglePinnedPanel,
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
  }) {
    if (threads.isEmpty) {
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

    final showAssistantSubtitle = ctrl.assistants.length > 1;
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
              subtitle: showAssistantSubtitle
                  ? ctrl.assistantNameFor(t.assistantId)
                  : null,
            );
          },
        ),
      );
    }

    final now = DateTime.now();
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

    final entries = <_ChatListEntry>[];
    L10nKey? lastBucket;
    for (final t in threads) {
      final bucket = bucketFor(t);
      if (bucket != lastBucket) {
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
            _ChatListThread(:final thread) => _buildThreadRow(
              theme,
              l10n,
              ctrl,
              thread,
              subtitle: showAssistantSubtitle
                  ? ctrl.assistantNameFor(thread.assistantId)
                  : null,
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
      // Undo instead of asking: delete at once, restorable from the 8 s Undo toast.
      onRequestDelete: () {
        setState(() => _pendingDeleteThreadId = null);
        unawaited(ctrl.deleteThread(thread.id));
      },
    );
  }

  /// Minimal, calm single-row footer — zero repeated `Add API Key` clutter.
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
    final showActions = _hovered || _focused;
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
    required this.isSelected,
    required this.isConfirmingDelete,
    required this.subtitle,
    required this.onTap,
    required this.onTogglePin,
    required this.onRename,
    required this.onRequestDelete,
  });

  final EngineThread thread;
  final bool isSelected;
  final bool isConfirmingDelete;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;
  final VoidCallback onRename;
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
    final showActions = _hovered || _focused || widget.isConfirmingDelete;

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
                        // The single bold rubric mark (`docs/design/DESIGN.md` §1.1).
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
                              InkText(
                                widget.thread.title,
                                role: widget.isSelected
                                    ? InkTextRole.labelStrong
                                    : InkTextRole.bodyCompact,
                                color: theme.inkPrimary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
  const _ChatListThread(this.thread);
  final EngineThread thread;
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
