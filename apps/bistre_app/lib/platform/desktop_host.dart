import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../bridge/api/media.dart' as core;

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
/// Largest pasted picture taken from the clipboard (bytes of PNG).
const int kMaxPastedImageBytes = 32 * 1024 * 1024;

/// Largest picture file Copy picture reads, in bytes.
const int kMaxCopiedPictureFileBytes = 64 * 1024 * 1024;

/// Longest side of a copied picture, in pixels; a larger one is scaled down to it (the
/// runners refuse more than its square).
const int kMaxCopiedPictureSidePx = 4096;

class BistreDesktopHost {
  BistreDesktopHost._();

  static const MethodChannel _channel = MethodChannel('bistre/desktop_host');
  static VoidCallback? _onSystemThemeChanged;
  static void Function(DesktopWindowBounds bounds)? _onWindowBoundsChanged;
  static void Function(String pcmBase64)? _onMicPcmChunk;
  static void Function(List<String> paths)? _onFilesDropped;
  static VoidCallback? _onQuickEntry;
  static bool _channelHandlerAttached = false;

  /// True while the saved quick entry shortcut is on but Windows refused it (another app
  /// holds it); Settings > Shortcuts says so.
  static final ValueNotifier<bool> quickEntryRefused = ValueNotifier<bool>(
    false,
  );

  static void _ensureChannelHandler() {
    // Windows sends theme, bounds, mic, and drops; Android and Linux send drops.
    if (_channelHandlerAttached ||
        !(Platform.isWindows || Platform.isAndroid || Platform.isLinux)) {
      return;
    }
    _channelHandlerAttached = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSystemThemeChanged') {
        _onSystemThemeChanged?.call();
      } else if (call.method == 'onQuickEntry') {
        _onQuickEntry?.call();
      } else if (call.method == 'onFilesDropped') {
        final raw = call.arguments;
        if (raw is List) {
          _onFilesDropped?.call(<String>[
            for (final p in raw)
              if (p is String && p.isNotEmpty) p,
          ]);
        }
      } else if (call.method == 'onMicPcmChunk') {
        final b64 = call.arguments;
        if (b64 is String && b64.isNotEmpty) {
          _onMicPcmChunk?.call(b64);
        }
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

  /// Files dragged onto the window (Windows, Linux) or the app (Android); the host keeps at
  /// most 16 per drop (Android copies each into the app's cache first).
  static void attachFilesDroppedListener(
    void Function(List<String> paths) callback,
  ) {
    _onFilesDropped = callback;
    _ensureChannelHandler();
  }

  /// Removes [callback] if it is the registered drop listener.
  static void detachFilesDroppedListener(
    void Function(List<String> paths) callback,
  ) {
    if (_onFilesDropped == callback) _onFilesDropped = null;
  }

  /// The quick entry shortcut was pressed in any app (Windows); the host has already
  /// brought the window to the front.
  static void attachQuickEntryListener(VoidCallback callback) {
    _onQuickEntry = callback;
    _ensureChannelHandler();
  }

  /// Removes [callback] if it is the registered quick entry listener.
  static void detachQuickEntryListener(VoidCallback callback) {
    if (_onQuickEntry == callback) _onQuickEntry = null;
  }

  /// Registers [combo] (the saved `Ctrl+Alt+B` form) as the system-wide quick entry
  /// shortcut, replacing the previous one; `''` turns it off. Windows only; elsewhere
  /// nothing is registered.
  static Future<void> setQuickEntryHotkey(String combo) async {
    if (!Platform.isWindows) return;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setQuickEntryHotkey',
        <String, Object?>{'combo': combo},
      );
      // Only the host's `false` means another app holds the combo; the notice says so.
      quickEntryRefused.value = combo.isNotEmpty && ok == false;
    } on PlatformException catch (e) {
      quickEntryRefused.value = false;
      debugPrint('[bistre] non-fatal quick_entry_hotkey: $e');
    } on MissingPluginException catch (e) {
      quickEntryRefused.value = false;
      debugPrint('[bistre] non-fatal quick_entry_hotkey: $e');
    }
  }

  /// The files or the picture (PNG bytes, at most [kMaxPastedImageBytes]) copied to the
  /// clipboard: Windows and Android through the host, Linux through core (`wl-paste` or
  /// `xclip`); none elsewhere.
  static Future<({List<String> files, Uint8List? png})>
  clipboardAttachments() async {
    if (Platform.isLinux) {
      final got = await core.linuxClipboardAttachments();
      final png = got.png;
      return (
        files: got.files,
        png: png != null && png.length <= kMaxPastedImageBytes ? png : null,
      );
    }
    if (!Platform.isWindows && !Platform.isAndroid) {
      return (files: const <String>[], png: null);
    }
    final raw = await _channel.invokeMethod<Object?>('clipboardAttachments');
    final files = <String>[];
    Uint8List? png;
    if (raw is Map<Object?, Object?>) {
      final listed = raw['files'];
      if (listed is List) {
        for (final p in listed) {
          if (p is String && p.isNotEmpty) files.add(p);
        }
      }
      final b64 = raw['png'];
      // Base64 holds 3 bytes in every 4 characters.
      if (b64 is String &&
          b64.isNotEmpty &&
          b64.length ~/ 4 * 3 <= kMaxPastedImageBytes) {
        png = base64Decode(b64);
      }
    }
    return (files: files, png: png);
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

  /// Sets the native window caption (`<chat title> - Bistre`, live run progress included).
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

  /// Whether this platform has the native open and save file dialogs (Windows
  /// `IFileDialog`, Linux GTK); elsewhere [pickLocalFile] and [saveLocalFile] return null.
  static bool get canSaveFiles => Platform.isWindows || Platform.isLinux;

  /// Opens a native OS file picker for local fonts (`.ttf`/`.otf`) or custom icons.
  static Future<String?> pickLocalFile({
    required String title,
    required String filterLabel,
    required String filterSpec,
  }) async {
    if (!canSaveFiles) return null;
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
      // Core runs zenity/kdialog contained, like every other child process.
      try {
        return await core.linuxPickFolder(title: title);
      } on Object catch (e) {
        debugPrint('[bistre] non-fatal linux_pick_folder: $e');
        return null;
      }
    }
    return null;
  }

  /// Whether the native desktop window is currently the OS foreground window.
  static Future<bool> isWindowFocused() async {
    // Elsewhere the embedder reports focus through the app lifecycle (inactive = unfocused).
    if (!Platform.isWindows) {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null || state == AppLifecycleState.resumed;
    }
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
      // Core runs notify-send contained, and the text can never be read as an option.
      try {
        await core.linuxNotify(title: title, body: body, playSound: playSound);
      } on Object catch (e) {
        debugPrint('[bistre] non-fatal linux_notify: $e');
      }
    }
  }

  /// Registers or unregisters run-on-startup (`HKCU\...\Run` on Windows, an XDG
  /// `~/.config/autostart/bistre.desktop` entry on Linux).
  static Future<bool> setAutoStart(bool enabled) async {
    if (Platform.isLinux) {
      final config =
          Platform.environment['XDG_CONFIG_HOME'] ??
          '${Platform.environment['HOME'] ?? ''}/.config';
      final entry = File('$config/autostart/bistre.desktop');
      try {
        if (!enabled) {
          if (entry.existsSync()) entry.deleteSync();
          return true;
        }
        entry.parent.createSync(recursive: true);
        entry.writeAsStringSync(
          linuxAutostartEntry(Platform.resolvedExecutable),
        );
        return true;
      } on FileSystemException {
        return false;
      }
    }
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

  /// The XDG autostart entry that starts [executable] at sign-in.
  static String linuxAutostartEntry(String executable) {
    // Desktop Entry `Exec` quoting: the path in double quotes; `"`, `` ` `` and `$` take a
    // backslash, and a backslash is written four times (string escaping, then quoting).
    final quoted = executable.replaceAllMapped(
      RegExp(r'["`$\\]'),
      (m) => m[0] == '\\' ? r'\\\\' : '\\${m[0]}',
    );
    return '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=Bistre\n'
        'Exec="$quoted"\n'
        'X-GNOME-Autostart-enabled=true\n';
  }

  /// The tray menu's labels (Open, Quit) in the app's language.
  static Future<void> setTrayLabels({
    required String open,
    required String quit,
  }) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('setTrayLabels', <String, Object?>{
        'open': open,
        'quit': quit,
      });
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
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
    if (!canSaveFiles) return null;
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
        await core.linuxOpenFolder(path: dirPath);
      } on Object catch (e) {
        debugPrint('[bistre] non-fatal linux_open_folder: $e');
      }
    }
  }

  /// `true` for an existing local file that is neither a Windows UNC network path nor named
  /// like an executable, script, or shortcut.
  static bool isSafeLocalFile(String rawPath) {
    final path = rawPath.trim();
    if (path.isEmpty || path.replaceAll(r'\', '/').startsWith('//')) {
      return false;
    }
    final dot = path.lastIndexOf('.');
    if (dot > 0 &&
        blockedOpenExtensions.contains(path.substring(dot + 1).toLowerCase())) {
      return false;
    }
    return FileSystemEntity.isFileSync(path);
  }

  /// Whether this platform can hand a file to its default app (on Android, the app the
  /// user picks).
  static bool get canOpenFiles =>
      Platform.isWindows || Platform.isLinux || Platform.isAndroid;

  /// The normalized link when [url] is `http(s)` with a host and no login, the only links
  /// Bistre hands to a browser; `null` otherwise.
  static String? webLink(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.toString();
  }

  /// Opens a web page in the default browser; `false` when it was not opened.
  static Future<bool> openWebLink(String url) async {
    final link = webLink(url);
    if (link == null) return false;
    try {
      if (Platform.isWindows || Platform.isAndroid) {
        return await _channel.invokeMethod<bool>(
              'openWebLink',
              <String, Object?>{'url': link},
            ) ??
            false;
      }
      if (Platform.isLinux) {
        await core.linuxOpenWebLink(url: link);
        return true;
      }
    } on PlatformException catch (e) {
      debugPrint('[bistre] non-fatal open_web_link: $e');
    } on MissingPluginException catch (e) {
      debugPrint('[bistre] non-fatal open_web_link: $e');
    } on Object catch (e) {
      debugPrint('[bistre] non-fatal linux_open_web_link: $e');
    }
    return false;
  }

  /// Android: opens the system installer on the verified update APK core staged; `false`
  /// when it did not open.
  static Future<bool> installUpdate(String apkPath) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'installUpdate',
            <String, Object?>{'path': apkPath},
          ) ??
          false;
    } on PlatformException catch (e) {
      debugPrint('[bistre] non-fatal install_update: $e');
    } on MissingPluginException catch (e) {
      debugPrint('[bistre] non-fatal install_update: $e');
    }
    return false;
  }

  /// Opens `filePath` in its default app (safe local files only); `false` when it was not
  /// opened.
  static Future<bool> openFile(String filePath) async {
    if (!isSafeLocalFile(filePath)) return false;
    try {
      if (Platform.isWindows || Platform.isAndroid) {
        return await _channel.invokeMethod<bool>('openFile', <String, Object?>{
              'path': filePath,
            }) ??
            false;
      }
      if (Platform.isLinux) {
        await core.linuxOpenFile(path: filePath);
        return true;
      }
    } on PlatformException catch (e) {
      debugPrint('[bistre] non-fatal open_file: $e');
    } on MissingPluginException catch (e) {
      debugPrint('[bistre] non-fatal open_file: $e');
    } on Object catch (e) {
      debugPrint('[bistre] non-fatal linux_open_file: $e');
    }
    return false;
  }

  /// Whether this platform can put a picture on the clipboard.
  static bool get canCopyPictures =>
      Platform.isWindows || Platform.isLinux || Platform.isAndroid;

  /// Puts the picture at [filePath] on the clipboard; `false` when it was not copied. Android
  /// shares the file itself; a desktop gets its pixels (and on Windows a PNG as well), decoded
  /// here at most [kMaxCopiedPictureSidePx] on a side. A file that does not decode throws.
  static Future<bool> copyPicture(String filePath) async {
    if (!isSafeLocalFile(filePath) || !canCopyPictures) return false;
    if (Platform.isAndroid) {
      return _invokeCopyPicture(<String, Object?>{'path': filePath});
    }
    final file = File(filePath);
    if (await file.length() > kMaxCopiedPictureFileBytes) return false;
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      await file.readAsBytes(),
    );
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) {
        final side = w > h ? w : h;
        if (side <= kMaxCopiedPictureSidePx) {
          return ui.TargetImageSize(width: w, height: h);
        }
        final scale = kMaxCopiedPictureSidePx / side;
        return ui.TargetImageSize(
          width: (w * scale).round().clamp(1, kMaxCopiedPictureSidePx),
          height: (h * scale).round().clamp(1, kMaxCopiedPictureSidePx),
        );
      },
    );
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    try {
      final rgba = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      final png = Platform.isWindows
          ? await image.toByteData(format: ui.ImageByteFormat.png)
          : null;
      if (rgba == null) return false;
      return await _invokeCopyPicture(<String, Object?>{
        'rgba': rgba.buffer.asUint8List(),
        'width': image.width,
        'height': image.height,
        if (png != null) 'png': png.buffer.asUint8List(),
      });
    } finally {
      image.dispose();
    }
  }

  static Future<bool> _invokeCopyPicture(Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<bool>('copyPicture', args) ?? false;
    } on PlatformException catch (e) {
      debugPrint('[bistre] non-fatal copy_picture: $e');
    } on MissingPluginException catch (e) {
      debugPrint('[bistre] non-fatal copy_picture: $e');
    }
    return false;
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

  /// Plays the OS notification chime immediately (Settings → Preview sound).
  static Future<void> playNotificationSound() async {
    if (Platform.isWindows) {
      try {
        await _channel.invokeMethod<bool>('playNotificationSound');
        return;
      } on PlatformException {
        return;
      } on MissingPluginException {
        return;
      }
    }
    await SystemSound.play(SystemSoundType.alert);
  }

  /// Plays WAV audio bytes natively (Win32 `PlaySoundW` / Android `MediaPlayer`).
  static Future<void> playWavBytes(List<int> wavBytes) async {
    if (wavBytes.isEmpty) return;
    if (Platform.isWindows || Platform.isAndroid) {
      try {
        await _channel.invokeMethod<bool>('playWavBytes', <String, Object?>{
          'bytes': Uint8List.fromList(wavBytes),
        });
        return;
      } on PlatformException {
        return;
      } on MissingPluginException {
        return;
      }
    }
  }

  /// Stops any active WAV playback or OS speech synthesis.
  static Future<void> stopAudioPlayback() async {
    if (Platform.isWindows || Platform.isAndroid) {
      try {
        await _channel.invokeMethod<bool>('stopAudioPlayback');
      } on PlatformException {
        // Non-fatal.
      } on MissingPluginException {
        // Non-fatal.
      }
    }
  }

  /// Registers a listener for 16 kHz 16-bit mono PCM mic chunks (base64) during Live Voice.
  static void attachMicPcmListener(void Function(String pcmBase64) callback) {
    _onMicPcmChunk = callback;
    _ensureChannelHandler();
  }

  static void detachMicPcmListener() {
    _onMicPcmChunk = null;
  }

  static Future<bool> startMicCapture() async {
    if (!Platform.isWindows) return false;
    try {
      return await _channel.invokeMethod<bool>('startMicCapture') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> stopMicCapture() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('stopMicCapture');
    } on PlatformException {
      // Non-fatal.
    } on MissingPluginException {
      // Non-fatal.
    }
  }

  /// Native OS speech-to-text dictation (Windows SAPI in the runner, Android
  /// `RecognizerIntent`): the words of one phrase, or null. No child process is started.
  static Future<String?> dictateVoiceOnce() async {
    if (!(Platform.isAndroid || Platform.isWindows)) return null;
    try {
      return await _channel.invokeMethod<String>('dictateVoiceOnce');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Ends a dictation early; it then completes with what was heard so far (or nothing).
  static Future<void> stopVoiceDictation() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<bool>('stopVoiceDictation');
    } on PlatformException {
      // Non-fatal: the dictation ends by itself after a pause.
    } on MissingPluginException {
      // Non-fatal: the dictation ends by itself after a pause.
    }
  }

  /// Reads [text] with the system voice (Windows SAPI in the runner, Android TextToSpeech);
  /// completes when it finishes or is stopped. No child process is started.
  static Future<void> speakTextAloud(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || !(Platform.isAndroid || Platform.isWindows)) return;
    try {
      await _channel.invokeMethod<bool>('speakTextAloud', <String, Object?>{
        // Bounded: a reply read aloud is at most this many characters.
        'text': clean.characters.take(4000).toString(),
      });
    } on PlatformException {
      // Non-fatal: the reply stays on screen.
    } on MissingPluginException {
      // Non-fatal: the reply stays on screen.
    }
  }

  static const MethodChannel _phoneUseChannel = MethodChannel(
    'bistre/phone_use',
  );

  /// Executes one approved `computer_use` (desktop) or `phone_use` (Android) host action
  /// through the native platform bridge and returns `{ok, outputText, imageBase64?}`.
  static Future<Map<String, Object?>> runComputerUseAction(
    Map<String, Object?> action,
  ) async {
    try {
      final res = Platform.isAndroid
          ? await _phoneUseChannel.invokeMethod<Map<Object?, Object?>>(
              'phoneUse',
              action,
            )
          : await _channel.invokeMethod<Map<Object?, Object?>>(
              'computerUse',
              action,
            );
      if (res == null) {
        return const <String, Object?>{
          'ok': false,
          'outputText': 'Native host bridge returned no result.',
        };
      }
      return <String, Object?>{
        'ok': res['ok'] as bool? ?? false,
        'outputText': res['outputText'] as String? ?? '',
        if (res['imageBase64'] is String)
          'imageBase64': res['imageBase64'] as String,
      };
    } on PlatformException catch (e) {
      return <String, Object?>{
        'ok': false,
        'outputText': e.message ?? 'Host action failed.',
      };
    } on MissingPluginException {
      return const <String, Object?>{
        'ok': false,
        'outputText':
            'Native screen-control bridge is unavailable on this host.',
      };
    }
  }
}
