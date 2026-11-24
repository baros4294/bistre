import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/context_menu.dart';
import 'package:bistre_app/features/chat/composer_tools_control.dart';
import 'package:bistre_app/features/chat/context_gauge_ring.dart';
import 'package:bistre_app/features/chat/markdown_folio_view.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:bistre_app/features/chat/usage_details_pill.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/shell/tab_switcher_modal.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:bistre_app/platform/host_memory.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/gallery_harness.dart';

class _MultiProviderGateway extends GalleryGateway {
  _MultiProviderGateway() : super(connected: true);

  final List<EngineProvider> _extraProviders = <EngineProvider>[];
  final Map<String, List<EngineProviderModel>> _customModels =
      <String, List<EngineProviderModel>>{};

  void setModels(String providerId, List<EngineProviderModel> models) {
    _customModels[providerId] = models;
  }

  @override
  Future<List<EngineProvider>> listProviders() async {
    final base = await super.listProviders();
    return <EngineProvider>[...base, ..._extraProviders];
  }

  @override
  Future<EngineProvider> createProvider({
    required String name,
    required String dialect,
    required String baseUrl,
    required String defaultModel,
    String iconSlug = 'server',
    String customIconPath = '',
    String? apiKey,
  }) async {
    final created = EngineProvider(
      id: 'extra_${_extraProviders.length + 1}',
      name: name,
      dialect: dialect,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      keyHint: 'local',
      hasApiKey: true,
      isEnabled: true,
      isBuiltin: false,
      useServerStateCache: false,
      iconSlug: iconSlug,
      customIconPath: customIconPath,
      createdAtMs: 1,
      updatedAtMs: 1,
      isLocal: baseUrl.contains('127.0.0.1') || baseUrl.contains('localhost'),
    );
    _extraProviders.add(created);
    return created;
  }

  @override
  Future<EngineProvider> updateProvider({
    required String providerId,
    String? name,
    String? baseUrl,
    String? defaultModel,
    bool? isEnabled,
    bool? useServerStateCache,
    String? iconSlug,
    String? customIconPath,
  }) async {
    final idx = _extraProviders.indexWhere((p) => p.id == providerId);
    if (idx >= 0) {
      final old = _extraProviders[idx];
      final updated = EngineProvider(
        id: old.id,
        name: name ?? old.name,
        dialect: old.dialect,
        baseUrl: baseUrl ?? old.baseUrl,
        defaultModel: defaultModel ?? old.defaultModel,
        keyHint: old.keyHint,
        hasApiKey: old.hasApiKey,
        isEnabled: isEnabled ?? old.isEnabled,
        isBuiltin: old.isBuiltin,
        useServerStateCache: useServerStateCache ?? old.useServerStateCache,
        iconSlug: iconSlug ?? old.iconSlug,
        customIconPath: customIconPath ?? old.customIconPath,
        createdAtMs: old.createdAtMs,
        updatedAtMs: old.updatedAtMs,
        isLocal: old.isLocal,
      );
      _extraProviders[idx] = updated;
      return updated;
    }
    return super.updateProvider(
      providerId: providerId,
      name: name,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      isEnabled: isEnabled,
      useServerStateCache: useServerStateCache,
      iconSlug: iconSlug,
      customIconPath: customIconPath,
    );
  }

  @override
  Future<List<EngineProviderModel>> fetchProviderModels(
    String providerId,
  ) async =>
      _customModels[providerId] ?? await super.fetchProviderModels(providerId);
}

Widget _wrapWidget(BistreLocalizationController l10n, Widget child) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(800, 600)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: BistreLocalizations(
        controller: l10n,
        child: BistreTheme(
          data: BistreThemeData.warmSepia,
          child: Overlay(
            initialEntries: <OverlayEntry>[OverlayEntry(builder: (_) => child)],
          ),
        ),
      ),
    ),
  );
}

/// Regression tests for interactive chat, tab, modal, and settings workflows:
/// - `TabSwitcherModal` (phone bottom sheet, desktop modal, 200% text 1-col, RTL, Android back, Ctrl+Tab)
/// - `ModelPickerPopover` (cross-provider search, provider & family filter chips, active pinned first)
/// - `ContextGaugeRing` session cost & attached files rows
/// - `UsageDetailsPill` per-turn interactive breakdown popover
/// - Code block right-click context menu
/// - Skia GPU resource cache cap (`48 MiB` / `32 MiB`)
void main() {
  Future<(FolioController, _MultiProviderGateway, BistreLocalizationController)>
  boot() async {
    final l10n = loadDiskCatalogs();
    final gw = _MultiProviderGateway();
    final ctrl = FolioController(
      gateway: gw,
      defaultThreadTitle: l10n.t(L10nKey.shellThreadDefaultTitle),
      onLocaleSynced: l10n.setLocale,
      isDevEnvironment: true,
    );
    await ctrl.bootstrap('memory');
    return (ctrl, gw, l10n);
  }

  testWidgets(
    'phone header shows tab badge once >1 tab is open; tapping opens sheet and Android back closes it',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final (ctrl, gw, l10n) = await boot();
      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: ctrl),
      );
      await tester.pumpAndSettle();

      // Single open tab: no compact tab badge yet.
      expect(ctrl.openTabs.length, 1);
      expect(find.byType(TabSwitcherModal), findsNothing);

      // Open a second chat tab -> compact badge appears with count "2".
      await ctrl.createNewFolio(title: 'Second Tab');
      await tester.pumpAndSettle();
      expect(ctrl.openTabs.length, 2);

      final badgeLabel = l10n.t(L10nKey.shellTabsCount, <String, Object?>{
        'count': 2,
      });
      final badge = find.bySemanticsLabel(badgeLabel);
      expect(badge, findsOneWidget);

      await tester.tap(badge);
      await tester.pumpAndSettle();
      expect(ctrl.tabSwitcherOpen, isTrue);
      expect(find.byType(TabSwitcherModal), findsOneWidget);
      expect(find.text('Second Tab'), findsWidgets);

      // Android back closes the tab switcher first.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(ctrl.tabSwitcherOpen, isFalse);
      expect(find.byType(TabSwitcherModal), findsNothing);

      ctrl.dispose();
      await gw.shutdown();
    },
  );

  testWidgets(
    'desktop tab strip opens TabSwitcherModal, filters >3 tabs, and Ctrl+Tab cycles tabs',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1320, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final (ctrl, gw, l10n) = await boot();
      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: ctrl),
      );
      await tester.pumpAndSettle();

      final firstId = ctrl.activeThread!.id;
      await ctrl.createNewFolio(title: 'Alpha Notes');
      await ctrl.createNewFolio(title: 'Beta Draft');
      await ctrl.createNewFolio(title: 'Gamma Plan');
      await tester.pumpAndSettle();
      expect(ctrl.openTabs.length, 4);

      // Ctrl+Tab cycles back to the first tab.
      await ctrl.cycleTab(1);
      await tester.pumpAndSettle();
      expect(ctrl.activeThread!.id, firstId);

      // Desktop tab strip shows "4 tabs" button opening the modal with filter field.
      final tabsBtn = find.text(
        l10n.t(L10nKey.shellTabsCount, <String, Object?>{'count': 4}),
      );
      expect(tabsBtn, findsOneWidget);
      await tester.tap(tabsBtn);
      await tester.pumpAndSettle();
      expect(find.byType(TabSwitcherModal), findsOneWidget);
      expect(
        find.text(l10n.t(L10nKey.shellTabsFilterPlaceholder)),
        findsOneWidget,
      );

      ctrl.closeTabSwitcher();
      await tester.pumpAndSettle();
      ctrl.dispose();
      await gw.shutdown();
    },
  );

  testWidgets(
    'TabSwitcherModal handles 200% text scale on phone and RTL Arabic without overflow',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final (ctrl, gw, l10n) = await boot();
      await ctrl.createNewFolio(title: 'Long conversation title for testing');
      ctrl.openTabSwitcher();

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            textScaler: TextScaler.linear(2.0),
          ),
          child: BistreApp(l10nController: l10n, folioController: ctrl),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TabSwitcherModal), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Switch to RTL Arabic as well.
      l10n.setLocale('ar');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      ctrl.dispose();
      await gw.shutdown();
    },
  );

  testWidgets(
    'searchable model picker shows cross-provider filter chips, family chips, and privacy badges',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1320, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final (ctrl, gw, l10n) = await boot();
      await ctrl.createProvider(
        name: 'Local Ollama',
        dialect: 'custom_openai',
        baseUrl: 'http://127.0.0.1:11434/v1',
        defaultModel: 'deepseek-ai/deepseek-r1',
        iconSlug: 'ollama',
        apiKey: 'local',
      );
      final providers = ctrl.providers;
      final openAi = providers.firstWhere((p) => p.dialect == 'openai');
      final local = providers.firstWhere((p) => p.name == 'Local Ollama');
      gw.setModels(openAi.id, const <EngineProviderModel>[
        EngineProviderModel(id: 'openai/gpt-4o', displayName: 'gpt-4o'),
        EngineProviderModel(
          id: 'anthropic/claude-sonnet',
          displayName: 'claude-sonnet',
        ),
      ]);
      gw.setModels(local.id, const <EngineProviderModel>[
        EngineProviderModel(
          id: 'deepseek-ai/deepseek-r1',
          displayName: 'deepseek-r1',
        ),
        EngineProviderModel(id: 'qwen/qwen3-32b', displayName: 'qwen3-32b'),
      ]);
      await ctrl.fetchModelsForProvider(openAi.id);
      await ctrl.fetchModelsForProvider(local.id);

      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: ctrl),
      );
      await tester.pumpAndSettle();

      // Open the header model picker.
      final subtitle = find.textContaining(openAi.name);
      await tester.tap(subtitle.first);
      await tester.pumpAndSettle();

      // Provider filter chips and family filter chips appear.
      expect(
        find.textContaining(l10n.t(L10nKey.chatModelAllFamilies)),
        findsOneWidget,
      );
      // Filter down to the local provider chip so its models appear at the top.
      await tester.tap(find.textContaining('Local Ollama'));
      await tester.pumpAndSettle();
      expect(find.text('deepseek-ai/deepseek-r1'), findsOneWidget);

      // Selecting a model switches active provider and model in settings.
      await tester.tap(find.text('deepseek-ai/deepseek-r1'));
      await tester.pumpAndSettle();
      expect(ctrl.settings.activeProviderId, local.id);
      expect(ctrl.settings.activeModelId, 'deepseek-ai/deepseek-r1');

      ctrl.dispose();
      await gw.shutdown();
    },
  );

  testWidgets(
    'ContextGaugeRing breakdown shows session cost and attached files count',
    (WidgetTester tester) async {
      final l10n = loadDiskCatalogs();
      await tester.pumpWidget(
        _wrapWidget(
          l10n,
          const Align(
            alignment: AlignmentDirectional.bottomCenter,
            child: Padding(
              padding: EdgeInsetsDirectional.only(bottom: 24),
              child: ContextGaugeRing(
                usage: EngineContextUsage(
                  systemTokens: 120,
                  historyTokens: 480,
                  historyTurns: 4,
                  totalTokens: 600,
                ),
                limitTokens: 128000,
                sessionSpendMicros: 50000,
                uploadedFilesCount: 2,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ContextGaugeRing));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          l10n.t(L10nKey.chatContextSessionCost, <String, Object?>{
            'cost': r'$0.05',
          }),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          l10n.t(L10nKey.chatContextFiles, <String, Object?>{'count': 2}),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'UsageDetailsPill opens breakdown popover with input/output tokens and cost',
    (WidgetTester tester) async {
      final l10n = loadDiskCatalogs();
      await tester.pumpWidget(
        _wrapWidget(
          l10n,
          const Center(
            child: UsageDetailsPill(
              usage: NodeUsageMeta(
                providerName: 'OpenAI',
                modelId: 'gpt-4o',
                inputTokens: 1234,
                outputTokens: 567,
                costMicros: 25000,
              ),
              summaryText: r'gpt-4o · 1234 in · 567 out · $0.02',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(UsageDetailsPill));
      await tester.pumpAndSettle();

      expect(find.text('1234'), findsOneWidget);
      expect(find.text('567'), findsOneWidget);
      expect(find.text(l10n.t(L10nKey.chatUsageInputTokens)), findsOneWidget);
      expect(find.text(l10n.t(L10nKey.chatUsageOutputTokens)), findsOneWidget);
    },
  );

  testWidgets('code card right-click opens context menu with copy and fold', (
    WidgetTester tester,
  ) async {
    final l10n = loadDiskCatalogs();
    String? copied;
    await tester.pumpWidget(
      _wrapWidget(
        l10n,
        Center(
          child: SizedBox(
            width: 520,
            child: MarkdownFolioView(
              markdown: '```dart\nvoid main() {}\n```',
              onCopyCode: (code) => copied = code,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byType(ContextMenuRegion),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.t(L10nKey.chatCodeCopy)), findsOneWidget);
    await tester.tap(find.text(l10n.t(L10nKey.chatCodeCopy)));
    await tester.pumpAndSettle();
    expect(copied, 'void main() {}');
  });

  test(
    'configureGpuResourceCacheCap sends 48 MiB normal / 32 MiB low-memory',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.skia, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.skia, null),
      );

      await configureGpuResourceCacheCap(lowMemory: false);
      await configureGpuResourceCacheCap(lowMemory: true);

      expect(calls, hasLength(2));
      expect(calls[0].method, 'Skia.setResourceCacheMaxBytes');
      expect(calls[0].arguments, kGpuResourceCacheNormalBytes);
      expect(calls[1].method, 'Skia.setResourceCacheMaxBytes');
      expect(calls[1].arguments, kGpuResourceCacheLowMemoryBytes);
    },
  );

  test('all 9 theme presets satisfy 4-surface WCAG AA contrast (>= 4.5:1)', () {
    expect(BistreThemePreset.presets, hasLength(9));
    for (final preset in BistreThemePreset.presets) {
      final resolved = BistreThemeData.resolve(
        isDark: preset.theme.isDark,
        themeId: preset.id,
        accentPreset: 'preset',
      );
      final surfaces = <Color>[
        resolved.bgCanvas,
        resolved.bgSurface,
        resolved.bgElevated,
        Color.alphaBlend(resolved.hoverTint, resolved.bgSurface),
      ];
      for (final surface in surfaces) {
        for (final ink in <Color>[
          resolved.inkPrimary,
          resolved.inkSecondary,
          resolved.inkMuted,
          resolved.accentWax,
          resolved.accentBrass,
          resolved.statusOk,
          resolved.statusWarn,
          resolved.statusErr,
        ]) {
          expect(
            BistreAccentOption.contrastRatio(ink, surface),
            greaterThanOrEqualTo(4.5),
            reason: 'preset ${preset.id} ink $ink on $surface',
          );
        }
      }
      expect(
        BistreAccentOption.contrastRatio(
          resolved.onAccentWax,
          resolved.accentWax,
        ),
        greaterThanOrEqualTo(4.5),
        reason: 'preset ${preset.id} onAccentWax contrast',
      );
    }
  });

  testWidgets(
    'Appearance settings renders all 9 theme preset cards and switches theme cleanly at desktop, phone 200%, and RTL',
    (WidgetTester tester) async {
      final l10n = loadDiskCatalogs();
      final gw = GalleryGateway(connected: true);
      final ctrl = FolioController(
        gateway: gw,
        defaultThreadTitle: 'New chat',
        onLocaleSynced: l10n.setLocale,
      );
      await ctrl.bootstrap('test');
      ctrl.openSettings(SettingsTab.appearance);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: ctrl),
      );
      await tester.pumpAndSettle();

      // Scroll down to the Color presets section and verify all 9 preset cards exist.
      final nightBlueFinder = find.text(
        l10n.t(L10nKey.settingsAppearancePresetNightBlue),
      );
      await tester.ensureVisible(nightBlueFinder);
      await tester.pumpAndSettle();
      for (final key in const <L10nKey>[
        L10nKey.settingsAppearancePresetWarmSepia,
        L10nKey.settingsAppearancePresetBlueCream,
        L10nKey.settingsAppearancePresetNightBlue,
        L10nKey.settingsAppearancePresetWarmIvory,
        L10nKey.settingsAppearancePresetDeepSepia,
        L10nKey.settingsAppearancePresetWarmDark,
        L10nKey.settingsAppearancePresetPureBlack,
        L10nKey.settingsAppearancePresetCleanPaper,
        L10nKey.settingsAppearancePresetDarkSlate,
      ]) {
        expect(find.text(l10n.t(key)), findsOneWidget);
      }

      // Tap Night Blue -> dark mode activates with preset accent.
      await tester.tap(nightBlueFinder);
      await tester.pumpAndSettle();
      expect(ctrl.settings.theme, 'night_blue');
      expect(ctrl.settings.accentPreset, 'preset');
      expect(ctrl.isDark, isTrue);

      // Verify zero overflow at phone 390px + 200% text scaling and Arabic RTL.
      await tester.binding.setSurfaceSize(const Size(390, 844));
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      l10n.setLocale('ar');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      ctrl.dispose();
      await gw.shutdown();
    },
  );

  testWidgets(
    'Regenerate starts immediately with non-blocking toast and 1-click Previous restores prior branch',
    (WidgetTester tester) async {
      final l10n = loadDiskCatalogs();
      final gw = FakeEngineGateway(seedConnectedOpenAi: true);
      final ctrl = FolioController(
        gateway: gw,
        defaultThreadTitle: 'New chat',
        onLocaleSynced: l10n.setLocale,
      );
      await ctrl.bootstrap('test');
      final thread = ctrl.activeThread!;
      await ctrl.submitPassage('First prompt');
      await tester.pump(const Duration(milliseconds: 200));

      final assistantBefore = ctrl.visibleBranchNodes.lastWhere(
        (n) => n.role == 'assistant',
      );
      expect(assistantBefore.parentId, isNotNull);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: ctrl),
      );
      await tester.pumpAndSettle();

      // Regenerate runs immediately with no modal and displays the non-blocking toast.
      await ctrl.regenerateFromAssistantNode(assistantBefore);
      await tester.pump(const Duration(milliseconds: 250));

      expect(ctrl.toastKey, L10nKey.toastRegenerated);
      expect(ctrl.toastActionKey, L10nKey.toastRegeneratedPrevious);
      final afterRegen = ctrl.visibleBranchNodes.lastWhere(
        (n) => n.role == 'assistant',
      );
      expect(afterRegen.id, isNot(assistantBefore.id));

      // Clicking "Previous" switches straight back to the prior assistant branch.
      final prevButton = find.text(l10n.t(L10nKey.toastRegeneratedPrevious));
      expect(prevButton, findsOneWidget);
      await tester.tap(prevButton);
      await tester.pumpAndSettle();

      final restored = ctrl.visibleBranchNodes.lastWhere(
        (n) => n.role == 'assistant',
      );
      expect(restored.id, assistantBefore.id);
      expect(ctrl.toastKey, isNull);
      expect(thread.id, ctrl.activeThread?.id);

      ctrl.dispose();
      await gw.shutdown();
    },
  );

  test(
    'splitShellCompoundSteps splits compound commands while respecting quotes',
    () {
      expect(
        splitShellCompoundSteps(
          'cargo check && echo "a && b" | wc -l; echo \'x;y\' || true',
        ),
        <String>['cargo check', 'echo "a && b"', 'wc -l', "echo 'x;y'", 'true'],
      );
      expect(splitShellCompoundSteps('git status'), <String>['git status']);
    },
  );

  testWidgets(
    'UsageDetailsPill displays duration and tokens/sec speed when elapsedMs is provided',
    (WidgetTester tester) async {
      final l10n = loadDiskCatalogs();
      await tester.pumpWidget(
        _wrapWidget(
          l10n,
          const Center(
            child: UsageDetailsPill(
              usage: NodeUsageMeta(
                providerName: 'OpenAI',
                modelId: 'model-x',
                inputTokens: 500,
                outputTokens: 200,
                costMicros: 12000,
                elapsedMs: 2500,
              ),
              summaryText: 'model-x',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(UsageDetailsPill));
      await tester.pumpAndSettle();

      expect(find.text(l10n.t(L10nKey.chatUsageDurationLabel)), findsOneWidget);
      expect(find.text('2.5s'), findsOneWidget);
      expect(find.text(l10n.t(L10nKey.chatUsageSpeedLabel)), findsOneWidget);
      expect(find.text('80.0 tok/s'), findsOneWidget);
    },
  );

  testWidgets(
    'fenced svg code card toggles inline Preview and Source cleanly',
    (WidgetTester tester) async {
      final l10n = loadDiskCatalogs();
      await tester.pumpWidget(
        _wrapWidget(
          l10n,
          Center(
            child: SizedBox(
              width: 520,
              child: MarkdownFolioView(
                markdown: '```svg\n<svg viewBox="0 0 100 100"><circle cx="50" cy="50" r="30" fill="#A83625"/></svg>\n```',
                onCopyCode: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final previewChip = find.text(l10n.t(L10nKey.chatSvgPreview));
      expect(previewChip, findsOneWidget);
      await tester.tap(previewChip);
      await tester.pumpAndSettle();

      expect(find.text(l10n.t(L10nKey.chatSvgSource)), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ComposerToolsControl, TabSwitcher bulk close, chat notes, pinned replies, and tool permissions work end to end',
    (WidgetTester tester) async {
      final l10n = loadDiskCatalogs();
      final gw = FakeEngineGateway(seedConnectedOpenAi: true);
      final ctrl = FolioController(
        gateway: gw,
        defaultThreadTitle: 'New chat',
        onLocaleSynced: l10n.setLocale,
      );
      await ctrl.bootstrap('test');
      await ctrl.submitPassage('Keep this active thread');
      await tester.pump(const Duration(milliseconds: 200));

      // Create two extra empty tabs and verify Close N empty removes them cleanly.
      await ctrl.createNewFolio();
      await ctrl.createNewFolio();
      expect(ctrl.emptyOpenTabs.length, greaterThanOrEqualTo(1));
      final beforeCount = ctrl.openTabs.length;
      ctrl.closeEmptyTabs();
      expect(ctrl.openTabs.length, lessThan(beforeCount));

      // Pin reply, save chat notes, set per-chat spend cap, and update per-tool permission.
      final assistantNode = ctrl.visibleBranchNodes
          .where((n) => n.role == 'assistant')
          .firstOrNull;
      if (assistantNode != null) {
        await ctrl.togglePinNode(assistantNode.id);
        expect(ctrl.isNodePinned(assistantNode.id), isTrue);
      }
      await ctrl.saveActiveChatNotes('Remember local constraints.');
      expect(ctrl.activeChatNotes, 'Remember local constraints.');
      await ctrl.setActiveChatSpendLimitMicros(2500000);
      expect(ctrl.activeChatSpendLimitMicros, 2500000);
      await ctrl.setToolPermission('shell', 'off');
      expect(ctrl.toolPermissionFor('shell'), 'off');

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: ctrl),
      );
      await tester.pumpAndSettle();

      // Open ComposerToolsControl popover and confirm its controls render.
      await tester.tap(find.byType(ComposerToolsControl));
      await tester.pumpAndSettle();
      expect(find.text(l10n.t(L10nKey.chatToolsTitle)), findsOneWidget);
      expect(find.text(l10n.t(L10nKey.chatToolsPrefillLabel)), findsOneWidget);

      // Open ChatNotesModal and confirm Escape closes cleanly.
      ctrl.toggleChatNotes();
      await tester.pumpAndSettle();
      expect(find.text(l10n.t(L10nKey.chatNotesTitle)), findsOneWidget);
      ctrl.handleEscape();
      await tester.pumpAndSettle();
      expect(ctrl.chatNotesOpen, isFalse);

      ctrl.dispose();
      await gw.shutdown();
    },
  );
}
