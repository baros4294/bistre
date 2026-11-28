import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/design/sidebar_slide_reveal.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';

Widget _wrap(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: BistreTheme(
    data: BistreThemeData.warmSepia,
    child: BistreLocalizations(
      controller: BistreLocalizationController(
        catalogs: const <String, BistreLocaleCatalog>{
          'en': BistreLocaleCatalog(
            locale: 'en',
            direction: TextDirection.ltr,
            messages: <String, String>{},
          ),
        },
      ),
      child: Overlay(
        initialEntries: <OverlayEntry>[
          OverlayEntry(builder: (_) => Center(child: child)),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('QuillInput supports mouse double-click word selection', (
    tester,
  ) async {
    final ctrl = TextEditingController(text: 'Hello world');
    final focus = FocusNode();
    addTearDown(() {
      ctrl.dispose();
      focus.dispose();
    });

    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 320,
          child: QuillInput(
            controller: ctrl,
            focusNode: focus,
            placeholder: 'Type',
            onSubmitted: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byType(EditableText));
    final tapPoint = Offset(rect.left + 16, rect.center.dy);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(tapPoint);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.down(tapPoint);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(ctrl.selection.isCollapsed, isFalse);
    expect(ctrl.selection.textInside(ctrl.text), 'Hello');
  });

  testWidgets(
    'a trailing dock never snaps back and the chat beside it lays out once per toggle',
    (tester) async {
      var open = true;
      late StateSetter setHostState;
      final chatWidths = <double>[];
      const panel = Key('panel');
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 800,
            height: 400,
            child: StatefulBuilder(
              builder: (context, setState) {
                setHostState = setState;
                return SidebarDock(
                  open: open,
                  trailing: true,
                  sidebar: const SizedBox(key: panel, width: 240),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      chatWidths.add(constraints.maxWidth);
                      return const SizedBox.expand();
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(panel)).dx, 560);

      // Rapid close -> reopen mid-flight.
      setHostState(() => open = false);
      await tester.pump(const Duration(milliseconds: 40));
      setHostState(() => open = true);
      chatWidths.clear();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(panel)).dx, 560);
      expect(chatWidths.toSet(), <double>{560});
    },
  );

  test(
    'deleteThread on only chat leaves exactly 1 open tab (no stale 2 tabs)',
    () async {
      final gw = FakeEngineGateway();
      final ctrl = FolioController(gateway: gw, defaultThreadTitle: 'New chat');
      await ctrl.bootstrap('/tmp/test');
      expect(ctrl.threads.length, 1);
      expect(ctrl.openTabs.length, 1);

      final onlyId = ctrl.threads.first.id;
      await ctrl.deleteThread(onlyId);

      expect(ctrl.threads.length, 1);
      expect(ctrl.threads.first.id, isNot(onlyId));
      expect(ctrl.openTabs.length, 1);
      expect(ctrl.openTabs.first.id, ctrl.threads.first.id);

      await ctrl.createNewFolio();
      expect(ctrl.threads.length, 2);
      await ctrl.clearAllThreads();
      expect(ctrl.threads.length, 1);
      expect(ctrl.openTabs.length, 1);

      ctrl.dispose();
    },
  );

  test('BistreSyntaxPalette provides 4 distinct syntax palettes', () {
    final ids = <String>[
      'sepia_warm',
      'github_light',
      'espresso_amber',
      'slate_dark',
    ];
    final bgs = ids
        .map((id) => BistreSyntaxPalette.forId(id, isDark: false).background)
        .toSet();
    final kws = ids
        .map((id) => BistreSyntaxPalette.forId(id, isDark: false).keyword)
        .toSet();
    expect(bgs.length, 4);
    expect(kws.length, 4);
  });
}
