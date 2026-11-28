import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Keeps an anchored popover on screen: a popover that starts (or ends) at its trigger can run
/// past the window edge on a phone. [popoverWidthFor] caps the width to the window, and
/// [popoverShiftFor] returns the horizontal offset that moves the popover back inside.
abstract final class PopoverPlacement {
  /// Space kept between a popover and the window edge.
  static const double margin = 12;

  /// [preferred] capped to the window width less the margins.
  static double popoverWidthFor(BuildContext context, double preferred) =>
      math.max(
        0,
        math.min(preferred, MediaQuery.sizeOf(context).width - 2 * margin),
      );

  /// Horizontal offset for a popover of [width] whose start ([alignStart]) or end edge is
  /// aligned with the same edge of the trigger owning [anchor], so it stays fully on screen.
  /// Zero until the trigger has been laid out.
  static double popoverShiftFor(
    BuildContext anchor, {
    required double width,
    required bool alignStart,
  }) {
    final box = anchor.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return 0;
    final screen = MediaQuery.sizeOf(anchor).width;
    final rtl = Directionality.of(anchor) == TextDirection.rtl;
    final left = box.localToGlobal(Offset.zero).dx;
    final right = left + box.size.width;
    // The popover's left edge as anchored.
    final atLeft = alignStart != rtl;
    final placed = atLeft ? left : right - width;
    final maxLeft = math.max(margin, screen - margin - width);
    final clamped = placed.clamp(margin, maxLeft);
    return clamped - placed;
  }
}
