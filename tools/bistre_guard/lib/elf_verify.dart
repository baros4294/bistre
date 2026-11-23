import 'dart:io';
import 'dart:typed_data';

/// Minimum Android 15+ page alignment for every ELF `PT_LOAD` segment (16 KiB).
const int requiredLoadAlignment = 0x4000;

/// Result of verifying one ELF64 shared object.
class ElfAlignmentResult {
  const ElfAlignmentResult(this.name, this.loadAlignments, this.error);
  final String name;
  final List<int> loadAlignments;
  final String? error;

  bool get isValid =>
      error == null &&
      loadAlignments.isNotEmpty &&
      loadAlignments.every((a) => a >= requiredLoadAlignment);

  String describe() {
    if (error != null) return 'FAIL $name: $error';
    final hex = loadAlignments
        .map((a) => '0x${a.toRadixString(16)}')
        .join(', ');
    if (loadAlignments.isEmpty) return 'FAIL $name: zero PT_LOAD segments';
    return '${isValid ? 'OK  ' : 'FAIL'} $name: PT_LOAD p_align [$hex]';
  }
}

/// Parses a little-endian ELF64 image and returns every `PT_LOAD` `p_align` (pure Dart,
/// zero `llvm-readelf` dependency).
ElfAlignmentResult verifyElfBytes(String name, Uint8List bytes) {
  if (bytes.length < 64 ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46) {
    return ElfAlignmentResult(name, const <int>[], 'not an ELF file');
  }
  if (bytes[4] != 2) {
    return ElfAlignmentResult(name, const <int>[], 'not ELF64 (EI_CLASS)');
  }
  if (bytes[5] != 1) {
    return ElfAlignmentResult(name, const <int>[], 'not little-endian');
  }
  final data = ByteData.sublistView(bytes);
  final phoff = data.getUint64(0x20, Endian.little);
  final phentsize = data.getUint16(0x36, Endian.little);
  final phnum = data.getUint16(0x38, Endian.little);
  if (phentsize < 0x38) {
    return ElfAlignmentResult(name, const <int>[], 'invalid e_phentsize');
  }
  final aligns = <int>[];
  for (var i = 0; i < phnum; i++) {
    final off = phoff + i * phentsize;
    if (off + 0x38 > bytes.length) {
      return ElfAlignmentResult(name, aligns, 'truncated program headers');
    }
    if (data.getUint32(off, Endian.little) == 1) {
      aligns.add(data.getUint64(off + 0x30, Endian.little));
    }
  }
  return ElfAlignmentResult(name, aligns, null);
}

/// Verifies a `.so`, a directory of `.so` files, or every `lib/arm64-v8a/*.so` inside an APK.
List<ElfAlignmentResult> verifyElfPath(String path) {
  final type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.directory) {
    return <ElfAlignmentResult>[
      for (final f
          in Directory(path)
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.so')))
        verifyElfBytes(f.path, f.readAsBytesSync()),
    ];
  }
  if (type != FileSystemEntityType.file) {
    return <ElfAlignmentResult>[
      ElfAlignmentResult(path, const <int>[], 'path not found'),
    ];
  }
  final bytes = File(path).readAsBytesSync();
  if (path.endsWith('.apk') || path.endsWith('.zip')) {
    final libs = readZipEntries(
      bytes,
      (n) => n.startsWith('lib/arm64-v8a/') && n.endsWith('.so'),
    );
    if (libs.isEmpty) {
      return <ElfAlignmentResult>[
        ElfAlignmentResult(path, const <int>[], 'no lib/arm64-v8a/*.so'),
      ];
    }
    return <ElfAlignmentResult>[
      for (final e in libs.entries) verifyElfBytes(e.key, e.value),
    ];
  }
  return <ElfAlignmentResult>[verifyElfBytes(path, bytes)];
}

/// Minimal ZIP central-directory reader (stored + deflate) for APK inspection.
Map<String, Uint8List> readZipEntries(
  Uint8List bytes,
  bool Function(String name) include,
) {
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  final minPos = bytes.length - 22 - 0xffff < 0
      ? 0
      : bytes.length - 22 - 0xffff;
  for (var i = bytes.length - 22; i >= minPos; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd == -1) throw const FormatException('ZIP end of central directory');
  final count = data.getUint16(eocd + 10, Endian.little);
  var cd = data.getUint32(eocd + 16, Endian.little);
  final out = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    if (data.getUint32(cd, Endian.little) != 0x02014b50) {
      throw const FormatException('ZIP central directory signature');
    }
    final method = data.getUint16(cd + 10, Endian.little);
    final compSize = data.getUint32(cd + 20, Endian.little);
    final nameLen = data.getUint16(cd + 28, Endian.little);
    final extraLen = data.getUint16(cd + 30, Endian.little);
    final commentLen = data.getUint16(cd + 32, Endian.little);
    final localOff = data.getUint32(cd + 42, Endian.little);
    final name = String.fromCharCodes(bytes, cd + 46, cd + 46 + nameLen);
    cd += 46 + nameLen + extraLen + commentLen;
    if (!include(name)) continue;
    final lNameLen = data.getUint16(localOff + 26, Endian.little);
    final lExtraLen = data.getUint16(localOff + 28, Endian.little);
    final start = localOff + 30 + lNameLen + lExtraLen;
    final raw = Uint8List.sublistView(bytes, start, start + compSize);
    if (method == 0) {
      out[name] = raw;
    } else if (method == 8) {
      out[name] = Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
    } else {
      throw FormatException('unsupported ZIP method $method for $name');
    }
  }
  return out;
}
