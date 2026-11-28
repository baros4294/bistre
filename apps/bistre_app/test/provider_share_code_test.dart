import 'dart:convert';

import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/settings/providers_settings_view.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/gallery_harness.dart' show loadDiskCatalogs;

Map<String, Object?> _payload(String code) => jsonDecode(
  utf8.decode(
    base64Url.decode(
      base64Url.normalize(code.substring('ai-provider:v1:'.length)),
    ),
  ),
) as Map<String, Object?>;

Future<(FolioController, BistreLocalizationController, List<String>)> _pump(
  WidgetTester tester,
  FakeEngineGateway gateway,
  Size size,
) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  final l10n = loadDiskCatalogs();
  final controller = FolioController(
    gateway: gateway,
    defaultThreadTitle: 'New chat',
  );
  addTearDown(controller.dispose);
  await controller.bootstrap('/tmp/bistre_test');
  await tester.pumpWidget(
    BistreLocalizations(
      controller: l10n,
      child: BistreTheme(
        data: BistreThemeData.resolve(isDark: false),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => ProvidersSettingsView(controller: controller),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (controller, l10n, copied);
}

/// Scrolls [finder] into view inside the settings page before tapping it.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in const <Size>[Size(1280, 960), Size(400, 900)]) {
    testWidgets(
      'a share code leaves the key out unless asked and adds a fresh provider '
      '(${size.width.toInt()} px)',
      (tester) async {
        final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
        final (ctrl, l10n, copied) = await _pump(tester, gateway, size);
        final original = ctrl.providers.first;
        final before = ctrl.providers.length;

        final share = find.text(l10n.t(L10nKey.providerShareConfig));
        await _tap(tester, share);
        expect(copied, hasLength(1));
        expect(copied.single, startsWith('ai-provider:v1:'));
        expect(_payload(copied.single).containsKey('apiKey'), isFalse);

        await _tap(
          tester,
          find.byWidgetPredicate(
            (w) =>
                w is BistreSwitch &&
                w.semanticsLabel == l10n.t(L10nKey.providerShareWithKey),
          ),
        );
        await _tap(tester, share);
        expect(_payload(copied.last)['apiKey'], 'sk-test-primary-key');

        await _tap(tester, find.text(l10n.t(L10nKey.providerAddButton)).first);
        final field = find.byWidgetPredicate(
          (w) =>
              w is QuillInput &&
              w.semanticsLabel == l10n.t(L10nKey.providerImportTitle),
        );
        await tester.ensureVisible(field);
        await tester.enterText(field, 'not a code');
        await _tap(tester, find.text(l10n.t(L10nKey.providerImportAction)));
        expect(
          find.text(l10n.t(L10nKey.providerImportInvalid)),
          findsOneWidget,
        );
        expect(ctrl.providers, hasLength(before));

        await tester.enterText(field, copied.first);
        await tester.pump();
        expect(find.text(l10n.t(L10nKey.providerImportInvalid)), findsNothing);
        await _tap(tester, find.text(l10n.t(L10nKey.providerImportAction)));
        expect(ctrl.providers, hasLength(before + 1));
        final copy = ctrl.providers.last;
        expect(copy.id, isNot(original.id));
        expect(copy.name, original.name);
        expect(copy.baseUrl, original.baseUrl);
        expect(copy.hasApiKey, isFalse);
        await tester.pump(const Duration(seconds: 9));
      },
    );
  }
}
