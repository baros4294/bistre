import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'perf_runner.dart';

/// App-owned idle memory budget (Spec 11 §1): the Dart main isolate's heap capacity plus
/// external memory, read over the VM service of a *profile* build after 10 s idle. The process
/// working set is dominated by the graphics driver and shared OS libraries (~225-250 MB of
/// ~250-270 MB on a GPU laptop), which Bistre does not control; the Rust core is bounded by the
/// daemon budget instead.
const int appOwnedBudgetBytes = 60 * 1024 * 1024;
const int appOwnedHardFailBytes = 80 * 1024 * 1024;

/// Profile bundle produced by `flutter build <windows|linux> --profile`.
File desktopProfileApp(Directory repoRoot) => Platform.isWindows
    ? File(
        '${repoRoot.path}/apps/bistre_app/build/windows/x64/runner/Profile/bistre_app.exe',
      )
    : File(
        '${repoRoot.path}/apps/bistre_app/build/linux/x64/profile/bundle/bistre_app',
      );

final RegExp _vmServiceUri = RegExp(r'(http://127\.0\.0\.1:\d+/[^\s/]+=/)');

Future<List<PerfMetric>> runAppOwnedMemory(Directory repoRoot) async {
  final app = desktopProfileApp(repoRoot);
  final daemon = File(
    '${repoRoot.path}/target/release/${Platform.isWindows ? 'bistre-daemon.exe' : 'bistre-daemon'}',
  );
  if (!app.existsSync() || !daemon.existsSync()) {
    throw StateError(
      'app-owned memory needs `flutter build ${Platform.isWindows ? 'windows' : 'linux'} --profile` '
      'and `cargo build --release -p bistre-daemon`.',
    );
  }
  final scratch = Directory.systemTemp.createTempSync('bistre_app_mem_');
  Process? proc;
  try {
    final dataDir = Directory('${scratch.path}/data')..createSync();
    final seed = await Process.run(daemon.path, <String>[
      '--seed-synthetic',
      '$perfSyntheticChats',
      '--data-dir',
      dataDir.path,
    ]);
    if (seed.exitCode != 0)
      throw StateError('synthetic seed failed: ${seed.stderr}');
    proc = await Process.start(
      app.path,
      const <String>[],
      environment: <String, String>{
        'BISTRE_DATA_DIR': dataDir.path,
        'BISTRE_PERF_PROBE': '${scratch.path}/probe.txt',
      },
    );
    final uri = Completer<String>();
    void scan(String chunk) {
      final m = _vmServiceUri.firstMatch(chunk);
      if (m != null && !uri.isCompleted) uri.complete(m.group(1));
    }

    proc.stdout.transform(utf8.decoder).listen(scan);
    proc.stderr.transform(utf8.decoder).listen(scan);
    final httpUri = await uri.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () =>
          throw StateError('profile app printed no VM service URI'),
    );
    // Same idle point as the RSS probe: chat list loaded, 10 s without input.
    await Future<void>.delayed(const Duration(seconds: 12));
    final heap = await _mainIsolateBytes(
      '${httpUri.replaceFirst('http', 'ws')}ws',
    );
    return <PerfMetric>[
      PerfMetric(
        'gui_app_owned_memory (Dart heap + external, profile)',
        heap ~/ (1024 * 1024),
        'MB',
        budget: appOwnedBudgetBytes ~/ (1024 * 1024),
        hardFail: appOwnedHardFailBytes ~/ (1024 * 1024),
      ),
    ];
  } finally {
    proc?.kill();
    await proc?.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      stderr.writeln('note: could not remove ${scratch.path}');
    }
  }
}

/// Heap capacity + external usage of the `main` isolate over the VM service (JSON-RPC 2.0).
Future<int> _mainIsolateBytes(String wsUri) async {
  final socket = await WebSocket.connect(wsUri);
  final pending = <String, Completer<Map<String, dynamic>>>{};
  var nextId = 0;
  final sub = socket.listen((raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    pending.remove(msg['id'])?.complete(msg);
  });
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = '${nextId++}';
    final done = Completer<Map<String, dynamic>>();
    pending[id] = done;
    socket.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return done.future.timeout(const Duration(seconds: 20));
  }

  try {
    final vm = await call('getVM');
    final result =
        vm['result'] as Map<String, dynamic>? ??
        (throw StateError('getVM failed: ${vm['error']}'));
    final isolates = (result['isolates'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final main =
        isolates.where((i) => i['name'] == 'main').firstOrNull ??
        (throw StateError(
          'no main isolate in ${isolates.map((i) => i['name']).toList()}',
        ));
    final usage = await call('getMemoryUsage', <String, Object?>{
      'isolateId': main['id'],
    });
    final r =
        usage['result'] as Map<String, dynamic>? ??
        (throw StateError('getMemoryUsage failed: ${usage['error']}'));
    return (r['heapCapacity'] as num).toInt() +
        (r['externalUsage'] as num).toInt();
  } finally {
    await sub.cancel();
    await socket.close();
  }
}
