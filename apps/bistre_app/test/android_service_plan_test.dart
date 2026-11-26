import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Android service follows the number of live runs (P13, P15)', () {
    // One of two runs finished: the service stays for the other (it used to stop).
    expect(
      androidServicePlan(liveRuns: 1, waitingForApproval: 0, keepAwake: true),
      const AndroidServicePlan(run: true, activeCount: 1, holdLocks: true),
    );
    // Every live run waits for the user: keep the service, release the wake locks.
    expect(
      androidServicePlan(liveRuns: 2, waitingForApproval: 2, keepAwake: true),
      const AndroidServicePlan(run: true, activeCount: 2, holdLocks: false),
    );
    // Nothing runs: stop.
    expect(
      androidServicePlan(
        liveRuns: 0,
        waitingForApproval: 0,
        keepAwake: true,
      ).run,
      isFalse,
    );
    // The user turned "Keep awake while running" off.
    expect(
      androidServicePlan(
        liveRuns: 3,
        waitingForApproval: 0,
        keepAwake: false,
      ).run,
      isFalse,
    );
  });
}
