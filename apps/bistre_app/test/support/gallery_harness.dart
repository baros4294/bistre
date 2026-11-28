/// Shared deterministic gallery harness (`just ui-gallery`): bundled OFL fonts, on-disk ICU
/// catalogs, high-DPI PNG capture, and a seeded in-memory engine gateway.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bistre_app/bridge/bistre_engine.dart';

import 'package:bistre_app/design/math_font_gate.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_context.dart';
import 'gallery_gateway_extras.dart';

export 'fake_context.dart' show kTestDialectDescriptors;

part 'gallery_gateway_story.dart';

/// Loads the real bundled OFL fonts (`Inter`, `JetBrainsMono`, `NotoSansMath`) and an Arabic
/// fallback, so gallery captures (`just ui-gallery`, `gallery_scenes.dart`) render like the app.
Future<void> loadBundledFonts() async {
  final fontRoot = Directory('assets/fonts').existsSync()
      ? Directory('assets/fonts')
      : Directory('apps/bistre_app/assets/fonts');

  Future<void> loadFamily(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final name in files) {
      final bytes = File('${fontRoot.path}/$name').readAsBytesSync();
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  await loadFamily('Inter', const <String>[
    'inter-regular.ttf',
    'inter-medium.ttf',
    'inter-semibold.ttf',
    'inter-bold.ttf',
  ]);
  await loadFamily('JetBrainsMono', const <String>[
    'jetbrains-mono-regular.ttf',
    'jetbrains-mono-medium.ttf',
  ]);
  final mathBytes = File('${fontRoot.path}/noto-sans-math-regular.ttf')
      .readAsBytesSync();
  await MathFontGate.ensureLoaded(
    source: Future<ByteData>.value(ByteData.sublistView(mathBytes)),
  );

  var arabicLoaded = false;
  for (final candidate in const <String>[
    r'C:\Windows\Fonts\segoeui.ttf',
    r'C:\Windows\Fonts\tahoma.ttf',
    '/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf',
  ]) {
    final f = File(candidate);
    if (f.existsSync()) {
      final loader = FontLoader('BistreArabicFallback');
      final bytes = f.readAsBytesSync();
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      arabicLoaded = true;
      break;
    }
  }
  // Baselines must never record missing-glyph boxes (Linux CI installs `fonts-noto-core`).
  if (_compareGoldens && !arabicLoaded) {
    throw StateError('no Arabic fallback font for the gallery goldens');
  }
}

BistreLocalizationController loadDiskCatalogs() {
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

/// `BISTRE_GOLDENS=compare` (Linux CI only, Spec 08 §4): every capture must equal its committed
/// baseline in `test/goldens/linux/` byte for byte. The same renderer and bundled fonts give
/// identical PNGs there, so any difference is a visual change to review. Elsewhere captures are
/// only written to `build/ui_gallery/` for review.
final bool _compareGoldens =
    Platform.isLinux && Platform.environment['BISTRE_GOLDENS'] == 'compare';

Future<void> capturePng(
  WidgetTester tester,
  GlobalKey boundaryKey,
  Directory outDir,
  String fileName, {
  bool settle = true,
}) async {
  Uint8List? captured;
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // Live states (a streaming reply, a pulsing run dot) animate forever: a fixed frame
    // budget keeps the capture deterministic.
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }
  await tester.runAsync(() async {
    final renderObject =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await renderObject.toImage(pixelRatio: 1.5);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (byteData != null) {
      captured = byteData.buffer.asUint8List();
      final target = File('${outDir.path}/$fileName');
      // Skip redundant overwrites and replace via temp rename so Windows AV/indexer memory maps
      // on an existing PNG never fail `CreateFile` with ERROR_USER_MAPPED_FILE (errno 1224).
      final unchanged =
          target.existsSync() && listEquals(target.readAsBytesSync(), captured);
      if (!unchanged) {
        final tmp = File('${outDir.path}/.$fileName.$pid.tmp');
        tmp.writeAsBytesSync(captured!);
        tmp.renameSync(target.path);
      }
    }
  });
  final bytes = captured;
  expect(bytes, isNotNull, reason: 'could not encode $fileName');
  if (!_compareGoldens || bytes == null) return;
  // Mismatches are collected and reported once at teardown, so one difference never stops the
  // remaining captures and CI always uploads the full set for review.
  if (!_goldenCheckRegistered) {
    _goldenCheckRegistered = true;
    addTearDown(() {
      _goldenCheckRegistered = false;
      final problems = List<String>.of(_goldenProblems);
      _goldenProblems.clear();
      expect(
        problems,
        isEmpty,
        reason:
            '${problems.join('\n')}\nReview the ui-gallery-linux artifact; commit or replace '
            'baselines in apps/bistre_app/test/goldens/linux/ only for intended changes.',
      );
    });
  }
  final golden = File('test/goldens/linux/$fileName');
  if (!golden.existsSync()) {
    _goldenProblems.add('no Linux baseline for $fileName');
  } else if (!listEquals(golden.readAsBytesSync(), bytes)) {
    _goldenProblems.add('$fileName differs from its Linux baseline');
  }
}

/// Golden mismatches of the running test (see [capturePng]).
final List<String> _goldenProblems = <String>[];
bool _goldenCheckRegistered = false;

/// Fixed gallery instant, so day-relative UI (sidebar groups, dates) never drifts with the
/// wall clock and Linux baselines stay byte-identical (CI10).
/// Boots a [FolioController] on a connected [GalleryGateway] with the disk catalogs.
Future<(FolioController, GalleryGateway, BistreLocalizationController)>
bootGalleryController() async {
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

DateTime galleryClock() => DateTime(2026, 3, 14, 10, 30);

class GalleryGateway
    with GalleryGatewayExtras, _GalleryRunsAndStory
    implements BistreEngineGateway {
  GalleryGateway({required bool connected, bool seedConversation = true}) {
    final nowMs = galleryClock().millisecondsSinceEpoch;
    _providers.addAll(<EngineProvider>[
      EngineProvider(
        id: 'openai',
        name: 'OpenAI',
        dialect: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        defaultModel: connected ? 'gpt-4.1' : '',
        keyHint: connected ? '••••8a4f' : '',
        hasApiKey: connected,
        isEnabled: true,
        isBuiltin: true,
        useServerStateCache: false,
        iconSlug: 'openai',
        createdAtMs: 1,
        updatedAtMs: 1,
      ),
      EngineProvider(
        id: 'google_gemini',
        name: 'Google Gemini',
        dialect: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        defaultModel: connected ? 'gemini-2.5-pro' : '',
        keyHint: connected ? '••••9c2d' : '',
        hasApiKey: connected,
        isEnabled: true,
        isBuiltin: true,
        useServerStateCache: false,
        iconSlug: 'gemini',
        createdAtMs: 2,
        updatedAtMs: 2,
      ),
      const EngineProvider(
        id: 'anthropic',
        name: 'Anthropic',
        dialect: 'anthropic',
        baseUrl: 'https://api.anthropic.com/v1',
        defaultModel: 'claude-sonnet-4-5',
        keyHint: '',
        hasApiKey: false,
        isEnabled: true,
        isBuiltin: true,
        useServerStateCache: false,
        iconSlug: 'claude',
        createdAtMs: 3,
        updatedAtMs: 3,
      ),
      if (connected)
        const EngineProvider(
          id: 'deepseek',
          name: 'DeepSeek',
          dialect: 'custom_openai',
          baseUrl: 'https://api.deepseek.com/v1',
          defaultModel: 'deepseek-reasoner',
          keyHint: '••••ds01',
          hasApiKey: true,
          isEnabled: true,
          isBuiltin: false,
          useServerStateCache: false,
          iconSlug: 'deepseek',
          createdAtMs: 4,
          updatedAtMs: 4,
        ),
    ]);
    _assistants.add(
      const EngineAssistant(
        id: 'default_assistant',
        name: 'Default',
        roleSubtitle: 'General local-first assistant',
        systemPrompt: '',
        defaultMode: 'chat',
        badgeCode: 'DF',
        isBuiltin: true,
        createdAtMs: 1,
      ),
    );
    if (connected) {
      _assistants.add(
        const EngineAssistant(
          id: 'custom_rust',
          name: 'Rust Architect',
          roleSubtitle: 'Systems architecture & perf review',
          systemPrompt: 'Review Rust and Dart changes with strict soundness and zero-allocation discipline.',
          defaultMode: 'chat',
          badgeCode: 'RA',
          iconSlug: 'claude',
          defaultProviderId: 'openai',
          defaultModelId: 'gpt-4.1',
          temperatureMilli: 300,
          maxOutputTokens: 4096,
          isBuiltin: false,
          createdAtMs: 2,
        ),
      );
      _settings = const EngineSettings(
        theme: 'day',
        activeProviderId: 'openai',
        activeModelId: 'gpt-4.1',
        walletDailyCeilingMicros: null,
        otaFeedUrl: 'https://releases.bistre.dev/stable/manifest.json',
      );
      if (seedConversation) {
        _threads.addAll(<EngineThread>[
          EngineThread(
            id: 't-1',
            workspaceId: 'ws',
            title: 'Refactor SQLite WAL actor',
            mode: 'chat',
            assistantId: 'custom_rust',
            isPinned: true,
            temperatureMilli: 400,
            maxOutputTokens: 4096,
            createdAtMs: nowMs - 600000,
            updatedAtMs: nowMs - 60000,
          ),
          EngineThread(
            id: 't-2',
            workspaceId: 'ws',
            title: 'Q4 product roadmap notes',
            mode: 'chat',
            createdAtMs: nowMs - 90000000,
            updatedAtMs: nowMs - 86400000,
          ),
          EngineThread(
            id: 't-3',
            workspaceId: 'ws',
            title: 'Vietnamese & Arabic UI review',
            mode: 'chat',
            createdAtMs: nowMs - 400000000,
            updatedAtMs: nowMs - 345600000,
          ),
          EngineThread(
            id: 't-rich',
            workspaceId: 'ws',
            title: 'Architecture & Benchmark Report',
            mode: 'code',
            createdAtMs: nowMs - 450000000,
            updatedAtMs: nowMs - 400000000,
          ),
          EngineThread(
            id: 't-write',
            workspaceId: 'ws',
            title: 'The Sunken Library',
            mode: 'write',
            createdAtMs: nowMs - 500000000,
            updatedAtMs: nowMs - 450000000,
          ),
        ]);
        _nodes.addAll(<EngineNode>[
          EngineNode(
            id: 'n-1',
            threadId: 't-1',
            role: 'user',
            content: 'How should we keep SQLite WAL checkpoints fast without blocking UI reads?',
            createdAtMs: nowMs - 500000,
          ),
          EngineNode(
            id: 'n-2a',
            threadId: 't-1',
            parentId: 'n-1',
            role: 'assistant',
            content: 'Keep one dedicated writer thread behind a bounded channel and open short-lived read connections.',
            createdAtMs: nowMs - 400000,
            providerMetaJson: jsonEncode(<String, Object?>{
              'model_id': 'gpt-4.1',
              'provider_name': 'OpenAI',
              'icon_slug': 'openai',
              'input_tokens': 312,
              'output_tokens': 96,
              'cost_micros': 1420,
            }),
          ),
          EngineNode(
            id: 'n-2b',
            threadId: 't-1',
            parentId: 'n-1',
            role: 'assistant',
            content:
                '## Clean Single-Writer WAL Pattern\n\n'
                'Isolating writes on one actor thread eliminates write-write `SQLITE_BUSY` while readers run concurrently:\n\n'
                '- **Writer**: One thread owning the `READ_WRITE` handle with `PRAGMA synchronous = NORMAL`.\n'
                '- **Readers**: Short-lived read-only connections dropped immediately so `wal_checkpoint(TRUNCATE)` never stalls.\n\n'
                '```rust\n'
                'pub fn checkpoint_truncate(conn: &Connection) -> Result<i64> {\n'
                '    conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| r.get(0))\n'
                '}\n'
                '```\n\n'
                '> Tip: Switch between versions using the `< 2 / 2 >` arrows above, or click **Reply** to quote this block.',
            createdAtMs: nowMs - 300000,
            providerMetaJson: jsonEncode(<String, Object?>{
              'model_id': 'gemini-2.5-pro',
              'provider_name': 'Google Gemini',
              'icon_slug': 'gemini',
              'input_tokens': 418,
              'output_tokens': 246,
              'cost_micros': 3180,
              'thinking_text': 'Checking WAL reader starvation edge cases:\n1. Dedicated single-writer thread avoids write-write SQLITE_BUSY.\n2. Dropping short-lived reader handles unblocks wal_checkpoint(TRUNCATE).',
              'thinking_duration_ms': 2400,
            }),
          ),
          EngineNode(
            id: 'n-rich-1',
            threadId: 't-rich',
            role: 'user',
            content: 'Summarize Bistre layer footprints with an equation and architecture flow.',
            createdAtMs: nowMs - 440000000,
          ),
          EngineNode(
            id: 'n-rich-2',
            threadId: 't-rich',
            parentId: 'n-rich-1',
            role: 'assistant',
            content: r'''
## Pure-Widgets & Rust Core Budgets

Frame budget scales cleanly with token throughput $\tau$ and batching interval $\Delta t = 16\text{ms}$:

$$
T_{\text{frame}} = \frac{C_{\text{layout}} + C_{\text{paint}}}{\sqrt{N_{\text{slivers}}}}
$$

| Layer | Implementation | Budget |
| :--- | :---: | ---: |
| UI Shell | Pure Widgets | 10 primitives |
| Daemon | Rust Tokio | <= 30 MB |
| Storage | SQLite WAL | p95 <= 15 ms |

```mermaid
flowchart LR
  UI[Sepia UI] --> FFI[FRB v2 16ms]
  FFI --> Core[Rust Core]
  Core --> DB[SQLite WAL]
```
''',
            createdAtMs: nowMs - 430000000,
            providerMetaJson: jsonEncode(<String, Object?>{
              'model_id': 'gpt-4.1',
              'provider_name': 'OpenAI',
              'icon_slug': 'openai',
              'input_tokens': 510,
              'output_tokens': 312,
              'cost_micros': 2480,
            }),
          ),
          EngineNode(
            id: 'n-write-1',
            threadId: 't-write',
            role: 'user',
            content: '*Avery sets the salt-crusted brass case beside the lantern.* "Rowan left this at the third bollard. Does the inner ring match Lock 7?"',
            createdAtMs: nowMs - 490000000,
          ),
          EngineNode(
            id: 'n-write-2',
            threadId: 't-write',
            parentId: 'n-write-1',
            role: 'assistant',
            content:
                '*Lyra turns the copperplate ring toward the warm lantern glow, tracing the stamped Roman numerals with her thumb.*\n\n'
                '"Not Lock 7," *she murmurs, glancing toward the dark breakwater steps.* "Look at the tide notch: Rowan shifted the bearing two leagues east. If we reach the outer floodgate before slack water, the reading room will still be dry."',
            createdAtMs: nowMs - 480000000,
            providerMetaJson: jsonEncode(<String, Object?>{
              'model_id': 'claude-sonnet-4',
              'provider_name': 'Anthropic',
              'icon_slug': 'claude',
              'input_tokens': 690,
              'output_tokens': 190,
              'cost_micros': 3900,
            }),
          ),
        ]);
      }
    } else {
      _settings = const EngineSettings(theme: 'day');
    }
  }

  final List<EngineProvider> _providers = <EngineProvider>[];
  final List<EngineAssistant> _assistants = <EngineAssistant>[];
  final List<EngineThread> _threads = <EngineThread>[];
  final List<EngineNode> _nodes = <EngineNode>[];
  final Map<String, String> _drafts = <String, String>{};
  EngineSettings _settings = const EngineSettings();
  final StreamController<BistreEvent> _events =
      StreamController<BistreEvent>.broadcast();

  @override
  Future<EngineHealth> init(String dataDir) async {
    if (failInitTimes > 0) {
      failInitTimes--;
      throw StateError('diag.storage.unavailable');
    }
    return getHealth();
  }

  /// Number of upcoming `init` calls that fail (boot-failure tests).
  int failInitTimes = 0;

  @override
  Future<EngineHealth> getHealth() async => EngineHealth(
    coreVersion: '0.1.0',
    schemaVersion: 5,
    walModeActive: true,
    threadCount: _threads.length,
    nodeCount: _nodes.length,
    activeRuns: 0,
    statusKey: 'diag.ok',
  );

  @override
  Future<List<EngineProvider>> listProviders() async => _providers;

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
  }) async => _providers.firstWhere((p) => p.id == providerId);

  @override
  Future<EngineProvider> setProviderApiKey({
    required String providerId,
    required String apiKey,
  }) async => _providers.firstWhere((p) => p.id == providerId);

  @override
  Future<EngineProvider> clearProviderApiKey(String providerId) async =>
      _providers.firstWhere((p) => p.id == providerId);

  @override
  Future<EngineProvider> createProvider({
    required String name,
    required String dialect,
    required String baseUrl,
    required String defaultModel,
    required String iconSlug,
    String customIconPath = '',
    String? apiKey,
  }) async => _providers.first;

  @override
  Future<EngineProvider> createCustomProvider({
    required String name,
    required String baseUrl,
    required String defaultModel,
    String? apiKey,
  }) async => _providers.first;

  @override
  Future<void> deleteProvider(String providerId) async {}

  @override
  Future<List<EngineProviderModel>> fetchProviderModels(
    String providerId,
  ) async => const <EngineProviderModel>[
    EngineProviderModel(id: 'gpt-4.1', displayName: 'GPT-4.1'),
    EngineProviderModel(id: 'gpt-4.1-mini', displayName: 'GPT-4.1 mini'),
    EngineProviderModel(id: 'o4-mini', displayName: 'o4-mini'),
  ];

  @override
  Future<List<EngineAssistant>> listAssistants() async => _assistants;

  @override
  Future<EngineAssistant> createAssistant({
    required String name,
    required String roleSubtitle,
    required String systemPrompt,
    required String defaultMode,
    required String badgeCode,
  }) async => _assistants.first;

  @override
  Future<EngineAssistant> updateAssistant({
    required String assistantId,
    String? name,
    String? roleSubtitle,
    String? systemPrompt,
    String? defaultMode,
    String? badgeCode,
    String? iconSlug,
    String? defaultProviderId,
    String? defaultModelId,
    int? temperatureMilli,
    bool clearTemperature = false,
    int? maxOutputTokens,
    bool clearMaxOutputTokens = false,
    int? topPMilli,
    bool clearTopP = false,
  }) async => _assistants.firstWhere((a) => a.id == assistantId);

  @override
  Future<void> deleteAssistant(String assistantId) async {}

  @override
  Future<EngineThread> createThread(
    String title,
    String mode, {
    String? topic,
    String? assistantId,
    String? projectId,
  }) async {
    final t = EngineThread(
      id: 't-${_threads.length + 1}',
      workspaceId: projectId ?? 'ws',
      title: title,
      mode: mode,
      topic: topic ?? 'general',
      assistantId: assistantId ?? 'default_assistant',
      createdAtMs: galleryClock().millisecondsSinceEpoch,
      updatedAtMs: galleryClock().millisecondsSinceEpoch,
    );
    _threads.add(t);
    return t;
  }

  @override
  Future<EngineThread> updateThread({
    required String threadId,
    String? title,
    bool? isPinned,
    String? topic,
    String? mode,
    String? assistantId,
    String? providerIdOverride,
    bool clearProviderOverride = false,
    String? modelIdOverride,
    bool clearModelOverride = false,
    String? systemPromptOverride,
    bool clearSystemPromptOverride = false,
    int? temperatureMilli,
    bool clearTemperature = false,
    int? maxOutputTokens,
    bool clearMaxOutputTokens = false,
    int? topPMilli,
    bool clearTopP = false,
  }) async {
    final idx = _threads.indexWhere((t) => t.id == threadId);
    final old = _threads[idx];
    final next = EngineThread(
      id: old.id,
      workspaceId: old.workspaceId,
      title: title ?? old.title,
      mode: mode ?? old.mode,
      topic: topic ?? old.topic,
      assistantId: assistantId ?? old.assistantId,
      isPinned: isPinned ?? old.isPinned,
      activeHeadNodeId: old.activeHeadNodeId,
      providerIdOverride: clearProviderOverride
          ? null
          : (providerIdOverride ?? old.providerIdOverride),
      modelIdOverride: clearModelOverride
          ? null
          : (modelIdOverride ?? old.modelIdOverride),
      systemPromptOverride: clearSystemPromptOverride
          ? null
          : (systemPromptOverride ?? old.systemPromptOverride),
      temperatureMilli: clearTemperature
          ? null
          : (temperatureMilli ?? old.temperatureMilli),
      maxOutputTokens: clearMaxOutputTokens
          ? null
          : (maxOutputTokens ?? old.maxOutputTokens),
      topPMilli: clearTopP ? null : (topPMilli ?? old.topPMilli),
      createdAtMs: old.createdAtMs,
      updatedAtMs: old.updatedAtMs,
    );
    _threads[idx] = next;
    return next;
  }

  @override
  Future<void> deleteThread(String threadId) async {
    deletedThreadIds.add(threadId);
  }

  /// Thread ids whose delete reached the engine (tests of the Undo window).
  final List<String> deletedThreadIds = <String>[];

  /// Artificial `listNodes` latency per thread id (thread-switch race tests).
  final Map<String, Duration> listNodesDelays = <String, Duration>{};

  @override
  Future<List<EngineThread>> listThreads() async =>
      List<EngineThread>.of(_threads);

  @override
  Future<void> moveThreadToProject(String threadId, String? projectId) async {
    final at = _threads.indexWhere((t) => t.id == threadId);
    if (at >= 0) _threads[at] = _threads[at].withWorkspace(projectId ?? 'ws');
  }

  /// A project with a folder, instructions, and a hooks file, holding the write chat and
  /// `t-3`; the other chats stay outside it.
  void seedProject() {
    projects.add(
      const EngineProject(
        id: 'p-novel',
        name: 'Harbor novel',
        folderPath: '/books/harbor-novel',
        instructions: 'Keep the narration in past tense. Lyra never learns the ring\'s origin before chapter 9.',
      ),
    );
    for (final id in <String>['t-write', 't-3']) {
      final at = _threads.indexWhere((t) => t.id == id);
      _threads[at] = _threads[at].withWorkspace('p-novel');
    }
    workspaceHooks = const EngineWorkspaceHooksStatus(
      hooks: <EngineWorkspaceHook>[
        EngineWorkspaceHook(
          event: 'post_tool_use',
          command: 'dart format manuscript/',
          toolFilter: 'edit',
        ),
      ],
      digest: 'gallery',
      approved: false,
    );
  }

  @override
  Future<EngineNode> appendNode({
    required String threadId,
    String? parentId,
    required String role,
    required String content,
  }) async => _nodes.first;

  @override
  Future<EngineNode> sendAndStreamReply({
    required String threadId,
    String? parentId,
    required String userContent,
  }) async => _nodes.first;

  @override
  Future<EngineNode> editUserNodeAndStream({
    required String threadId,
    required String nodeId,
    required String newContent,
  }) async => _nodes.first;

  @override
  Future<void> deleteNode({
    required String threadId,
    required String nodeId,
  }) async {}

  @override
  Future<EngineThread> forkThread({
    required String threadId,
    required String nodeId,
  }) async => _threads.first;

  @override
  Future<void> deleteFromNode({
    required String threadId,
    required String nodeId,
  }) async {}

  @override
  Future<void> clearThreadMessages(String threadId) async {}

  @override
  Future<String> regenerateReply({
    required String threadId,
    required String userNodeId,
  }) async => 'r';

  @override
  Future<bool> cancelActiveRun(String threadId) async => false;

  @override
  Future<bool> retryRunNow(String threadId) async => false;

  @override
  Future<List<EngineNode>> listNodes(String threadId) async {
    final delay = listNodesDelays[threadId];
    if (delay != null) await Future<void>.delayed(delay);
    return _nodes.where((n) => n.threadId == threadId).toList(growable: false);
  }

  @override
  Future<void> saveDraft(String threadId, String text) async {
    _drafts[threadId] = text;
  }

  @override
  Future<String?> loadDraft(String threadId) async => _drafts[threadId];

  @override
  Future<EngineSettings> loadSettings() async => _settings;

  @override
  Future<EngineSettings> saveSettings(EngineSettings settings) async {
    _settings = settings;
    return _settings;
  }

  @override
  Future<int> getWalletSpendMicros() async => 1850000;

  @override
  Future<int> getWalletDailySpendMicros() async => 1420000;

  @override
  Future<EngineStorageStats> getStorageStats() async => EngineStorageStats(
    dataDir: r'c:\baros4294\bistre\.bistre-dev',
    dbSizeBytes: 348160,
    coreVersion: '0.1.0',
    schemaVersion: 6,
    walModeActive: true,
    threadCount: _threads.length,
    nodeCount: _nodes.length,
    activeRuns: 1,
  );

  @override
  Future<String> exportThread({
    required String threadId,
    required String format,
  }) async => '# Export';

  @override
  Future<void> backupDatabase(String destPath) async {}

  /// Pushes an engine event into the controller (gallery & regression tests).
  void emit(BistreEvent event) => _events.add(event);

  @override
  Future<List<String>> getProviderApiKeys(String providerId) async =>
      const <String>[];

  @override
  Future<EngineModelCatalogInfo?> lookupModelCatalogInfo(
    String providerId,
    String modelId,
  ) async => null;

  @override
  Future<EngineNode> sendAndStreamReplyWithAttachments({
    required String threadId,
    String? parentId,
    required String userContent,
    required List<EngineAttachmentInput> attachments,
  }) => sendAndStreamReply(
    threadId: threadId,
    parentId: parentId,
    userContent: userContent,
  );

  @override
  Future<EngineNode> steerActiveRunNow({
    required String threadId,
    required String content,
  }) => sendAndStreamReply(threadId: threadId, userContent: content);

  @override
  Future<int> importThreadsJson(String rawJson) async => 0;

  @override
  Future<String> exportSettingsJson() async => '{}';

  @override
  Future<EngineSettings> importSettingsJson(
    String rawJson, {
    bool allowLoosening = false,
  }) async => _settings;

  @override
  Future<List<EngineStorageFileEntry>> listStorageFiles() async =>
      const <EngineStorageFileEntry>[];

  @override
  Future<bool> deleteStorageFile(String relPath) async => true;

  @override
  Future<int> cleanUnusedStorageFiles() async => 0;

  @override
  Future<List<int>> synthesizeSpeech({
    required String providerId,
    required String modelId,
    required String text,
    String? voice,
  }) async => const <int>[];

  @override
  Future<String> startLiveVoiceSession({
    required String providerId,
    required String modelId,
    required String voice,
    required String systemPrompt,
  }) async => 'live_gallery';

  @override
  Future<void> sendLiveVoicePcmChunk({
    required String sessionId,
    required String pcmBase64,
  }) async {}

  @override
  Future<void> sendLiveVoiceText({
    required String sessionId,
    required String text,
  }) async {}

  @override
  Future<void> stopLiveVoiceSession(String sessionId) async {}

  @override
  Future<EngineThread> generateThreadTitle(String threadId) async => _threads
      .firstWhere((t) => t.id == threadId, orElse: () => _threads.first);

  @override
  Future<EngineNode> translateNode({
    required String threadId,
    required String nodeId,
    String? targetLanguage,
  }) async => _nodes.first;

  @override
  Stream<BistreEvent> subscribeEvents() => _events.stream;

  @override
  Future<void> shutdown() async {
    await _events.close();
  }
}
