import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/context_menu.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/design/press_feedback.dart';
import 'package:bistre_app/features/chat/folio_message_feed.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/sidebar/folio_sidebar.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

/// Regression tests for interaction details: chip and hover feedback, the message menu,
/// names, the model picker, settings search, phone settings, Android back, and repaint
/// isolation while a reply streams.
void main() {
  testWidgets('chip colours cross-fade when selected', (
    WidgetTester tester,
  ) async {
    final theme = BistreThemeData.resolve(isDark: false);
    Future<void> pumpChip({required bool selected}) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: BistreTheme(
          data: theme,
          child: Center(
            child: InkChip(
              label: 'High',
              selected: selected,
              onSelected: () {},
            ),
          ),
        ),
      ),
    );
    Color? fill() {
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(EaseDecoration),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return (box.decoration as BoxDecoration).color;
    }

    await pumpChip(selected: false);
    expect(fill(), theme.bgSurface);
    await pumpChip(selected: true);
    await tester.pump(const Duration(milliseconds: 60));
    expect(fill(), isNot(theme.bgSurface));
    expect(fill(), isNot(theme.bgElevated));
    await tester.pumpAndSettle();
    expect(fill(), theme.bgElevated);
  });

  testWidgets('icon buttons name themselves after a hover rest', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: BistreTheme(
          data: BistreThemeData.resolve(isDark: false),
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => Center(
                  child: BistreIconButton(
                    icon: BistreUiIcon.search,
                    semanticsLabel: 'Search chats',
                    onPressed: () {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(BistreIconButton)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.text('Search chats'),
      findsNothing,
      reason: 'no hint before the rest',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Search chats'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.text('Search chats'), findsNothing);
  });

  testWidgets('right-clicking a message opens its actions menu', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1320, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await bootGalleryController();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
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
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();

    // A message's own menu (its code cards have smaller ones). The chat opens at its newest
    // message, so the last message is on screen; the click lands near its lower edge, away
    // from any code card.
    final delete = l10n.t(L10nKey.chatActionDelete);
    final message = find
        .descendant(
          of: find.byType(FolioMessageFeed),
          matching: find.byWidgetPredicate(
            (w) =>
                w is ContextMenuRegion &&
                w.entries.any((e) => e.label == delete),
          ),
        )
        .last;
    await tester.tapAt(
      tester.getBottomLeft(message) + const Offset(80, -16),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    final copy = find.text(l10n.t(L10nKey.chatActionCopy));
    expect(copy, findsOneWidget);
    expect(find.text(l10n.t(L10nKey.chatActionDelete)), findsWidgets);

    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, isNotNull);
    expect(copied, isNotEmpty);
    expect(copy, findsNothing, reason: 'choosing an entry closes the menu');

    // Sidebar chats have their own menu.
    await tester.tap(
      find
          .descendant(
            of: find.byType(FolioSidebar),
            matching: find.byType(ContextMenuRegion),
          )
          .first,
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.t(L10nKey.threadRename)), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text(l10n.t(L10nKey.threadRename)), findsNothing);

    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets('your name labels your messages', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1320, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await bootGalleryController();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Ana Lima', findRichText: true, skipOffstage: false),
      findsNothing,
    );
    await ctrl.updateSettings(
      ctrl.settings.copyWith(userDisplayName: 'Ana Lima'),
    );
    await tester.pumpAndSettle();
    // The chat opens at its newest reply, so the user's turn may sit above the fold.
    expect(
      find.textContaining('Ana Lima', findRichText: true, skipOffstage: false),
      findsWidgets,
    );
    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets('the model picker marks only the exceptions', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1320, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await bootGalleryController();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(ctrl.activeProvider!.name).first);
    await tester.pumpAndSettle();
    // Cloud providers that keep nothing carry no badge; each provider's icon names it, so
    // its name shows once, on its filter chip, with no count.
    expect(find.text('gpt-4.1'), findsWidgets);
    expect(find.text('Google Gemini'), findsOneWidget);
    expect(find.text(l10n.t(L10nKey.chatModelAllProviders)), findsOneWidget);
    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets('settings search names the setting that matched', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1320, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await bootGalleryController();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    ctrl.openSettings(); // Providers: the matching setting is on another page.
    await tester.pumpAndSettle();
    final search = find.ancestor(
      of: find.text(l10n.t(L10nKey.settingsSearchPlaceholder)),
      matching: find.byType(QuillInput),
    );
    await tester.enterText(
      find.descendant(of: search, matching: find.byType(EditableText)),
      'your name',
    );
    await tester.pumpAndSettle();
    // The Appearance page is listed, with the matching setting under it.
    expect(find.text(l10n.t(L10nKey.settingsProfileName)), findsWidgets);
    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets('phone settings: card list, one page, back and swipe step back', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await bootGalleryController();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    ctrl.openSettings();
    await tester.pumpAndSettle();

    // Root: one header (Settings + Chat), search, and every page as a vertical card.
    final appearance = find.text(l10n.t(L10nKey.settingsTabAppearance));
    final shortcuts = find.text(l10n.t(L10nKey.settingsTabShortcuts));
    expect(find.text(l10n.t(L10nKey.settingsChat)), findsOneWidget);
    expect(
      find.text(l10n.t(L10nKey.settingsSearchPlaceholder)),
      findsOneWidget,
    );
    expect(find.text(l10n.t(L10nKey.settingsSubShortcuts)), findsOneWidget);
    await tester.dragUntilVisible(
      shortcuts,
      find.byType(SingleChildScrollView).last,
      const Offset(0, -200),
    );
    expect(
      tester.getTopLeft(shortcuts).dy,
      greaterThan(tester.getTopLeft(appearance).dy),
    );
    expect(
      tester.getTopLeft(shortcuts).dx,
      tester.getTopLeft(appearance).dx,
      reason: 'a vertical list, not a sideways strip',
    );

    // A page opens alone, with a Settings back button.
    await tester.tap(appearance);
    await tester.pumpAndSettle();
    expect(find.text(l10n.t(L10nKey.settingsProfileName)), findsWidgets);
    expect(shortcuts, findsNothing);

    // Android back: page -> list -> chat.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(appearance, findsOneWidget);
    expect(ctrl.settingsOpen, isTrue);

    // Swipe from the start edge also steps back from a page.
    await tester.tap(appearance);
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(20, 400), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(appearance, findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(ctrl.settingsOpen, isFalse);
    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets('Android back closes the innermost layer first', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1320, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await bootGalleryController();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    ctrl
      ..toggleInspector()
      ..toggleCommandPalette();
    await tester.pumpAndSettle();
    expect(ctrl.commandPaletteOpen, isTrue);
    expect(ctrl.inspectorOpen, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(ctrl.commandPaletteOpen, isFalse, reason: 'palette closes first');
    expect(ctrl.inspectorOpen, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(ctrl.inspectorOpen, isFalse);
    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets('streaming deltas never repaint sidebar, header, or composer', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1320, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await bootGalleryController();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    ctrl.liveTurn.shouldPace = () => false;
    final threadId = ctrl.activeThread!.id;
    gw.emit(RunStartedEvent(threadId: threadId, nodeId: 'c1-live'));
    await tester.pump();
    gw.emit(
      DeltaBatchEvent(
        threadId: threadId,
        nodeId: 'c1-live',
        textDelta: '```rust\nfn probe() {\n',
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 30; i++) {
      gw.emit(
        DeltaBatchEvent(
          threadId: threadId,
          nodeId: 'c1-live',
          textDelta: '    let v_$i = compute_checkpoint(frames, budget);\n',
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    FlutterTimeline.debugCollectionEnabled = true;
    debugProfilePaintsEnabled = true;
    FlutterTimeline.debugReset();
    for (var i = 0; i < 10; i++) {
      gw.emit(
        DeltaBatchEvent(
          threadId: threadId,
          nodeId: 'c1-live',
          textDelta: '    let m_$i = compute_checkpoint(frames, budget);\n',
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    final blocks = FlutterTimeline.debugCollect().aggregatedBlocks;
    debugProfilePaintsEnabled = false;
    FlutterTimeline.debugCollectionEnabled = false;

    final mouseRegionPaints = blocks
        .where((b) => b.name == 'RenderMouseRegion')
        .fold<int>(0, (sum, b) => sum + b.count);
    // Without the RepaintBoundary around FolioMessageFeed and code-card header actions,
    // streaming painted ~78 RenderMouseRegion/frame (~780 over 10 frames).
    expect(
      mouseRegionPaints / 10.0,
      lessThan(20.0),
      reason: 'streaming repainted widgets outside the feed (C1 regression)',
    );

    gw.emit(
      RunFinishedEvent(threadId: threadId, nodeId: 'c1-live', cancelled: false),
    );
    await tester.pumpAndSettle();
    ctrl.dispose();
    await gw.shutdown();
  });
}
