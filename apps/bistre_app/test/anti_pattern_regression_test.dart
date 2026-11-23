import 'dart:async';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/code_wrap_scope.dart';
import 'package:bistre_app/features/chat/folio_message_feed.dart';
import 'package:bistre_app/features/chat/markdown_folio_view.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/sidebar/folio_sidebar.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

/// Regression tests for the v2 anti-pattern audit (`docs/design/DESIGN.md` §8). Each one fails
/// on the pre-fix code: a centered constrained `ListView`, root-notifying stream deltas,
/// parent-rebuilding hover state, and always-horizontal code fences.
void main() {
  Future<(FolioController, GalleryGateway, BistreLocalizationController)>
  boot() async {
    final l10n = loadDiskCatalogs();
    final gw = GalleryGateway(connected: true);
    final ctrl = FolioController(
      gateway: gw,
      defaultThreadTitle: l10n.t(L10nKey.shellThreadDefaultTitle),
      onLocaleSynced: l10n.setLocale,
      isDevEnvironment: true,
    );
    await ctrl.bootstrap('memory');
    return (ctrl, gw, l10n);
  }

  testWidgets('wheel scrolls the chat from the empty desktop page margin', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1320, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await boot();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();

    final feed = find.byType(FolioMessageFeed);
    final scrollable = find
        .descendant(of: feed, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(0));
    // Opens anchored at the newest message.
    expect(position.pixels, moreOrLessEquals(position.maxScrollExtent));

    final rect = tester.getRect(feed);
    final margin = Offset(rect.right - 24, rect.center.dy);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(margin);
    final before = position.pixels;
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -240)));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(before));

    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets('streaming deltas never notify the shell or sidebar', (
    WidgetTester tester,
  ) async {
    final (ctrl, gw, l10n) = await boot();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    final threadId = ctrl.activeThread!.id;
    gw.emit(RunStartedEvent(threadId: threadId, nodeId: 'live'));
    await tester.pump();

    var shellNotifications = 0;
    var leafNotifications = 0;
    void onShell() => shellNotifications++;
    void onLeaf() => leafNotifications++;
    ctrl.addListener(onShell);
    ctrl.liveTurn.addListener(onLeaf);
    // Count render-object layouts during the deltas: the feed must be a relayout boundary, so
    // the shell's `LayoutBuilder`s above it are not laid out again on every delta.
    FlutterTimeline.debugCollectionEnabled = true;
    debugProfileLayoutsEnabled = true;
    FlutterTimeline.debugReset();
    for (var i = 0; i < 20; i++) {
      gw.emit(
        DeltaBatchEvent(threadId: threadId, nodeId: 'live', textDelta: 'w$i '),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    final layouts = FlutterTimeline.debugCollect().aggregatedBlocks;
    debugProfileLayoutsEnabled = false;
    FlutterTimeline.debugCollectionEnabled = false;
    ctrl.removeListener(onShell);
    ctrl.liveTurn.removeListener(onLeaf);

    expect(shellNotifications, 0);
    expect(leafNotifications, 20);
    final shellLayouts = layouts
        .where((b) => b.name == '_RenderLayoutBuilder')
        .fold<int>(0, (sum, b) => sum + b.count);
    expect(
      shellLayouts,
      lessThan(5),
      reason: 'streaming deltas re-laid out the shell above the feed',
    );
    expect(ctrl.liveTurn.value?.text, startsWith('w0 w1 '));
    expect(find.textContaining('w19', findRichText: true), findsWidgets);

    gw.emit(
      RunFinishedEvent(threadId: threadId, nodeId: 'live', cancelled: false),
    );
    await tester.pumpAndSettle();
    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets('hover and press states never rebuild the parent', (
    WidgetTester tester,
  ) async {
    var parentBuilds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: BistreTheme(
          data: BistreThemeData.dayParchment,
          child: Center(
            child: Builder(
              builder: (context) {
                parentBuilds++;
                return EngravedButton(label: 'Send', onPressed: () {});
              },
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(EngravedButton)));
    await tester.pump();
    await gesture.down(tester.getCenter(find.byType(EngravedButton)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(parentBuilds, 1);
  });

  testWidgets(
    'mobile code fences soft-wrap at 360 px and 200% text without overflow',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final l10n = loadDiskCatalogs();
      final overrides = CodeWrapOverrides();
      addTearDown(overrides.dispose);
      const md =
          '```kotlin\nfun exportName(title: String, id: String): String = title.take(48) + "-" + id\n```';

      Widget app({required bool wrap}) => BistreLocalizations(
        controller: l10n,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: BistreTheme(
            data: BistreThemeData.dayParchment,
            child: MediaQuery.fromView(
              view: tester.view,
              child: CodeWrapScope(
                wrapByDefault: wrap,
                overrides: overrides,
                child: MarkdownFolioView(markdown: md, onCopyCode: (_) {}),
              ),
            ),
          ),
        ),
      );
      final horizontalScroll = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );

      await tester.pumpWidget(app(wrap: true));
      expect(tester.takeException(), isNull);
      expect(horizontalScroll, findsNothing);

      // The per-fence toggle switches this fence to horizontal scrolling.
      await tester.tap(
        find.bySemanticsLabel(l10n.t(L10nKey.chatCodeNoWrap)).first,
      );
      await tester.pump();
      expect(horizontalScroll, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('consecutive completed read/search steps fold into one quiet row', () {
    ToolActivityEntry e(
      String id,
      String tool, {
      String status = 'completed',
    }) => ToolActivityEntry(
      id: id,
      toolName: tool,
      summary: '$tool $id',
      status: status,
    );
    final folded = foldReadOnlySteps(<ToolActivityEntry>[
      e('1', 'read'),
      e('2', 'grep'),
      e('3', 'glob'),
      e('4', 'edit'),
      e('5', 'read'),
      e('6', 'read', status: 'running'),
    ], joinSummaries: (p) => p.join(' · '));
    expect(folded.map((x) => x.id), <String>['1', '4', '5', '6']);
    expect(folded.first.summary, 'read 1 · grep 2 · glob 3');
  });

  test(
    'meta joins isolate each fragment so mixed-direction text keeps its order',
    () async {
      final (ctrl, gw, l10n) = await boot();
      expect(
        l10n.joinMeta(<String>['Inter', '', '15px']),
        '\u2068Inter\u2069 · \u206815px\u2069',
      );
      ctrl.dispose();
      await gw.shutdown();
    },
  );

  testWidgets('deleting a chat is undoable for 8 seconds', (
    WidgetTester tester,
  ) async {
    final (ctrl, gw, l10n) = await boot();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    final victim = ctrl.threads.last.id;
    final before = ctrl.threads.length;

    await ctrl.deleteThread(victim);
    await tester.pump();
    expect(ctrl.threads.any((t) => t.id == victim), isFalse);
    expect(ctrl.toastActionKey, L10nKey.toastUndo);
    expect(find.text(l10n.t(L10nKey.toastUndo)), findsOneWidget);

    await tester.tap(find.text(l10n.t(L10nKey.toastUndo)));
    await tester.pumpAndSettle();
    expect(ctrl.threads.length, before);
    expect(ctrl.threads.any((t) => t.id == victim), isTrue);

    ctrl.dispose();
    await gw.shutdown();
  });

  test(
    'toasts and ordinary notifications do not change the root appearance',
    () async {
      final (ctrl, gw, _) = await boot();
      var rootRebuildSignals = 0;
      ctrl.appearance.addListener(() => rootRebuildSignals++);
      ctrl.showToast(L10nKey.toastDeleted);
      ctrl.dismissToast();
      await ctrl.updateSearch('');
      expect(rootRebuildSignals, 0);
      ctrl.dispose();
      await gw.shutdown();
    },
  );

  test(
    'a fast thread switch never shows the previous chat\'s messages',
    () async {
      final (ctrl, gw, _) = await boot();
      final threads = ctrl.threads;
      expect(threads.length, greaterThanOrEqualTo(2));
      final slow = threads[0].id;
      final fast = threads[1].id;
      gw.listNodesDelays[slow] = const Duration(milliseconds: 40);
      final slowSwitch = ctrl.selectThread(slow);
      await ctrl.selectThread(fast);
      await slowSwitch;
      expect(ctrl.activeThread?.id, fast);
      expect(ctrl.nodes.every((n) => n.threadId == fast), isTrue);
      ctrl.dispose();
      await gw.shutdown();
    },
  );

  test(
    'chats deleted inside the Undo window are committed when the app closes',
    () async {
      final (ctrl, gw, _) = await boot();
      final victim = ctrl.threads.first.id;
      await ctrl.deleteThread(victim);
      expect(
        gw.deletedThreadIds,
        isEmpty,
        reason: 'still inside the Undo window',
      );
      await ctrl.flushPendingDeletes();
      expect(gw.deletedThreadIds, <String>[victim]);
      ctrl.dispose();
      await gw.shutdown();
    },
  );

  test('a failed first load reports failure and Try again recovers', () async {
    final l10n = loadDiskCatalogs();
    final gw = GalleryGateway(connected: true)..failInitTimes = 1;
    final ctrl = FolioController(
      gateway: gw,
      defaultThreadTitle: l10n.t(L10nKey.shellThreadDefaultTitle),
      onLocaleSynced: l10n.setLocale,
      isDevEnvironment: true,
    );
    expect(ctrl.bootState, BootState.loading);
    await ctrl.bootstrap('memory');
    expect(ctrl.bootState, BootState.failed);
    await ctrl.retryBootstrap();
    expect(ctrl.bootState, BootState.ready);
    expect(ctrl.threads, isNotEmpty);
    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets(
    'small icon buttons accept taps across a 40 px target without growing',
    (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: BistreTheme(
            data: BistreThemeData.resolve(isDark: false),
            child: Center(
              child: BistreIconButton(
                key: const Key('tiny'),
                icon: BistreUiIcon.copy,
                dimension: 24,
                semanticsLabel: 'copy',
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byKey(const Key('tiny')));
      expect(rect.width, 24, reason: 'layout keeps the visual size');
      // 7 px outside the 24 px chip, still inside the 40 px target.
      await tester.tapAt(rect.centerRight + const Offset(7, 0));
      expect(taps, 1);
      // Outside the 40 px target: no tap.
      await tester.tapAt(rect.centerRight + const Offset(12, 0));
      expect(taps, 1);
    },
  );

  test('opened chats become tabs; closing the current tab switches to its neighbour', () async {
    final (ctrl, gw, _) = await boot();
    final first = ctrl.activeThread!.id;
    final second = ctrl.threads.firstWhere((t) => t.id != first).id;
    await ctrl.selectThread(second);
    expect(ctrl.openTabs.map((t) => t.id), <String>[first, second]);
    await ctrl.closeTab(second);
    expect(ctrl.activeThread?.id, first);
    expect(ctrl.openTabs.map((t) => t.id), <String>[first]);
    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets('toasts and search keystrokes never rebuild the sidebar', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1320, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await boot();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FolioSidebar), findsOneWidget);

    var sidebarBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is FolioSidebar) sidebarBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);

    ctrl.showToast(L10nKey.toastCopied);
    await tester.pump();
    expect(find.text(l10n.t(L10nKey.toastCopied)), findsOneWidget);
    ctrl.dismissToast();
    await tester.pump();
    for (final q in <String>['h', 'he', 'hel']) {
      unawaited(ctrl.updateSearch(q));
      await tester.pump();
    }
    await tester.pump(FolioController.searchDebounce);
    await tester.pumpAndSettle();
    expect(ctrl.searchQuery, 'hel');
    expect(sidebarBuilds, 0);

    ctrl.dispose();
    await gw.shutdown();
  });
}
