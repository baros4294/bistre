import 'dart:io';

import 'package:flutter/services.dart';

/// Descriptor for a locally installed or user-selected font file.
class LocalFontEntry {
  const LocalFontEntry({
    required this.familyName,
    required this.filePath,
    this.isMonospaceHint = false,
  });

  final String familyName;
  final String filePath;
  final bool isMonospaceHint;
}

/// Pure-Flutter offline local & system font discovery + runtime `FontLoader` registry.
///
/// Zero external packages, zero network fetches: reads local `.ttf`/`.otf` font files
/// directly into Flutter's engine so users can pick any installed system font or browse
/// a custom font file from disk.
class BistreFontManager {
  BistreFontManager._();

  static final Map<String, String> _loadedPathToFamily = <String, String>{};
  static List<LocalFontEntry>? _cachedSystemFonts;

  /// Loads a local `.ttf` or `.otf` font file into Flutter's runtime `FontLoader`,
  /// returning the registered font family name ready for `TextStyle.fontFamily`.
  static Future<String?> loadFontFromFile(
    String filePath, {
    String? preferredFamily,
  }) async {
    final trimmed = filePath.trim();
    if (trimmed.isEmpty) return null;
    final cached = _loadedPathToFamily[trimmed];
    if (cached != null) return cached;

    final file = File(trimmed);
    if (!file.existsSync()) return null;
    final lower = trimmed.toLowerCase();
    if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) {
      return null;
    }

    try {
      final bytes = await file.readAsBytes();
      if (bytes.length < 64) return null;
      final derivedName =
          (preferredFamily != null && preferredFamily.trim().isNotEmpty)
          ? preferredFamily.trim()
          : _prettyNameFromPath(trimmed);
      final familyKey = 'BistreCustom_$derivedName';
      final loader = FontLoader(familyKey);
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedPathToFamily[trimmed] = familyKey;
      return familyKey;
    } on FileSystemException {
      return null;
    }
  }

  /// Scans OS system font directories cleanly off the frame path, returning deduplicated
  /// readable `.ttf`/`.otf` entries sorted alphabetically.
  static Future<List<LocalFontEntry>> discoverSystemFonts() async {
    if (_cachedSystemFonts != null) return _cachedSystemFonts!;

    final dirs = <Directory>[];
    if (Platform.isWindows) {
      final winDir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      dirs.add(Directory('$winDir\\Fonts'));
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        dirs.add(Directory('$localAppData\\Microsoft\\Windows\\Fonts'));
      }
    } else if (Platform.isLinux) {
      dirs.add(Directory('/usr/share/fonts'));
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        dirs.add(Directory('$home/.local/share/fonts'));
      }
    }

    final seen = <String, LocalFontEntry>{};
    for (final dir in dirs) {
      if (!dir.existsSync()) continue;
      try {
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final lower = entity.path.toLowerCase();
          if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) continue;
          // Prefer Regular / base weight variants to keep the picker clean and scannable.
          final baseName = entity.uri.pathSegments.last;
          final lowerBase = baseName.toLowerCase();
          if (lowerBase.contains('bold') ||
              lowerBase.contains('italic') ||
              lowerBase.contains('oblique') ||
              lowerBase.contains('light') ||
              lowerBase.contains('black') ||
              lowerBase.contains('thin') ||
              lowerBase.contains('semil') ||
              lowerBase.contains('semib') ||
              lowerBase.endsWith('bd.ttf') ||
              lowerBase.endsWith('bi.ttf') ||
              lowerBase.endsWith('i.ttf') ||
              lowerBase.endsWith('z.ttf')) {
            continue;
          }
          final pretty = _prettyNameFromPath(entity.path);
          if (pretty.isEmpty) continue;
          final key = pretty.toLowerCase();
          seen.putIfAbsent(
            key,
            () => LocalFontEntry(
              familyName: pretty,
              filePath: entity.path,
              isMonospaceHint: _looksMonospace(pretty),
            ),
          );
        }
      } on FileSystemException {
        // Ignore restricted directories gracefully.
      }
    }

    final list = seen.values.toList()
      ..sort(
        (a, b) =>
            a.familyName.toLowerCase().compareTo(b.familyName.toLowerCase()),
      );
    _cachedSystemFonts = list;
    return list;
  }

  static String _prettyNameFromPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final fileName = normalized.split('/').last;
    final stem = fileName.replaceAll(
      RegExp(r'\.(ttf|otf)$', caseSensitive: false),
      '',
    );
    final cleaned = stem
        .replaceAll(
          RegExp(r'[-_](Regular|Normal|Book|Roman)$', caseSensitive: false),
          '',
        )
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .replaceAllMapped(
          RegExp(r'([a-z])([A-Z])'),
          (m) => '${m.group(1)} ${m.group(2)}',
        )
        .trim();
    if (cleaned.isEmpty) return stem;
    return cleaned[0].toUpperCase() + cleaned.substring(1);
  }

  static bool _looksMonospace(String name) {
    final lower = name.toLowerCase();
    return lower.contains('mono') ||
        lower.contains('code') ||
        lower.contains('consola') ||
        lower.contains('courier') ||
        lower.contains('cascadia') ||
        lower.contains('hack') ||
        lower.contains('fira') ||
        lower.contains('iosevka') ||
        lower.contains('inconsolata') ||
        lower.contains('menlo') ||
        lower.contains('ubuntu mono') ||
        lower.contains('lucida console');
  }
}
