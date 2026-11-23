import 'dart:io';

/// One GiB / MiB in bytes.
const int gib = 1024 * 1024 * 1024;
const int mib = 1024 * 1024;

/// Workspace build-cache budgets locked by `docs/specs/11-performance-and-budgets.md` §4.
class StorageBudget {
  const StorageBudget(this.relPath, this.maxBytes, this.label);
  final String relPath;
  final int maxBytes;
  final String label;
}

const List<StorageBudget> storageBudgets = <StorageBudget>[
  StorageBudget('target', 5 * gib, 'Rust target/'),
  StorageBudget('apps/bistre_app/build', 1 * gib, 'Flutter build/'),
  StorageBudget('apps/bistre_app/.dart_tool', 512 * mib, 'Flutter .dart_tool/'),
  StorageBudget('.bistre-local', 128 * mib, 'Local verification state'),
];

/// Maximum size of a single verification log under `.bistre-local/`.
const int maxVerificationLogBytes = 2 * mib;

/// Number of newest nested `build/<crate>/<hash>/` units kept per unit kind.
const int keepBuildUnitsDebug = 2;
const int keepBuildUnitsRelease = 1;

/// Measured size of one budgeted bucket.
class BucketUsage {
  const BucketUsage(this.budget, this.bytes);
  final StorageBudget budget;
  final int bytes;
  bool get overBudget => bytes > budget.maxBytes;
}

/// Summary of a non-destructive prune pass.
class PruneReport {
  int removedEntries = 0;
  int reclaimedBytes = 0;
  final List<String> actions = <String>[];

  void record(String action, int bytes) {
    removedEntries++;
    reclaimedBytes += bytes;
    actions.add(action);
  }
}

/// Recursively sums file sizes (symlinks are never followed).
int directorySize(Directory dir) {
  if (!dir.existsSync()) return 0;
  var total = 0;
  try {
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += entity.lengthSync();
        } on FileSystemException {
          // Files deleted or locked mid-scan are skipped; the scan stays best-effort.
          continue;
        }
      }
    }
  } on FileSystemException {
    return total;
  }
  return total;
}

/// Measures every budgeted bucket under [repoRoot].
List<BucketUsage> measureStorage(Directory repoRoot) => <BucketUsage>[
  for (final b in storageBudgets)
    BucketUsage(b, directorySize(Directory('${repoRoot.path}/${b.relPath}'))),
];

String formatBytes(int bytes) {
  if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(2)} GiB';
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MiB';
  return '${(bytes / 1024).toStringAsFixed(1)} KiB';
}

/// Human-readable `just disk` report.
String renderDiskReport(List<BucketUsage> usage) {
  final buf = StringBuffer();
  for (final u in usage) {
    final flag = u.overBudget ? '  [OVER BUDGET]' : '';
    buf.writeln(
      '${u.budget.label.padRight(26)} ${formatBytes(u.bytes).padLeft(11)} / ${formatBytes(u.budget.maxBytes)}$flag',
    );
  }
  return buf.toString();
}

/// Surgical, non-destructive cache pruner. Never runs `cargo clean`; only removes superseded
/// incremental sessions, stale nested build units, orphaned flat `deps/`, stale hashed `deps/`
/// files, and oversized verification logs.
PruneReport pruneWorkspace(Directory repoRoot) {
  final report = PruneReport();
  final target = Directory('${repoRoot.path}/target');
  if (target.existsSync()) {
    for (final profileDir in _profileDirs(target)) {
      final name = profileDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final keep = name == 'debug'
          ? keepBuildUnitsDebug
          : keepBuildUnitsRelease;
      pruneIncremental(profileDir, report);
      final orphaned = pruneOrphanedFlatDeps(profileDir, report);
      if (!orphaned) pruneStaleDeps(profileDir, report);
      pruneNestedBuildUnits(profileDir, keep, report);
    }
  }
  pruneVerificationLogs(Directory('${repoRoot.path}/.bistre-local'), report);
  return report;
}

/// Runs [pruneWorkspace] only when any budget is exceeded. Returns `null` when within budget.
PruneReport? autoEnforceStorageBudget(Directory repoRoot) {
  final over = measureStorage(repoRoot).any((u) => u.overBudget);
  return over ? pruneWorkspace(repoRoot) : null;
}

/// `target/<profile>/` plus cross-compiled `target/<triple>/<profile>/` directories.
Iterable<Directory> _profileDirs(Directory target) sync* {
  for (final child in target.listSync().whereType<Directory>()) {
    if (File('${child.path}/.rustc_info.json').existsSync()) continue;
    if (Directory('${child.path}/build').existsSync() ||
        Directory('${child.path}/incremental').existsSync() ||
        Directory('${child.path}/deps').existsSync()) {
      yield child;
      continue;
    }
    for (final nested in child.listSync().whereType<Directory>()) {
      if (Directory('${nested.path}/build').existsSync() ||
          Directory('${nested.path}/incremental').existsSync()) {
        yield nested;
      }
    }
  }
}

/// Splits Cargo's `<stem>-<hash>` names into the stem (`bistre_core-0kkj...` → `bistre_core`).
String cargoHashedStem(String name) {
  final idx = name.lastIndexOf('-');
  return idx <= 0 ? name : name.substring(0, idx);
}

/// Keeps only the newest incremental session per crate stem.
void pruneIncremental(Directory profileDir, PruneReport report) {
  final inc = Directory('${profileDir.path}/incremental');
  if (!inc.existsSync()) return;
  final groups = <String, List<Directory>>{};
  for (final d in inc.listSync().whereType<Directory>()) {
    groups.putIfAbsent(cargoHashedStem(_name(d)), () => <Directory>[]).add(d);
  }
  for (final entries in groups.values) {
    _deleteAllButNewest(entries, 1, report);
  }
}

/// Removes a legacy flat `deps/` directory once Cargo's nested `build/<crate>/<hash>/out/` layout
/// is clearly active (`>= 5` nested crates and `deps/` older than `build/`).
bool pruneOrphanedFlatDeps(Directory profileDir, PruneReport report) {
  final deps = Directory('${profileDir.path}/deps');
  final build = Directory('${profileDir.path}/build');
  if (!deps.existsSync() || !build.existsSync()) return false;
  var nestedCrates = 0;
  for (final crate in build.listSync().whereType<Directory>()) {
    final hasNested = crate.listSync().whereType<Directory>().any(
      (h) => Directory('${h.path}/out').existsSync() && _isHashName(_name(h)),
    );
    if (hasNested) nestedCrates++;
  }
  if (nestedCrates < 5) return false;
  if (!deps.statSync().modified.isBefore(build.statSync().modified)) {
    return false;
  }
  final bytes = directorySize(deps);
  if (_tryDelete(deps)) {
    report.record('removed orphaned flat ${_rel(deps)}', bytes);
    return true;
  }
  return false;
}

/// Keeps the newest file per `<stem>\0<ext>` inside a still-active flat `deps/`.
void pruneStaleDeps(Directory profileDir, PruneReport report) {
  final deps = Directory('${profileDir.path}/deps');
  if (!deps.existsSync()) return;
  final groups = <String, List<File>>{};
  for (final f in deps.listSync().whereType<File>()) {
    final name = _name(f);
    final dot = name.indexOf('.');
    final base = dot == -1 ? name : name.substring(0, dot);
    final ext = dot == -1 ? '' : name.substring(dot);
    if (!base.contains('-')) continue;
    if (ext == '.dll' || ext == '.so' || ext == '.dylib') {
      // Proc-macro shared objects may be mapped by rust-analyzer; never delete them.
      continue;
    }
    groups
        .putIfAbsent('${cargoHashedStem(base)}\u0000$ext', () => <File>[])
        .add(f);
  }
  for (final files in groups.values) {
    _deleteAllButNewest(files, 1, report);
  }
}

/// Groups `target/<profile>/build/<crate>/<16hex>/` units by fingerprint kind and keeps [keep]
/// newest per kind. Directories holding any shared library (proc-macro `.dll`) are skipped.
void pruneNestedBuildUnits(Directory profileDir, int keep, PruneReport report) {
  final build = Directory('${profileDir.path}/build');
  if (!build.existsSync()) return;
  for (final crate in build.listSync().whereType<Directory>()) {
    final groups = <String, List<Directory>>{};
    for (final unit in crate.listSync().whereType<Directory>()) {
      if (!_isHashName(_name(unit))) continue;
      if (containsSharedLibrary(unit)) continue;
      groups.putIfAbsent(cargoUnitKindKey(unit), () => <Directory>[]).add(unit);
    }
    for (final units in groups.values) {
      _deleteAllButNewest(units, keep, report);
    }
  }
}

/// Unit kind from the fingerprint file names (`lib-x.json`, `test-lib-x.json`,
/// `build-script-build-script-build.json`, `run-build-script-...`), so kinds never clobber each other.
String cargoUnitKindKey(Directory unit) {
  final fp = Directory('${unit.path}/fingerprint');
  if (!fp.existsSync()) return '<no-fingerprint>';
  final kinds =
      fp
          .listSync()
          .whereType<File>()
          .map(_name)
          .where((n) => n.endsWith('.json'))
          .map((n) => n.substring(0, n.length - 5))
          .toList()
        ..sort();
  return kinds.isEmpty ? '<no-fingerprint>' : kinds.join('|');
}

bool containsSharedLibrary(Directory dir) {
  try {
    return dir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .any((f) {
          final n = _name(f).toLowerCase();
          return n.endsWith('.dll') ||
              n.endsWith('.so') ||
              n.endsWith('.dylib');
        });
  } on FileSystemException {
    return true;
  }
}

/// Deletes `.log` files above [maxVerificationLogBytes] under `.bistre-local/` (keeps the ledger).
void pruneVerificationLogs(Directory local, PruneReport report) {
  if (!local.existsSync()) return;
  for (final f in local.listSync(recursive: true).whereType<File>()) {
    if (!_name(f).endsWith('.log')) continue;
    final len = f.lengthSync();
    if (len > maxVerificationLogBytes && _tryDelete(f)) {
      report.record('removed oversized log ${_rel(f)}', len);
    }
  }
}

void _deleteAllButNewest(
  List<FileSystemEntity> entries,
  int keep,
  PruneReport report,
) {
  if (entries.length <= keep) return;
  entries.sort((a, b) => _mtime(b).compareTo(_mtime(a)));
  for (final stale in entries.skip(keep)) {
    final bytes = stale is Directory
        ? directorySize(stale)
        : (stale as File).lengthSync();
    if (_tryDelete(stale)) {
      report.record('removed ${_rel(stale)}', bytes);
    }
  }
}

DateTime _mtime(FileSystemEntity e) {
  try {
    if (e is Directory) {
      // Cargo rewrites fingerprint files (`invoked.timestamp`, `*.json`) on every unit build.
      final fp = Directory('${e.path}/fingerprint');
      if (fp.existsSync()) {
        var newest = DateTime.fromMillisecondsSinceEpoch(0);
        for (final f in fp.listSync().whereType<File>()) {
          final m = f.lastModifiedSync();
          if (m.isAfter(newest)) newest = m;
        }
        return newest;
      }
    }
    return e.statSync().modified;
  } on FileSystemException {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

bool _tryDelete(FileSystemEntity e) {
  try {
    e.deleteSync(recursive: true);
    return true;
  } on FileSystemException {
    // Locked (e.g. mapped by a running process) entries are left in place.
    return false;
  }
}

bool _isHashName(String name) => RegExp(r'^[0-9a-f]{16}$').hasMatch(name);

String _name(FileSystemEntity e) =>
    e.uri.pathSegments.where((s) => s.isNotEmpty).last;

String _rel(FileSystemEntity e) {
  final p = e.path.replaceAll('\\', '/');
  final idx = p.indexOf('target/');
  if (idx != -1) return p.substring(idx);
  final local = p.indexOf('.bistre-local/');
  return local != -1 ? p.substring(local) : p;
}
