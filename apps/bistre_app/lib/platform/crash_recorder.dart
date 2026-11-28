import 'dart:io';

/// Local-only, zero-telemetry crash recorder that scrubs secrets before persisting the latest
/// uncaught error to `<dataDir>/last_crash_report.txt` (capped at 16 KiB).
class CrashRecorder {
  CrashRecorder._();

  static const int maxReportBytes = 16 * 1024;
  static const String _kFileName = 'last_crash_report.txt';

  static final List<RegExp> _secretPatterns = <RegExp>[
    RegExp(r'sk-(?:proj-|ant-)?[A-Za-z0-9_\-]{12,}'),
    RegExp(r'AIzaSy[0-9A-Za-z_\-]{20,}'),
    RegExp(r'ghp_[A-Za-z0-9]{20,}'),
    RegExp(r'github_pat_[A-Za-z0-9_]{20,}'),
    RegExp(r'(bearer\s+)[A-Za-z0-9._\-+/=]{8,}', caseSensitive: false),
    RegExp(
      r'((?:api[_-]?key|x-api-key|authorization|token|key)\s*[:=]\s*)[^\s&;,]+',
      caseSensitive: false,
    ),
  ];

  /// Replaces API keys, bearer tokens, and query-param credentials with `[REDACTED]`.
  static String redactSecrets(String raw) {
    var out = raw;
    for (final p in _secretPatterns) {
      out = out.replaceAllMapped(p, (m) {
        if (m.groupCount >= 1 && m.group(1) != null) {
          return '${m.group(1)}[REDACTED]';
        }
        return '[REDACTED]';
      });
    }
    return out;
  }

  static File _reportFile(String dataDir) =>
      File('$dataDir${Platform.pathSeparator}$_kFileName');

  /// Persists a redacted crash report bounded to [maxReportBytes].
  static void recordSync(String dataDir, Object error, StackTrace? stack) {
    if (dataDir.trim().isEmpty) return;
    final raw = StringBuffer()
      ..writeln('Bistre local crash report')
      ..writeln(error.toString());
    if (stack != null) {
      raw.writeln(stack.toString());
    }
    var clean = redactSecrets(raw.toString());
    if (clean.length > maxReportBytes) {
      clean = '${clean.substring(0, maxReportBytes)}\n...[truncated]';
    }
    try {
      final file = _reportFile(dataDir);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(clean, flush: true);
    } on FileSystemException {
      // Never throw recursively from an uncaught error handler.
    }
  }

  /// Reads any crash report left by the previous session and clears it once consumed.
  static String? readAndClearPending(String dataDir) {
    if (dataDir.trim().isEmpty) return null;
    try {
      final file = _reportFile(dataDir);
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      file.deleteSync();
      return text.isEmpty ? null : text;
    } on FileSystemException {
      return null;
    }
  }
}
