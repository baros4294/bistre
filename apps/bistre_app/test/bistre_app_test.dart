import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/design/math_font_gate.dart';
import 'package:bistre_app/features/chat/markdown_folio_view.dart';
import 'package:bistre_app/features/chat/reasoning_block.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';

BistreLocalizationController _loadDiskCatalogs() {
  final root = Directory('../../l10n/catalog').existsSync()
      ? Directory('../../l10n/catalog')
      : Directory('l10n/catalog');
  final catalogs = <String, BistreLocaleCatalog>{};
  for (final code in const <String>['en', 'vi', 'ar']) {
    final raw = File('${root.path}/$code.bistre-l10n.json').readAsStringSync();
    catalogs[code] = BistreLocaleCatalog.fromJsonString(raw);
  }
  return BistreLocalizationController(catalogs: catalogs);
}

double _relativeLuminance(Color c) {
  double lin(double channel) => channel <= 0.03928
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

double _contrastRatio(Color a, Color b) {
  final l1 = _relativeLuminance(a);
  final l2 = _relativeLuminance(b);
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('Day Parchment, Night Candlelight, and all 5 accent presets pass WCAG AA/AAA contrast ratios', () {
    for (final isDark in const <bool>[false, true]) {
      for (final preset in BistreAccentOption.presets) {
        final theme = BistreThemeData.resolve(
          isDark: isDark,
          accentPreset: preset.id,
        );
        expect(
          _contrastRatio(theme.onAccentWax, theme.accentWax),
          greaterThanOrEqualTo(4.5),
          reason: 'Failed onAccent contrast for ${preset.id} dark=$isDark',
        );
        for (final bg in <Color>[
          theme.bgCanvas,
          theme.bgSurface,
          theme.bgElevated,
        ]) {
          expect(
            _contrastRatio(theme.inkPrimary, bg),
            greaterThanOrEqualTo(7.0),
          );
          expect(
            _contrastRatio(theme.inkSecondary, bg),
            greaterThanOrEqualTo(7.0),
          );
          expect(_contrastRatio(theme.inkMuted, bg), greaterThanOrEqualTo(4.5));
          expect(_contrastRatio(theme.statusOk, bg), greaterThanOrEqualTo(4.5));
          expect(
            _contrastRatio(theme.statusErr, bg),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    }
  });

  test(
    'ICU plural evaluator handles English, Vietnamese, and Arabic CLDR rules',
    () {
      final l10n = _loadDiskCatalogs();
      expect(
        l10n.t(L10nKey.shellSearchResults, <String, Object?>{'count': 0}),
        'No matching messages',
      );
      expect(
        l10n.t(L10nKey.shellSearchResults, <String, Object?>{'count': 1}),
        '1 matching message',
      );
      l10n.setLocale('ar');
      expect(
        l10n.t(L10nKey.shellSearchResults, <String, Object?>{'count': 2}),
        'رسالتان مطابقتان',
      );
    },
  );

  testWidgets(
    'BistreApp shows single Add API Key CTA, opens Full-Window Settings, deletes providers freely, streams & branches DAG, supports Unlimited budget + OTA + RTL',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final l10n = _loadDiskCatalogs();
      final gateway = FakeEngineGateway();
      final controller = FolioController(
        gateway: gateway,
        defaultThreadTitle: l10n.t(L10nKey.shellThreadDefaultTitle),
        onLocaleSynced: l10n.setLocale,
        isDevEnvironment: true,
      );
      await controller.bootstrap('memory');

      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: controller),
      );
      await tester.pumpAndSettle();

      // Strictly ONE "Add API Key" button when unconfigured (zero duplicates in header or sidebar!).
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Connect an AI provider'), findsOneWidget);
      expect(find.text('Add API Key'), findsOneWidget);

      // Tap Add API Key -> Full-Window Settings Workspace on Providers & Keys.
      await tester.tap(find.text('Add API Key'));
      await tester.pumpAndSettle();
      expect(find.text('Back to chat'), findsOneWidget);
      expect(find.text('OpenAI'), findsWidgets);
      expect(find.text('Google Gemini'), findsOneWidget);
      expect(find.text('Anthropic'), findsOneWidget);

      // Save API key + load live models + pick gpt-4.1.
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('provider_api_key_input')),
          matching: find.byType(EditableText),
        ),
        'sk-test-demo-key-9988',
      );
      await tester.tap(find.text('Save key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load models'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('gpt-4.1'));
      await tester.tap(find.text('gpt-4.1'));
      await tester.pumpAndSettle();

      // Built-in Anthropic can be freely deleted with 2 clicks!
      await tester.tap(find.text('Anthropic'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Delete provider'));
      await tester.tap(find.text('Delete provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Click again to delete'));
      await tester.pumpAndSettle();
      expect(find.text('Anthropic'), findsNothing);

      // Verify Unlimited budget toggle in Safety & Budget tab.
      controller.setSettingsTab(SettingsTab.trust);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BistreSwitch).first);
      await tester.pumpAndSettle();
      expect(find.text('Unlimited'), findsOneWidget);

      // Verify real OTA Check for updates flow in Updates & Storage tab.
      controller.setSettingsTab(SettingsTab.updates);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(find.text('Update available: v0.2.0'), findsOneWidget);
      expect(find.text('Ed25519 signature verified'), findsOneWidget);

      // Return cleanly to chat with Escape.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Submit a Vietnamese/Arabic message and verify streaming reply + fenced code + token metrics.
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('composer_input')),
          matching: find.byType(EditableText),
        ),
        'Xin chào từ Bistre — مرحبا',
      );
      await tester.pump();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Reply draft #1'), findsOneWidget);
      expect(find.text('fn main() {}'), findsOneWidget);

      // Regenerate assistant reply -> 2 / 2 switcher -> navigate back to 1 / 2.
      await tester.tap(find.bySemanticsLabel('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Reply draft #2'), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Previous version'));
      await tester.pumpAndSettle();
      expect(find.text('Reply draft #1'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);

      // Chat parameters moved from the header to the command palette (Parchment v2.6.0
      // header); open and close the drawer the way the palette entry does.
      controller.toggleInspector();
      await tester.pumpAndSettle();
      expect(find.text('Export Markdown'), findsOneWidget);
      controller.toggleInspector();
      await tester.pumpAndSettle();

      // Open Command Menu via Ctrl+K and dismiss via Escape.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('Quick actions'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Switch to Language tab -> VI -> AR (RTL) + hot-load French pack.
      controller.openSettings(SettingsTab.language);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tiếng Việt'));
      await tester.pumpAndSettle();
      expect(find.text('Quay lại trò chuyện'), findsOneWidget);

      await tester.tap(find.text('العربية'));
      await tester.pumpAndSettle();
      expect(find.text('العودة إلى المحادثة'), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.text('العودة إلى المحادثة'))),
        TextDirection.rtl,
      );

      final hotPack = jsonEncode(<String, Object?>{
        'locale': 'fr',
        'direction': 'ltr',
        'entries': <String, Object?>{
          'settings.back_to_chat': <String, Object?>{'message': 'Retour'},
          'app.title': <String, Object?>{'message': 'Bistre'},
        },
      });
      l10n.applyHotLocalePack(hotPack);
      await tester.pump();
      expect(find.text('Retour'), findsOneWidget);

      controller.closeSettings();
      await tester.pump(const Duration(seconds: 3));

      controller.dispose();
      await gateway.shutdown();
    },
  );

  testWidgets(
    'BistreMotion.overlayDuration honors MediaQuery reduceMotion, disableAnimations, and user override',
    (WidgetTester tester) async {
      late Duration defaultDuration;
      late Duration reducedDuration;
      late Duration disabledDuration;
      late Duration overrideDuration;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Builder(
            builder: (context) {
              defaultDuration = BistreMotion.overlayDuration(context);
              overrideDuration = BistreMotion.overlayDuration(
                context,
                reduceMotionOverride: true,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(defaultDuration, const Duration(milliseconds: 160));
      expect(overrideDuration, Duration.zero);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(reduceMotion: true),
          child: Builder(
            builder: (context) {
              reducedDuration = BistreMotion.overlayDuration(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(reducedDuration, Duration.zero);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              disabledDuration = BistreMotion.overlayDuration(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(disabledDuration, Duration.zero);
    },
  );

  testWidgets(
    'ParchmentScaffold preserves physical left/right cutout padding in RTL mode',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const BistreTheme(
          data: BistreThemeData.dayParchment,
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: MediaQuery(
              data: MediaQueryData(
                padding: EdgeInsets.fromLTRB(44, 12, 16, 20),
              ),
              child: ParchmentScaffold(
                header: SizedBox(height: 10),
                body: SizedBox.expand(),
                footer: SizedBox(height: 10),
              ),
            ),
          ),
        ),
      );

      final paddingWidget = tester.widget<Padding>(find.byType(Padding).first);
      final resolved = paddingWidget.padding.resolve(TextDirection.rtl);
      expect(resolved.left, 44);
      expect(resolved.right, 16);
      expect(resolved.top, 12);
      expect(resolved.bottom, 20);
    },
  );

  test('FolioController extracts diag.* keys safely and converts micro-USD without floats', () {
    expect(
      FolioController.extractDiagnosticKey(
        'AnyhowException(diag.provider.not_configured)',
      ),
      'diag.provider.not_configured',
    );
    expect(
      FolioController.extractDiagnosticKey('Unexpected stack trace'),
      'diag.internal.error',
    );
    expect(FolioController.formatMicrosUsd(0), r'$0.00');
    expect(FolioController.formatMicrosUsd(5000000), r'$5.00');
    expect(FolioController.formatMicrosUsd(12340000), r'$12.34');
    expect(FolioController.parseUsdToMicros('12.50'), 12500000);
    expect(FolioController.parseUsdToMicros(r'$0.75'), 750000);
  });

  testWidgets(
    'Wave B ReasoningBlock, ToolTimelineView diff+approval+rewind, and Agent Settings render cleanly',
    (WidgetTester tester) async {
      final l10n = _loadDiskCatalogs();
      String? quoted;
      String? rewoundCp;
      String? approvedId;

      await tester.pumpWidget(
        BistreLocalizations(
          controller: l10n,
          child: BistreTheme(
            data: BistreThemeData.dayParchment,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ReasoningBlock(
                      thinkingText: 'Step 1: Verify blake3 hash anchor.',
                      durationMs: 3800,
                      onQuoteIntoComposer: (t) => quoted = t,
                    ),
                    ToolTimelineView(
                      entries: const <ToolActivityEntry>[
                        ToolActivityEntry(
                          id: 't1',
                          toolName: 'edit',
                          summary: 'edited src/lib.rs',
                          status: 'completed',
                          diffText: '@@ -1,1 +1,1 @@\n-old\n+new\n',
                          checkpointId: 'cp-1',
                          durationMs: 42,
                        ),
                        ToolActivityEntry(
                          id: 't2',
                          toolName: 'shell',
                          summary: 'cargo test',
                          status: 'awaiting_approval',
                        ),
                      ],
                      onRewindCheckpoint: (cp) => rewoundCp = cp,
                      onApproveOnce: (id) => approvedId = id,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand thinking drawer and quote into composer.
      await tester.tap(find.textContaining('3.8s'));
      await tester.pumpAndSettle();
      expect(find.textContaining('blake3'), findsOneWidget);
      await tester.tap(find.text(l10n.t(L10nKey.chatQuoteThinking)));
      expect(quoted, 'Step 1: Verify blake3 hash anchor.');

      // Rewind checkpoint and approve Tier-2 tool call.
      await tester.tap(find.text(l10n.t(L10nKey.toolRewind)));
      expect(rewoundCp, 'cp-1');
      await tester.tap(find.text(l10n.t(L10nKey.toolApproveOnce)));
      expect(approvedId, 't2');
    },
  );

  testWidgets(
    'Wave C GFM Tables, NotoSansMath LaTeX, and Mermaid CustomPainter render cleanly with copy actions',
    (WidgetTester tester) async {
      // The math face registers lazily in production; register it from disk up front so its
      // font-change relayout never lands after this test tears the tree down.
      await tester.runAsync(() async {
        await MathFontGate.ensureLoaded(
          source: Future<ByteData>.value(
            ByteData.sublistView(
              File('assets/fonts/NotoSansMath-Regular.ttf').readAsBytesSync(),
            ),
          ),
        );
        // Let the engine's `fontsChange` system message arrive before any frame is pumped.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      final l10n = _loadDiskCatalogs();
      String? lastCopied;
      const sampleMarkdown = r'''
## Architecture Summary

Inline math $\alpha + \beta = \gamma$ works seamlessly.

$$
\frac{a + b}{\sqrt{c^2 + 1}}
$$

| Layer | Runtime | Footprint |
| :--- | :---: | ---: |
| UI | Pure Widgets | 10 primitives |
| Core | Pure Rust | 30 MB |

```mermaid
flowchart LR
  UI[Sepia UI] --> Core[Rust Core]
  Core --> DB[SQLite WAL]
```
''';

      await tester.pumpWidget(
        BistreLocalizations(
          controller: l10n,
          child: BistreTheme(
            data: BistreThemeData.dayParchment,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SingleChildScrollView(
                child: MarkdownFolioView(
                  markdown: sampleMarkdown,
                  onCopyCode: (v) => lastCopied = v,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Architecture Summary'), findsOneWidget);
      expect(find.text('Pure Rust'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);

      // Copy CSV from GFM Table.
      await tester.tap(find.text(l10n.t(L10nKey.chatTableCopyCsv)));
      await tester.pump();
      expect(lastCopied, contains('Layer,Runtime,Footprint'));
      expect(lastCopied, contains('Core,Pure Rust,30 MB'));
      await tester.pump(const Duration(milliseconds: 1500));
    },
  );

  testWidgets(
    'Wave E Writing & Roleplay Studio renders Story Bible, Prompt Inspector Cache Boundary, Roleplay Controls, and Manuscript Beats canvas',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1360, 860);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final l10n = _loadDiskCatalogs();
      final gateway = FakeEngineGateway();
      await gateway.upsertCharacterCard(
        const EngineCharacterCard(
          name: 'Lyra Vance',
          description: 'Archivist of the Sunken Library.',
          firstMessage:
              '*She sets the brass lantern down.* "You brought the key."',
          alternateGreetings: <String>[
            '*Rain taps the stained glass.* "We are out of time."',
          ],
        ),
      );
      await gateway.upsertStoryEntry(
        const EngineStoryEntry(
          name: 'Sunken Library',
          category: 'location',
          keys: <String>['library', 'archive'],
          content: 'Flooded marble vaults beneath the harbor.',
        ),
      );

      final controller = FolioController(
        gateway: gateway,
        defaultThreadTitle: l10n.t(L10nKey.shellThreadDefaultTitle),
        onLocaleSynced: l10n.setLocale,
      );
      await controller.bootstrap('memory');
      await controller.setActiveThreadMode('write');
      await controller.addStoryChapter('Chapter I · The Lantern');
      final chId = controller.storyChapters.first.id;
      await controller.addStoryScene(chId, 'Harbor Descent');

      await tester.pumpWidget(
        BistreApp(l10nController: l10n, folioController: controller),
      );
      await tester.pumpAndSettle();

      // Roleplay Controls bar shows View toggle, Continue, Impersonate, and Turn-0 Alt-Greeting 1 / 2.
      expect(find.text(l10n.t(L10nKey.storyViewManuscript)), findsOneWidget);
      expect(find.text(l10n.t(L10nKey.storyActionImpersonate)), findsOneWidget);
      expect(
        find.text(
          l10n.t(L10nKey.storyAltGreeting, <String, Object?>{
            'current': 1,
            'total': 2,
          }),
        ),
        findsOneWidget,
      );

      // Open Studio Pane -> Story Bible tab & verify Character + Lorebook entries render.
      controller.setStudioTab(StudioTab.story);
      await tester.pumpAndSettle();
      expect(find.text('Lyra Vance'), findsWidgets);
      expect(find.text('Sunken Library'), findsOneWidget);

      // Switch to Prompt Inspector tab & verify Cache Boundary + Lorebook Trace render.
      controller.setStudioTab(StudioTab.prompt);
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.t(L10nKey.storyInspectorCacheBoundary)),
        findsOneWidget,
      );
      expect(find.text('Iron Citadel'), findsOneWidget);

      // Switch to Manuscript view & verify Chapter, Scene, Beats, and Laser Rewrite Tools render.
      controller.toggleManuscriptView(true);
      await tester.pumpAndSettle();
      expect(find.text('Harbor Descent'), findsWidgets);
      expect(find.text(l10n.t(L10nKey.storyGenerateProse)), findsOneWidget);
      expect(find.text(l10n.t(L10nKey.storyLaserPolish)), findsOneWidget);

      controller.dispose();
    },
  );
}
