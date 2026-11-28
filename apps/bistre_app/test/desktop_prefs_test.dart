import 'dart:convert';
import 'dart:io';

import 'package:bistre_app/platform/desktop_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Settings > Appearance > Desktop: the tray and run-at-startup hold across launches, and
/// the Linux autostart entry starts exactly this app.
void main() {
  test('the Linux autostart entry quotes the app path', () {
    final entry = BistreDesktopHost.linuxAutostartEntry(
      r'/opt/My $App\bin/bistre',
    );
    expect(entry, startsWith('[Desktop Entry]\n'));
    expect(entry, contains(r'Exec="/opt/My \$App\\\\bin/bistre"'));
    expect(entry, contains('Type=Application\n'));
  });

  testWidgets(
    'a saved tray and run-at-startup are applied again at launch',
    (tester) async {
      final calls = <MethodCall>[];
      const host = MethodChannel('bistre/desktop_host');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(host, (
        call,
      ) async {
        calls.add(call);
        return const {'setTrayEnabled', 'setAutoStart'}.contains(call.method)
            ? true
            : null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          host,
          null,
        ),
      );
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
      await gateway.setKvMeta(
        'settings.ui_prefs',
        jsonEncode({'systemTrayEnabled': true, 'runOnStartup': true}),
      );
      await ShellHarness.pump(tester, gateway: gateway);
      Map<Object?, Object?>? argsOf(String method) =>
          calls.where((c) => c.method == method).lastOrNull?.arguments
              as Map<Object?, Object?>?;
      expect(argsOf('setTrayEnabled')?['enabled'], isTrue);
      expect(argsOf('setAutoStart')?['enabled'], isTrue);
    },
    skip: !Platform.isWindows,
  ); // The tray and run at startup are Windows host calls.
}
