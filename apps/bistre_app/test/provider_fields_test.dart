import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/settings/providers_settings_view.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

Future<(FolioController, BistreLocalizationController)> _pump(
  WidgetTester tester,
) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 960);
  final l10n = loadDiskCatalogs();
  final controller = FolioController(
    gateway: GalleryGateway(connected: true),
    defaultThreadTitle: 'New chat',
  );
  addTearDown(controller.dispose);
  await controller.bootstrap('/tmp/bistre_test');
  final theme = BistreThemeData.resolve(isDark: false);
  await tester.pumpWidget(
    BistreLocalizations(
      controller: l10n,
      child: BistreTheme(
        data: theme,
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
  return (controller, l10n);
}

void main() {
  testWidgets(
    'a new Gemini provider starts from core\'s server URL (S4, A-W 5b)',
    (tester) async {
      final (_, l10n) = await _pump(tester);
      await tester.tap(find.text(l10n.t(L10nKey.providerAddButton)).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Gemini').last);
      await tester.pumpAndSettle();
      final urls = tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((e) => e.controller.text)
          .where((t) => t.startsWith('http'))
          .toList();
      expect(urls, contains('https://generativelanguage.googleapis.com'));
      expect(urls.any((u) => u.endsWith('/v1beta')), isFalse);
    },
  );

  testWidgets('headers and body fields live only in Advanced', (tester) async {
    final (_, l10n) = await _pump(tester);
    expect(find.text(l10n.t(L10nKey.providerCustomHeaders)), findsNothing);
    expect(find.text(l10n.t(L10nKey.providerCustomBody)), findsNothing);
    final placeholders = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .length;
    expect(placeholders, greaterThan(0));
  });
}
