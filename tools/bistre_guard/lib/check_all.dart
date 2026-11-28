import 'dart:io';

import 'binary_smoke.dart';
import 'bistre_guard.dart';
import 'ledger.dart';
import 'storage_qc.dart';

class _CheckTask {
  const _CheckTask(
    this.label,
    this.executable,
    this.args, {
    this.workingDirectory,
  });

  final String label;
  final String executable;
  final List<String> args;
  final String? workingDirectory;
}

class _CheckOutcome {
  const _CheckOutcome(this.label, this.exitCode, this.output, this.elapsedMs);

  final String label;
  final int exitCode;
  final String output;
  final int elapsedMs;
}

/// Runs the full local verification suite (`just check-all`) with two phases:
/// 1. Lock-free formatting, guards, i18n, cargo-deny, Dart/Flutter analysis, and tooling tests
///    in parallel (one Dart VM, zero `target/` contention).
/// 2. Heavy Cargo and Flutter test suites sequentially under [SingleRunLock], followed by
///    storage-budget enforcement and ledger recording.
Future<int> runFastCheckAll(Directory repoRoot) async {
  final totalClock = Stopwatch()..start();

  // Phase 1: parallel, lock-free static gates and tooling tests.
  final guardClock = Stopwatch()..start();
  final guardResult = runRepoGuards(repoRoot);
  guardClock.stop();

  final parallelTasks = <_CheckTask>[
    const _CheckTask('cargo-fmt', 'cargo', <String>['fmt', '--all', '--check']),
    const _CheckTask('dart-format', 'dart', <String>[
      'format',
      '--output=none',
      '--set-exit-if-changed',
      'apps/bistre_app/lib',
      'apps/bistre_app/test',
      'apps/bistre_app/hook',
      'tools/bistre_lints',
      'tools/bistre_i18n',
      'tools/bistre_guard',
    ]),
    const _CheckTask('i18n-check', 'dart', <String>[
      'run',
      'tools/bistre_i18n/bin/bistre_i18n.dart',
      'check',
    ]),
    const _CheckTask('cargo-deny', 'cargo', <String>[
      'deny',
      '--locked',
      'check',
    ]),
    const _CheckTask('flutter-analyze', 'flutter', <String>[
      'analyze',
      'apps/bistre_app',
    ]),
    const _CheckTask('dart-analyze', 'dart', <String>[
      'analyze',
      'tools/bistre_lints',
      'tools/bistre_i18n',
      'tools/bistre_guard',
    ]),
    const _CheckTask('test-tools', 'dart', <String>[
      'test',
      'tools/bistre_lints',
      'tools/bistre_i18n',
      'tools/bistre_guard',
    ]),
  ];

  final outcomes = await Future.wait(
    parallelTasks.map((t) => _runBuffered(repoRoot, t)),
  );

  var failed = false;
  if (!guardResult.isValid) {
    failed = true;
    stderr.writeln('FAIL guard (${guardClock.elapsedMilliseconds} ms):');
    for (final err in guardResult.errors) {
      stderr.writeln('  GUARD ERROR: $err');
    }
  } else {
    stdout.writeln('OK   guard (${guardClock.elapsedMilliseconds} ms)');
  }
  for (final o in outcomes) {
    if (o.exitCode != 0) {
      failed = true;
      stderr.writeln(
        'FAIL ${o.label} (exit ${o.exitCode}, ${o.elapsedMs} ms):',
      );
      if (o.output.isNotEmpty) stderr.writeln(o.output);
    } else {
      stdout.writeln('OK   ${o.label} (${o.elapsedMs} ms)');
    }
  }
  if (failed) return 1;

  // Phase 2: heavy Rust and Flutter build/test steps under one advisory lock.
  final lock = SingleRunLock.tryAcquire(repoRoot);
  if (lock == null) {
    stderr.writeln(
      'ERROR: another heavy verification run holds $verificationDir/$lockFileName; wait for it to finish.',
    );
    return 75;
  }
  try {
    final heavySteps = <_CheckTask>[
      const _CheckTask('cargo-clippy', 'cargo', <String>[
        'clippy',
        '--locked',
        '--workspace',
        '--all-targets',
        '--',
        '-D',
        'warnings',
      ]),
      const _CheckTask('cargo-nextest', 'cargo', <String>[
        'nextest',
        'run',
        '--locked',
        '--workspace',
      ]),
      const _CheckTask('cargo-doctest', 'cargo', <String>[
        'test',
        '--doc',
        '--locked',
        '--workspace',
      ]),
    ];
    for (final step in heavySteps) {
      final code = await _runStreaming(repoRoot, step);
      if (code != 0) return code;
    }

    final smokeClock = Stopwatch()..start();
    final smokeFailures = await runBinarySmoke(repoRoot);
    smokeClock.stop();
    if (smokeFailures.isNotEmpty) {
      for (final f in smokeFailures) {
        stderr.writeln('SMOKE ERROR: $f');
      }
      return 1;
    }
    stdout.writeln('OK   daemon-smoke (${smokeClock.elapsedMilliseconds} ms)');

    final flutterCode = await _runStreaming(
      repoRoot,
      _CheckTask('flutter-test', 'flutter', const <String>[
        'test',
      ], workingDirectory: '${repoRoot.path}/apps/bistre_app'),
    );
    if (flutterCode != 0) return flutterCode;

    final pruned = autoEnforceStorageBudget(repoRoot);
    if (pruned != null) {
      stdout.writeln(
        'Storage budget exceeded: auto-pruned ${pruned.removedEntries} entries (${formatBytes(pruned.reclaimedBytes)}).',
      );
    }
  } finally {
    lock.release();
  }

  final fingerprints = fingerprintWorkspace(repoRoot);
  writeLedger(repoRoot, fingerprints);
  stdout.writeln(
    'OK   check-all finished in ${(totalClock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s '
    '(${fingerprints.length} file fingerprints recorded).',
  );
  return 0;
}

Future<_CheckOutcome> _runBuffered(Directory repoRoot, _CheckTask task) async {
  final sw = Stopwatch()..start();
  final res = await Process.run(
    task.executable,
    task.args,
    workingDirectory: task.workingDirectory ?? repoRoot.path,
    runInShell: Platform.isWindows,
  );
  sw.stop();
  final out = '${res.stdout}${res.stderr}'.trim();
  return _CheckOutcome(task.label, res.exitCode, out, sw.elapsedMilliseconds);
}

Future<int> _runStreaming(Directory repoRoot, _CheckTask task) async {
  final sw = Stopwatch()..start();
  stdout.writeln('==> ${task.label}');
  final proc = await Process.start(
    task.executable,
    task.args,
    workingDirectory: task.workingDirectory ?? repoRoot.path,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  final code = await proc.exitCode;
  sw.stop();
  if (code == 0) {
    stdout.writeln('OK   ${task.label} (${sw.elapsedMilliseconds} ms)');
  } else {
    stderr.writeln(
      'FAIL ${task.label} (exit $code, ${sw.elapsedMilliseconds} ms)',
    );
  }
  return code;
}
