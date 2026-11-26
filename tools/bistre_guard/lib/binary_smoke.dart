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

/// Checks that the updater without arguments exits with the usage code `2`.
List<SmokeFailure> checkUpdaterUsageExit(int exitCode) => <SmokeFailure>[
  if (exitCode != 2)
    SmokeFailure('bistre-updater usage exit code is $exitCode, expected 2'),
];

/// Builds the daemon and updater (debug) and runs the same smoke checks as CI.
Future<List<SmokeFailure>> runBinarySmoke(Directory repoRoot) async {
  final build = await Process.run('cargo', const <String>[
    'build',
    '--locked',
    '-p',
    'bistre-daemon',
    '-p',
    'bistre-updater',
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
    final updater = await Process.run(
      '$bin/bistre-updater$ext',
      const <String>[],
    );
    return <SmokeFailure>[
      ...checkDaemonHealth('${health.stdout}'),
      ...checkUpdaterUsageExit(updater.exitCode),
    ];
  } finally {
    await dataDir.delete(recursive: true);
  }
}
