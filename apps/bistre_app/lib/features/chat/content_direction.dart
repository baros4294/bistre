import 'package:flutter/widgets.dart';

/// Direction of a message from its first strong character (Unicode bidi rules P2–P3), or null
/// when it has none (only digits, punctuation, or symbols), so the caller keeps the surrounding
/// direction. An English reply inside the Arabic UI then reads left to right with its punctuation
/// in place, and an Arabic reply inside the English UI reads right to left.
TextDirection? contentDirection(String text) {
  for (final rune in text.runes) {
    if (_isStrongRtl(rune)) return TextDirection.rtl;
    if (_isStrongLtr(rune)) return TextDirection.ltr;
  }
  return null;
}

/// Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, their presentation forms, and the
/// supplementary RTL blocks.
bool _isStrongRtl(int r) =>
    (r >= 0x0590 && r <= 0x08FF) ||
    (r >= 0xFB1D && r <= 0xFDFF) ||
    (r >= 0xFE70 && r <= 0xFEFF) ||
    (r >= 0x10800 && r <= 0x10FFF) ||
    (r >= 0x1E800 && r <= 0x1EFFF);

/// Letters of the common LTR scripts: Latin (incl. Vietnamese), Greek, Cyrillic, Armenian,
/// Indic, Thai, Georgian, Hangul, kana, and CJK.
bool _isStrongLtr(int r) =>
    (r >= 0x41 && r <= 0x5A) ||
    (r >= 0x61 && r <= 0x7A) ||
    (r >= 0xC0 && r <= 0x24F && r != 0xD7 && r != 0xF7) ||
    (r >= 0x0370 && r <= 0x058F) ||
    (r >= 0x0900 && r <= 0x0E7F) ||
    (r >= 0x10A0 && r <= 0x10FF) ||
    (r >= 0x1E00 && r <= 0x1FFF) ||
    (r >= 0x3040 && r <= 0x9FFF) ||
    (r >= 0xAC00 && r <= 0xD7AF);
