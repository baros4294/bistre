import 'package:flutter/widgets.dart';

import '../../design/bistre_theme.dart';

final Map<String, _CodeHighlightStyles> _codeStyleCache =
    <String, _CodeHighlightStyles>{};

final class _CodeHighlightStyles {
  _CodeHighlightStyles(BistreSyntaxPalette palette, BistreTypographyConfig typo)
    : base = BistreTypography.codeBlock(palette.base, config: typo),
      comment = BistreTypography.codeBlock(
        palette.comment,
        config: typo,
      ).copyWith(fontStyle: FontStyle.italic),
      string = BistreTypography.codeBlock(palette.string, config: typo),
      keyword = BistreTypography.codeBlock(
        palette.keyword,
        config: typo,
      ).copyWith(fontWeight: FontWeight.w500),
      typeOrNumber = BistreTypography.codeBlock(
        palette.typeOrNumber,
        config: typo,
      );

  final TextStyle base;
  final TextStyle comment;
  final TextStyle string;
  final TextStyle keyword;
  final TextStyle typeOrNumber;
}

/// Zero-dependency syntax highlighter using WCAG-verified `BistreSyntaxPalette` themes.
/// Preserves every source character verbatim so text selection and `toPlainText()` stay exact.
TextSpan highlightCodeSpans(
  String source,
  BistreThemeData theme, {
  String? syntaxThemeIdOverride,
}) {
  final syntaxId = syntaxThemeIdOverride ?? theme.syntaxThemeId;
  final palette = BistreSyntaxPalette.forId(syntaxId, isDark: theme.isDark);
  final cacheKey =
      '${palette.id}:${theme.typography.monoFontFamily}:${theme.typography.baseFontSizePx}';
  final styles = _codeStyleCache.putIfAbsent(
    cacheKey,
    () => _CodeHighlightStyles(palette, theme.typography),
  );

  final spans = <InlineSpan>[];
  var cursor = 0;

  for (final match in _codeTokenPattern.allMatches(source)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: source.substring(cursor, match.start)));
    }
    final tok = match.group(0)!;
    if (tok.startsWith('//') || tok.startsWith('/*') || tok.startsWith('#')) {
      spans.add(TextSpan(text: tok, style: styles.comment));
    } else if (tok.startsWith('"') ||
        tok.startsWith("'") ||
        tok.startsWith('`')) {
      spans.add(TextSpan(text: tok, style: styles.string));
    } else if (_codeKeywords.contains(tok)) {
      spans.add(TextSpan(text: tok, style: styles.keyword));
    } else if (_isTypeOrNumber(tok)) {
      spans.add(TextSpan(text: tok, style: styles.typeOrNumber));
    } else {
      spans.add(TextSpan(text: tok));
    }
    cursor = match.end;
  }

  if (cursor < source.length) {
    spans.add(TextSpan(text: source.substring(cursor)));
  }

  return TextSpan(style: styles.base, children: spans);
}

final RegExp _codeTokenPattern = RegExp(
  r'//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*|"(?:\\.|[^"\\])*"|'
  r"'(?:\\.|[^'\\])*'"
  r'|\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b|\b[A-Za-z_][A-Za-z0-9_]*\b',
);

const Set<String> _codeKeywords = <String>{
  'pub',
  'fn',
  'let',
  'mut',
  'const',
  'static',
  'struct',
  'enum',
  'impl',
  'trait',
  'match',
  'if',
  'else',
  'for',
  'while',
  'loop',
  'return',
  'async',
  'await',
  'use',
  'mod',
  'where',
  'class',
  'final',
  'void',
  'var',
  'import',
  'export',
  'from',
  'def',
  'function',
  'type',
  'interface',
  'true',
  'false',
  'null',
  'None',
  'self',
  'this',
  'super',
  'PRAGMA',
  'SELECT',
  'FROM',
  'WHERE',
  'INSERT',
  'UPDATE',
  'DELETE',
};

bool _isTypeOrNumber(String token) {
  if (token.isEmpty) return false;
  final first = token.codeUnitAt(0);
  if (first >= 48 && first <= 57) return true;
  if (first >= 65 && first <= 90) return true;
  return token == 'i32' ||
      token == 'i64' ||
      token == 'u32' ||
      token == 'u64' ||
      token == 'usize' ||
      token == 'bool' ||
      token == 'str';
}
