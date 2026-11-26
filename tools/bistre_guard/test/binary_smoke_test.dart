import 'package:bistre_guard/binary_smoke.dart';
import 'package:test/test.dart';

void main() {
  test('daemon health passes only with WAL active and diag.ok', () {
    expect(
      checkDaemonHealth('{"wal_mode_active":true,"status_key":"diag.ok"}'),
      isEmpty,
    );
    expect(
      checkDaemonHealth('{"wal_mode_active":false,"status_key":"diag.ok"}'),
      hasLength(1),
    );
    expect(
      checkDaemonHealth(
        '{"wal_mode_active":true,"status_key":"diag.storage.io"}',
      ),
      hasLength(1),
    );
    expect(checkDaemonHealth('not json'), hasLength(1));
    expect(checkDaemonHealth('[1]'), hasLength(1));
  });

  test('updater must exit with the usage code 2', () {
    expect(checkUpdaterUsageExit(2), isEmpty);
    expect(checkUpdaterUsageExit(0), hasLength(1));
    expect(checkUpdaterUsageExit(1), hasLength(1));
  });
}
