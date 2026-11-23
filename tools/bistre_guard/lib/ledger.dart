import 'dart:io';
import 'dart:typed_data';

/// Local verification state root (gitignored).
const String verificationDir = '.bistre-local/verification';
const String ledgerFileName = 'ledger.txt';
const String lockFileName = 'run.lock';

/// 64-bit FNV-1a over raw bytes (Dart VM ints wrap modulo 2^64).
int fnv1a64(Uint8List bytes) {
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b;
    hash *= 0x100000001b3;
  }
  return hash;
}

/// Unsigned 16-digit hex (Dart ints are signed 64-bit, so render the two 32-bit halves).
String fnvHex(int hash) {
  final high = (hash >> 32) & 0xffffffff;
  final low = hash & 0xffffffff;
  return high.toRadixString(16).padLeft(8, '0') +
      low.toRadixString(16).padLeft(8, '0');
}

/// Verification stacks a touched path belongs to.
enum Stack { docs, rust, dart, android, l10n, ci }

/// Classifies a repo-relative path into the stacks whose checks it can affect.
Set<Stack> classifyPath(String rel) {
  final p = rel.replaceAll('\\', '/');
  if (p.startsWith('.github/')) return <Stack>{Stack.ci};
  if (p.startsWith('l10n/')) return <Stack>{Stack.l10n};
  if (p.startsWith('apps/bistre_app/android/')) return <Stack>{Stack.android};
  if (p.startsWith('crates/') ||
      p.startsWith('.cargo/') ||
      p == 'Cargo.toml' ||
      p == 'Cargo.lock' ||
      p == 'rust-toolchain.toml' ||
      p == 'clippy.toml' ||
      p == 'deny.toml') {
    // FFI surface changes also require Flutter tests against regenerated bindings.
    if (p.startsWith('crates/bistre-ffi/')) {
      return <Stack>{Stack.rust, Stack.dart};
    }
    return <Stack>{Stack.rust};
  }
  if (p.endsWith('.md') || p.startsWith('docs/') || p == 'LICENSE') {
    return <Stack>{Stack.docs};
  }
  if (p.startsWith('apps/') ||
      p.startsWith('tools/') ||
      p == 'pubspec.yaml' ||
      p == 'pubspec.lock' ||
      p == 'analysis_options.yaml') {
    return <Stack>{Stack.dart};
  }
  return <Stack>{Stack.docs};
}

/// Ordered `just` recipes required for the given stacks (guard always runs).
List<String> recipesFor(Set<Stack> stacks) {
  final recipes = <String>['guard'];
  final rust = stacks.contains(Stack.rust);
  final dart = stacks.contains(Stack.dart) || stacks.contains(Stack.android);
  final l10n = stacks.contains(Stack.l10n);
  if (rust || dart) recipes.add('fmt-check');
  if (rust) recipes.add('lint-rust');
  if (rust || l10n) recipes.add('i18n-check');
  if (dart || l10n) recipes.add('lint-dart');
  if (rust) recipes.add('test-rust');
  if (dart || l10n || stacks.contains(Stack.rust)) recipes.add('test-dart');
  return recipes;
}

/// Lists tracked + untracked-but-not-ignored files via git.
List<String> listWorkspaceFiles(Directory repoRoot) {
  final result = Process.runSync('git', <String>[
    'ls-files',
    '-co',
    '--exclude-standard',
    '-z',
  ], workingDirectory: repoRoot.path);
  if (result.exitCode != 0) {
    throw StateError('git ls-files failed: ${result.stderr}');
  }
  return (result.stdout as String)
      .split('\u0000')
      .where((p) => p.isNotEmpty)
      .toList()
    ..sort();
}

/// Current content fingerprints for every workspace file.
Map<String, String> fingerprintWorkspace(Directory repoRoot) {
  final out = <String, String>{};
  for (final rel in listWorkspaceFiles(repoRoot)) {
    final f = File('${repoRoot.path}/$rel');
    if (!f.existsSync()) continue;
    out[rel] = fnvHex(fnv1a64(f.readAsBytesSync()));
  }
  return out;
}

Map<String, String> readLedger(Directory repoRoot) {
  final f = File('${repoRoot.path}/$verificationDir/$ledgerFileName');
  if (!f.existsSync()) return <String, String>{};
  final out = <String, String>{};
  for (final line in f.readAsLinesSync()) {
    final space = line.indexOf(' ');
    if (space != 16) continue;
    out[line.substring(space + 1)] = line.substring(0, space);
  }
  return out;
}

void writeLedger(Directory repoRoot, Map<String, String> fingerprints) {
  final dir = Directory('${repoRoot.path}/$verificationDir')
    ..createSync(recursive: true);
  final keys = fingerprints.keys.toList()..sort();
  final tmp = File('${dir.path}/$ledgerFileName.tmp')
    ..writeAsStringSync(
      keys.map((k) => '${fingerprints[k]} $k\n').join(),
      flush: true,
    );
  tmp.renameSync('${dir.path}/$ledgerFileName');
}

/// Paths whose content differs from (or is missing in) the last recorded green run.
List<String> unverifiedPaths(
  Map<String, String> current,
  Map<String, String> ledger,
) {
  final out = <String>[
    for (final e in current.entries)
      if (ledger[e.key] != e.value) e.key,
    for (final k in ledger.keys)
      if (!current.containsKey(k)) k,
  ]..sort();
  return out;
}

Set<Stack> stacksFor(Iterable<String> paths) => <Stack>{
  for (final p in paths) ...classifyPath(p),
};

/// Advisory exclusive lock preventing concurrent heavy Rust/Flutter verification runs.
class SingleRunLock {
  SingleRunLock._(this._raf);
  final RandomAccessFile _raf;

  /// Returns `null` when another process already holds the lock.
  static SingleRunLock? tryAcquire(Directory repoRoot) {
    final dir = Directory('${repoRoot.path}/$verificationDir')
      ..createSync(recursive: true);
    final raf = File('${dir.path}/$lockFileName')
        .openSync(mode: FileMode.append);
    try {
      raf.lockSync();
    } on FileSystemException {
      raf.closeSync();
      return null;
    }
    raf
      ..truncateSync(0)
      ..writeStringSync('$pid\n');
    return SingleRunLock._(raf);
  }

  void release() {
    try {
      _raf.unlockSync();
    } finally {
      _raf.closeSync();
    }
  }
}
