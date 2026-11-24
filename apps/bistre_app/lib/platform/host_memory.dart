import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_host.dart';

/// Hosts with less physical memory than this run in low-memory mode (Spec 11 §3).
const int kLowMemoryThresholdBytes = 4 * 1024 * 1024 * 1024;

/// GPU resource cache cap (Parchment v2.6.0 `desktopMain/.../Main.kt:183-188`):
/// 48 MiB on normal hosts, 32 MiB on `< 4 GiB` hosts, preventing Intel UMA bloat.
const int kGpuResourceCacheNormalBytes = 48 * 1024 * 1024;
const int kGpuResourceCacheLowMemoryBytes = 32 * 1024 * 1024;

/// Streaming redraw interval in low-memory mode (30 fps).
const Duration kLowMemoryFrameInterval = Duration(milliseconds: 33);

/// Caps Flutter's Skia GPU resource cache (`SystemChannels.skia`,
/// `Skia.setResourceCacheMaxBytes`). No-op on backends that do not expose the channel.
Future<void> configureGpuResourceCacheCap({required bool lowMemory}) async {
  final limitBytes = lowMemory
      ? kGpuResourceCacheLowMemoryBytes
      : kGpuResourceCacheNormalBytes;
  try {
    await SystemChannels.skia.invokeMethod<void>(
      'Skia.setResourceCacheMaxBytes',
      limitBytes,
    );
  } on MissingPluginException {
    // Tests and non-Skia backends may not register `flutter/skia`.
    return;
  } on PlatformException catch (e) {
    debugPrint('[bistre] skia resource cache cap skipped: ${e.code}');
  }
}

/// Detects low-memory hardware: `< 4 GB` RAM (Windows/Linux) or Android `isLowRamDevice`.
/// Unknown memory is treated as normal (never degrade a capable machine on a failed probe).
Future<bool> detectLowMemoryHost() async {
  try {
    if (Platform.isAndroid) {
      const channel = MethodChannel('dev.bistre.app/power_guard');
      final info = await channel.invokeMethod<Map<Object?, Object?>>(
        'getMemoryInfo',
      );
      final lowRam = info?['lowRamDevice'] == true;
      final total = (info?['totalBytes'] as num?)?.toInt() ?? 0;
      return lowRam || (total > 0 && total < kLowMemoryThresholdBytes);
    }
    if (Platform.isWindows) {
      final total = await BistreDesktopHost.totalMemoryBytes();
      return total > 0 && total < kLowMemoryThresholdBytes;
    }
    if (Platform.isLinux) {
      final meminfo = File('/proc/meminfo');
      if (!meminfo.existsSync()) return false;
      final match = RegExp(
        r'^MemTotal:\s+(\d+)\s+kB',
        multiLine: true,
      ).firstMatch(meminfo.readAsStringSync());
      final kb = int.tryParse(match?.group(1) ?? '');
      return kb != null && kb * 1024 < kLowMemoryThresholdBytes;
    }
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  } on FileSystemException {
    return false;
  }
  return false;
}
