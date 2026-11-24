import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../l10n/bistre_localizations.dart';
import '../l10n/l10n_keys.g.dart';
import 'bistre_theme.dart';
import 'ink_primitives.dart';

/// Pure `package:flutter/widgets.dart` text selection controls for `SelectableRegion`
/// (zero Material/Cupertino dependency, ADR-0001).
class BistreSelectionControls extends TextSelectionControls {
  BistreSelectionControls();

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) {
    final theme = BistreTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 14,
        height: 14,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.accentWax,
            shape: BoxShape.circle,
            border: Border.all(color: theme.bgElevated, width: 1.5),
          ),
        ),
      ),
    );
  }

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) {
    return const Offset(7, 0);
  }

  @override
  Size getHandleSize(double textLineHeight) => const Size(14, 14);

  @override
  Widget buildToolbar(
    BuildContext context,
    Rect globalEditableRegion,
    double textLineHeight,
    Offset selectionMidpoint,
    List<TextSelectionPoint> endpoints,
    TextSelectionDelegate delegate,
    ValueListenable<ClipboardStatus>? clipboardStatus,
    Offset? lastSecondaryTapDownPosition,
  ) {
    final l10n = BistreLocalizations.of(context);
    final anchor =
        lastSecondaryTapDownPosition ??
        Offset(
          globalEditableRegion.left + selectionMidpoint.dx,
          globalEditableRegion.top + selectionMidpoint.dy - textLineHeight - 44,
        );

    return CustomSingleChildLayout(
      delegate: _ToolbarLayoutDelegate(anchor: anchor),
      child: FolioSurface(
        tone: FolioTone.elevated,
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: BistreSpacing.s8,
          vertical: BistreSpacing.s4,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            EngravedButton(
              label: l10n.t(L10nKey.shellSelectionCopy),
              onPressed: () {
                delegate.copySelection(SelectionChangedCause.toolbar);
                delegate.hideToolbar();
              },
            ),
            const SizedBox(width: BistreSpacing.s8),
            EngravedButton(
              label: l10n.t(L10nKey.shellSelectionSelectAll),
              onPressed: () {
                delegate.selectAll(SelectionChangedCause.toolbar);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Pure `package:flutter/widgets.dart` context menu for `EditableText` inside `QuillInput`
/// (Cut / Copy / Paste / Select all, zero Material/Cupertino dependency).
Widget buildBistreEditableContextMenu(
  BuildContext context,
  EditableTextState editableTextState,
) {
  final l10n = BistreLocalizations.of(context);
  final items = editableTextState.contextMenuButtonItems;
  if (items.isEmpty) return const SizedBox.shrink();

  String? labelFor(ContextMenuButtonType type) => switch (type) {
    ContextMenuButtonType.cut => l10n.t(L10nKey.shellSelectionCut),
    ContextMenuButtonType.copy => l10n.t(L10nKey.shellSelectionCopy),
    ContextMenuButtonType.paste => l10n.t(L10nKey.shellSelectionPaste),
    ContextMenuButtonType.selectAll => l10n.t(L10nKey.shellSelectionSelectAll),
    _ => null,
  };

  final visible = <(String, VoidCallback)>[];
  for (final item in items) {
    final label = labelFor(item.type);
    final onPressed = item.onPressed;
    if (label != null && onPressed != null) {
      visible.add((label, onPressed));
    }
  }
  if (visible.isEmpty) return const SizedBox.shrink();

  final anchors = editableTextState.contextMenuAnchors;
  final anchor = anchors.secondaryAnchor ?? anchors.primaryAnchor;

  return CustomSingleChildLayout(
    delegate: _ToolbarLayoutDelegate(anchor: anchor),
    child: FolioSurface(
      tone: FolioTone.elevated,
      borderRadius: 10,
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: BistreSpacing.s8,
        vertical: BistreSpacing.s4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < visible.length; i++) ...[
            if (i > 0) const SizedBox(width: BistreSpacing.s4),
            EngravedButton(
              label: visible[i].$1,
              compact: true,
              onPressed: visible[i].$2,
            ),
          ],
        ],
      ),
    ),
  );
}

class _ToolbarLayoutDelegate extends SingleChildLayoutDelegate {
  const _ToolbarLayoutDelegate({required this.anchor});

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final dx = (anchor.dx - childSize.width / 2).clamp(
      8.0,
      (size.width - childSize.width - 8.0).clamp(8.0, double.infinity),
    );
    final dy = anchor.dy.clamp(
      8.0,
      (size.height - childSize.height - 8.0).clamp(8.0, double.infinity),
    );
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(_ToolbarLayoutDelegate oldDelegate) =>
      oldDelegate.anchor != anchor;
}
