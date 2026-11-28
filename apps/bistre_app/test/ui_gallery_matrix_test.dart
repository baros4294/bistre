import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';
import 'support/gallery_scenes.dart';

/// `just ui-gallery`, verification matrix: the core screens at desktop and phone, 100% and
/// 200% text, LTR and RTL, light and dark, plus every colour preset and Vietnamese.
void main() {
  testWidgets('gallery: layout, text size, direction, and theme matrix', (
    tester,
  ) async {
    await loadBundledFonts();
    resetGalleryView(tester);
    final g = GalleryShooter(tester);

    final scenes = <(String, bool, Future<void> Function(GalleryScene)?)>[
      ('chat', true, null),
      ('empty', false, null),
      (
        'settings-appearance',
        true,
        (s) async {
          s.ctrl.openSettings(SettingsTab.appearance);
          await s.tester.pumpAndSettle();
        },
      ),
    ];
    for (final theme in const <String>['day', 'night']) {
      for (final (scene, seeded, prepare) in scenes) {
        // Dark covers the dense chat; light covers every scene.
        if (theme == 'night' && scene != 'chat') continue;
        for (final (layout, size) in const <(String, Size)>[
          ('desktop', GallerySize.desktop),
          ('phone', GallerySize.phone),
        ]) {
          for (final scale in const <double>[1.0, 2.0]) {
            for (final locale in const <String>['en', 'ar']) {
              await g.shoot(
                'matrix-$scene-$theme-$layout-${(scale * 100).round()}-$locale',
                size: size,
                textScale: scale,
                locale: locale,
                theme: theme,
                seed: seeded,
                prepare: prepare,
              );
            }
          }
        }
      }
    }
    for (final preset in BistreThemePreset.presets) {
      if (preset.id == 'day' || preset.id == 'night') continue;
      await g.shoot('matrix-chat-preset-${preset.id}', theme: preset.id);
      await g.shoot(
        'matrix-settings-preset-${preset.id}',
        theme: preset.id,
        prepare: (s) async {
          s.ctrl.openSettings(SettingsTab.appearance);
          await s.tester.pumpAndSettle();
        },
      );
    }
    for (final (layout, size) in const <(String, Size)>[
      ('desktop', GallerySize.desktop),
      ('phone', GallerySize.phone),
    ]) {
      await g.shoot('matrix-chat-day-$layout-100-vi', size: size, locale: 'vi');
    }
    g.verify();
  });
}
