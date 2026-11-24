import 'package:flutter/widgets.dart';

/// Dynamic typography & reading geometry owned by the end user (zero forced presets).
@immutable
class BistreTypographyConfig {
  const BistreTypographyConfig({
    this.proseFontFamily = 'Inter',
    this.monoFontFamily = 'JetBrainsMono',
    this.baseFontSizePx = 15.0,
    this.lineHeightFactor = 1.6,
    this.readingWidthPx = 760.0,
  });

  final String proseFontFamily;
  final String monoFontFamily;
  final double baseFontSizePx;
  final double lineHeightFactor;
  final double readingWidthPx;

  static const BistreTypographyConfig defaults = BistreTypographyConfig();

  BistreTypographyConfig copyWith({
    String? proseFontFamily,
    String? monoFontFamily,
    double? baseFontSizePx,
    double? lineHeightFactor,
    double? readingWidthPx,
  }) => BistreTypographyConfig(
    proseFontFamily: proseFontFamily ?? this.proseFontFamily,
    monoFontFamily: monoFontFamily ?? this.monoFontFamily,
    baseFontSizePx: baseFontSizePx ?? this.baseFontSizePx,
    lineHeightFactor: lineHeightFactor ?? this.lineHeightFactor,
    readingWidthPx: readingWidthPx ?? this.readingWidthPx,
  );

  @override
  bool operator ==(Object other) =>
      other is BistreTypographyConfig &&
      other.proseFontFamily == proseFontFamily &&
      other.monoFontFamily == monoFontFamily &&
      other.baseFontSizePx == baseFontSizePx &&
      other.lineHeightFactor == lineHeightFactor &&
      other.readingWidthPx == readingWidthPx;

  @override
  int get hashCode => Object.hash(
    proseFontFamily,
    monoFontFamily,
    baseFontSizePx,
    lineHeightFactor,
    readingWidthPx,
  );
}

/// Curated Sepia Atelier accent presets plus custom user hex support.
@immutable
class BistreAccentOption {
  const BistreAccentOption({
    required this.id,
    required this.dayPrimary,
    required this.dayBrass,
    required this.nightPrimary,
    required this.nightBrass,
  });

  final String id;
  final Color dayPrimary;
  final Color dayBrass;
  final Color nightPrimary;
  final Color nightBrass;

  static const List<BistreAccentOption> presets = <BistreAccentOption>[
    BistreAccentOption(
      id: 'wax',
      dayPrimary: Color(0xFFA83625),
      dayBrass: Color(0xFF8B5014),
      nightPrimary: Color(0xFFE06350),
      nightBrass: Color(0xFFE8A955),
    ),
    BistreAccentOption(
      id: 'brass',
      dayPrimary: Color(0xFF8B5014),
      dayBrass: Color(0xFF9C5D18),
      nightPrimary: Color(0xFFE5A44D),
      nightBrass: Color(0xFFF0BE73),
    ),
    BistreAccentOption(
      id: 'pine',
      dayPrimary: Color(0xFF255C40),
      dayBrass: Color(0xFF2E6E4D),
      nightPrimary: Color(0xFF6BC295),
      nightBrass: Color(0xFF85D1A8),
    ),
    BistreAccentOption(
      id: 'cobalt',
      dayPrimary: Color(0xFF264E86),
      dayBrass: Color(0xFF3262A3),
      nightPrimary: Color(0xFF77A8E8),
      nightBrass: Color(0xFF93BCEF),
    ),
    BistreAccentOption(
      id: 'plum',
      dayPrimary: Color(0xFF6B325E),
      dayBrass: Color(0xFF7D3E6E),
      nightPrimary: Color(0xFFD68CC5),
      nightBrass: Color(0xFFE3A6D5),
    ),
  ];

  static BistreAccentOption byId(String id) {
    for (final p in presets) {
      if (p.id == id) return p;
    }
    return presets.first;
  }

  /// Parses `#RRGGBB` or `RRGGBB` into a `Color`, returning `null` when invalid.
  static Color? tryParseHex(String raw) {
    final cleaned = raw.trim().replaceFirst('#', '');
    if (cleaned.length != 6) return null;
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return null;
    return Color(0xFF000000 | parsed);
  }

  /// `onFillInk`: warm ivory `#FFFDF8` whenever it reaches WCAG AA (>= 4.5:1) on `bg`,
  /// otherwise whichever of ivory / espresso `#19120D` contrasts more.
  static Color highContrastInkOn(Color bg) {
    const darkInk = Color(0xFF19120D);
    const lightInk = Color(0xFFFFFDF8);
    final withLight = contrastRatio(lightInk, bg);
    if (withLight >= 4.5) return lightInk;
    return contrastRatio(darkInk, bg) >= withLight ? darkInk : lightInk;
  }

  /// WCAG 2.x contrast ratio between two opaque colors.
  static double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// `readableInk`: nudges `ink` toward `toward` in small steps until it reaches `minRatio`
  /// against EVERY surface in `surfaces` (`docs/design/DESIGN.md` §2, 4-surface auto-contrast).
  static Color readableInk(
    Color ink,
    List<Color> surfaces,
    Color toward, {
    double minRatio = 4.5,
  }) {
    var current = ink;
    for (var step = 1; step <= 20; step++) {
      if (surfaces.every((s) => contrastRatio(current, s) >= minRatio)) {
        return current;
      }
      current = Color.lerp(ink, toward, step / 20)!;
    }
    return current;
  }
}

/// Calibrated Sepia Book color tokens anchored to `assets/brand/bistre-icon.svg` (ADR-0011).
/// Every text/background pair is mathematically verified WCAG AA (>=4.5:1) or AAA (>=7.5:1).
@immutable
class BistreThemeData {
  const BistreThemeData({
    required this.isDark,
    required this.bgCanvas,
    required this.bgSurface,
    required this.bgElevated,
    required this.inkPrimary,
    required this.inkSecondary,
    required this.inkMuted,
    required this.accentWax,
    required this.onAccentWax,
    required this.accentBrass,
    required this.statusOk,
    required this.statusWarn,
    required this.statusErr,
    required this.borderHairline,
    required this.selectionFill,
    required this.hoverTint,
    required this.scrim,
    required this.windowBorder,
    this.typography = BistreTypographyConfig.defaults,
    this.reducedEffects = false,
  });

  final bool isDark;
  final Color bgCanvas;
  final Color bgSurface;
  final Color bgElevated;
  final Color inkPrimary;
  final Color inkSecondary;
  final Color inkMuted;
  final Color accentWax;
  final Color onAccentWax;
  final Color accentBrass;
  final Color statusOk;
  final Color statusWarn;
  final Color statusErr;
  final Color borderHairline;
  final Color selectionFill;
  final Color hoverTint;
  final Color scrim;
  final Color windowBorder;
  final BistreTypographyConfig typography;

  /// Low-memory mode: overlay drop shadows are skipped (`docs/design/DESIGN.md` §8).
  final bool reducedEffects;

  /// Resolves a complete theme combining the chosen color preset (or Light/Dark default),
  /// user accent preset or custom hex, and user typography preferences.
  static BistreThemeData resolve({
    required bool isDark,
    String themeId = '',
    String accentPreset = 'brass',
    String customAccentHex = '',
    BistreTypographyConfig typography = BistreTypographyConfig.defaults,
    bool reducedEffects = false,
  }) {
    final preset = BistreThemePreset.tryById(themeId);
    final base = preset?.theme ?? (isDark ? warmDark : warmSepia);
    final effectiveDark = base.isDark;
    Color primaryAccent;
    Color brassAccent;
    if (accentPreset == 'preset') {
      primaryAccent = base.accentWax;
      brassAccent = base.accentBrass;
    } else if (accentPreset == 'custom') {
      final custom = BistreAccentOption.tryParseHex(customAccentHex);
      if (custom != null) {
        primaryAccent = custom;
        brassAccent = custom;
      } else {
        primaryAccent = base.accentWax;
        brassAccent = base.accentBrass;
      }
    } else {
      final opt = BistreAccentOption.byId(accentPreset);
      primaryAccent = effectiveDark ? opt.nightPrimary : opt.dayPrimary;
      brassAccent = effectiveDark ? opt.nightBrass : opt.dayBrass;
    }

    // The four reading surfaces every ink must stay legible on (incl. the hover composite).
    final surfaces = <Color>[
      base.bgCanvas,
      base.bgSurface,
      base.bgElevated,
      Color.alphaBlend(base.hoverTint, base.bgSurface),
    ];
    Color readable(Color ink) =>
        BistreAccentOption.readableInk(ink, surfaces, base.inkPrimary);
    final wax = readable(primaryAccent);

    return BistreThemeData(
      isDark: effectiveDark,
      bgCanvas: base.bgCanvas,
      bgSurface: base.bgSurface,
      bgElevated: base.bgElevated,
      inkPrimary: base.inkPrimary,
      inkSecondary: readable(base.inkSecondary),
      inkMuted: readable(base.inkMuted),
      accentWax: wax,
      onAccentWax: BistreAccentOption.highContrastInkOn(wax),
      accentBrass: readable(brassAccent),
      statusOk: readable(base.statusOk),
      statusWarn: readable(base.statusWarn),
      statusErr: readable(base.statusErr),
      borderHairline: base.borderHairline,
      selectionFill: brassAccent.withValues(alpha: effectiveDark ? 0.28 : 0.22),
      hoverTint: base.hoverTint,
      scrim: base.scrim,
      windowBorder: base.windowBorder,
      typography: typography,
      reducedEffects: reducedEffects,
    );
  }

  /// Soft warm diffused shadow for elevated surfaces and tactile active controls.
  List<BoxShadow> get cardShadow => reducedEffects
      ? const <BoxShadow>[]
      : isDark
      ? <BoxShadow>[
          BoxShadow(
            color: scrim.withValues(alpha: 0.42),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ]
      : <BoxShadow>[
          BoxShadow(
            color: inkPrimary.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: inkPrimary.withValues(alpha: 0.03),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ];

  /// Two-layer architectural depth for floating composer, popovers, and drawers.
  List<BoxShadow> get floatingShadow => reducedEffects
      ? const <BoxShadow>[]
      : isDark
      ? <BoxShadow>[
          BoxShadow(
            color: scrim.withValues(alpha: 0.65),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: scrim.withValues(alpha: 0.45),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ]
      : <BoxShadow>[
          BoxShadow(
            color: inkPrimary.withValues(alpha: 0.09),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: inkPrimary.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ];

  static const BistreThemeData warmSepia = BistreThemeData(
    isDark: false,
    bgCanvas: Color(0xFFF6EFE2),
    bgSurface: Color(0xFFEFE3CF),
    bgElevated: Color(0xFFFFFDF8),
    inkPrimary: Color(0xFF24160E),
    inkSecondary: Color(0xFF594030),
    inkMuted: Color(0xFF6E5442),
    accentWax: Color(0xFF8B5014),
    onAccentWax: Color(0xFFFFFDF8),
    accentBrass: Color(0xFF9C5D18),
    statusOk: Color(0xFF2B5E3F),
    statusWarn: Color(0xFF8A520F),
    statusErr: Color(0xFF9E2A1C),
    borderHairline: Color(0x2E6B4B32), // #6B4B32 @ 18%
    selectionFill: Color(0x42DA8F3D), // #DA8F3D @ 26%
    hoverTint: Color(0x146B4B32), // #6B4B32 @ 8%
    scrim: Color(0x5224160E), // #24160E @ 32%
    windowBorder: Color(0xFFD8C8B2),
  );

  static const BistreThemeData warmDark = BistreThemeData(
    isDark: true,
    bgCanvas: Color(0xFF19120D),
    bgSurface: Color(0xFF231912),
    bgElevated: Color(0xFF2E2118),
    inkPrimary: Color(0xFFF2E6D3),
    inkSecondary: Color(0xFFC9B69E),
    inkMuted: Color(0xFFA38E76),
    accentWax: Color(0xFFE5A44D),
    onAccentWax: Color(0xFF19120D),
    accentBrass: Color(0xFFF0BE73),
    statusOk: Color(0xFF74B88E),
    statusWarn: Color(0xFFE6A856),
    statusErr: Color(0xFFEB6B59),
    borderHairline: Color(0x29E8D7BC), // #E8D7BC @ 16%
    selectionFill: Color(0x47E8A955), // #E8A955 @ 28%
    hoverTint: Color(0x14E8D7BC), // #E8D7BC @ 8%
    scrim: Color(0x8F0D0906), // #0D0906 @ 56%
    windowBorder: Color(0xFF3D2F24),
  );

  @override
  bool operator ==(Object other) =>
      other is BistreThemeData &&
      other.isDark == isDark &&
      other.bgCanvas == bgCanvas &&
      other.bgSurface == bgSurface &&
      other.bgElevated == bgElevated &&
      other.inkPrimary == inkPrimary &&
      other.accentWax == accentWax &&
      other.accentBrass == accentBrass &&
      other.typography == typography &&
      other.reducedEffects == reducedEffects;

  @override
  int get hashCode => Object.hash(
    isDark,
    bgCanvas,
    bgSurface,
    bgElevated,
    inkPrimary,
    accentWax,
    accentBrass,
    typography,
    reducedEffects,
  );
}

/// Curated color themes with plain everyday names and WCAG-verified contrast ratios.
/// everyday names and automatic 4-surface WCAG AA contrast via [BistreThemeData.resolve].
@immutable
class BistreThemePreset {
  const BistreThemePreset({required this.id, required this.theme});

  final String id;
  final BistreThemeData theme;

  static const List<BistreThemePreset> presets = <BistreThemePreset>[
    BistreThemePreset(id: 'day', theme: BistreThemeData.warmSepia),
    BistreThemePreset(
      id: 'blue_cream',
      theme: BistreThemeData(
        isDark: false,
        bgCanvas: Color(0xFFEFEEE3),
        bgSurface: Color(0xFFE6E5D8),
        bgElevated: Color(0xFFF8F7EF),
        inkPrimary: Color(0xFF1D2230),
        inkSecondary: Color(0xFF4A4F5C),
        inkMuted: Color(0xFF666A72),
        accentWax: Color(0xFF2A4A9E),
        onAccentWax: Color(0xFFFFFDF8),
        accentBrass: Color(0xFF8F6A12),
        statusOk: Color(0xFF245C42),
        statusWarn: Color(0xFF8F6A12),
        statusErr: Color(0xFFB3261E),
        borderHairline: Color(0x2E4A4F5C),
        selectionFill: Color(0x382A4A9E),
        hoverTint: Color(0x141D2230),
        scrim: Color(0x521D2230),
        windowBorder: Color(0xFFD4D3C2),
      ),
    ),
    BistreThemePreset(
      id: 'night_blue',
      theme: BistreThemeData(
        isDark: true,
        bgCanvas: Color(0xFF12151C),
        bgSurface: Color(0xFF0E1117),
        bgElevated: Color(0xFF191D26),
        inkPrimary: Color(0xFFE6E4D8),
        inkSecondary: Color(0xFFA9ACB3),
        inkMuted: Color(0xFF8A8F99),
        accentWax: Color(0xFF8FA6E8),
        onAccentWax: Color(0xFF12151C),
        accentBrass: Color(0xFFD4B25A),
        statusOk: Color(0xFF74C29A),
        statusWarn: Color(0xFFD4B25A),
        statusErr: Color(0xFFF0857A),
        borderHairline: Color(0x38A9ACB3),
        selectionFill: Color(0x428FA6E8),
        hoverTint: Color(0x14E6E4D8),
        scrim: Color(0x8F090B10),
        windowBorder: Color(0xFF2C3240),
      ),
    ),
    BistreThemePreset(
      id: 'warm_ivory',
      theme: BistreThemeData(
        isDark: false,
        bgCanvas: Color(0xFFF8F7F4),
        bgSurface: Color(0xFFEFECE6),
        bgElevated: Color(0xFFFFFFFF),
        inkPrimary: Color(0xFF1E1B18),
        inkSecondary: Color(0xFF5A524C),
        inkMuted: Color(0xFF6F6760),
        accentWax: Color(0xFF7A5216),
        onAccentWax: Color(0xFFFFFDF8),
        accentBrass: Color(0xFF9E6B24),
        statusOk: Color(0xFF2B5E3F),
        statusWarn: Color(0xFF8A520F),
        statusErr: Color(0xFFA62B2B),
        borderHairline: Color(0x2E5A524C),
        selectionFill: Color(0x389E6B24),
        hoverTint: Color(0x121E1B18),
        scrim: Color(0x521E1B18),
        windowBorder: Color(0xFFE2DDD5),
      ),
    ),
    BistreThemePreset(
      id: 'deep_sepia',
      theme: BistreThemeData(
        isDark: false,
        bgCanvas: Color(0xFFEADBC0),
        bgSurface: Color(0xFFDECBA8),
        bgElevated: Color(0xFFF3E7D0),
        inkPrimary: Color(0xFF1F160F),
        inkSecondary: Color(0xFF523F2E),
        inkMuted: Color(0xFF6B5744),
        accentWax: Color(0xFF8C3823),
        onAccentWax: Color(0xFFFFFDF8),
        accentBrass: Color(0xFF9E6B24),
        statusOk: Color(0xFF26573A),
        statusWarn: Color(0xFF7E4A10),
        statusErr: Color(0xFF9E2A1C),
        borderHairline: Color(0x33523F2E),
        selectionFill: Color(0x3D9E6B24),
        hoverTint: Color(0x141F160F),
        scrim: Color(0x521F160F),
        windowBorder: Color(0xFFC4AE88),
      ),
    ),
    BistreThemePreset(id: 'night', theme: BistreThemeData.warmDark),
    BistreThemePreset(
      id: 'pure_black',
      theme: BistreThemeData(
        isDark: true,
        bgCanvas: Color(0xFF0A0908),
        bgSurface: Color(0xFF12100E),
        bgElevated: Color(0xFF181512),
        inkPrimary: Color(0xFFE5DDD0),
        inkSecondary: Color(0xFFB3A48E),
        inkMuted: Color(0xFF8C7E6A),
        accentWax: Color(0xFFC97A3E),
        onAccentWax: Color(0xFF0A0908),
        accentBrass: Color(0xFFC49142),
        statusOk: Color(0xFF74B88E),
        statusWarn: Color(0xFFE0A450),
        statusErr: Color(0xFFEB6B59),
        borderHairline: Color(0x2EE5DDD0),
        selectionFill: Color(0x47C97A3E),
        hoverTint: Color(0x14E5DDD0),
        scrim: Color(0xA6000000),
        windowBorder: Color(0xFF2E2822),
      ),
    ),
    BistreThemePreset(
      id: 'clean_paper',
      theme: BistreThemeData(
        isDark: false,
        bgCanvas: Color(0xFFF7F7F5),
        bgSurface: Color(0xFFEFEFED),
        bgElevated: Color(0xFFFFFFFF),
        inkPrimary: Color(0xFF18181B),
        inkSecondary: Color(0xFF52525B),
        inkMuted: Color(0xFF686870),
        accentWax: Color(0xFF4F46E5),
        onAccentWax: Color(0xFFFFFFFF),
        accentBrass: Color(0xFF0D9488),
        statusOk: Color(0xFF1E6B47),
        statusWarn: Color(0xFF9A5B13),
        statusErr: Color(0xFFB42318),
        borderHairline: Color(0x2618181B),
        selectionFill: Color(0x334F46E5),
        hoverTint: Color(0x1018181B),
        scrim: Color(0x5218181B),
        windowBorder: Color(0xFFE4E4E0),
      ),
    ),
    BistreThemePreset(
      id: 'dark_slate',
      theme: BistreThemeData(
        isDark: true,
        bgCanvas: Color(0xFF0E0F12),
        bgSurface: Color(0xFF131519),
        bgElevated: Color(0xFF17191E),
        inkPrimary: Color(0xFFECECEE),
        inkSecondary: Color(0xFFA0A6B2),
        inkMuted: Color(0xFF838996),
        accentWax: Color(0xFF5E6AD2),
        onAccentWax: Color(0xFFFFFFFF),
        accentBrass: Color(0xFF38BDF8),
        statusOk: Color(0xFF6EE7B7),
        statusWarn: Color(0xFFFBBF24),
        statusErr: Color(0xFFF87171),
        borderHairline: Color(0x2EECECEE),
        selectionFill: Color(0x425E6AD2),
        hoverTint: Color(0x14ECECEE),
        scrim: Color(0x99060709),
        windowBorder: Color(0xFF2A2E37),
      ),
    ),
  ];

  static BistreThemePreset? tryById(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  static bool isDarkFor(String themeId, {required bool systemIsDark}) {
    if (themeId == 'system') return systemIsDark;
    if (themeId == 'night') return true;
    if (themeId == 'day') return false;
    return tryById(themeId)?.theme.isDark ?? systemIsDark;
  }

  static String activePresetId(String themeId, {required bool isDark}) {
    if (themeId == 'system') return isDark ? 'night' : 'day';
    return tryById(themeId)?.id ?? (isDark ? 'night' : 'day');
  }
}

/// Dynamic typography role factory honoring user-chosen local fonts & exact px size.
class BistreTypography {
  const BistreTypography._();

  static const String fontProse = 'Inter';
  static const String fontMono = 'JetBrainsMono';
  static const String fontMath = 'NotoSansMath';
  static const List<String> _proseFallback = <String>[
    'Inter',
    'BistreArabicFallback',
    'Segoe UI',
    'Noto Sans Arabic',
    'Tahoma',
    'Arial',
  ];
  static const List<String> _monoFallback = <String>[
    'JetBrainsMono',
    'Cascadia Mono',
    'Consolas',
    'Inter',
  ];

  static String _proseFamily(BistreTypographyConfig cfg) =>
      cfg.proseFontFamily.trim().isEmpty ? fontProse : cfg.proseFontFamily;

  static String _monoFamily(BistreTypographyConfig cfg) =>
      cfg.monoFontFamily.trim().isEmpty ? fontMono : cfg.monoFontFamily;

  static TextStyle titleLarge(
    Color color, {
    BistreTypographyConfig config = BistreTypographyConfig.defaults,
  }) {
    final sz = (config.baseFontSizePx * 1.46).clamp(18.0, 36.0);
    return TextStyle(
      fontFamily: _proseFamily(config),
      fontFamilyFallback: _proseFallback,
      fontSize: sz,
      height: 1.32,
      fontWeight: FontWeight.w600,
      color: color,
      letterSpacing: -0.35,
    );
  }

  static TextStyle titleMedium(
    Color color, {
    BistreTypographyConfig config = BistreTypographyConfig.defaults,
  }) {
    final sz = (config.baseFontSizePx * 1.08).clamp(14.0, 26.0);
    return TextStyle(
      fontFamily: _proseFamily(config),
      fontFamilyFallback: _proseFallback,
      fontSize: sz,
      height: 1.36,
      fontWeight: FontWeight.w600,
      color: color,
      letterSpacing: -0.15,
    );
  }

  static TextStyle bodyProse(
    Color color, {
    BistreTypographyConfig config = BistreTypographyConfig.defaults,
  }) {
    return TextStyle(
      fontFamily: _proseFamily(config),
      fontFamilyFallback: _proseFallback,
      fontSize: config.baseFontSizePx,
      height: config.lineHeightFactor,
      fontWeight: FontWeight.w400,
      color: color,
    );
  }

  static TextStyle bodyCompact(
    Color color, {
    BistreTypographyConfig config = BistreTypographyConfig.defaults,
  }) {
    final sz = (config.baseFontSizePx - 1.0).clamp(12.0, 24.0);
    return TextStyle(
      fontFamily: _proseFamily(config),
      fontFamilyFallback: _proseFallback,
      fontSize: sz,
      height: 1.44,
      fontWeight: FontWeight.w400,
      color: color,
    );
  }

  static TextStyle labelStrong(
    Color color, {
    BistreTypographyConfig config = BistreTypographyConfig.defaults,
  }) {
    final sz = (config.baseFontSizePx - 1.5).clamp(12.0, 21.0);
    return TextStyle(
      fontFamily: _proseFamily(config),
      fontFamilyFallback: _proseFallback,
      fontSize: sz,
      height: 1.38,
      fontWeight: FontWeight.w600,
      color: color,
    );
  }

  static TextStyle captionMeta(
    Color color, {
    BistreTypographyConfig config = BistreTypographyConfig.defaults,
  }) {
    final sz = (config.baseFontSizePx - 2.5).clamp(11.0, 18.0);
    return TextStyle(
      fontFamily: _proseFamily(config),
      fontFamilyFallback: _proseFallback,
      fontSize: sz,
      height: 1.34,
      fontWeight: FontWeight.w500,
      color: color,
    );
  }

  static TextStyle codeBlock(
    Color color, {
    BistreTypographyConfig config = BistreTypographyConfig.defaults,
  }) {
    final sz = (config.baseFontSizePx - 1.5).clamp(11.0, 24.0);
    return TextStyle(
      fontFamily: _monoFamily(config),
      fontFamilyFallback: _monoFallback,
      fontSize: sz,
      height: 1.52,
      fontWeight: FontWeight.w400,
      color: color,
    );
  }
}

/// Frequency-aware motion policy honoring `MediaQuery.maybeReduceMotionOf` (ADR-0011).
class BistreMotion {
  const BistreMotion._();

  /// Zero duration for 100+/day and keyboard-initiated interactions.
  static const Duration instant = Duration.zero;

  static bool shouldReduceMotion(
    BuildContext context, {
    bool reduceMotionOverride = false,
  }) {
    if (reduceMotionOverride) return true;
    final reduceMotion = MediaQuery.maybeReduceMotionOf(context) ?? false;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final accessibleNav =
        MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    return reduceMotion || disableAnimations || accessibleNav;
  }

  /// Motion timings (`docs/design/DESIGN.md` §6): 150 ms arriving,
  /// 110 ms leaving, 180 ms travelling. Overlays and drawers disappear instantly when closed, so
  /// closing never waits on an animation.
  static const Duration arriving = Duration(milliseconds: 150);
  static const Duration leaving = Duration(milliseconds: 110);
  static const Duration travelling = Duration(milliseconds: 180);

  /// `leaving`, or zero under reduced motion.
  static Duration leaveDuration(
    BuildContext context, {
    bool reduceMotionOverride = false,
  }) => shouldReduceMotion(context, reduceMotionOverride: reduceMotionOverride)
      ? Duration.zero
      : leaving;

  /// Crisp ease-out entrance for overlays, popovers, and toasts (transform/opacity only).
  static Duration overlayDuration(
    BuildContext context, {
    bool reduceMotionOverride = false,
  }) {
    if (shouldReduceMotion(
      context,
      reduceMotionOverride: reduceMotionOverride,
    )) {
      return Duration.zero;
    }
    return arriving;
  }

  /// Smooth GPU-composited slide/fade duration for drawers and spatial panels (transform/opacity only).
  static Duration panelDuration(
    BuildContext context, {
    bool reduceMotionOverride = false,
  }) {
    if (shouldReduceMotion(
      context,
      reduceMotionOverride: reduceMotionOverride,
    )) {
      return Duration.zero;
    }
    return travelling;
  }

  static const Curve easeOut = Curves.easeOutCubic;
}

/// 8pt spacing scale & layout geometry constants.
class BistreSpacing {
  const BistreSpacing._();

  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double sidebarWidth = 268;
  static const double inspectorWidth = 312;
  static const double maxReadingWidth = 760;
  static const double maxBreakoutWidth = 1160;
}

class BistreTheme extends InheritedWidget {
  const BistreTheme({super.key, required this.data, required super.child});

  final BistreThemeData data;

  static BistreThemeData of(BuildContext context) {
    final inherited = context.dependOnInheritedWidgetOfExactType<BistreTheme>();
    assert(inherited != null, 'BistreTheme missing above context.');
    return inherited!.data;
  }

  @override
  bool updateShouldNotify(BistreTheme oldWidget) => data != oldWidget.data;
}
