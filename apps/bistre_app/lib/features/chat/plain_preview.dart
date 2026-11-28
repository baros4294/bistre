import 'package:flutter/widgets.dart';

/// [text] cut to at most [max] characters, then "…". A character is what a reader sees
/// (an emoji, an accented letter), so a cut never splits one.
String clipText(String text, int max) {
  final chars = text.characters;
  return chars.length <= max ? text : '${chars.take(max)}…';
}

/// [n] moved one unit on when `text.substring(0, n)` would end in half of a surrogate pair
/// (most emoji), so a cut by length never shows a broken character.
int wholeUnits(String text, int n) {
  if (n <= 0 || n >= text.length) return n;
  final unit = text.codeUnitAt(n - 1);
  return unit >= 0xD800 && unit <= 0xDBFF ? n + 1 : n;
}

/// A message as plain text with its line breaks, for Copy as plain text: heading, quote,
/// emphasis, and code marks and link targets are dropped; code block lines and list
/// markers are kept as written.
String markdownToPlainText(String markdown) {
  final out = <String>[];
  var inCode = false;
  for (final raw in markdown.split('\n')) {
    final t = raw.trimLeft();
    if (t.startsWith('```') || t.startsWith('~~~')) {
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      out.add(raw);
      continue;
    }
    final line = raw
        .replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '')
        .replaceFirst(RegExp(r'^\s*(>\s?)+'), '');
    // Inline code (between backticks) keeps its text as written.
    final parts = line.split('`');
    for (var i = 0; i < parts.length; i += 2) {
      parts[i] = parts[i]
          .replaceAllMapped(
            RegExp(r'!?\[([^\]]*)\]\([^)]*\)'),
            (m) => m[1] ?? '',
          )
          .replaceAll(RegExp(r'(\*\*|__|~~)'), '')
          .replaceAllMapped(
            RegExp(r'(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])'),
            (m) => m[1] ?? '',
          );
    }
    out.add(parts.join());
  }
  return out.join('\n').trim();
}

/// One line of a message as plain words, for previews (the conversation tree): the marks
/// [markdownToPlainText] drops plus list bullets, with runs of space folded to one, so an
/// identifier keeps its underscores. Bounded: at most [maxChars] characters, then "…".
String plainPreview(String markdown, {int maxChars = 108}) {
  final source = markdown.length > 4096
      ? markdown.substring(0, 4096)
      : markdown;
  final single = markdownToPlainText(source)
      .split('\n')
      .map((l) => l.trim().replaceFirst(RegExp(r'^([-*+]|\d+[.)])\s+'), ''))
      .where((l) => l.isNotEmpty)
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ');
  return clipText(single, maxChars);
}
