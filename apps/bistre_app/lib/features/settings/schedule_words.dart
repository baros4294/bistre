import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// A task's schedule in words, for the two forms core's `cron.rs` reads:
/// `every 30m` (s, m, h, d) and a 5-field UTC cron. The common cron shapes read as
/// "Every day at 09:00 UTC" or "Every 15 minutes"; any other expression is shown as typed.
String scheduleInWords(BistreLocalizationController l10n, String expr) {
  final raw = expr.trim();
  final norm = raw.toLowerCase();
  if (norm.startsWith('every ')) {
    final spec = norm.substring(6).trim();
    final count = spec.length < 2
        ? null
        : int.tryParse(spec.substring(0, spec.length - 1).trim());
    if (count == null || count <= 0) return raw;
    final key = switch (spec[spec.length - 1]) {
      's' => L10nKey.automationsEverySeconds,
      'm' => L10nKey.automationsEveryMinutes,
      'h' => L10nKey.automationsEveryHours,
      'd' => L10nKey.automationsEveryDays,
      _ => null,
    };
    return key == null ? raw : l10n.t(key, <String, Object?>{'count': count});
  }
  final f = norm.split(RegExp(r'\s+'));
  if (f.length != 5 || f[2] != '*' || f[3] != '*' || f[4] != '*') return raw;
  final everyMinutes = RegExp(r'^\*/(\d+)$').firstMatch(f[0]);
  if (f[1] == '*' && (f[0] == '*' || everyMinutes != null)) {
    final n = f[0] == '*' ? 1 : int.parse(everyMinutes!.group(1)!);
    return l10n.t(L10nKey.automationsEveryMinutes, <String, Object?>{
      'count': n,
    });
  }
  final minute = int.tryParse(f[0]);
  final hour = int.tryParse(f[1]);
  if (minute == null || hour == null || minute > 59 || hour > 23) return raw;
  final time =
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  return l10n.t(L10nKey.automationsDailyAt, <String, Object?>{'time': time});
}

/// The last run's outcome in words; nothing before the first run.
String? scheduleStatusInWords(
  BistreLocalizationController l10n,
  String status,
) => switch (status) {
  'idle' || '' => null,
  'triggered' || 'started' => l10n.t(L10nKey.automationsLastStarted),
  'invalid_schedule' => l10n.t(L10nKey.automationsInvalidSchedule),
  _ => l10n.t(L10nKey.automationsLastFailed),
};
