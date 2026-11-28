import 'dart:async';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/disclosure_reveal.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/design/press_feedback.dart';
import 'package:bistre_app/design/smooth_scroll.dart';
import 'package:bistre_app/features/chat/code_wrap_scope.dart';
import 'package:bistre_app/features/chat/content_direction.dart';
import 'package:bistre_app/features/chat/context_gauge_ring.dart';
import 'package:bistre_app/features/chat/folio_message_feed.dart';
import 'package:bistre_app/features/chat/markdown_folio_view.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/shell/live_turn_notifier.dart';
import 'package:bistre_app/features/sidebar/folio_sidebar.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:bistre_app/platform/vault_key_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

/// Regression tests for the v2 anti-pattern audit (`docs/design/design.md` §8). Each one fails
/// on the pre-fix code: a centered constrained `ListView`, root-notifying stream deltas,
/// parent-rebuilding hover state, and always-horizontal code fences.
void main() {
  testWidgets('wheel scrolls the chat from the empty desktop page margin', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1320, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (ctrl, gw, l10n) = await bootGalleryController();
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
    final (ctrl, gw, l10n) = await bootGalleryController();
    await tester.pumpWidget(
      BistreApp(l10nController: l10n, folioController: ctrl),
    );
    await tester.pumpAndSettle();
    // This test counts bridge batches; the reading pacer has its own test below.
    ctrl.liveTurn.shouldPace = () => false;
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
          data: BistreThemeData.warmSepia,
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
            data: BistreThemeData.warmSepia,
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

    // Thinking between two reads folds with them; thinking before the edit stays with it.
    final across = foldReadOnlySteps(<ToolActivityEntry>[
      e('t0', kThinkingRow),
      e('1', 'read'),
      e('t1', kThinkingRow),
      e('2', 'grep'),
      e('t2', kThinkingRow),
      e('3', 'edit'),
    ], joinSummaries: (p) => p.join(' · '));
    expect(across.map((x) => x.id), <String>['t0', '1', 't2', '3']);
    expect(across[1].summary, 'read 1 · grep 2');
  });

  test(
    'meta joins isolate each fragment so mixed-direction text keeps its order',
    () async {
      final (ctrl, gw, l10n) = await bootGalleryController();
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
    final (ctrl, gw, l10n) = await bootGalleryController();
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
      final (ctrl, gw, _) = await bootGalleryController();
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
      final (ctrl, gw, _) = await bootGalleryController();
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
      final (ctrl, gw, _) = await bootGalleryController();
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

  test(
    'wipeVaultKeyBytes handles unmodifiable platform-channel byte views',
    () {
      final mutable = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      wipeVaultKeyBytes(mutable);
      expect(mutable.every((b) => b == 0), isTrue);

      final reply = ByteData(32);
      for (var i = 0; i < 32; i++) {
        reply.setUint8(i, i + 1);
      }
      final unmodifiableView = reply.asUnmodifiableView().buffer.asUint8List(
        0,
        32,
      );
      expect(() => wipeVaultKeyBytes(unmodifiableView), returnsNormally);
      expect(() => wipeVaultKeyBytes(null), returnsNormally);
    },
  );

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
    final (ctrl, gw, _) = await bootGalleryController();
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

  testWidgets(
    'toasts, search, drafts, and the sidebar filter rebuild only their own widgets',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1320, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (ctrl, gw, l10n) = await bootGalleryController();
      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: ctrl),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FolioSidebar), findsOneWidget);

      var sidebarBuilds = 0;
      var feedBuilds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        if (element.widget is FolioSidebar) sidebarBuilds++;
        if (element.widget is FolioMessageFeed) feedBuilds++;
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
      ctrl.scheduleDraftSave('a draft');
      await ctrl.flushPendingDraft();
      await tester.pump();
      expect(ctrl.draftSaved, isTrue);
      // The engine echoes every save; the echo changes nothing and must not rebuild.
      gw.emit(DraftSavedEvent(threadId: ctrl.activeThread!.id, updatedAtMs: 0));
      await tester.pump();
      expect(sidebarBuilds, 0);

      feedBuilds = 0;
      for (final q in <String>['c', 'ch']) {
        ctrl.setSidebarFilter(q);
        await tester.pump();
      }
      expect(feedBuilds, 0);

      ctrl.dispose();
      await gw.shutdown();
    },
  );

  test(
    'the conversation gauge shows core\'s estimate for the visible branch',
    () async {
      final (ctrl, gw, _) = await bootGalleryController();
      await pumpEventQueue();
      final thread = ctrl.activeThread!.id;
      final leaf = ctrl.visibleBranchNodes.last.id;
      final expected = await gw.contextBreakdown(thread, leaf);
      expect(expected.totalSent, greaterThan(0));
      expect(ctrl.contextBreakdown.value, expected);

      // A different chat asks core again and shows that chat's number.
      final other = ctrl.threads.firstWhere((t) => t.id != thread).id;
      await ctrl.selectThread(other);
      await pumpEventQueue();
      final otherLeaf = ctrl.visibleBranchNodes.lastOrNull?.id;
      expect(
        ctrl.contextBreakdown.value,
        otherLeaf == null
            ? EngineContextBreakdown.empty
            : await gw.contextBreakdown(other, otherLeaf),
      );
      ctrl.dispose();
      await gw.shutdown();
    },
  );

  test('a message takes its direction from its first strong character', () {
    expect(contentDirection('How should we keep WAL fast?'), TextDirection.ltr);
    expect(contentDirection('**Tiếng Việt** trước'), TextDirection.ltr);
    expect(contentDirection('## مرحبا بالعالم'), TextDirection.rtl);
    expect(contentDirection('42: שלום'), TextDirection.rtl);
    expect(contentDirection('123 ... !'), isNull);
  });

  testWidgets('an English reply inside the Arabic UI lays out left to right', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.rtl,
        child: BistreTheme(
          data: BistreThemeData.resolve(isDark: false),
          child: MarkdownFolioView(
            markdown: 'Readers run concurrently:',
            onCopyCode: (_) {},
          ),
        ),
      ),
    );
    final text = find.textContaining(
      'Readers run concurrently',
      findRichText: true,
    );
    expect(text, findsOneWidget);
    expect(Directionality.of(tester.element(text)), TextDirection.ltr);
  });

  testWidgets('the context ring opens a breakdown of what fills the chat', (
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

    expect(find.text(l10n.t(L10nKey.chatContextTitle)), findsNothing);
    await tester.tap(find.byType(ContextGaugeRing));
    await tester.pumpAndSettle();
    expect(find.text(l10n.t(L10nKey.chatContextTitle)), findsOneWidget);
    final turns = ctrl.contextBreakdown.value.countOf('messages') ?? 0;
    expect(
      find.text(
        l10n.t(L10nKey.chatContextCatMessages, <String, Object?>{
          'count': turns,
        }),
      ),
      findsOneWidget,
    );
    expect(find.text(l10n.t(L10nKey.chatContextCatFree)), findsOneWidget);

    // Escape fades the popover out (DESIGN §6) before removing it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text(l10n.t(L10nKey.chatContextTitle)), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text(l10n.t(L10nKey.chatContextTitle)), findsNothing);

    ctrl.dispose();
    await gw.shutdown();
  });

  testWidgets(
    'the composer thinking chip opens a slider that sets the effort',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1700, 820);
      // Wide enough for the full labels in one row (narrower windows use the compact
      // labels; see composer_toolbar_test.dart).
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (ctrl, gw, l10n) = await bootGalleryController();
      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: ctrl),
      );
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      String chip(L10nKey level) => l10n.t(
        L10nKey.chatThinkingChip,
        <String, Object?>{'level': l10n.t(level)},
      );
      expect(find.text(chip(L10nKey.chatEffortAuto)), findsOneWidget);
      await tester.tap(find.text(chip(L10nKey.chatEffortAuto)));
      await tester.pumpAndSettle();
      final slider = find.byType(BistreSlider);
      expect(slider, findsOneWidget);
      // The slider holds the levels Off..Max (Auto is a choice beside it): 4 is Extra.
      tester.widget<BistreSlider>(slider).onChanged(4);
      await tester.pumpAndSettle();
      expect(ctrl.settings.reasoningEffort, 'xhigh');
      expect(find.text(chip(L10nKey.chatEffortExtra)), findsOneWidget);

      ctrl.dispose();
      await gw.shutdown();
    },
  );

  testWidgets(
    'buttons spring down when pressed and stay still under reduced motion',
    (WidgetTester tester) async {
      double scaleOf() {
        final t = tester.widget<Transform>(
          find
              .descendant(
                of: find.byType(PressFeedback),
                matching: find.byType(Transform),
              )
              .first,
        );
        return t.transform.entry(0, 0);
      }

      Future<void> pumpButton({required bool reduceMotion}) =>
          tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: BistreTheme(
                  data: BistreThemeData.resolve(isDark: false),
                  child: Center(
                    child: EngravedButton(label: 'Send', onPressed: () {}),
                  ),
                ),
              ),
            ),
          );

      await pumpButton(reduceMotion: false);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(EngravedButton)),
      );
      await tester.pumpAndSettle();
      expect(scaleOf(), closeTo(0.96, 0.001));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scaleOf(), closeTo(1.0, 0.001));

      await pumpButton(reduceMotion: true);
      final still = await tester.startGesture(
        tester.getCenter(find.byType(EngravedButton)),
      );
      await tester.pump();
      expect(scaleOf(), 1.0);
      await still.up();
    },
  );

  testWidgets(
    'a wheel notch glides to its target; trackpad deltas and reduced motion jump',
    (WidgetTester tester) async {
      final controller = SmoothScrollController();
      addTearDown(controller.dispose);
      Future<void> pumpList({required bool reduceMotion}) => tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ListView.builder(
              controller: controller,
              itemCount: 200,
              itemBuilder: (_, i) => SizedBox(height: 40, child: Text('$i')),
            ),
          ),
        ),
      );
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      Future<void> wheel(double dy) async {
        mouse.hover(tester.getCenter(find.byType(ListView)));
        await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
      }

      await pumpList(reduceMotion: false);
      await wheel(120);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final mid = controller.offset;
      expect(mid, greaterThan(0));
      expect(mid, lessThan(120));
      await wheel(120); // a quick second notch extends the same glide
      await tester.pumpAndSettle();
      expect(controller.offset, 240);

      await wheel(8); // trackpad-sized delta stays 1:1
      await tester.pump();
      expect(controller.offset, 248);

      await pumpList(reduceMotion: true);
      await wheel(120);
      await tester.pump();
      expect(controller.offset, 368);
    },
  );

  testWidgets(
    'streamed text reveals at a reading pace and catches up elastically',
    (WidgetTester tester) async {
      final live = LiveTurnNotifier()..shouldPace = () => true;
      addTearDown(live.dispose);
      live.start('t', 'n');
      live.appendText('t', 'a' * 20);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final early = live.value!.text.length;
      expect(early, greaterThan(0));
      expect(
        early,
        lessThan(20),
        reason: 'a small backlog reveals at ~92 chars/s',
      );

      live.appendText(
        't',
        '\u{1F600}' * 600,
      ); // a big burst: 1,200 UTF-16 units
      // ~0.6 s to shed the burst, then the last 28 characters at reading pace (~0.3 s).
      for (var i = 0; i < 70; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final shown = live.value!.text;
        expect(
          shown.isEmpty || !_endsWithLoneHighSurrogate(shown),
          isTrue,
          reason: 'never splits a surrogate pair',
        );
      }
      expect(live.value!.text.length, 20 + 1200, reason: 'elastic catch-up');

      live.shouldPace = () => false; // Reduce motion: each batch shows at once
      live.appendText('t', 'z');
      expect(live.value!.text.endsWith('z'), isTrue);
    },
  );

  testWidgets(
    'disclosures grow open on a spring and snap under reduced motion',
    (WidgetTester tester) async {
      Future<void> pumpReveal({required bool open, required bool reduce}) =>
          tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(disableAnimations: reduce),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: DisclosureReveal(
                    open: open,
                    child: const SizedBox(key: Key('body'), height: 200),
                  ),
                ),
              ),
            ),
          );
      double height() => tester.getSize(find.byType(DisclosureReveal)).height;

      await pumpReveal(open: false, reduce: false);
      expect(find.byKey(const Key('body')), findsNothing);
      await pumpReveal(open: true, reduce: false);
      await tester.pump(const Duration(milliseconds: 40));
      expect(height(), greaterThan(0));
      expect(height(), lessThan(200));
      await tester.pumpAndSettle();
      expect(height(), 200);

      await pumpReveal(open: false, reduce: true);
      await tester.pump();
      expect(find.byKey(const Key('body')), findsNothing);
    },
  );
}

bool _endsWithLoneHighSurrogate(String s) {
  final last = s.codeUnitAt(s.length - 1);
  return last >= 0xD800 && last <= 0xDBFF;
}
