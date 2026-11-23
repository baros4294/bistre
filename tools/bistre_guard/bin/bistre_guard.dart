import 'dart:io';

import 'package:bistre_guard/bistre_guard.dart';
import 'package:bistre_guard/elf_verify.dart';
import 'package:bistre_guard/ledger.dart';
import 'package:bistre_guard/perf_runner.dart';
import 'package:bistre_guard/storage_qc.dart';

const String _usage = '''
Usage: dart run tools/bistre_guard/bin/bistre_guard.dart [command]

Commands:
  (none)               Run all repository guards
  disk                 Report workspace build-cache usage against Spec 11 budgets
  prune                Non-destructively prune stale Cargo/Flutter caches and oversized logs
  status               Show storage warnings and files not yet verified by a green run
  affected [--run]     Print (or run) the just recipes affected by unverified files
  record               Record current file fingerprints after a green verification run
  locked <cmd> [args]  Run a heavy command under the single-run lock, then enforce budgets
  verify-elf <path>    Verify 16 KiB PT_LOAD alignment of a .so, directory, or APK
  perf [--android] [--skip-desktop]
                       Streaming frame probe + 300-chat desktop cold start / idle RSS
''';

Future<void> main(List<String> args) async {
  final repoRoot = _findRepoRoot(Directory.current);
  final command = args.isEmpty ? '' : args.first;
  switch (command) {
    case '':
      _runGuards(repoRoot);
    case 'disk':
      stdout.write(renderDiskReport(measureStorage(repoRoot)));
    case 'prune':
      final before = measureStorage(repoRoot);
      final report = pruneWorkspace(repoRoot);
      stdout
        ..writeln('Before:')
        ..write(renderDiskReport(before))
        ..writeln(
          'Pruned ${report.removedEntries} stale entr${report.removedEntries == 1 ? 'y' : 'ies'}, '
          'reclaimed ${formatBytes(report.reclaimedBytes)}.',
        )
        ..writeln('After:')
        ..write(renderDiskReport(measureStorage(repoRoot)));
    case 'status':
      _status(repoRoot);
    case 'affected':
      exitCode = await _affected(repoRoot, run: args.contains('--run'));
    case 'record':
      final fingerprints = fingerprintWorkspace(repoRoot);
      writeLedger(repoRoot, fingerprints);
      stdout.writeln(
        'Recorded ${fingerprints.length} verified file fingerprint(s).',
      );
    case 'locked':
      if (args.length < 2) {
        stderr.write(_usage);
        exitCode = 64;
        return;
      }
      exitCode = await _locked(repoRoot, args[1], args.sublist(2));
    case 'verify-elf':
      if (args.length != 2) {
        stderr.write(_usage);
        exitCode = 64;
        return;
      }
      final results = verifyElfPath(args[1]);
      for (final r in results) {
        stdout.writeln(r.describe());
      }
      if (results.isEmpty || results.any((r) => !r.isValid)) exitCode = 1;
    case 'perf':
      exitCode = await _perf(
        repoRoot,
        android: args.contains('--android'),
        desktop: !args.contains('--skip-desktop'),
      );
    default:
      stderr.write(_usage);
      exitCode = 64;
  }
}

Future<int> _perf(
  Directory repoRoot, {
  required bool android,
  required bool desktop,
}) async {
  final metrics = <PerfMetric>[];
  final notes = <String>[];
  Future<void> section(Future<List<PerfMetric>> Function() run) async {
    try {
      metrics.addAll(await run());
    } on StateError catch (e) {
      notes.add('SKIP ${e.message}');
    }
  }

  await section(() => runStreamingProbe(repoRoot));
  if (desktop) await section(() => runDesktopColdStart(repoRoot));
  if (android) await section(runAndroidProbe);
  for (final m in metrics) {
    stdout.writeln(m.describe());
  }
  for (final n in notes) {
    stdout.writeln(n);
  }
  return metrics.any((m) => m.failed) ? 1 : 0;
}

void _runGuards(Directory repoRoot) {
  final result = runRepoGuards(repoRoot);
  if (!result.isValid) {
    for (final err in result.errors) {
      stderr.writeln('GUARD ERROR: $err');
    }
    stderr.writeln(
      '\nFAILED: ${result.errors.length} repository rigor violation(s) detected.',
    );
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'OK: all Bistre code hygiene, documentation integrity, version parity, and CI security guards passed.',
  );
}

void _status(Directory repoRoot) {
  for (final u in measureStorage(repoRoot).where((u) => u.overBudget)) {
    stdout.writeln(
      'WARNING: ${u.budget.label} is ${formatBytes(u.bytes)} (budget ${formatBytes(u.budget.maxBytes)}); run `just prune`.',
    );
  }
  final pending = unverifiedPaths(
    fingerprintWorkspace(repoRoot),
    readLedger(repoRoot),
  );
  if (pending.isEmpty) {
    stdout.writeln('All files verified by the last green run.');
    return;
  }
  stdout.writeln('Not yet verified: ${pending.length} file(s).');
  for (final p in pending.take(20)) {
    stdout.writeln('  $p');
  }
  if (pending.length > 20) stdout.writeln('  ...');
  stdout.writeln(
    'Next check: just ${recipesFor(stacksFor(pending)).join(' ')}',
  );
}

Future<int> _affected(Directory repoRoot, {required bool run}) async {
  final current = fingerprintWorkspace(repoRoot);
  final pending = unverifiedPaths(current, readLedger(repoRoot));
  final recipes = recipesFor(stacksFor(pending));
  if (pending.isEmpty) {
    stdout.writeln('Nothing to verify.');
    return 0;
  }
  stdout.writeln(recipes.join(' '));
  if (!run) return 0;
  for (final recipe in recipes) {
    final proc = await Process.start(
      'just',
      <String>[recipe],
      workingDirectory: repoRoot.path,
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
    final code = await proc.exitCode;
    if (code != 0) return code;
  }
  writeLedger(repoRoot, fingerprintWorkspace(repoRoot));
  return 0;
}

Future<int> _locked(
  Directory repoRoot,
  String executable,
  List<String> args,
) async {
  final lock = SingleRunLock.tryAcquire(repoRoot);
  if (lock == null) {
    stderr.writeln(
      'ERROR: another heavy verification run holds $verificationDir/$lockFileName; wait for it to finish.',
    );
    return 75;
  }
  try {
    final proc = await Process.start(
      executable,
      args,
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
    final code = await proc.exitCode;
    final report = autoEnforceStorageBudget(repoRoot);
    if (report != null) {
      stdout.writeln(
        'Storage budget exceeded: auto-pruned ${report.removedEntries} entries (${formatBytes(report.reclaimedBytes)}).',
      );
    }
    return code;
  } finally {
    lock.release();
  }
}

Directory _findRepoRoot(Directory start) {
  var dir = start.absolute;
  while (true) {
    if (File('${dir.path}/AGENTS.md').existsSync() &&
        File('${dir.path}/Cargo.toml').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return start.absolute;
    }
    dir = parent;
  }
}
