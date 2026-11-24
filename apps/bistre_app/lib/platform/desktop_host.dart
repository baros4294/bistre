import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Persisted normal/maximized desktop window bounds.
class DesktopWindowBounds {
  const DesktopWindowBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.maximized,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final bool maximized;

  String toJsonString() => jsonEncode(<String, Object?>{
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'maximized': maximized,
  });

  static DesktopWindowBounds? tryParseJson(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, Object?>) return null;
      final x = (decoded['x'] as num?)?.toInt();
      final y = (decoded['y'] as num?)?.toInt();
      final width = (decoded['width'] as num?)?.toInt();
      final height = (decoded['height'] as num?)?.toInt();
      final maximized = decoded['maximized'] as bool? ?? false;
      if (x == null || y == null || width == null || height == null) {
        return null;
      }
      if (width < 720 || height < 520) return null;
      return DesktopWindowBounds(
        x: x,
        y: y,
        width: width,
        height: height,
        maximized: maximized,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Thin native desktop host bridge (`bistre/desktop_host`).
///
/// On Windows, communicates directly with `FlutterWindow` in `windows/runner/`
/// (zero third-party Flutter plugins) for:
/// - Windows 11 native DWM caption/text/border tinting & rounded corners
/// - Native `IFileOpenDialog` / `IFileSaveDialog`
/// - `ShellExecuteW` folder opening
/// - Multi-monitor-safe window geometry persistence
///
/// Safely degrades to no-op on Android, Linux, or widget tests.
class BistreDesktopHost {
  BistreDesktopHost._();

  static const MethodChannel _channel = MethodChannel('bistre/desktop_host');
  static VoidCallback? _onSystemThemeChanged;
  static void Function(DesktopWindowBounds bounds)? _onWindowBoundsChanged;
  static bool _channelHandlerAttached = false;

  static void _ensureChannelHandler() {
    if (_channelHandlerAttached || !Platform.isWindows) return;
    _channelHandlerAttached = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSystemThemeChanged') {
        _onSystemThemeChanged?.call();
      } else if (call.method == 'onWindowBoundsChanged') {
        final raw = call.arguments;
        if (raw is Map<Object?, Object?>) {
          final x = (raw['x'] as num?)?.toInt();
          final y = (raw['y'] as num?)?.toInt();
          final w = (raw['width'] as num?)?.toInt();
          final h = (raw['height'] as num?)?.toInt();
          final max = raw['maximized'] as bool? ?? false;
          if (x != null &&
              y != null &&
              w != null &&
              h != null &&
              w >= 720 &&
              h >= 520) {
            _onWindowBoundsChanged?.call(
              DesktopWindowBounds(
                x: x,
                y: y,
                width: w,
                height: h,
                maximized: max,
              ),
            );
          }
        }
      }
    });
  }

  static void attachSystemThemeListener(VoidCallback callback) {
    _onSystemThemeChanged = callback;
    _ensureChannelHandler();
  }

  /// Removes [callback] if it is the registered system-theme listener.
  static void detachSystemThemeListener(VoidCallback callback) {
    if (_onSystemThemeChanged == callback) _onSystemThemeChanged = null;
  }

  static void attachWindowBoundsListener(
    void Function(DesktopWindowBounds bounds) callback,
  ) {
    _onWindowBoundsChanged = callback;
    _ensureChannelHandler();
  }

  static void detachWindowBoundsListener(
    void Function(DesktopWindowBounds bounds) callback,
  ) {
    if (_onWindowBoundsChanged == callback) _onWindowBoundsChanged = null;
  }

  /// Syncs Windows 11 native title bar colors cleanly to Bistre's active theme.
  static Future<void> syncWindowTheme({
    required bool isDark,
    required Color captionColor,
    required Color textColor,
    required Color borderColor,
  }) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('setWindowTheme', <String, Object?>{
        'isDark': isDark,
        'captionRgb': captionColor.toARGB32() & 0x00FFFFFF,
        'textRgb': textColor.toARGB32() & 0x00FFFFFF,
        'borderRgb': borderColor.toARGB32() & 0x00FFFFFF,
      });
    } on PlatformException {
      // Safe fallback in headless tests or older Windows hosts.
    } on MissingPluginException {
      // Safe fallback in widget tests.
    }
  }

  /// Sets the native window caption (`<chat title> — Bistre`, live run progress included).
  static Future<void> setWindowTitle(String title) async {
    if (!Platform.isWindows || title.trim().isEmpty) return;
    try {
      await _channel.invokeMethod<bool>('setWindowTitle', <String, Object?>{
        'title': title,
      });
    } on PlatformException {
      // Headless tests or hosts without the runner channel.
    } on MissingPluginException {
      // Widget tests.
    }
  }

  /// Total physical memory in bytes on Windows (`0` when unknown).
  static Future<int> totalMemoryBytes() async {
    if (!Platform.isWindows) return 0;
    try {
      return await _channel.invokeMethod<int>('getTotalMemoryBytes') ?? 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// Opens a native OS file picker for local fonts (`.ttf`/`.otf`) or custom icons.
  static Future<String?> pickLocalFile({
    required String title,
    required String filterLabel,
    required String filterSpec,
  }) async {
    if (!Platform.isWindows) return null;
    try {
      return await _channel.invokeMethod<String>(
        'pickLocalFile',
        <String, Object?>{
          'title': title,
          'filterLabel': filterLabel,
          'filterSpec': filterSpec,
        },
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens a native OS folder picker (Windows `IFileOpenDialog` `FOS_PICKFOLDERS`,
  /// Android `ACTION_OPEN_DOCUMENT_TREE`, Linux `zenity`/`kdialog`).
  static Future<String?> pickLocalFolder({required String title}) async {
    if (Platform.isWindows || Platform.isAndroid) {
      try {
        final chosen = await _channel.invokeMethod<String>(
          'pickLocalFolder',
          <String, Object?>{'title': title},
        );
        if (chosen == null || chosen.trim().isEmpty) return null;
        return chosen.trim();
      } on PlatformException {
        return null;
      } on MissingPluginException {
        return null;
      }
    }
    if (Platform.isLinux) {
      for (final cmd in const <(String, List<String>)>[
        ('zenity', <String>['--file-selection', '--directory']),
        ('kdialog', <String>['--getexistingdirectory', '.']),
      ]) {
        try {
          final args = cmd.$1 == 'zenity'
              ? <String>[...cmd.$2, '--title=$title']
              : <String>[...cmd.$2, '--title', title];
          final res = await Process.run(cmd.$1, args);
          if (res.exitCode == 0) {
            final path = (res.stdout as String? ?? '').trim();
            if (path.isNotEmpty) return path;
          }
          return null;
        } on ProcessException {
          continue;
        }
      }
    }
    return null;
  }

  /// Whether the native desktop window is currently the OS foreground window.
  static Future<bool> isWindowFocused() async {
    if (!Platform.isWindows) return true;
    try {
      return await _channel.invokeMethod<bool>('isWindowFocused') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// Sends a native OS desktop notification (Windows tray balloon / Linux `notify-send`).
  static Future<void> showNotification({
    required String title,
    required String body,
    bool playSound = false,
  }) async {
    if (Platform.isWindows) {
      try {
        await _channel.invokeMethod<bool>('showNotification', <String, Object?>{
          'title': title,
          'body': body,
          'playSound': playSound,
        });
      } on PlatformException {
        return;
      } on MissingPluginException {
        return;
      }
      return;
    }
    if (Platform.isLinux) {
      try {
        await Process.start('notify-send', <String>[title, body]);
      } on ProcessException {
        return;
      }
    }
  }

  /// Registers or unregisters run-on-startup (`HKCU\...\Run` on Windows).
  static Future<bool> setAutoStart(bool enabled) async {
    if (!Platform.isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'setAutoStart',
            <String, Object?>{'enabled': enabled},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Enables or disables the native system tray icon.
  static Future<void> setTrayEnabled(bool enabled) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('setTrayEnabled', <String, Object?>{
        'enabled': enabled,
      });
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
  }

  /// Opens a native OS save-file dialog (for SQLite backups or Markdown/JSON chat export).
  static Future<String?> saveLocalFile({
    required String title,
    required String defaultName,
    required String filterLabel,
    required String filterSpec,
  }) async {
    if (!Platform.isWindows) return null;
    try {
      return await _channel.invokeMethod<String>(
        'saveLocalFile',
        <String, Object?>{
          'title': title,
          'defaultName': defaultName,
          'filterLabel': filterLabel,
          'filterSpec': filterSpec,
        },
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Extensions never handed to the OS "open" verb (mirrors Rust
  /// `process_util::BLOCKED_OPEN_EXTENSIONS`).
  static const Set<String> blockedOpenExtensions = <String>{
    'exe', 'com', 'bat', 'cmd', 'ps1', 'psm1', 'vbs', 'vbe', 'js', 'jse', //
    'wsf', 'wsh', 'msi', 'msp', 'scr', 'pif', 'cpl', 'hta', 'jar', 'lnk',
    'reg', 'inf', 'sh', 'appimage', 'desktop',
  };

  /// `true` only for an existing local directory that is neither a Windows UNC network path
  /// (probing one sends SMB credentials) nor named like an executable or shortcut.
  static bool isSafeLocalFolder(String rawPath) {
    final path = rawPath.trim();
    if (path.isEmpty) return false;
    final unix = path.replaceAll(r'\', '/');
    if (unix.startsWith('//')) return false;
    final name = unix.split('/').where((p) => p.isNotEmpty).lastOrNull ?? '';
    final dot = name.lastIndexOf('.');
    if (dot > 0 &&
        blockedOpenExtensions.contains(name.substring(dot + 1).toLowerCase())) {
      return false;
    }
    return FileSystemEntity.isDirectorySync(path);
  }

  /// Opens `dirPath` in the native OS file explorer (safe local folders only).
  static Future<void> openFolder(String dirPath) async {
    if (!isSafeLocalFolder(dirPath)) return;
    if (Platform.isWindows) {
      try {
        await _channel.invokeMethod<bool>('openFolder', <String, Object?>{
          'path': dirPath,
        });
        return;
      } on PlatformException {
        return;
      } on MissingPluginException {
        return;
      }
    }
    if (Platform.isLinux) {
      try {
        await Process.start('xdg-open', <String>[dirPath]);
      } on ProcessException {
        // Best-effort on headless Linux environments.
      }
    }
  }

  static Future<DesktopWindowBounds?> readWindowBounds() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        'getWindowBounds',
      );
      if (raw == null) return null;
      final x = (raw['x'] as num?)?.toInt();
      final y = (raw['y'] as num?)?.toInt();
      final w = (raw['width'] as num?)?.toInt();
      final h = (raw['height'] as num?)?.toInt();
      final max = raw['maximized'] as bool? ?? false;
      if (x == null || y == null || w == null || h == null) return null;
      return DesktopWindowBounds(
        x: x,
        y: y,
        width: w,
        height: h,
        maximized: max,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> restoreWindowBounds(DesktopWindowBounds bounds) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('setWindowBounds', <String, Object?>{
        'x': bounds.x,
        'y': bounds.y,
        'width': bounds.width,
        'height': bounds.height,
        'maximized': bounds.maximized,
      });
    } on PlatformException {
      // Non-fatal.
    } on MissingPluginException {
      // Non-fatal.
    }
  }
}
