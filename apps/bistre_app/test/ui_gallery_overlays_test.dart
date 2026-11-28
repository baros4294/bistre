import 'package:bistre_app/features/chat/composer_tools_control.dart';
import 'package:bistre_app/features/chat/context_gauge_ring.dart';
import 'package:bistre_app/features/chat/folio_composer.dart';
import 'package:bistre_app/features/chat/thinking_control.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';
import 'support/gallery_scenes.dart';

/// `just ui-gallery`, overlays: composer popovers and menus, the model picker, the context
/// popover, the command palette, the tab switcher, and the message context menu, on desktop
/// and phone.
void main() {
  testWidgets('gallery: overlays, menus, and modals', (tester) async {
    await loadBundledFonts();
    resetGalleryView(tester);
    final g = GalleryShooter(tester);

    Finder composerField() => find.descendant(
      of: find.byType(FolioComposer),
      matching: find.byType(EditableText),
    );

    Future<void> openModelPicker(GalleryScene s) => s.tap(
      find.text(
        s.t(L10nKey.shellModelOnProvider, <String, Object?>{
          'model': 'gpt-4.1',
          'provider': 'OpenAI',
        }),
      ),
    );

    for (final (suffix, size) in const <(String, Size)>[
      ('desktop', GallerySize.desktop),
      ('phone', GallerySize.phone),
    ]) {
      await g.shoot(
        'overlay-model-picker-$suffix',
        size: size,
        prepare: openModelPicker,
      );
      await g.shoot(
        'overlay-composer-tools-$suffix',
        size: size,
        prepare: (s) async {
          if (size == GallerySize.phone) await s.openComposerTray();
          await s.tap(find.byType(ComposerToolsControl));
        },
      );
      await g.shoot(
        'overlay-composer-thinking-$suffix',
        size: size,
        prepare: (s) async {
          if (size == GallerySize.phone) await s.openComposerTray();
          await s.tap(find.byType(ThinkingControl));
        },
      );
      await g.shoot(
        'overlay-context-breakdown-$suffix',
        size: size,
        prepare: (s) => s.tap(find.byType(ContextGaugeRing)),
      );
      await g.shoot(
        'overlay-command-palette-$suffix',
        size: size,
        prepare: (s) async => s.ctrl.toggleCommandPalette(),
      );
      await g.shoot(
        'overlay-tab-switcher-$suffix',
        size: size,
        prepare: (s) async {
          await s.ctrl.selectThread('t-2');
          await s.ctrl.selectThread('t-rich');
          await s.ctrl.selectThread('t-1');
          s.ctrl.openTabSwitcher();
          await s.tester.pumpAndSettle();
        },
      );
    }
    await g.shoot(
      'overlay-phone-composer-tray',
      size: GallerySize.phone,
      prepare: (s) => s.openComposerTray(),
    );
    await g.shoot(
      'overlay-slash-menu',
      prepare: (s) async {
        await s.tester.enterText(composerField(), '/');
        await s.tester.pumpAndSettle();
      },
    );
    await g.shoot(
      'overlay-mention-menu',
      prepare: (s) async {
        await s.ctrl.setWorkspaceRootPath('/workspace/bistre');
        await s.tester.enterText(composerField(), '@');
        await s.tester.pumpAndSettle();
      },
    );
    await g.shoot(
      'overlay-message-context-menu',
      prepare: (s) async {
        await s.tester.tap(
          find.textContaining('Isolating writes').first,
          buttons: kSecondaryMouseButton,
        );
        await s.tester.pumpAndSettle();
      },
    );
    await g.shoot(
      'overlay-sidebar-chat-context-menu',
      prepare: (s) async {
        await s.tester.tap(
          find.text('Q4 product roadmap notes').first,
          buttons: kSecondaryMouseButton,
        );
        await s.tester.pumpAndSettle();
      },
    );
    await g.shoot(
      'overlay-phone-drawer',
      size: GallerySize.phone,
      prepare: (s) => s.openPhoneDrawer(),
    );
    g.verify();
  });
}
