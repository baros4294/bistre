import 'dart:io';

import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_engine_gateway.dart';

/// The layouts every UI behaviour is checked at (AGENTS section 2).
enum ShellLayout {
  /// Phone, below the 720 dp breakpoint.
  phone(Size(390, 844)),

  /// Desktop window.
  desktop(Size(1280, 820));

  const ShellLayout(this.size);

  final Size size;
}

/// A running app shell over a [FakeEngineGateway], driven by real key, pointer and IME events.
class ShellHarness {
  ShellHarness._(this.tester, this.gateway, this.controller, this.l10n);

  final WidgetTester tester;
  final FakeEngineGateway gateway;
  final FolioController controller;
  final BistreLocalizationController l10n;

  /// Pumps [BistreApp] at [layout], [textScale] and [locale] (`ar` is RTL).
  static Future<ShellHarness> pump(
    WidgetTester tester, {
    ShellLayout layout = ShellLayout.desktop,
    double textScale = 1.0,
    String locale = 'en',
    FakeEngineGateway? gateway,
    DateTime Function()? clock,
  }) async {
    tester.view.physicalSize = layout.size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final l10n = loadShellCatalogs();
    final gw = gateway ?? FakeEngineGateway(seedConnectedOpenAi: true);
    final controller = FolioController(
      gateway: gw,
      defaultThreadTitle: l10n.t(L10nKey.shellThreadDefaultTitle),
      onLocaleSynced: l10n.setLocale,
      isDevEnvironment: true,
      clock: clock ?? DateTime.now,
    );
    await controller.bootstrap('memory');
    // Bootstrap syncs the saved locale; the requested one is applied after it.
    l10n.setLocale(locale);
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: controller),
    );
    await tester.pumpAndSettle();
    return ShellHarness._(tester, gw, controller, l10n);
  }

  /// Localized text for [key] in the active locale.
  String t(
    L10nKey key, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => l10n.t(key, args);
}

/// The en, vi and ar catalogs from `l10n/catalog/`.
BistreLocalizationController loadShellCatalogs() {
  final root = Directory('../../l10n/catalog').existsSync()
      ? Directory('../../l10n/catalog')
      : Directory('l10n/catalog');
  final catalogs = <String, BistreLocaleCatalog>{};
  for (final code in const <String>['en', 'vi', 'ar']) {
    final raw = File('${root.path}/$code.bistre-l10n.json').readAsStringSync();
    catalogs[code] = BistreLocaleCatalog.fromJsonString(raw);
  }
  return BistreLocalizationController(catalogs: catalogs);
}
