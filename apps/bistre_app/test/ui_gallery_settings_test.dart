import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';
import 'support/gallery_scenes.dart';

/// `just ui-gallery`, Settings: every page and sub-page on desktop (populated, empty, and
/// unconfigured states), and the phone list, search, and every page on a phone.
/// A tab's name as a file name: `defaultModels` -> `default-models` (names are lowercase).
String _fileName(SettingsTab tab) => tab.name.replaceAllMapped(
  RegExp('[A-Z]'),
  (m) => '-${m[0]!.toLowerCase()}',
);

void main() {
  testWidgets('gallery: settings', (tester) async {
    await loadBundledFonts();
    resetGalleryView(tester);
    final g = GalleryShooter(tester);

    Future<void> open(GalleryScene s, SettingsTab tab) async {
      s.ctrl.openSettings(tab);
      await s.tester.pumpAndSettle();
    }

    Future<void> populatedMemory(GalleryScene s) async {
      await s.ctrl.setWorkspaceRootPath('/workspace/bistre');
      await s.ctrl.refreshMemorySkillsAndCron();
      await open(s, SettingsTab.memory);
    }

    for (final tab in SettingsTab.values) {
      await g.shoot(
        'settings-${_fileName(tab)}',
        prepare: (s) async {
          if (tab == SettingsTab.memory) return populatedMemory(s);
          if (tab == SettingsTab.updates) await s.ctrl.checkForUpdates();
          await open(s, tab);
        },
      );
    }
    for (final (name, size, scale, locale) in <(String, Size, double, String)>[
      ('settings-projects-editor', GallerySize.desktop, 1.0, 'en'),
      ('settings-projects-editor-phone-ar-200', GallerySize.phone, 2.0, 'ar'),
    ]) {
      await g.shoot(
        name,
        size: size,
        textScale: scale,
        locale: locale,
        fixtures: (gw) => gw.seedProject(),
        prepare: (s) async {
          s.ctrl.openProjectEditor('p-novel');
          await s.tester.pumpAndSettle();
        },
      );
    }
    await g.shoot(
      'settings-providers-ready-detail',
      prepare: (s) async {
        await open(s, SettingsTab.providers);
        await s.ctrl.fetchModelsForProvider('google_gemini');
        await s.tap(find.text('Google Gemini'));
      },
    );
    await g.shoot(
      'settings-providers-missing-key',
      prepare: (s) async {
        await open(s, SettingsTab.providers);
        await s.tap(find.text('Anthropic'));
      },
    );
    await g.shoot(
      'settings-providers-advanced',
      prepare: (s) async {
        await open(s, SettingsTab.providers);
        await s.tap(find.text(s.t(L10nKey.settingsProviderAdvancedTitle)));
      },
    );
    await g.shoot(
      'settings-providers-add',
      prepare: (s) async {
        await open(s, SettingsTab.providers);
        await s.tap(find.text(s.t(L10nKey.providerAddButton)));
      },
    );
    // Share codes sit at the end of the page: scrolled into view at every layout.
    Future<void> openProviders(GalleryScene s, Size size) async {
      await open(s, SettingsTab.providers);
      // The phone opens on the page list; step into Providers like a user.
      if (size == GallerySize.phone) {
        await s.tap(find.text(s.t(L10nKey.settingsTabProviders)));
      }
    }

    for (final (name, size, scale, locale) in <(String, Size, double, String)>[
      ('desktop', GallerySize.desktop, 1.0, 'en'),
      ('phone-200', GallerySize.phone, 2.0, 'en'),
      ('desktop-ar', GallerySize.desktop, 1.0, 'ar'),
    ]) {
      await g.shoot(
        'settings-providers-share-$name',
        size: size,
        textScale: scale,
        locale: locale,
        prepare: (s) async {
          await openProviders(s, size);
          await s.tap(find.text('Google Gemini'));
          final share = find.text(s.t(L10nKey.providerShareConfig));
          await s.tester.ensureVisible(share);
          await s.tester.pumpAndSettle();
        },
      );
      await g.shoot(
        'settings-providers-import-$name',
        size: size,
        textScale: scale,
        locale: locale,
        prepare: (s) async {
          await openProviders(s, size);
          await s.tap(find.text(s.t(L10nKey.providerAddButton)));
          final add = find.text(s.t(L10nKey.providerImportAction));
          await s.tester.ensureVisible(add);
          await s.tester.pumpAndSettle();
          await s.tester.enterText(
            find.byType(EditableText).last,
            'ai-provider:v1:not-a-real-code-that-goes-on-and-on-and-on',
          );
          await s.tap(add);
          await s.tester.ensureVisible(
            find.text(s.t(L10nKey.providerImportInvalid)),
          );
          await s.tester.pumpAndSettle();
        },
      );
    }
    await g.shoot(
      'settings-providers-first-run',
      connected: false,
      prepare: (s) => open(s, SettingsTab.providers),
    );
    await g.shoot(
      'settings-assistants-editor',
      prepare: (s) async {
        s.ctrl.openAssistantEditor('custom_rust');
        await s.tester.pumpAndSettle();
      },
    );
    await g.shoot(
      'settings-trust-capped',
      prepare: (s) async {
        await s.ctrl.updateSettings(
          s.ctrl.settings.copyWith(walletDailyCeilingMicros: 5000000),
          quiet: true,
        );
        await open(s, SettingsTab.trust);
      },
    );
    await g.shoot(
      'settings-memory-empty',
      prepare: (s) => open(s, SettingsTab.memory),
    );
    await g.shoot(
      'settings-search',
      prepare: (s) async {
        await open(s, SettingsTab.providers);
        await s.tester.enterText(
          find.byType(EditableText).first,
          s.t(L10nKey.settingsPrefsShowModelName).split(' ').first,
        );
        await s.tester.pumpAndSettle();
      },
    );

    // Phone: the list, search, and every page.
    await g.shoot(
      'settings-phone-list',
      size: GallerySize.phone,
      prepare: (s) async {
        s.ctrl.openSettings();
        await s.tester.pumpAndSettle();
      },
    );
    for (final tab in SettingsTab.values) {
      await g.shoot(
        'settings-phone-${_fileName(tab)}',
        size: GallerySize.phone,
        prepare: (s) async {
          if (tab == SettingsTab.memory) return populatedMemory(s);
          await open(s, tab);
          // The default page opens as the phone list; step into it like a user.
          if (tab == SettingsTab.providers) {
            await s.tap(find.text(s.t(L10nKey.settingsTabProviders)));
          }
        },
      );
    }
    g.verify();
  });
}
