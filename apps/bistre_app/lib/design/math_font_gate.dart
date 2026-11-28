import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Lazily registers the bundled `NotoSansMath` face the first time a math block renders, so the
/// font never costs startup time or memory in chats without math (Spec 11 §3).
class MathFontGate {
  MathFontGate._();

  static const String family = 'NotoSansMath';
  static const String asset = 'assets/fonts/noto-sans-math-regular.ttf';

  /// Flips to `true` once the face is registered; math widgets rebuild on it.
  static final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  static Future<void>? _loading;

  /// Starts (or joins) the one-time registration; idempotent and never throws. `source`
  /// overrides the bundled asset bytes (tests and the gallery read the file from disk).
  static Future<void> ensureLoaded({Future<ByteData>? source}) =>
      _loading ??= _load(source ?? rootBundle.load(asset));

  static Future<void> _load(Future<ByteData> bytes) async {
    try {
      final loader = FontLoader(family)..addFont(bytes);
      await loader.load();
      ready.value = true;
    } on FlutterError {
      // Missing asset in a stripped test bundle: fall back to system math glyphs.
    } on PlatformException {
      // Same fallback on hosts that refuse runtime font registration.
    }
  }
}
