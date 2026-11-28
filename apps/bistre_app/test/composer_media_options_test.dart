import 'dart:convert';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/composer_phone_controls.dart';
import 'package:bistre_app/features/chat/media_options_control.dart';
import 'package:bistre_app/features/chat/thinking_control.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// The Format chip's label, full (`Format: 16:9`) or short (`16:9`) as the width allows.
Finder chip(String value) => find.descendant(
  of: find.descendant(
    of: find.byType(MediaOptionsControl),
    matching: find.byType(EngravedButton),
  ),
  matching: find.byWidgetPredicate(
    (w) => w is Text && (w.data == value || w.data == 'Format: $value'),
  ),
);

void main() {
  test('shapes parse with decimals and reject anything else', () {
    expect(aspectOf('16:9'), closeTo(16 / 9, 1e-9));
    expect(aspectOf('9:19.5'), closeTo(9 / 19.5, 1e-9));
    expect(aspectOf('auto'), isNull);
    expect(aspectOf('0:1'), isNull);
    expect(aspectOf('1:2:3'), isNull);
  });

  testWidgets(
    'a model that thinks and draws shows both controls; the format is saved',
    (tester) async {
      final gw = FakeEngineGateway(seedConnectedOpenAi: true)
        ..modelInfo = const EngineModelCatalogInfo(
          reasoning: true,
          aspectRatios: <String>['1:1', '16:9', '9:19.5'],
          resolutions: <String>['1K', '2K'],
        );
      final shell = await ShellHarness.pump(tester, gateway: gw);
      expect(find.byType(ThinkingControl), findsOneWidget);
      expect(find.byType(MediaOptionsControl), findsOneWidget);
      expect(chip('Default'), findsOneWidget);

      await tester.tap(find.byType(MediaOptionsControl));
      await tester.pumpAndSettle();
      expect(find.text('Shape'), findsOneWidget);
      expect(find.text('Size'), findsOneWidget);
      expect(find.text('Length'), findsNothing, reason: 'no lengths listed');
      await tester.tap(find.text('16:9'));
      await tester.pumpAndSettle();
      expect(
        jsonDecode((await gw.getKvMeta(MediaOptions.kvKey))!),
        <String, Object?>{'aspect_ratio': '16:9'},
      );
      expect(shell.controller.mediaOptions.aspectRatio, '16:9');
      expect(chip('16:9'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets(
    'a model that only films hides Thinking and drops a shape it does not list',
    (tester) async {
      final gw = FakeEngineGateway(seedConnectedOpenAi: true)
        ..modelInfo = const EngineModelCatalogInfo(
          writesText: false,
          aspectRatios: <String>['9:16'],
          durationsS: <int>[4, 8],
        );
      await gw.setKvMeta(MediaOptions.kvKey, '{"aspect_ratio":"16:9"}');
      await ShellHarness.pump(tester, gateway: gw);
      expect(find.byType(ThinkingControl), findsNothing);
      expect(chip('Default'), findsOneWidget);
      await tester.tap(find.byType(MediaOptionsControl));
      await tester.pumpAndSettle();
      expect(find.text('16:9'), findsNothing);
      expect(find.text('8 s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
    },
  );

  for (final (locale, scale) in <(String, double)>[('ar', 1.0), ('en', 2.0)]) {
    testWidgets('the phone tray holds both controls ($locale, ${scale}x)', (
      tester,
    ) async {
      final gw = FakeEngineGateway(seedConnectedOpenAi: true)
        ..modelInfo = const EngineModelCatalogInfo(
          reasoning: true,
          aspectRatios: <String>['1:1', '21:9', '9:16'],
          resolutions: <String>['1K', '2K', '4K'],
          durationsS: <int>[5, 10],
        );
      await ShellHarness.pump(
        tester,
        gateway: gw,
        layout: ShellLayout.phone,
        locale: locale,
        textScale: scale,
      );
      await tester.tap(find.byType(ComposerTrayToggle));
      await tester.pumpAndSettle();
      expect(find.byType(ThinkingControl), findsOneWidget);
      expect(find.byType(MediaOptionsControl), findsOneWidget);
      await tester.ensureVisible(find.byType(MediaOptionsControl));
      await tester.tap(find.byType(MediaOptionsControl));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 9));
    });
  }
}
