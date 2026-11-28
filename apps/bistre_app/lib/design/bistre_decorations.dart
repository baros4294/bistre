import 'package:flutter/widgets.dart';

import 'bistre_theme.dart';

/// Width of the single bold start-edge accent bar.
const double kRubricMarkWidth = 3;

/// Maximum growth of fixed-width columns at large text scales (`docs/design/design.md` §7).
const double kMaxTextScaledWidthFactor = 1.6;

/// Text scale at which phone header secondary actions stack below the title.
const double kHeaderStackTextScale = 1.35;

/// "One bold mark" (`docs/design/design.md` §1.1): the single start-edge accent bar used ONLY
/// for the selected sidebar chat, the active settings category, the empty-chat intro, and user
/// prompts in `Document` layout. Direction-aware (start edge in LTR and RTL).
/// Square-cornered on purpose: Flutter cannot paint a one-sided border with rounded corners.
BoxDecoration rubricMark(BistreThemeData theme, {Color? fill}) => BoxDecoration(
  color: fill,
  border: BorderDirectional(
    start: BorderSide(color: theme.accentWax, width: kRubricMarkWidth),
  ),
);

/// Current text scale factor (1.0 = 100%).
double textScaleOf(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(100) / 100;

/// Largest growth of icons with the user's text size (DESIGN §7): at `200%` text an icon is
/// 1.5x its base size, so icons and icon buttons stay in proportion with the words beside them
/// without crowding dense rows.
const double kMaxIconScale = 1.5;

/// Icon size factor for the user's text size (1.0 at `100%`, at most [kMaxIconScale]).
double iconScaleOf(BuildContext context) =>
    textScaleOf(context).clamp(1.0, kMaxIconScale).toDouble();

/// Scales a fixed column width with the user's text size, capped at `1.6x`, so labels in
/// sidebars and settings navigation never break mid-word at `200%` text.
double textScaledWidth(BuildContext context, double base) {
  final factor = textScaleOf(context)
      .clamp(1.0, kMaxTextScaledWidthFactor)
      .toDouble();
  return base * factor;
}
