import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';
import 'support/gallery_scenes.dart';

/// `just ui-gallery`, stress: very long unbroken model ids, titles, file names, and URLs;
/// a desktop window snapped to half a screen; several chats replying at once; Vietnamese
/// diacritics; Arabic mixed with English; and 200% text on a phone.
void main() {
  testWidgets('gallery: real-world stress fixtures', (tester) async {
    await loadBundledFonts();
    resetGalleryView(tester);
    final g = GalleryShooter(tester);

    Future<void> longChat(GalleryScene s) async {
      await s.ctrl.updateSettings(
        s.ctrl.settings.copyWith(
          activeProviderId: 'fireworks',
          activeModelId: kLongModelId,
        ),
        quiet: true,
      );
      await s.ctrl.selectThread('t-long');
      await s.tester.pumpAndSettle();
    }

    for (final (layout, size) in const <(String, Size)>[
      ('desktop', GallerySize.desktop),
      ('narrow-split', GallerySize.narrowSplit),
      ('phone', GallerySize.phone),
    ]) {
      await g.shoot(
        'stress-long-strings-$layout',
        size: size,
        fixtures: seedStressFixtures,
        prepare: longChat,
      );
    }
    await g.shoot(
      'stress-long-strings-phone-200',
      size: GallerySize.phone,
      textScale: 2.0,
      fixtures: seedStressFixtures,
      prepare: longChat,
    );
    await g.shoot(
      'stress-long-strings-phone-drawer',
      size: GallerySize.phone,
      fixtures: seedStressFixtures,
      prepare: (s) async {
        await longChat(s);
        await s.openPhoneDrawer();
      },
    );
    await g.shoot(
      'stress-long-strings-settings-provider',
      fixtures: seedStressFixtures,
      prepare: (s) async {
        s.ctrl.openSettings();
        await s.tester.pumpAndSettle();
        await s.tap(find.textContaining('Fireworks AI'));
      },
    );
    await g.shoot(
      'stress-narrow-split-dense-chat',
      size: GallerySize.narrowSplit,
    );
    await g.shoot(
      'stress-narrow-split-inspector',
      size: GallerySize.narrowSplit,
      prepare: (s) async => s.ctrl.toggleInspector(),
    );
    await g.shoot(
      'stress-narrow-split-settings',
      size: GallerySize.narrowSplit,
      prepare: (s) async {
        s.ctrl.openSettings();
        await s.tester.pumpAndSettle();
      },
    );
    await g.shoot(
      'stress-concurrent-runs',
      size: GallerySize.wide,
      settle: false,
      fixtures: seedStressFixtures,
      prepare: (s) async {
        for (final id in const <String>['t-long', 't-vi', 't-ar', 't-1']) {
          await s.ctrl.selectThread(id);
        }
        await s.emit(const <BistreEvent>[
          RunStartedEvent(threadId: 't-long', nodeId: 'l1'),
          RunStartedEvent(threadId: 't-vi', nodeId: 'l2'),
          RunStartedEvent(threadId: 't-ar', nodeId: 'l3'),
          RunStartedEvent(threadId: 't-1', nodeId: 'l4'),
          DeltaBatchEvent(
            threadId: 't-1',
            nodeId: 'l4',
            textDelta: 'Three other chats are replying in the background while',
          ),
        ]);
        s.ctrl.setStudioTab(StudioTab.runs);
      },
    );
    for (final (layout, size, scale) in const <(String, Size, double)>[
      ('desktop', GallerySize.desktop, 1.0),
      ('phone', GallerySize.phone, 1.0),
      ('phone-200', GallerySize.phone, 2.0),
    ]) {
      await g.shoot(
        'stress-vietnamese-$layout',
        size: size,
        textScale: scale,
        locale: 'vi',
        fixtures: seedStressFixtures,
        prepare: (s) => s.ctrl.selectThread('t-vi'),
      );
      await g.shoot(
        'stress-arabic-mixed-$layout',
        size: size,
        textScale: scale,
        locale: 'ar',
        fixtures: seedStressFixtures,
        prepare: (s) => s.ctrl.selectThread('t-ar'),
      );
    }
    await g.shoot(
      'stress-arabic-ui-english-chat',
      locale: 'ar',
      fixtures: seedStressFixtures,
      prepare: (s) => s.ctrl.selectThread('t-long'),
    );
    g.verify();
  });
}
