import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_decorations.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import 'folio_controller.dart';

/// Open-tab overview modal / bottom sheet:
/// - Compact screens (`!isWide`): bottom sheet (`topStart/topEnd = 18`, full width, up to 84% height).
/// - Wide screens (`isWide`): centered modal (`maxWidth: 860`, 92% width, up to 80% height).
/// - 1 column on very narrow effective widths (`< 420 px` including 200% text), 2 columns otherwise.
/// - Shows a filter input when more than 3 tabs are open.
/// - Focus-trapped (`FocusScope`), closes on Escape, outside tap, or Android back.
class TabSwitcherModal extends StatefulWidget {
  const TabSwitcherModal({
    super.key,
    required this.controller,
    required this.isWide,
    required this.onClose,
  });

  final FolioController controller;
  final bool isWide;
  final VoidCallback onClose;

  @override
  State<TabSwitcherModal> createState() => _TabSwitcherModalState();
}

class _TabSwitcherModalState extends State<TabSwitcherModal> {
  final TextEditingController _filterCtrl = TextEditingController();
  final FocusNode _filterFocus = FocusNode();

  @override
  void dispose() {
    _filterCtrl.dispose();
    _filterFocus.dispose();
    super.dispose();
  }

  List<EngineThread> _filterTabs(
    List<EngineThread> tabs,
    FolioController ctrl,
  ) {
    final q = _filterCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return tabs;
    return <EngineThread>[
      for (final t in tabs)
        if (t.title.toLowerCase().contains(q) ||
            (ctrl.assistantNameFor(t.assistantId)?.toLowerCase().contains(q) ??
                false) ||
            (t.modelIdOverride?.toLowerCase().contains(q) ?? false))
          t,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final tabs = ctrl.openTabs;
    final filtered = _filterTabs(tabs, ctrl);
    final activeId = ctrl.activeThread?.id;
    final activeStreamingCount = tabs
        .where((t) => ctrl.isThreadStreaming(t.id))
        .length;
    final media = MediaQuery.sizeOf(context);
    final scale = textScaleOf(context);
    final compact = !widget.isWide;
    final sheetRadius = compact
        ? const BorderRadiusDirectional.only(
            topStart: Radius.circular(18),
            topEnd: Radius.circular(18),
          )
        : BorderRadiusDirectional.circular(12);

    return FolioModalBackdrop(
      onDismiss: widget.onClose,
      reduceMotionOverride: ctrl.reduceMotionOverride,
      alignment: compact
          ? AlignmentDirectional.bottomCenter
          : AlignmentDirectional.center,
      child: FocusScope(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, _) {
            final modalMaxW = compact
                ? media.width
                : (media.width * 0.92).clamp(280.0, 860.0);
            final modalMaxH = media.height * (compact ? 0.84 : 0.80);
            final columns = (modalMaxW / scale) < 420 ? 1 : 2;
            final rows = <List<EngineThread>>[];
            for (var i = 0; i < filtered.length; i += columns) {
              rows.add(
                filtered.sublist(
                  i,
                  i + columns > filtered.length ? filtered.length : i + columns,
                ),
              );
            }

            final headingParts = <String>[
              l10n.t(L10nKey.shellTabsOpenHeading, <String, Object?>{
                'count': tabs.length,
              }),
              if (activeStreamingCount > 0)
                l10n.t(L10nKey.shellTabsActiveCount, <String, Object?>{
                  'count': activeStreamingCount,
                }),
            ];

            return GestureDetector(
              // Block taps on the sheet from dismissing the backdrop underneath.
              onTap: () {},
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: modalMaxW,
                  maxHeight: modalMaxH,
                ),
                child: FolioSurface(
                  tone: FolioTone.elevated,
                  customBorderRadius: sheetRadius,
                  padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
                  boxShadow: theme.floatingShadow,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Keep the close button pinned to the top-end corner at every width.
                      Row(
                        children: [
                          BistreIcon(
                            BistreUiIcon.chat,
                            size: 17,
                            color: theme.accentBrass,
                          ),
                          const SizedBox(width: BistreSpacing.s8),
                          Expanded(
                            child: InkText(
                              l10n.joinMeta(headingParts),
                              role: InkTextRole.titleMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!compact && scale < 1.3) ...[
                            const SizedBox(width: BistreSpacing.s8),
                            if (ctrl.emptyOpenTabs.isNotEmpty) ...[
                              EngravedButton(
                                label: l10n.t(
                                  L10nKey.shellTabsCloseEmpty,
                                  <String, Object?>{
                                    'count': ctrl.emptyOpenTabs.length,
                                  },
                                ),
                                compact: true,
                                onPressed: ctrl.closeEmptyTabs,
                              ),
                              const SizedBox(width: BistreSpacing.s4),
                            ],
                            EngravedButton(
                              label: l10n.t(L10nKey.shellTabsNewTab),
                              primary: true,
                              compact: true,
                              leading: BistreIcon(
                                BistreUiIcon.plus,
                                size: 13,
                                color: theme.onAccentWax,
                              ),
                              onPressed: () {
                                widget.onClose();
                                unawaited(ctrl.createNewFolio());
                              },
                            ),
                            const SizedBox(width: BistreSpacing.s4),
                          ],
                          BistreIconButton(
                            icon: BistreUiIcon.close,
                            size: 15,
                            semanticsLabel: l10n.t(
                              L10nKey.shellTabsCloseOverview,
                            ),
                            onPressed: widget.onClose,
                          ),
                        ],
                      ),
                      if (compact || scale >= 1.3) ...[
                        const SizedBox(height: BistreSpacing.s8),
                        Wrap(
                          spacing: BistreSpacing.s8,
                          runSpacing: BistreSpacing.s8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            EngravedButton(
                              label: l10n.t(L10nKey.shellTabsNewTab),
                              primary: true,
                              compact: true,
                              leading: BistreIcon(
                                BistreUiIcon.plus,
                                size: 13,
                                color: theme.onAccentWax,
                              ),
                              onPressed: () {
                                widget.onClose();
                                unawaited(ctrl.createNewFolio());
                              },
                            ),
                            if (ctrl.emptyOpenTabs.isNotEmpty)
                              EngravedButton(
                                label: l10n.t(
                                  L10nKey.shellTabsCloseEmpty,
                                  <String, Object?>{
                                    'count': ctrl.emptyOpenTabs.length,
                                  },
                                ),
                                compact: true,
                                onPressed: ctrl.closeEmptyTabs,
                              ),
                          ],
                        ),
                      ],
                      if (tabs.length > 3) ...[
                        const SizedBox(height: BistreSpacing.s12),
                        QuillInput(
                          controller: _filterCtrl,
                          focusNode: _filterFocus,
                          placeholder: l10n.t(
                            L10nKey.shellTabsFilterPlaceholder,
                          ),
                          maxLines: 1,
                          compact: true,
                          submitOnEnter: false,
                          onSubmitted: () {
                            if (filtered.isNotEmpty) {
                              final first = filtered.first;
                              widget.onClose();
                              unawaited(ctrl.selectThread(first.id));
                            }
                          },
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                      const SizedBox(height: BistreSpacing.s12),
                      const FolioDivider(),
                      const SizedBox(height: BistreSpacing.s12),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsetsDirectional.symmetric(
                            vertical: BistreSpacing.s24,
                          ),
                          child: Center(
                            child: InkText(
                              l10n.t(L10nKey.shellTabsNoMatches),
                              role: InkTextRole.bodyCompact,
                              color: theme.inkMuted,
                            ),
                          ),
                        )
                      else
                        Flexible(
                          child: SmoothScrollable(
                            builder: (_, scroll) => ListView.separated(
                              controller: scroll,
                              shrinkWrap: true,
                              itemCount: rows.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: BistreSpacing.s8),
                              itemBuilder: (context, rowIndex) {
                                final pair = rows[rowIndex];
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (var c = 0; c < pair.length; c++) ...[
                                      if (c > 0)
                                        const SizedBox(width: BistreSpacing.s8),
                                      Expanded(
                                        child: _TabCard(
                                          thread: pair[c],
                                          assistantName:
                                              ctrl.assistantNameFor(
                                                pair[c].assistantId,
                                              ) ??
                                              l10n.t(
                                                L10nKey.shellRoleAssistant,
                                              ),
                                          modelLabel: _modelLabelFor(
                                            pair[c],
                                            ctrl,
                                          ),
                                          selected: pair[c].id == activeId,
                                          streaming: ctrl.isThreadStreaming(
                                            pair[c].id,
                                          ),
                                          reduceMotionOverride:
                                              ctrl.reduceMotionOverride,
                                          onSelect: () {
                                            widget.onClose();
                                            unawaited(
                                              ctrl.selectThread(pair[c].id),
                                            );
                                          },
                                          onClose: () => unawaited(
                                            ctrl.closeTab(pair[c].id),
                                          ),
                                        ),
                                      ),
                                    ],
                                    if (columns == 2 && pair.length == 1) ...[
                                      const SizedBox(width: BistreSpacing.s8),
                                      const Expanded(child: SizedBox.shrink()),
                                    ],
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _modelLabelFor(EngineThread thread, FolioController ctrl) {
    final override = thread.modelIdOverride?.trim() ?? '';
    if (override.isNotEmpty) {
      return override.contains('/') ? override.split('/').last : override;
    }
    final activeModel = ctrl.activeModelId;
    if (activeModel.isEmpty) return '';
    return activeModel.contains('/')
        ? activeModel.split('/').last
        : activeModel;
  }
}

class _TabCard extends StatefulWidget {
  const _TabCard({
    required this.thread,
    required this.assistantName,
    required this.modelLabel,
    required this.selected,
    required this.streaming,
    required this.reduceMotionOverride,
    required this.onSelect,
    required this.onClose,
  });

  final EngineThread thread;
  final String assistantName;
  final String modelLabel;
  final bool selected;
  final bool streaming;
  final bool reduceMotionOverride;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  State<_TabCard> createState() => _TabCardState();
}

class _TabCardState extends State<_TabCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final borderColor = _focused || widget.selected
        ? theme.accentBrass
        : _hovered
        ? theme.accentBrass.withValues(alpha: 0.55)
        : theme.borderHairline;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.thread.title,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelect();
              return null;
            },
          ),
        },
        child: PressFeedback(
          pressScale: kRowPressScale,
          hoverScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSelect,
            child: EaseDecoration(
              decoration: BoxDecoration(
                color: widget.selected
                    ? theme.bgSurface
                    : (_hovered ? theme.hoverTint : theme.bgCanvas),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: borderColor,
                  width: _focused || widget.selected ? 1.8 : 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.all(BistreSpacing.s12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: InkText(
                            widget.thread.title,
                            role: InkTextRole.labelStrong,
                            color: widget.selected
                                ? theme.accentBrass
                                : theme.inkPrimary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: BistreSpacing.s4),
                        BistreIconButton(
                          icon: BistreUiIcon.close,
                          size: 12,
                          dimension: 26,
                          semanticsLabel: l10n.t(L10nKey.shellCloseTab),
                          onPressed: widget.onClose,
                        ),
                      ],
                    ),
                    const SizedBox(height: BistreSpacing.s4),
                    InkText(
                      widget.assistantName,
                      role: InkTextRole.captionMeta,
                      color: theme.accentBrass,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.modelLabel.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      InkText(
                        widget.modelLabel,
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (widget.streaming) ...[
                      const SizedBox(height: BistreSpacing.s8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StreamingPulseDot(
                            color: theme.accentBrass,
                            reduceMotionOverride: widget.reduceMotionOverride,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: InkText(
                              l10n.t(L10nKey.shellTabsReplyingBackground),
                              role: InkTextRole.captionMeta,
                              color: theme.accentBrass,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
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
