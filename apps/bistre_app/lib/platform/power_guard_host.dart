import 'dart:io';

import 'package:flutter/services.dart';

/// Live Android foreground-service and battery-exemption status returned by `MainActivity`.
class AndroidPowerState {
  const AndroidPowerState({
    this.fgsActive = false,
    this.batteryUnrestricted = false,
  });

  final bool fgsActive;
  final bool batteryUnrestricted;
}

/// Live Android Termux (`com.termux.RUN_COMMAND`) availability status.
class AndroidTermuxStatus {
  const AndroidTermuxStatus({
    this.installed = false,
    this.permissionGranted = false,
    this.setupCommand = 'mkdir -p ~/.termux && echo "allow-external-apps = true" >> ~/.termux/termux.properties',
  });

  final bool installed;
  final bool permissionGranted;
  final String setupCommand;
}

/// Thin platform-channel shim coordinating Android `specialUse` FGS, battery exemption,
/// OS power callbacks, and optional Termux command execution. Safe no-op on desktop/tests.
class BistrePowerGuardHost {
  const BistrePowerGuardHost._();

  static const MethodChannel _powerChannel = MethodChannel(
    'dev.bistre.app/power_guard',
  );
  static const MethodChannel _termuxChannel = MethodChannel(
    'dev.bistre.app/termux',
  );

  static bool get isAndroid => Platform.isAndroid;

  static void attachPowerEventListener(
    void Function(String eventKind) onEvent,
  ) {
    if (!Platform.isAndroid) return;
    _powerChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPowerEvent') {
        final args = call.arguments;
        if (args is Map<Object?, Object?>) {
          final kind = args['event'] as String?;
          if (kind != null && kind.isNotEmpty) {
            onEvent(kind);
          }
        }
      }
    });
  }

  static Future<AndroidPowerState> startAndroidAgentService({
    required int activeCount,
    required String summary,
    bool holdLocks = true,
  }) async {
    if (!Platform.isAndroid) return const AndroidPowerState();
    try {
      final raw = await _powerChannel.invokeMethod<Map<Object?, Object?>>(
        'startAgentService',
        <String, Object?>{
          'activeCount': activeCount,
          'summary': summary,
          'holdLocks': holdLocks,
        },
      );
      return _decodePowerState(raw);
    } on PlatformException {
      return const AndroidPowerState();
    } on MissingPluginException {
      return const AndroidPowerState();
    }
  }

  static Future<AndroidPowerState> stopAndroidAgentService() async {
    if (!Platform.isAndroid) return const AndroidPowerState();
    try {
      final raw = await _powerChannel.invokeMethod<Map<Object?, Object?>>(
        'stopAgentService',
      );
      return _decodePowerState(raw);
    } on PlatformException {
      return const AndroidPowerState();
    } on MissingPluginException {
      return const AndroidPowerState();
    }
  }

  static Future<AndroidPowerState> getAndroidPowerState() async {
    if (!Platform.isAndroid) return const AndroidPowerState();
    try {
      final raw = await _powerChannel.invokeMethod<Map<Object?, Object?>>(
        'getPowerState',
      );
      return _decodePowerState(raw);
    } on PlatformException {
      return const AndroidPowerState();
    } on MissingPluginException {
      return const AndroidPowerState();
    }
  }

  static Future<AndroidPowerState> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return const AndroidPowerState();
    try {
      final raw = await _powerChannel.invokeMethod<Map<Object?, Object?>>(
        'requestIgnoreBatteryOptimizations',
      );
      return _decodePowerState(raw);
    } on PlatformException {
      return const AndroidPowerState();
    } on MissingPluginException {
      return const AndroidPowerState();
    }
  }

  static Future<void> openAndroidAppSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _powerChannel.invokeMethod<bool>('openAppSettings');
    } on PlatformException {
      // Ignore on unsupported devices.
    } on MissingPluginException {
      // Ignore in widget tests.
    }
  }

  static Future<AndroidTermuxStatus> getTermuxStatus() async {
    if (!Platform.isAndroid) return const AndroidTermuxStatus();
    try {
      final raw = await _termuxChannel.invokeMethod<Map<Object?, Object?>>(
        'getStatus',
      );
      if (raw == null) return const AndroidTermuxStatus();
      return AndroidTermuxStatus(
        installed: raw['installed'] as bool? ?? false,
        permissionGranted: raw['permissionGranted'] as bool? ?? false,
        setupCommand:
            raw['setupCommand'] as String? ??
            const AndroidTermuxStatus().setupCommand,
      );
    } on PlatformException {
      return const AndroidTermuxStatus();
    } on MissingPluginException {
      return const AndroidTermuxStatus();
    }
  }

  static Future<bool> runTermuxCommand({
    required String executablePath,
    required List<String> args,
    String? workDir,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _termuxChannel.invokeMethod<bool>(
            'runCommand',
            <String, Object?>{
              'path': executablePath,
              'args': args,
              'workDir': workDir,
            },
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static AndroidPowerState _decodePowerState(Map<Object?, Object?>? raw) {
    if (raw == null) return const AndroidPowerState();
    return AndroidPowerState(
      fgsActive: raw['fgsActive'] as bool? ?? false,
      batteryUnrestricted: raw['batteryUnrestricted'] as bool? ?? false,
    );
  }
}
