import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  testWidgets('closing the app shuts the engine down exactly once', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);

    // Real async: on a Windows host the window-bounds read is a platform call that the fake
    // test clock never completes.
    await tester.runAsync(shell.controller.shutdownEngine);
    expect(shell.gateway.callsTo('shutdown'), hasLength(1));

    // A later lifecycle `detached` (or a second request) never shuts down twice.
    await tester.runAsync(shell.controller.shutdownEngine);
    expect(shell.gateway.callsTo('shutdown'), hasLength(1));
  });
}
