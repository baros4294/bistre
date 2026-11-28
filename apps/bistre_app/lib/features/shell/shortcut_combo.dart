import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Why a recorded key press cannot become a shortcut.
enum ShortcutRefusal {
  /// Without Ctrl, Alt or Meta the key would stop typing its character.
  needsModifier,

  /// Copy, cut, paste, undo, redo and select all keep their editing meaning.
  editing,
}

/// A custom keyboard shortcut: the text saved in settings ("Ctrl+Shift+F") and the activator
/// the shell binds. One parser serves both, so whatever can be recorded also fires.
abstract final class ShortcutCombo {
  static final Map<String, LogicalKeyboardKey> _keys = {
    for (var c = 0; c < 26; c++)
      String.fromCharCode(0x41 + c): LogicalKeyboardKey(
        LogicalKeyboardKey.keyA.keyId + c,
      ),
    for (var d = 0; d < 10; d++)
      '$d': LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + d),
    for (final (i, f) in _functionKeys.indexed) 'F${i + 1}': f,
    ',': LogicalKeyboardKey.comma,
    '/': LogicalKeyboardKey.slash,
    '.': LogicalKeyboardKey.period,
    ';': LogicalKeyboardKey.semicolon,
  };

  static const List<LogicalKeyboardKey> _functionKeys = [
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  ];

  static const Set<String> _editingKeys = {'A', 'C', 'V', 'X', 'Y', 'Z'};

  /// The saved name of [key], or null when it cannot be part of a shortcut.
  static String? nameOf(LogicalKeyboardKey key) {
    for (final entry in _keys.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }

  /// The combo for [key] pressed with these modifiers, or why it is refused. Null for a key
  /// that cannot be bound at all (a modifier on its own, arrows, Enter).
  static ({String? combo, ShortcutRefusal? refusal})? record(
    LogicalKeyboardKey key, {
    bool control = false,
    bool meta = false,
    bool alt = false,
    bool shift = false,
  }) {
    final name = nameOf(key);
    if (name == null) return null;
    final functionKey = _functionKeys.contains(key);
    if (!functionKey && !control && !meta && !alt) {
      return (combo: null, refusal: ShortcutRefusal.needsModifier);
    }
    if ((control || meta) && !alt && _editingKeys.contains(name)) {
      return (combo: null, refusal: ShortcutRefusal.editing);
    }
    final combo = [
      if (control) 'Ctrl',
      if (meta) 'Meta',
      if (alt) 'Alt',
      if (shift) 'Shift',
      name,
    ].join('+');
    return (combo: combo, refusal: null);
  }

  /// The activator for a saved [combo], or null when it names no bindable key.
  static SingleActivator? parse(String combo) {
    var control = false;
    var meta = false;
    var alt = false;
    var shift = false;
    LogicalKeyboardKey? trigger;
    for (final part in combo.split('+').map((p) => p.trim())) {
      switch (part.toLowerCase()) {
        case '':
          continue;
        case 'ctrl' || 'control':
          control = true;
        case 'meta' || 'cmd':
          meta = true;
        case 'alt':
          alt = true;
        case 'shift':
          shift = true;
        default:
          trigger = _keys[part.toUpperCase()];
      }
    }
    if (trigger == null) return null;
    return SingleActivator(
      trigger,
      control: control,
      meta: meta,
      alt: alt,
      shift: shift,
    );
  }

  /// Whether [a] and [b] are the same key press, whatever their spelling.
  static bool same(String a, String b) {
    final x = parse(a);
    final y = parse(b);
    return x != null &&
        y != null &&
        x.trigger == y.trigger &&
        x.control == y.control &&
        x.meta == y.meta &&
        x.alt == y.alt &&
        x.shift == y.shift;
  }
}
