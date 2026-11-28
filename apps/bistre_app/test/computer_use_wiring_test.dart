import 'dart:convert';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  testWidgets(
    'HostActionRequestedEvent invokes native bridge and delivers result via respondHostAction, and Android labels it Phone use',
    (tester) async {
      const phoneUseChannel = MethodChannel('bistre/phone_use');
      const desktopHostChannel = MethodChannel('bistre/desktop_host');
      final handled = <Map<String, Object?>>[];

      Future<Object?> mockHandler(MethodCall call) async {
        if (call.method == 'computerUse' || call.method == 'phoneUse') {
          final args = Map<String, Object?>.from(call.arguments as Map);
          handled.add(args);
          return <String, Object?>{
            'ok': true,
            'outputText': 'Captured 1280x720 screenshot.',
            'imageBase64': 'iVBORw0KGgo=',
          };
        }
        return null;
      }

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        phoneUseChannel,
        mockHandler,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        desktopHostChannel,
        mockHandler,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          phoneUseChannel,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          desktopHostChannel,
          null,
        );
      });

      final shell = await ShellHarness.pump(tester);
      final gw = shell.gateway;

      gw.emit(
        HostActionRequestedEvent(
          requestId: 'host_req_1',
          threadId: shell.controller.activeThread!.id,
          runId: 'run_1',
          actionJson: jsonEncode(<String, Object?>{'action': 'screenshot'}),
        ),
      );
      await tester.pumpAndSettle();

      expect(handled, hasLength(1));
      expect(handled.single['action'], 'screenshot');
      final responses = gw.callsTo('respondHostAction');
      expect(responses, hasLength(1));
      expect(responses.single.args['requestId'], 'host_req_1');
      expect(responses.single.args['ok'], isTrue);
      expect(responses.single.args['hasImage'], isTrue);

      // Flutter widget tests run on Android targetPlatform; Agent settings uses "Phone use" on Android
      // and "Computer use" on desktop.
      shell.controller.openSettings(SettingsTab.agent);
      await tester.pumpAndSettle();
      expect(
        find.text(shell.t(L10nKey.settingsAgentComputerUse)),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 9));
    },
  );
}
