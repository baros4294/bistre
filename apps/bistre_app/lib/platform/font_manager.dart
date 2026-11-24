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
          final pretty =
              await _readSfntFamilyName(entity) ??
              _prettyNameFromPath(entity.path);
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

  /// Parses the OpenType/TrueType `name` table (NameID 16 Preferred Family or NameID 1 Family)
  /// so Windows 8.3 filenames like `AGENCYB.TTF` or `BRLNSR.TTF` display their real human names
  /// (`Agency FB`, `Berlin Sans FB`) instead of cryptic stems.
  static Future<String?> _readSfntFamilyName(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final fileLen = await raf.length();
      if (fileLen < 12) return null;
      final headerBytes = await raf.read(12);
      if (headerBytes.length < 12) return null;
      final hdr = ByteData.sublistView(headerBytes);
      final numTables = hdr.getUint16(4);
      if (numTables == 0 || numTables > 128) return null;

      final dirLen = numTables * 16;
      final dirBytes = await raf.read(dirLen);
      if (dirBytes.length < dirLen) return null;
      final dir = ByteData.sublistView(dirBytes);

      int? nameOffset;
      int? nameLength;
      for (var i = 0; i < numTables; i++) {
        final base = i * 16;
        // 'name' tag = 0x6E616D65
        if (dir.getUint32(base) == 0x6E616D65) {
          nameOffset = dir.getUint32(base + 8);
          nameLength = dir.getUint32(base + 12);
          break;
        }
      }
      if (nameOffset == null || nameLength == null || nameLength < 6) {
        return null;
      }
      // Cap read to 64 KiB so huge CJK fonts never stall discovery.
      final clampedLen = nameLength > 65536 ? 65536 : nameLength;
      if (nameOffset + clampedLen > fileLen) return null;
      await raf.setPosition(nameOffset);
      final tblBytes = await raf.read(clampedLen);
      if (tblBytes.length < 6) return null;
      final tbl = ByteData.sublistView(tblBytes);
      final count = tbl.getUint16(2);
      final stringStorageOffset = tbl.getUint16(4);

      String? preferred;
      String? family;
      final maxRecords = count > 256 ? 256 : count;
      for (var i = 0; i < maxRecords; i++) {
        final recBase = 6 + i * 12;
        if (recBase + 12 > tblBytes.length) break;
        final platformId = tbl.getUint16(recBase);
        final nameId = tbl.getUint16(recBase + 6);
        if (nameId != 1 && nameId != 16) continue;
        final len = tbl.getUint16(recBase + 8);
        final strOff = stringStorageOffset + tbl.getUint16(recBase + 10);
        if (len == 0 || strOff + len > tblBytes.length) continue;

        String? decoded;
        if (platformId == 3 || platformId == 0) {
          // UTF-16BE (Windows / Unicode)
          if (len.isOdd) continue;
          final units = <int>[];
          for (var j = 0; j < len; j += 2) {
            units.add((tblBytes[strOff + j] << 8) | tblBytes[strOff + j + 1]);
          }
          decoded = String.fromCharCodes(units).trim();
        } else if (platformId == 1) {
          // Mac Roman ASCII subset
          decoded = String.fromCharCodes(tblBytes.sublist(strOff, strOff + len))
              .trim();
        }
        if (decoded == null || decoded.isEmpty) continue;
        if (nameId == 16) {
          preferred ??= decoded;
          if (platformId == 3) preferred = decoded;
        } else {
          family ??= decoded;
          if (platformId == 3) family = decoded;
        }
      }
      final result = (preferred ?? family)?.trim();
      if (result == null || result.isEmpty || result.startsWith('.')) {
        return null;
      }
      return result;
    } on FileSystemException {
      return null;
    } finally {
      await raf?.close();
    }
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
