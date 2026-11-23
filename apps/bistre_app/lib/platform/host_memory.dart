import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop_host.dart';

/// Hosts with less physical memory than this run in low-memory mode (Spec 11 §3).
const int kLowMemoryThresholdBytes = 4 * 1024 * 1024 * 1024;

/// Streaming redraw interval in low-memory mode (30 fps).
const Duration kLowMemoryFrameInterval = Duration(milliseconds: 33);

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
