import 'package:flutter/foundation.dart';

import '../design/bistre_theme.dart';

/// Everything the root `WidgetsApp` and theme depend on. The root listens only to this value
/// (plus locale), so ordinary controller notifications never rebuild the whole app.
@immutable
class AppAppearance {
  const AppAppearance({
    required this.isDark,
    required this.accentPreset,
    required this.customAccentHex,
    required this.typography,
    required this.reducedEffects,
  });

  final bool isDark;
  final String accentPreset;
  final String customAccentHex;
  final BistreTypographyConfig typography;
  final bool reducedEffects;

  @override
  bool operator ==(Object other) =>
      other is AppAppearance &&
      other.isDark == isDark &&
      other.accentPreset == accentPreset &&
      other.customAccentHex == customAccentHex &&
      other.typography == typography &&
      other.reducedEffects == reducedEffects;

  @override
  int get hashCode => Object.hash(
    isDark,
    accentPreset,
    customAccentHex,
    typography,
    reducedEffects,
  );
}
