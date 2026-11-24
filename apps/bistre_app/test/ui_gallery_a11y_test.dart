import 'dart:io';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

/// Accessibility gallery (`just ui-gallery`): `200%` text on phone and desktop, the backoff
/// notice with its inline `Retry now`, and a dual-size (22 px + 12 px) icon clarity sheet.
void main() {
  Future<(FolioController, GalleryGateway)> boot({
    bool connected = true,
    bool seed = true,
  }) async {
    final l10n = loadDiskCatalogs();
    final gw = GalleryGateway(connected: connected, seedConversation: seed);
    final ctrl = FolioController(
      gateway: gw,
      defaultThreadTitle: l10n.t(L10nKey.shellThreadDefaultTitle),
      onLocaleSynced: l10n.setLocale,
      isDevEnvironment: true,
    );
    await ctrl.bootstrap('memory');
    return (ctrl, gw);
  }

  testWidgets('captures 200% text, retry notice, and icon clarity sheets', (
    WidgetTester tester,
  ) async {
    await loadBundledFonts();
    final outDir = Directory('build/ui_gallery')..createSync(recursive: true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    Future<void> shoot(
      String file,
      Size size,
      double textScale,
      Future<void> Function(FolioController, GalleryGateway)? prepare,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      final l10n = loadDiskCatalogs();
      final (ctrl, gw) = await boot();
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: BistreApp(l10nController: l10n, folioController: ctrl),
        ),
      );
      await prepare?.call(ctrl, gw);
      await capturePng(tester, key, outDir, file);
      final error = tester.takeException();
      expect(
        error,
        isNull,
        reason:
            '$file: ${error is FlutterError ? error.toStringDeep() : error}',
      );
      ctrl.dispose();
      await gw.shutdown();
    }

    await shoot('29_phone_text200_chat.png', const Size(360, 800), 2.0, null);
    await shoot(
      '30_phone_text200_settings.png',
      const Size(360, 800),
      2.0,
      (ctrl, _) async => ctrl.openSettings(SettingsTab.appearance),
    );
    // Phone Settings root at normal text: the v2.6.0 card list.
    await shoot(
      '36_phone_settings_list.png',
      const Size(390, 844),
      1.0,
      (ctrl, _) async => ctrl.openSettings(),
    );
    await shoot(
      '31_desktop_text200_chat.png',
      const Size(1320, 820),
      2.0,
      null,
    );
    await shoot('32_desktop_retry_now_notice.png', const Size(1320, 820), 1.0, (
      ctrl,
      gw,
    ) async {
      gw.emit(
        const DiagnosticRaisedEvent(
          key: 'diag.run.backoff_waiting',
          detailCode: 'retry_in_ms=12000;reason=diag.provider.rate_limited',
        ),
      );
      await tester.pump();
    });

    // Dual-size icon clarity sheet: every UI icon at 22 px and 12 px.
    tester.view.physicalSize = const Size(900, 360);
    tester.platformDispatcher.textScaleFactorTestValue = 1.0;
    final sheetKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: sheetKey,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: BistreTheme(
            data: BistreThemeData.dayParchment,
            child: ColoredBox(
              color: BistreThemeData.dayParchment.bgCanvas,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final size in const <double>[22, 12])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final icon in BistreUiIcon.values)
                              BistreIcon(
                                icon,
                                size: size,
                                color: BistreThemeData.dayParchment.inkPrimary,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await capturePng(tester, sheetKey, outDir, '33_icon_clarity_22px_12px.png');
  });
}
