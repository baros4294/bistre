import 'dart:io';
import 'dart:typed_data';

import 'package:bistre_guard/elf_verify.dart';
import 'package:bistre_guard/ledger.dart';
import 'package:bistre_guard/storage_qc.dart';
import 'package:test/test.dart';

Directory _tmp() {
  final dir = Directory.systemTemp.createTempSync('bistre_qc_test_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

Directory _unit(
  Directory build,
  String crate,
  String hash,
  String kind,
  DateTime mtime, {
  bool withDll = false,
}) {
  final unit = Directory('${build.path}/$crate/$hash')
    ..createSync(recursive: true);
  final fp = Directory('${unit.path}/fingerprint')..createSync();
  final json = File('${fp.path}/$kind.json')..writeAsStringSync('{}');
  final out = Directory('${unit.path}/out')..createSync();
  File('${out.path}/payload.rmeta').writeAsBytesSync(List<int>.filled(64, 1));
  if (withDll) File('${out.path}/macros.dll').writeAsBytesSync(<int>[0]);
  json.setLastModifiedSync(mtime);
  return unit;
}

Uint8List _bytes(String text) => Uint8List.fromList(text.codeUnits);

/// Builds a minimal little-endian ELF64 image whose program headers are all `PT_LOAD`.
Uint8List _syntheticElf(List<int> loadAligns) {
  const phoff = 64;
  const phentsize = 56;
  final bytes = Uint8List(phoff + phentsize * loadAligns.length);
  final data = ByteData.sublistView(bytes);
  bytes
    ..[0] = 0x7f
    ..[1] = 0x45
    ..[2] = 0x4c
    ..[3] = 0x46
    ..[4] = 2
    ..[5] = 1;
  data
    ..setUint64(0x20, phoff, Endian.little)
    ..setUint16(0x36, phentsize, Endian.little)
    ..setUint16(0x38, loadAligns.length, Endian.little);
  for (var i = 0; i < loadAligns.length; i++) {
    final off = phoff + i * phentsize;
    data
      ..setUint32(off, 1, Endian.little)
      ..setUint64(off + 0x30, loadAligns[i], Endian.little);
  }
  return bytes;
}

void main() {
  group('storage QC pruner', () {
    test('keeps newest units per kind, never mixes kinds, skips DLL units', () {
      final root = _tmp();
      final build = Directory('${root.path}/target/debug/build')
        ..createSync(recursive: true);
      final t0 = DateTime(2026, 2, 3);
      final libOld = _unit(build, 'core', '0000000000000001', 'lib-core', t0);
      final libMid = _unit(
        build,
        'core',
        '0000000000000002',
        'lib-core',
        t0.add(const Duration(hours: 1)),
      );
      final libNew = _unit(
        build,
        'core',
        '0000000000000003',
        'lib-core',
        t0.add(const Duration(hours: 2)),
      );
      final testOld = _unit(
        build,
        'core',
        '0000000000000004',
        'test-lib-core',
        t0,
      );
      final macroOld = _unit(
        build,
        'derive',
        '0000000000000005',
        'lib-derive',
        t0,
        withDll: true,
      );
      _unit(
        build,
        'derive',
        '0000000000000006',
        'lib-derive',
        t0.add(const Duration(hours: 1)),
      );
      _unit(
        build,
        'derive',
        '0000000000000007',
        'lib-derive',
        t0.add(const Duration(hours: 2)),
      );

      final report = pruneWorkspace(root);

      expect(libOld.existsSync(), isFalse);
      expect(libMid.existsSync(), isTrue);
      expect(libNew.existsSync(), isTrue);
      expect(testOld.existsSync(), isTrue, reason: 'different unit kind');
      expect(macroOld.existsSync(), isTrue, reason: 'holds a proc-macro DLL');
      expect(report.removedEntries, 1);
    });

    test('keeps one incremental session per crate stem', () {
      final root = _tmp();
      final inc = Directory('${root.path}/target/debug/incremental')
        ..createSync(recursive: true);
      final old = Directory('${inc.path}/bistre_core-0aaa')..createSync();
      File('${old.path}/s').writeAsStringSync('x');
      final fresh = Directory('${inc.path}/bistre_core-0bbb')..createSync();
      File('${fresh.path}/s').writeAsStringSync('x');
      final other = Directory('${inc.path}/bistre_storage-0ccc')..createSync();

      pruneIncremental(Directory('${root.path}/target/debug'), PruneReport());

      expect(
        <bool>[old.existsSync(), fresh.existsSync()].where((e) => e).length,
        1,
      );
      expect(other.existsSync(), isTrue);
    });

    test('flags over-budget buckets and removes oversized logs only', () {
      final root = _tmp();
      final logs = Directory('${root.path}/.bistre-local/verification')
        ..createSync(recursive: true);
      final big = File('${logs.path}/run.log')
        ..writeAsBytesSync(List<int>.filled(maxVerificationLogBytes + 1, 0));
      final small = File('${logs.path}/ok.log')..writeAsStringSync('ok');
      final ledger = File('${logs.path}/ledger.txt')
        ..writeAsBytesSync(List<int>.filled(maxVerificationLogBytes + 1, 0));

      pruneVerificationLogs(
        Directory('${root.path}/.bistre-local'),
        PruneReport(),
      );

      expect(big.existsSync(), isFalse);
      expect(small.existsSync(), isTrue);
      expect(ledger.existsSync(), isTrue);
      const usage = BucketUsage(StorageBudget('target', 10, 't'), 11);
      expect(usage.overBudget, isTrue);
      expect(renderDiskReport(<BucketUsage>[usage]), contains('[OVER BUDGET]'));
    });

    test('keeps only the debug and Android caches and drops stray builds', () {
      final root = _tmp();
      for (final dir in <String>[
        'target/debug/deps',
        'target/release/deps',
        'target/x86_64-pc-windows-msvc/release',
        'target/aarch64-linux-android/release',
        'target/tmp',
        'build/ui_gallery',
        'apps/bistre_app/build/native_assets',
      ]) {
        Directory('${root.path}/$dir').createSync(recursive: true);
        File('${root.path}/$dir/f.bin').writeAsBytesSync(<int>[1, 2, 3]);
      }
      final report = pruneWorkspace(root);
      bool kept(String rel) => Directory('${root.path}/$rel').existsSync();
      expect(kept('target/debug'), isTrue);
      expect(kept('target/aarch64-linux-android'), isTrue);
      expect(kept('target/tmp'), isTrue);
      expect(kept('apps/bistre_app/build/native_assets'), isTrue);
      expect(kept('target/release'), isFalse);
      expect(kept('target/x86_64-pc-windows-msvc'), isFalse);
      expect(kept('build'), isFalse);
      expect(report.reclaimedBytes, 9);
    });

    test('cargoHashedStem strips the trailing hash only', () {
      expect(cargoHashedStem('bistre_core-0kkjxpdrsvs33'), 'bistre_core');
      expect(cargoHashedStem('serde_json-1a2b'), 'serde_json');
      expect(cargoHashedStem('plain'), 'plain');
    });
  });

  group('verification ledger', () {
    test('FNV-1a 64 matches published vectors', () {
      expect(fnvHex(fnv1a64(_bytes(''))), 'cbf29ce484222325');
      expect(fnvHex(fnv1a64(_bytes('a'))), 'af63dc4c8601ec8c');
      expect(fnvHex(fnv1a64(_bytes('foobar'))), '85944171f73967e8');
    });

    test('classifies paths into stacks and minimal recipes', () {
      expect(classifyPath('docs/specs/11-performance-and-budgets.md'), <Stack>{
        Stack.docs,
      });
      expect(classifyPath('crates/bistre-core/src/lib.rs'), <Stack>{
        Stack.rust,
      });
      expect(classifyPath('crates/bistre-ffi/src/api.rs'), <Stack>{
        Stack.rust,
        Stack.dart,
      });
      expect(classifyPath('apps/bistre_app/lib/main.dart'), <Stack>{
        Stack.dart,
      });
      expect(
        classifyPath('apps/bistre_app/android/app/build.gradle.kts'),
        <Stack>{Stack.android},
      );
      expect(recipesFor(<Stack>{Stack.docs}), <String>['guard']);
      expect(
        recipesFor(<Stack>{Stack.rust}),
        containsAll(<String>['lint-rust', 'test-rust', 'i18n-check']),
      );
      expect(recipesFor(<Stack>{Stack.dart}), isNot(contains('test-rust')));
    });

    test('reports changed, new, and deleted files', () {
      final pending = unverifiedPaths(
        <String, String>{'a': '1', 'b': '2', 'new': '3'},
        <String, String>{'a': '1', 'b': 'old', 'gone': '4'},
      );
      expect(pending, <String>['b', 'gone', 'new']);
    });

    test('single-run lock rejects a second holder until released', () async {
      final root = _tmp();
      final first = SingleRunLock.tryAcquire(root);
      expect(first, isNotNull);
      // Advisory locks are per-process on POSIX, so contention is proven from a child isolate-free process.
      final script = File('${root.path}/probe.dart')
        ..writeAsStringSync('''
import 'dart:io';
void main(List<String> a) {
  final raf = File(a.first).openSync(mode: FileMode.append);
  try { raf.lockSync(); stdout.write('acquired'); } on FileSystemException { stdout.write('busy'); }
}
''');
      final lockPath = '${root.path}/$verificationDir/$lockFileName';
      final busy = await Process.run(Platform.resolvedExecutable, <String>[
        script.path,
        lockPath,
      ]);
      expect(busy.stdout, 'busy');
      first!.release();
      final free = await Process.run(Platform.resolvedExecutable, <String>[
        script.path,
        lockPath,
      ]);
      expect(free.stdout, 'acquired');
    });
  });

  group('ELF 16 KiB verifier', () {
    test('accepts 16 KiB PT_LOAD alignment and rejects 4 KiB', () {
      final ok = verifyElfBytes('ok.so', _syntheticElf(<int>[0x4000, 0x4000]));
      expect(ok.isValid, isTrue, reason: ok.describe());
      final bad = verifyElfBytes(
        'bad.so',
        _syntheticElf(<int>[0x4000, 0x1000]),
      );
      expect(bad.isValid, isFalse);
      expect(bad.describe(), contains('0x1000'));
      final none = verifyElfBytes('none.so', _syntheticElf(<int>[]));
      expect(none.isValid, isFalse);
      final notElf = verifyElfBytes(
        'x.so',
        _bytes('not an elf file at all, padded out to 64 bytes....'),
      );
      expect(notElf.error, isNotNull);
    });
  });
}
