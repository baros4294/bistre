import 'package:flutter/foundation.dart';

import '../design/bistre_theme.dart';

/// Everything the root `WidgetsApp` and theme depend on. The root listens only to this value
/// (plus locale), so ordinary controller notifications never rebuild the whole app.
@immutable
class AppAppearance {
  const AppAppearance({
    required this.isDark,
    this.themeId = '',
    required this.accentPreset,
    required this.customAccentHex,
    required this.typography,
    required this.reducedEffects,
    this.reduceMotion = false,
    this.syntaxThemeId = '',
    this.textSizePercent = 100,
  });

  final bool isDark;
  final String themeId;
  final String accentPreset;
  final String customAccentHex;
  final BistreTypographyConfig typography;
  final bool reducedEffects;

  /// The in-app Reduce motion setting; the root turns it into
  /// `MediaQuery.disableAnimations`, so every motion widget honours it.
  final bool reduceMotion;
  final String syntaxThemeId;

  /// Settings > Appearance > App text size, applied on top of the system text size.
  final int textSizePercent;

  @override
  bool operator ==(Object other) =>
      other is AppAppearance &&
      other.isDark == isDark &&
      other.themeId == themeId &&
      other.accentPreset == accentPreset &&
      other.customAccentHex == customAccentHex &&
      other.typography == typography &&
      other.reducedEffects == reducedEffects &&
      other.reduceMotion == reduceMotion &&
      other.syntaxThemeId == syntaxThemeId &&
      other.textSizePercent == textSizePercent;

  @override
  int get hashCode => Object.hash(
    isDark,
    themeId,
    accentPreset,
    customAccentHex,
    typography,
    reducedEffects,
    reduceMotion,
    syntaxThemeId,
    textSizePercent,
  );
}
