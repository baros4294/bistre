import 'dart:convert';
import 'dart:io';

/// One failed expectation of the binary smoke test.
class SmokeFailure {
  const SmokeFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Checks the daemon `--health-check` JSON: WAL active and `diag.ok`.
List<SmokeFailure> checkDaemonHealth(String healthJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(healthJson.trim());
  } on FormatException catch (e) {
    return <SmokeFailure>[
      SmokeFailure('daemon health output is not JSON: ${e.message}'),
    ];
  }
  if (decoded is! Map<String, Object?>) {
    return const <SmokeFailure>[
      SmokeFailure('daemon health output is not a JSON object'),
    ];
  }
  return <SmokeFailure>[
    if (decoded['wal_mode_active'] != true)
      const SmokeFailure('daemon health: wal_mode_active is not true'),
    if (decoded['status_key'] != 'diag.ok')
      SmokeFailure('daemon health: status_key is ${decoded['status_key']}'),
  ];
}

/// Builds the daemon (debug) and runs the same smoke check as CI.
Future<List<SmokeFailure>> runBinarySmoke(Directory repoRoot) async {
  final build = await Process.run('cargo', const <String>[
    'build',
    '--locked',
    '-p',
    'bistre-daemon',
  ], workingDirectory: repoRoot.path);
  if (build.exitCode != 0) {
    return <SmokeFailure>[
      SmokeFailure('cargo build failed (${build.exitCode}):\n${build.stderr}'),
    ];
  }
  final ext = Platform.isWindows ? '.exe' : '';
  final bin = '${repoRoot.path}/target/debug';
  final dataDir = await Directory.systemTemp.createTemp('bistre-smoke-');
  try {
    final health = await Process.run('$bin/bistre-daemon$ext', <String>[
      '--health-check',
      '--data-dir',
      dataDir.path,
    ]);
    if (health.exitCode != 0) {
      return <SmokeFailure>[
        SmokeFailure(
          'daemon --health-check exited ${health.exitCode}:\n${health.stderr}',
        ),
      ];
    }
    return checkDaemonHealth('${health.stdout}');
  } finally {
    await dataDir.delete(recursive: true);
  }
}
