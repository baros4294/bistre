import 'package:bistre_app/app/shell_notifiers.dart';
import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/bistre_motion_widgets.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/sidebar_slide_reveal.dart';
import 'package:bistre_app/design/smooth_scroll.dart';
import 'package:bistre_app/features/chat/message_nav_rail.dart';
import 'package:bistre_app/features/settings/assistants_settings_view.dart';
import 'package:bistre_app/features/settings/budget_safety_settings_view.dart';
import 'package:bistre_app/features/settings/default_models_settings_view.dart';
import 'package:bistre_app/features/settings/provider_presets.dart';
import 'package:bistre_app/features/settings/providers_settings_view.dart';
import 'package:bistre_app/features/settings/worldbook_cards_settings_view.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/shell/live_turn_notifier.dart';
import 'package:bistre_app/features/sidebar/folio_sidebar.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/gallery_harness.dart';

Widget _wrapTest(
  BistreLocalizationController l10n,
  Widget child, {
  bool isDark = false,
}) {
  final theme = BistreThemeData.resolve(isDark: isDark);
  return BistreLocalizations(
    controller: l10n,
    child: BistreTheme(
      data: theme,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: theme.bgCanvas,
          child: Overlay(
            key: ValueKey<Type>(child.runtimeType),
            initialEntries: <OverlayEntry>[OverlayEntry(builder: (_) => child)],
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('default Warm Sepia theme uses calm Warm Sepia Brown accent', () {
    const defaults = EngineSettings();
    expect(defaults.accentPreset, 'brass');
    expect(defaults.theme, 'system');
    final light = BistreThemeData.resolve(isDark: false);
    final dark = BistreThemeData.resolve(isDark: true);
    expect(light.accentWax, isNot(const Color(0xFFA83625)));
    expect(dark.accentWax, isNot(const Color(0xFFE06350)));
    expect(
      BistreAccentOption.contrastRatio(light.accentWax, light.bgCanvas),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      BistreAccentOption.contrastRatio(dark.accentWax, dark.bgCanvas),
      greaterThanOrEqualTo(4.5),
    );
  });

  test(
    'NodeUsageMeta parses cached, cache-write, reasoning, and TTFT fields',
    () {
      final meta = NodeUsageMeta.tryParse(
        '{"provider_id":"p1","model_id":"m1","input_tokens":500,"output_tokens":120,'
        '"cached_input_tokens":300,"cache_creation_input_tokens":50,'
        '"reasoning_tokens":80,"first_token_ms":420,"elapsed_ms":2000,"cost_micros":1500}',
      );
      expect(meta, isNotNull);
      expect(meta!.cachedInputTokens, 300);
      expect(meta.cacheCreationInputTokens, 50);
      expect(meta.reasoningTokens, 80);
      expect(meta.firstTokenMs, 420);
      expect(meta.tokensPerSecond, closeTo(60.0, 0.1));
    },
  );

  testWidgets(
    'BudgetSafetySettingsView supports 4 presets and persists Strict & Off',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 960);
      final l10n = loadDiskCatalogs();
      final ctrl = FolioController(
        gateway: GalleryGateway(connected: true),
        defaultThreadTitle: 'New chat',
      );
      await ctrl.bootstrap('/tmp/bistre_test');

      await tester.pumpWidget(
        _wrapTest(l10n, BudgetSafetySettingsView(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      final strictFinder = find.text(l10n.t(L10nKey.settingsTrustParchment));
      await tester.ensureVisible(strictFinder);
      await tester.tap(strictFinder);
      await tester.pumpAndSettle();
      expect(ctrl.settings.trustPreset, 'strict');

      final offFinder = find.text(l10n.t(L10nKey.settingsAgentPermOff));
      await tester.ensureVisible(offFinder);
      await tester.tap(offFinder);
      await tester.pumpAndSettle();
      expect(ctrl.settings.trustPreset, 'off');

      ctrl.dispose();
    },
  );

  testWidgets(
    'AssistantsSettingsView shows validation error when saving empty name',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 960);
      final l10n = loadDiskCatalogs();
      final ctrl = FolioController(
        gateway: GalleryGateway(connected: true),
        defaultThreadTitle: 'New chat',
      );
      await ctrl.bootstrap('/tmp/bistre_test');

      await tester.pumpWidget(
        _wrapTest(l10n, AssistantsSettingsView(controller: ctrl)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.t(L10nKey.sidebarAddAssistant)));
      await tester.pumpAndSettle();

      final createBtn = find.text(
        l10n.t(L10nKey.settingsAssistantsCreateAction),
      );
      await tester.ensureVisible(createBtn);
      await tester.tap(createBtn);
      await tester.pumpAndSettle();

      expect(
        find.text(l10n.t(L10nKey.diagValidationInvalidInput)),
        findsOneWidget,
      );
      ctrl.dispose();
    },
  );

  testWidgets(
    'DefaultModelsSettingsView and WorldbookCardsSettingsView render cleanly',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 960);
      final l10n = loadDiskCatalogs();
      final ctrl = FolioController(
        gateway: GalleryGateway(connected: true),
        defaultThreadTitle: 'New chat',
      );
      await ctrl.bootstrap('/tmp/bistre_test');

      await tester.pumpWidget(
        _wrapTest(l10n, DefaultModelsSettingsView(controller: ctrl)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.t(L10nKey.settingsDefaultModelsGlobalHeading)),
        findsOneWidget,
      );
      expect(
        find.text(l10n.t(L10nKey.settingsDefaultModelsFollowGlobal)),
        findsNWidgets(3),
      );

      await tester.pumpWidget(
        _wrapTest(l10n, WorldbookCardsSettingsView(controller: ctrl)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.t(L10nKey.settingsWorldBookCardsHeading)),
        findsOneWidget,
      );
      expect(
        find.text(l10n.t(L10nKey.settingsWorldBookLoreHeading)),
        findsOneWidget,
      );
      ctrl.dispose();
    },
  );

  testWidgets(
    'FolioTopBanner, centered FolioToastBanner, SidebarSlideReveal, and MessageNavRail work',
    (tester) async {
      final l10n = loadDiskCatalogs();
      var dismissed = false;
      var jumped = -1;
      final nodes = <EngineNode>[
        const EngineNode(
          id: 'n1',
          threadId: 't1',
          role: 'user',
          content: 'First user prompt',
          createdAtMs: 1,
        ),
        const EngineNode(
          id: 'n2',
          threadId: 't1',
          parentId: 'n1',
          role: 'assistant',
          content: 'Assistant answer',
          createdAtMs: 2,
        ),
      ];

      await tester.pumpWidget(
        _wrapTest(
          l10n,
          Stack(
            children: [
              Column(
                children: [
                  FolioTopBanner(
                    visible: true,
                    icon: BistreUiIcon.download,
                    message: 'Update v0.2.0 is available',
                    actionLabel: 'Update',
                    onAction: () {},
                    onDismiss: () => dismissed = true,
                  ),
                  const SidebarSlideReveal(
                    open: true,
                    reduceMotionOverride: true,
                    child: SizedBox(width: 120, height: 40),
                  ),
                  BistreSlider(
                    value: 2,
                    min: 0,
                    max: 5,
                    reduceMotionOverride: true,
                    semanticsLabel: 'Effort',
                    onChanged: (_) {},
                  ),
                ],
              ),
              FolioToastBanner(
                message: 'Connection OK',
                reduceMotionOverride: true,
                onDismiss: () => dismissed = true,
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: MessageNavRail(
                  nodes: nodes,
                  visible: true,
                  reduceMotionOverride: true,
                  onJumpTop: () {},
                  onJumpPrev: () {},
                  onJumpNext: () {},
                  onJumpLatest: () {},
                  onJumpToIndex: (i) => jumped = i,
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Update v0.2.0 is available'), findsOneWidget);
      expect(find.text('Connection OK'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel(l10n.t(L10nKey.chatNavMap)));
      await tester.pumpAndSettle();
      expect(find.textContaining('First user prompt'), findsOneWidget);
      await tester.tap(find.textContaining('First user prompt'));
      await tester.pumpAndSettle();
      expect(jumped, 0);

      const msg = ToastMessage(
        L10nKey.toastProviderConnectionOk,
        args: <String, Object?>{'seconds': '0.3', 'count': 12},
        tone: ToastTone.ok,
      );
      expect(msg.tone, ToastTone.ok);
      expect(dismissed, isFalse);
    },
  );

  testWidgets(
    'Provider settings expose strictly Big 3 + Custom presets and no local server detector',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 960);

      expect(kProviderPresets.map((p) => p.name).toList(), <String>[
        'OpenAI',
        'Google Gemini',
        'Anthropic',
        'Custom',
      ]);
      final l10n = loadDiskCatalogs();
      final controller = FolioController(
        gateway: GalleryGateway(connected: false),
        defaultThreadTitle: 'New chat',
      );
      addTearDown(controller.dispose);
      await controller.bootstrap('/tmp/bistre_test');

      await tester.pumpWidget(
        _wrapTest(l10n, ProvidersSettingsView(controller: controller)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.t(L10nKey.providerAddButton)));
      await tester.pumpAndSettle();

      expect(find.text('OpenAI'), findsWidgets);
      expect(find.text('Google Gemini'), findsWidgets);
      expect(find.text('Anthropic'), findsWidgets);
      expect(find.text('Custom'), findsWidgets);
      expect(find.textContaining('Ollama'), findsNothing);
      expect(find.textContaining('OpenRouter'), findsNothing);
      expect(find.textContaining('DeepSeek'), findsNothing);
      expect(find.textContaining('Detect local'), findsNothing);
    },
  );

  testWidgets(
    'LiveTurnNotifier throttles low-memory redraws via VSync frames without raw Timer',
    (tester) async {
      final live = LiveTurnNotifier();
      addTearDown(live.dispose);
      live.shouldPace = () => false;
      live.minInterval = const Duration(milliseconds: 33);

      var notifications = 0;
      live.addListener(() => notifications++);

      live.start('t1', 'm1');
      notifications = 0;
      live.appendText('t1', 'alpha ');
      live.appendText('t1', 'beta ');
      expect(notifications, 0);

      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 35));
      expect(notifications, greaterThanOrEqualTo(1));
      expect(live.value?.text, 'alpha beta ');
    },
  );

  testWidgets(
    'SmoothScrollController preserves momentum across consecutive wheel ticks',
    (tester) async {
      final scroll = SmoothScrollController();
      addTearDown(scroll.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 400,
            height: 300,
            child: ListView.builder(
              controller: scroll,
              itemCount: 80,
              itemExtent: 48,
              itemBuilder: (_, i) => Text('Row $i'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.byType(ListView));
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 100)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 100)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();

      expect(scroll.offset, greaterThan(120));
    },
  );

  testWidgets(
    'FolioSidebar virtualizes 300 chats cleanly via ListView.builder',
    (tester) async {
      final l10n = loadDiskCatalogs();
      final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
      for (var i = 0; i < 300; i++) {
        await gateway.createThread('Synthetic Chat $i', 'chat');
      }
      final controller = FolioController(
        gateway: gateway,
        defaultThreadTitle: 'New chat',
      );
      addTearDown(controller.dispose);
      await controller.bootstrap('/tmp/bistre_test');
      await tester.pumpWidget(
        _wrapTest(
          l10n,
          SizedBox(
            width: 280,
            height: 700,
            child: FolioSidebar(
              controller: controller,
              onSelectThreadComplete: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Synthetic Chat 299'), findsOneWidget);
      expect(find.text('Synthetic Chat 0'), findsNothing);
    },
  );
}
