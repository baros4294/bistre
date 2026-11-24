import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';

/// One selectable entry in the vertical `@` mention or `/` slash command menu.
@immutable
class ComposerTriggerItem {
  const ComposerTriggerItem({
    required this.token,
    required this.label,
    required this.description,
    required this.icon,
    this.badge,
  });

  final String token;
  final String label;
  final String description;
  final BistreUiIcon icon;
  final String? badge;
}

/// Vertical, keyboard-navigable (`↑`/`↓`/`Enter`/`Tab`/`Esc`) menu shown directly above
/// the composer when typing `@` mentions or `/` slash commands.
class ComposerTriggerMenu extends StatelessWidget {
  const ComposerTriggerMenu({
    super.key,
    required this.title,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.onHoverIndex,
    this.reduceMotionOverride = false,
  });

  final String title;
  final List<ComposerTriggerItem> items;
  final int selectedIndex;
  final ValueChanged<ComposerTriggerItem> onSelect;
  final ValueChanged<int> onHoverIndex;
  final bool reduceMotionOverride;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    if (items.isEmpty) return const SizedBox.shrink();
    final countText = items.length.toString();

    return FolioFadeSlide(
      beginOffset: const Offset(0, 0.05),
      reduceMotionOverride: reduceMotionOverride,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.bgElevated,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 272),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 14, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: InkText(
                        title,
                        role: InkTextRole.captionMeta,
                        color: theme.accentBrass,
                      ),
                    ),
                    InkText(
                      countText,
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                  ],
                ),
              ),
              const FolioDivider(),
              Flexible(
                child: SmoothScrollable(
                  builder: (_, scroll) => ListView.builder(
                    controller: scroll,
                    shrinkWrap: true,
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final selected = index == selectedIndex;
                      return _TriggerRow(
                        item: item,
                        selected: selected,
                        onHover: () => onHoverIndex(index),
                        onTap: () => onSelect(item),
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
  }
}

class _TriggerRow extends StatelessWidget {
  const _TriggerRow({
    required this.item,
    required this.selected,
    required this.onHover,
    required this.onTap,
  });

  final ComposerTriggerItem item;
  final bool selected;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final semanticName = item.description.isEmpty
        ? item.label
        : '${item.label} ${item.description}';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => onHover(),
      child: PressFeedback(
        pressScale: kRowPressScale,
        hoverScale: 1,
        child: Semantics(
          button: true,
          selected: selected,
          label: semanticName,
          child: FocusableActionDetector(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            },
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  onTap();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected ? theme.hoverTint : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      BistreIcon(
                        item.icon,
                        size: 14,
                        color: selected
                            ? theme.accentBrass
                            : theme.inkSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkText(
                              item.label,
                              role: InkTextRole.labelStrong,
                              color: selected
                                  ? theme.accentBrass
                                  : theme.inkPrimary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (item.description.isNotEmpty)
                              InkText(
                                item.description,
                                role: InkTextRole.captionMeta,
                                color: theme.inkMuted,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      if (item.badge != null && item.badge!.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.bgSurface,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: theme.borderHairline),
                          ),
                          child: Padding(
                            padding: const EdgeInsetsDirectional.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: InkText(
                              item.badge!,
                              role: InkTextRole.captionMeta,
                              color: theme.inkSecondary,
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
}
