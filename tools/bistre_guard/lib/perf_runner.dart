import 'dart:io';

/// Spec 11 budgets checked by `just perf` (`budget`, `hard fail`).
const int desktopFirstFrameBudgetMs = 400;
const int desktopFirstFrameHardFailMs = 600;
const int androidColdStartBudgetMs = 650;
const int androidColdStartHardFailMs = 900;
const int idleRssBudgetBytes = 120 * 1024 * 1024;
const int idleRssHardFailBytes = 160 * 1024 * 1024;
const double streamFrameP95BudgetMs = 7.5;
const double streamFrameP95Budget60HzMs = 12;

/// Synthetic chats seeded into the scratch data directory.
const int perfSyntheticChats = 300;

/// Android application id launched by `--android`.
const String androidApplicationId = 'dev.bistre.app';

/// One measured metric with its budget verdict.
class PerfMetric {
  const PerfMetric(
    this.name,
    this.value,
    this.unit, {
    this.budget,
    this.hardFail,
  });

  final String name;
  final num value;
  final String unit;
  final num? budget;
  final num? hardFail;

  bool get overBudget => budget != null && value > budget!;
  bool get failed => hardFail != null && value > hardFail!;

  String describe() {
    final status = failed
        ? 'FAIL'
        : overBudget
        ? 'OVER'
        : 'OK  ';
    final b = budget == null ? '' : ' (budget $budget$unit)';
    return '$status $name: $value$unit$b';
  }
}

/// Parses `key=value` pairs from probe text (`[BISTRE_PERF] a=1 b=2` or one pair per line).
Map<String, String> parseProbe(String text) {
  final out = <String, String>{};
  for (final m in RegExp(r'([a-z0-9_]+)=([0-9.]+)').allMatches(text)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

/// Median of a non-empty list.
num median(List<num> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

/// Parses `TotalTime` from `am start -W` output.
int? parseAmStartTotalTime(String output) => int.tryParse(
  RegExp(r'TotalTime:\s*(\d+)').firstMatch(output)?.group(1) ?? '',
);

/// Parses `TOTAL PSS` (KB) from `dumpsys meminfo` output.
int? parseDumpsysTotalPssKb(String output) {
  final m =
      RegExp(r'TOTAL PSS:\s*(\d+)').firstMatch(output) ??
      RegExp(r'^\s*TOTAL\s+(\d+)', multiLine: true).firstMatch(output);
  return int.tryParse(m?.group(1) ?? '');
}

/// Runs the streaming frame probe test and returns its metrics.
Future<List<PerfMetric>> runStreamingProbe(Directory repoRoot) async {
  final result = await Process.run(
    'flutter',
    <String>['test', 'test/perf/streaming_frame_probe_test.dart'],
    workingDirectory: '${repoRoot.path}/apps/bistre_app',
    runInShell: Platform.isWindows,
  );
  final probe = parseProbe(
    '${result.stdout}'
        .split('\n')
        .where((l) => l.contains('[BISTRE_PERF]'))
        .join(' '),
  );
  final p50 = double.tryParse(probe['stream_frame_p50_ms'] ?? '');
  final p95 = double.tryParse(probe['stream_frame_p95_ms'] ?? '');
  if (result.exitCode != 0 || p50 == null || p95 == null) {
    throw StateError(
      'streaming probe failed:\n${result.stdout}\n${result.stderr}',
    );
  }
  final a11yP95 = double.tryParse(probe['stream_a11y_frame_p95_ms'] ?? '');
  return <PerfMetric>[
    PerfMetric('stream_frame_p50 (UI thread, debug test VM)', p50, 'ms'),
    PerfMetric(
      'stream_frame_p95 vs 60 Hz (UI thread, debug test VM)',
      p95,
      'ms',
      budget: streamFrameP95Budget60HzMs,
    ),
    PerfMetric(
      'stream_frame_p95 vs 120 Hz (UI thread, debug test VM)',
      p95,
      'ms',
      budget: streamFrameP95BudgetMs,
    ),
    if (a11yP95 != null)
      PerfMetric(
        'stream_frame_p95 with screen reader (debug test VM)',
        a11yP95,
        'ms',
        budget: streamFrameP95Budget60HzMs,
      ),
  ];
}

String _exe(String base) => Platform.isWindows ? '$base.exe' : base;

/// Release desktop app binary built by `flutter build windows|linux --release`.
File desktopReleaseApp(Directory repoRoot) => Platform.isWindows
    ? File(
        '${repoRoot.path}/apps/bistre_app/build/windows/x64/runner/Release/bistre_app.exe',
      )
    : File(
        '${repoRoot.path}/apps/bistre_app/build/linux/x64/release/bundle/bistre_app',
      );

/// Seeds a scratch data dir with synthetic chats via the release daemon, launches the release
/// app three times against it (median first frame / chat ready), and reads idle RSS once.
Future<List<PerfMetric>> runDesktopColdStart(Directory repoRoot) async {
  final daemon = File(
    '${repoRoot.path}/target/release/${_exe('bistre-daemon')}',
  );
  final app = desktopReleaseApp(repoRoot);
  if (!daemon.existsSync() || !app.existsSync()) {
    throw StateError(
      'missing release binaries (${daemon.path}, ${app.path}); build once with '
      '`cargo build --release -p bistre-daemon` and `flutter build ${Platform.isWindows ? 'windows' : 'linux'} --release`.',
    );
  }
  final scratch = Directory.systemTemp.createTempSync('bistre_perf_');
  try {
    final dataDir = Directory('${scratch.path}/data')..createSync();
    final seed = await Process.run(daemon.path, <String>[
      '--seed-synthetic',
      '$perfSyntheticChats',
      '--data-dir',
      dataDir.path,
    ]);
    if (seed.exitCode != 0) {
      throw StateError('synthetic seed failed: ${seed.stderr}');
    }
    final firstFrames = <num>[];
    final chatReady = <num>[];
    num? idleRss;
    for (var run = 0; run < 3; run++) {
      final probeFile = File('${scratch.path}/probe_$run.txt');
      final proc = await Process.start(
        app.path,
        const <String>[],
        environment: <String, String>{
          'BISTRE_DATA_DIR': dataDir.path,
          'BISTRE_PERF_PROBE': probeFile.path,
        },
      );
      final waitFor = run == 0 ? 'idle_rss_bytes' : 'chat_ready_ms';
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      Map<String, String> probe = const <String, String>{};
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (probeFile.existsSync()) {
          probe = parseProbe(probeFile.readAsStringSync());
          if (probe.containsKey(waitFor)) break;
        }
      }
      if (run == 0) {
        stdout.writeln(
          'rss at first frame: ${probe['first_frame_rss_bytes']} bytes; after 10 s idle: ${probe['idle_rss_bytes']} bytes',
        );
        if (Platform.isLinux) printRssByMapping(proc.pid);
      }
      proc.kill();
      await proc.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () => -1,
      );
      final ff = int.tryParse(probe['first_frame_ms'] ?? '');
      final cr = int.tryParse(probe['chat_ready_ms'] ?? '');
      if (ff == null || cr == null) {
        throw StateError('app probe incomplete on run $run: $probe');
      }
      firstFrames.add(ff);
      chatReady.add(cr);
      if (run == 0) idleRss = int.tryParse(probe['idle_rss_bytes'] ?? '');
    }
    return <PerfMetric>[
      PerfMetric(
        'desktop_first_frame (median of 3)',
        median(firstFrames),
        'ms',
        budget: desktopFirstFrameBudgetMs,
        hardFail: desktopFirstFrameHardFailMs,
      ),
      PerfMetric(
        'desktop_chat_ready_$perfSyntheticChats (median of 3)',
        median(chatReady),
        'ms',
      ),
      if (idleRss != null)
        PerfMetric(
          'desktop_idle_rss_after_10s',
          idleRss ~/ (1024 * 1024),
          'MB',
          budget: idleRssBudgetBytes ~/ (1024 * 1024),
          hardFail: idleRssHardFailBytes ~/ (1024 * 1024),
        ),
    ];
  } finally {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      stderr.writeln('note: could not remove ${scratch.path}');
    }
  }
}

/// Prints the ten largest resident mappings of [pid] (`/proc/<pid>/smaps`, Rss summed per
/// pathname; anonymous memory as `[anon]`) so an RSS budget failure names its owner.
void printRssByMapping(int pid) {
  final List<String> lines;
  try {
    lines = File('/proc/$pid/smaps').readAsLinesSync();
  } on FileSystemException catch (e) {
    stderr.writeln('note: smaps unavailable for $pid: ${e.message}');
    return;
  }
  final header = RegExp(r'^[0-9a-f]+-[0-9a-f]+ \S+ \S+ \S+ \S+\s*(.*)$');
  final kb = <String, int>{};
  var current = '[anon]';
  for (final line in lines) {
    final h = header.firstMatch(line);
    if (h != null) {
      final name = h.group(1)!.trim();
      current = name.isEmpty ? '[anon]' : name;
      continue;
    }
    if (line.startsWith('Rss:')) {
      final v = int.tryParse(line.split(RegExp(r'\s+'))[1]);
      if (v != null) kb[current] = (kb[current] ?? 0) + v;
    }
  }
  final top = kb.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('RSS by mapping (top 10 of ${kb.length}):');
  for (final e in top.take(10)) {
    stdout.writeln(
      '  ${(e.value / 1024).toStringAsFixed(1).padLeft(7)} MB  ${e.key}',
    );
  }
  // Threads by name: each allocating thread gets its own glibc malloc arena (`[anon]`).
  final byName = <String, int>{};
  try {
    for (final t in Directory('/proc/$pid/task').listSync()) {
      final comm = File('${t.path}/comm').readAsStringSync().trim();
      final key = comm.replaceAll(RegExp(r'[0-9]+$'), '#');
      byName[key] = (byName[key] ?? 0) + 1;
    }
    final status = File('/proc/$pid/status')
        .readAsLinesSync()
        .where(
          (l) =>
              RegExp(r'^(VmRSS|RssAnon|RssFile|RssShmem|Threads):').hasMatch(l),
        )
        .map((l) => l.replaceAll(RegExp(r'\s+'), ' '));
    stdout.writeln('status: ${status.join('; ')}');
  } on FileSystemException catch (e) {
    stderr.writeln('note: task list unavailable for $pid: ${e.message}');
  }
  final threads = byName.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln(
    'threads: ${threads.map((e) => '${e.key}x${e.value}').join(', ')}',
  );
}

/// Android cold start (`am start -W`) and PSS (`dumpsys meminfo`) on an installed APK.
Future<List<PerfMetric>> runAndroidProbe() async {
  final start = await Process.run('adb', <String>[
    'shell',
    'am',
    'start',
    '-W',
    '-S',
    '-n',
    '$androidApplicationId/dev.bistre.bistre_app.MainActivity',
  ]);
  final total = parseAmStartTotalTime('${start.stdout}');
  if (start.exitCode != 0 || total == null) {
    throw StateError('adb am start failed: ${start.stdout}${start.stderr}');
  }
  await Future<void>.delayed(const Duration(seconds: 10));
  final mem = await Process.run('adb', <String>[
    'shell',
    'dumpsys',
    'meminfo',
    androidApplicationId,
  ]);
  final pssKb = parseDumpsysTotalPssKb('${mem.stdout}');
  return <PerfMetric>[
    PerfMetric(
      'android_cold_start_total_time',
      total,
      'ms',
      budget: androidColdStartBudgetMs,
      hardFail: androidColdStartHardFailMs,
    ),
    if (pssKb != null)
      PerfMetric(
        'android_total_pss_after_10s',
        pssKb ~/ 1024,
        'MB',
        budget: 110,
      ),
  ];
}
