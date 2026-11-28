import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android only: returns the secret vault's data key, unwrapped by the Android Keystore in
/// `VaultKeyStore.kt` (ADR-0010). The Rust core seals every vault entry with it; Dart only
/// carries the opaque bytes into `initRuntime` and wipes mutable copies right after.
///
/// Returns `null` on other platforms (Windows uses DPAPI, Linux resolves its key in Rust) and
/// when the Keystore fails, in which case the core opens the vault read-only and refuses to store
/// new keys unencrypted.
Future<Uint8List?> obtainAndroidVaultKey() async {
  if (!Platform.isAndroid) return null;
  const channel = MethodChannel('dev.bistre.app/vault_key');
  try {
    return await channel.invokeMethod<Uint8List>('obtainDataKey');
  } on PlatformException catch (e) {
    debugPrint('[bistre] vault key unavailable: ${e.code} ${e.message}');
    return null;
  } on MissingPluginException catch (e) {
    debugPrint('[bistre] vault key channel missing: ${e.message}');
    return null;
  }
}

/// Best-effort in-place zeroing of a Dart vault-key buffer.
///
/// Flutter's platform-channel reply buffers are wrapped as unmodifiable `ByteData` views
/// (`_wrapUnmodifiableByteData`), so `ReadBuffer.getUint8List` yields an unmodifiable
/// `Uint8List` view that cannot be written in Dart (the Kotlin side zeroes its own copy after
/// encoding, and Rust keeps a zeroizing copy). Mutable buffers (such as tests) are zeroed.
void wipeVaultKeyBytes(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return;
  try {
    bytes.fillRange(0, bytes.length, 0);
  } on UnsupportedError {
    // Platform-channel reply views are read-only by Flutter engine design.
    return;
  }
}
