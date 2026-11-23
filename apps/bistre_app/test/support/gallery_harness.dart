/// Shared deterministic gallery harness (`just ui-gallery`): bundled OFL fonts, on-disk ICU
/// catalogs, high-DPI PNG capture, and a seeded in-memory engine gateway.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/math_font_gate.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic visual gallery test harness (`just ui-gallery`).
/// Loads real bundled OFL fonts (`Inter`, `JetBrainsMono`, `NotoSansMath`) and captures
/// 18 high-DPI PNG screenshots of every major state, full-window Settings view, color lab icons,
/// inspector drawer, dark/RTL mode, and mobile drawer into `build/ui_gallery/`.
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
    'Inter-Regular.ttf',
    'Inter-Medium.ttf',
    'Inter-SemiBold.ttf',
    'Inter-Bold.ttf',
  ]);
  await loadFamily('JetBrainsMono', const <String>[
    'JetBrainsMono-Regular.ttf',
    'JetBrainsMono-Medium.ttf',
  ]);
  final mathBytes = File('${fontRoot.path}/NotoSansMath-Regular.ttf')
      .readAsBytesSync();
  await MathFontGate.ensureLoaded(
    source: Future<ByteData>.value(ByteData.sublistView(mathBytes)),
  );

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
      break;
    }
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

Future<void> capturePng(
  WidgetTester tester,
  GlobalKey boundaryKey,
  Directory outDir,
  String fileName,
) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final renderObject =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await renderObject.toImage(pixelRatio: 1.5);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (byteData != null) {
      File('${outDir.path}/$fileName')
          .writeAsBytesSync(byteData.buffer.asUint8List());
    }
  });
}

class GalleryGateway implements BistreEngineGateway {
  GalleryGateway({required bool connected, bool seedConversation = true}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
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
                '"Not Lock 7," *she murmurs, glancing toward the dark breakwater steps.* "Look at the tide notch — Rowan shifted the bearing two leagues east. If we reach the outer floodgate before slack water, the reading room will still be dry."',
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
  Future<EngineHealth> init(String dataDir) async => getHealth();

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
  }) async {
    final t = EngineThread(
      id: 't-${_threads.length + 1}',
      workspaceId: 'ws',
      title: title,
      mode: mode,
      topic: topic ?? 'general',
      assistantId: assistantId ?? 'default_assistant',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
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
  Future<List<EngineThread>> listThreads() async => _threads;

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

  @override
  Future<EngineUpdateCheck> checkForUpdates({String? feedUrlOverride}) async =>
      const EngineUpdateCheck(
        currentVersion: '0.1.0',
        latestVersion: '0.2.0',
        updateAvailable: true,
        track: 'track_b',
        ownershipMode: 'direct_github',
        signatureVerified: true,
        activeRunsBlocking: false,
        releaseNotes: 'Windows 11 DWM Sepia title bar, offline full-color AI lab icons, local custom fonts, unlimited daily budget option, and per-chat inspector drawer.',
        downloadUrl: 'https://example.invalid/bistre-0.2.0.zip',
        sha256Hex: '0000',
        downloadSizeBytes: 12400000,
        checkedAtMs: 1700000000000,
      );

  @override
  Future<String> stageUpdate(EngineUpdateCheck check) async =>
      '.bistre-dev/updates/bistre-0.2.0.zip';

  @override
  Future<List<EngineSearchHit>> searchNodes(
    String query, {
    String? threadId,
    int limit = 20,
  }) async => const <EngineSearchHit>[];

  @override
  Future<String> verifyDataPack({
    required String publicKeyB64,
    required List<int> manifestBytes,
    required String manifestSigText,
    required List<int> packPayload,
  }) async => '1.0.0';

  @override
  Future<List<EngineAgentRun>> listAgentRuns({
    String? threadId,
    bool onlyActive = false,
    int limit = 50,
  }) async => const <EngineAgentRun>[
    EngineAgentRun(
      id: 'run-1',
      threadId: 't-code',
      mode: 'code',
      status: 'running',
      stepIndex: 3,
      maxSteps: 24,
      unattendedPolicy: 'pause_and_notify',
      lastHeartbeatMs: 1700000000000,
      costMicros: 14200,
      createdAtMs: 1700000000000,
      updatedAtMs: 1700000005000,
    ),
  ];

  @override
  Future<EngineSteeringMessage> enqueueSteering({
    required String threadId,
    required String content,
  }) async => EngineSteeringMessage(
    id: 'steer-1',
    threadId: threadId,
    content: content,
    status: 'pending',
    createdAtMs: 1700000006000,
  );

  @override
  Future<List<EngineSteeringMessage>> listPendingSteering(
    String threadId,
  ) async => const <EngineSteeringMessage>[];

  @override
  Future<void> deleteSteering(String steeringId) async {}

  @override
  Future<EnginePowerGuardStatus> powerGuardStatus() async =>
      const EnginePowerGuardStatus(
        keepAwakeActive: true,
        daemonConnected: true,
        sleepPreventedReason: 'Active agent run',
        activeRunCount: 1,
      );

  @override
  Future<int> notifyPowerEvent(String eventKind, {bool? onAc}) async => 0;

  @override
  Future<EnginePowerGuardStatus> setAndroidPowerState({
    required bool fgsActive,
    required bool batteryUnrestricted,
  }) async => EnginePowerGuardStatus(
    platform: 'android',
    androidFgsActive: fgsActive,
    androidBatteryUnrestricted: batteryUnrestricted,
  );

  @override
  Future<EngineAgentRun> resolveIndeterminateRun({
    required String runId,
    required bool confirmCompleted,
  }) async => (await listAgentRuns()).first;

  final Map<String, String> _kvMeta = <String, String>{};
  final Map<String, String> _contextPins = <String, String>{};

  int refreshPricesCalls = 0;

  @override
  Future<void> refreshPrices() async => refreshPricesCalls++;

  @override
  Future<String> approveToolCall({
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
  }) async => 'permit-$toolName';

  @override
  Future<EngineToolOutput> executeWorkspaceTool({
    required String workspaceRoot,
    required String threadId,
    required String toolName,
    required Map<String, Object?> arguments,
    String? permitId,
  }) async => EngineToolOutput(
    toolName: toolName,
    riskTier: 'tier0_read_only',
    ok: true,
    summary: '$toolName ok',
    outputText: 'ok',
  );

  @override
  Future<String> rewindCheckpoint({
    required String workspaceRoot,
    required String checkpointId,
  }) async => 'file.rs';

  @override
  Future<List<EngineCheckpoint>> listCheckpoints(
    String threadId, {
    int limit = 50,
  }) async => const <EngineCheckpoint>[];

  @override
  Future<EngineNode> compactThread({
    required String threadId,
    int keepRecentTurns = 4,
    String? customSummary,
  }) async => EngineNode(
    id: 'compact-1',
    threadId: threadId,
    role: 'compaction_summary',
    content: customSummary ?? 'Summary',
    createdAtMs: 1700000007000,
  );

  @override
  Future<void> undoCompaction({
    required String threadId,
    required String compactionNodeId,
  }) async {}

  @override
  Future<String?> setContextStartPin({
    required String threadId,
    String? nodeId,
  }) async {
    if (nodeId == null) {
      _contextPins.remove(threadId);
      return null;
    }
    _contextPins[threadId] = nodeId;
    return nodeId;
  }

  @override
  Future<String?> getContextStartPin(String threadId) async =>
      _contextPins[threadId];

  @override
  Future<List<EngineLocalServer>> discoverLocalServers() async =>
      const <EngineLocalServer>[];

  @override
  Future<EngineMcpDiscoveryReport> discoverMcpServer(
    EngineMcpServerConfig server,
  ) async => const EngineMcpDiscoveryReport(
    negotiatedProtocol: '2026-07-28',
    toolNames: <String>['workspace_search'],
  );

  @override
  Future<String?> getKvMeta(String key) async => _kvMeta[key];

  @override
  Future<void> setKvMeta(String key, String value) async {
    _kvMeta[key] = value;
  }

  @override
  Future<List<EngineMemoryEntry>> listMemoryEntries({String? scope}) async =>
      const <EngineMemoryEntry>[
        EngineMemoryEntry(
          id: 'mem-1',
          scope: 'global',
          scopeId: 'default',
          key: 'style',
          content: 'Prefer concise Rust solutions with zero unwrap calls.',
          pinned: true,
        ),
      ];

  @override
  Future<EngineMemoryEntry> upsertMemoryEntry({
    String? id,
    required String scope,
    required String scopeId,
    required String key,
    required String content,
    bool pinned = false,
  }) async => EngineMemoryEntry(
    id: id ?? 'mem-new',
    scope: scope,
    scopeId: scopeId,
    key: key,
    content: content,
    pinned: pinned,
  );

  @override
  Future<void> deleteMemoryEntry(String entryId) async {}

  @override
  Future<List<EngineSkillIndex>> discoverWorkspaceSkills(
    String workspaceRoot,
  ) async => const <EngineSkillIndex>[
    EngineSkillIndex(
      name: 'fullstack-architect',
      description: 'Layer boundaries, UI craft, and engineering gates.',
      path: '.agents/skills/fullstack-architect/SKILL.md',
    ),
  ];

  @override
  Future<String> loadSkillBody(String workspaceRoot, String skillPath) async =>
      '# Fullstack Architect\nKeep strict layer separation.';

  @override
  Future<List<EngineCronJob>> listCronJobs() async => const <EngineCronJob>[
    EngineCronJob(
      id: 'cron-1',
      name: 'Morning codebase digest',
      scheduleExpr: '0 9 * * *',
      prompt: 'Summarize overnight commits and open issues.',
    ),
  ];

  @override
  Future<EngineCronJob> upsertCronJob(EngineCronJob job) async => job;

  @override
  Future<void> deleteCronJob(String jobId) async {}

  final List<EngineCharacterCard> _cards = <EngineCharacterCard>[
    const EngineCharacterCard(
      id: 'char-lyra',
      name: 'Lyra Vance',
      description: 'Archivist of the Sunken Library. Observant, measured, carries a brass compass.',
      firstMessage: '*She sets the brass lantern onto the wet slate.* "You actually found the harbour cipher."',
      alternateGreetings: <String>[
        '*Rain drums against the iron skylights.* "We have twenty minutes before the tide seals the vault."',
      ],
    ),
    const EngineCharacterCard(
      id: 'char-rowan',
      name: 'Rowan Hale',
      description: 'Harbour cartographer who mapped the lower locks.',
    ),
  ];

  final List<EngineUserPersona> _personas = <EngineUserPersona>[
    const EngineUserPersona(
      id: 'persona-1',
      name: 'Avery Mercer',
      description: 'Independent restorer of flooded maritime manuscripts.',
      isDefault: true,
    ),
  ];

  final List<EngineStoryEntry> _storyEntries = <EngineStoryEntry>[
    const EngineStoryEntry(
      id: 'lore-vault',
      category: 'location',
      name: 'Sunken Library',
      keys: <String>['library', 'vault', 'archive'],
      content:
          'Three submerged limestone halls beneath the eastern breakwater.',
      constant: true,
    ),
    const EngineStoryEntry(
      id: 'lore-cipher',
      name: 'Harbour Cipher',
      keys: <String>['cipher', 'brass'],
      content: 'Tidal lock bearings engraved in copperplate numerals.',
    ),
  ];

  final List<EngineStoryProgression> _progressions = <EngineStoryProgression>[
    const EngineStoryProgression(
      id: 'prog-1',
      entryId: 'lore-vault',
      chapterOrder: 1,
      deltaText: 'Outer floodgate jammed open after the autumn storm.',
    ),
    const EngineStoryProgression(
      id: 'prog-2',
      entryId: 'lore-cipher',
      chapterOrder: 2,
      deltaText: 'Lyra decoded the second ring pointing to Lock 7.',
    ),
  ];

  final List<EngineStoryChapter> _chapters = <EngineStoryChapter>[
    const EngineStoryChapter(
      id: 'ch-1',
      threadId: 't-write',
      title: 'The Lantern & The Lock',
      eraSummary: 'Lyra and Avery recovered the brass cipher at low tide.',
    ),
    const EngineStoryChapter(
      id: 'ch-2',
      threadId: 't-write',
      orderIndex: 2,
      title: 'Submerged Reading Room',
    ),
  ];

  final List<EngineStoryScene> _scenes = <EngineStoryScene>[
    const EngineStoryScene(
      id: 'sc-1',
      chapterId: 'ch-1',
      title: 'East Breakwater Steps',
      beatsText: '1. Low tide reveals the iron grate beneath the pier.\n2. Lyra checks the brass lantern wick against salt spray.\n3. Avery spots the chalk tally left by Rowan an hour earlier.',
      proseText: 'Salt mist clung to the iron rungs as the tide withdrew. Lyra tilted her brass lantern low over the flagstones, catching the faint chalk tally Rowan had promised to leave beside the third bollard.\n\n"He kept his word," she murmured, pulling her coat tighter against the harbour wind. "Ten minutes before the siphon turns."',
      wordCount: 57,
    ),
    const EngineStoryScene(
      id: 'sc-2',
      chapterId: 'ch-1',
      orderIndex: 2,
      title: 'The Copperplate Folio',
      beatsText: '1. Unlock the cedar chest.\n2. Match the compass bearings to the tidal chart.',
    ),
  ];

  EngineStoryThreadState _storyState = const EngineStoryThreadState(
    threadId: 't-write',
    activeCharacterIds: <String>['char-lyra', 'char-rowan'],
    userPersonaId: 'persona-1',
    authorNote: 'Maintain crisp sensory atmosphere, warm maritime detail, and measured dialogue.',
    storyMemory: 'Avery and Lyra are tracing the lost harbour charts before the winter flood.',
    dialogueStyling: true,
    currentChapterOrder: 2,
  );

  final List<EngineRegexRule> _regexRules = <EngineRegexRule>[
    const EngineRegexRule(
      id: 'rx-1',
      name: 'Hide OOC notes',
      pattern: r'\(\(OOC:[^)]*\)\)',
    ),
  ];

  @override
  Future<List<EngineCharacterCard>> listCharacterCards() async => _cards;

  @override
  Future<EngineCharacterCard> upsertCharacterCard(
    EngineCharacterCard card,
  ) async => card;

  @override
  Future<void> deleteCharacterCard(String cardId) async {}

  @override
  Future<EngineCharacterCard> importCharacterCardFile(String filePath) async =>
      _cards.first;

  @override
  Future<String> exportCharacterCardCcv3(String cardId) async => '{}';

  @override
  Future<List<EngineUserPersona>> listUserPersonas() async => _personas;

  @override
  Future<EngineUserPersona> upsertUserPersona(
    EngineUserPersona persona,
  ) async => persona;

  @override
  Future<List<EngineStoryEntry>> listStoryEntries({String? bookId}) async =>
      _storyEntries;

  @override
  Future<EngineStoryEntry> upsertStoryEntry(EngineStoryEntry entry) async =>
      entry;

  @override
  Future<void> deleteStoryEntry(String entryId) async {}

  @override
  Future<List<EngineStoryProgression>> listStoryProgressions({
    String? entryId,
  }) async => _progressions;

  @override
  Future<EngineStoryProgression> addStoryProgression(
    EngineStoryProgression progression,
  ) async => progression;

  @override
  Future<List<EngineStoryChapter>> listStoryChapters(String threadId) async =>
      _chapters;

  @override
  Future<EngineStoryChapter> upsertStoryChapter(
    EngineStoryChapter chapter,
  ) async => chapter;

  @override
  Future<List<EngineStoryScene>> listStoryScenes(String chapterId) async =>
      _scenes.where((s) => s.chapterId == chapterId).toList(growable: false);

  @override
  Future<EngineStoryScene> upsertStoryScene(EngineStoryScene scene) async =>
      scene;

  @override
  Future<EngineStoryThreadState> loadStoryThreadState(String threadId) async =>
      _storyState;

  @override
  Future<EngineStoryThreadState> saveStoryThreadState(
    EngineStoryThreadState state,
  ) async {
    _storyState = state;
    return _storyState;
  }

  @override
  Future<List<EngineRegexRule>> listRegexRules() async => _regexRules;

  @override
  Future<EngineRegexRule> upsertRegexRule(EngineRegexRule rule) async => rule;

  @override
  Future<List<EngineStorySnapshot>> listStorySnapshots({
    required String entityType,
    required String entityId,
    int limit = 10,
  }) async => const <EngineStorySnapshot>[];

  @override
  Future<EnginePromptReport> inspectStoryPrompt({
    required String threadId,
    String? activeSceneBeats,
  }) async => const EnginePromptReport(
    blocks: <EnginePromptBlock>[
      EnginePromptBlock(
        id: 'system_base',
        label: 'System prompt',
        role: 'system',
        content: 'Write grounded maritime literary fiction with crisp pacing.',
        estimatedTokens: 142,
        isStaticPrefix: true,
      ),
      EnginePromptBlock(
        id: 'char_lyra',
        label: 'Character · Lyra Vance',
        role: 'system',
        content: 'Archivist of the Sunken Library. Observant, measured, carries a brass compass.',
        estimatedTokens: 286,
        isStaticPrefix: true,
      ),
      EnginePromptBlock(
        id: 'story_memory',
        label: 'Story Memory',
        role: 'system',
        content: 'Avery and Lyra are tracing the lost harbour charts before the winter flood.',
        estimatedTokens: 164,
        isStaticPrefix: true,
      ),
      EnginePromptBlock(
        id: 'era_summaries',
        label: 'Continuity Era Summaries',
        role: 'system',
        content: 'Ch 1: Lyra and Avery recovered the brass cipher at low tide.',
        estimatedTokens: 98,
        isStaticPrefix: true,
      ),
      EnginePromptBlock(
        id: 'lore_vault',
        label: 'Lorebook · Sunken Library',
        role: 'system',
        content: 'Three submerged limestone halls beneath the eastern breakwater. [Ch 1] Outer floodgate jammed open.',
        estimatedTokens: 124,
        isStaticPrefix: false,
      ),
      EnginePromptBlock(
        id: 'author_note',
        label: "Author's Note (@D4)",
        role: 'system',
        content: 'Maintain crisp sensory atmosphere, warm maritime detail, and measured dialogue.',
        estimatedTokens: 66,
        isStaticPrefix: false,
      ),
    ],
    cacheBoundaryIndex: 4,
    totalEstimatedTokens: 880,
    staticPrefixTokens: 690,
    loreTrace: <EngineLoreTraceItem>[
      EngineLoreTraceItem(
        entryId: 'lore-vault',
        name: 'Sunken Library',
        fired: true,
        reason: 'constant + 1 progression',
        estimatedTokens: 124,
      ),
      EngineLoreTraceItem(
        entryId: 'lore-cipher',
        name: 'Harbour Cipher',
        fired: true,
        reason: 'keyword:cipher + 1 progression',
        estimatedTokens: 82,
      ),
      EngineLoreTraceItem(
        entryId: 'lore-lighthouse',
        name: 'North Lighthouse',
        fired: false,
        reason: 'no_keyword_match',
        estimatedTokens: 0,
      ),
    ],
    loreTokensUsed: 206,
  );

  /// Pushes an engine event into the controller (gallery & regression tests).
  void emit(BistreEvent event) => _events.add(event);

  @override
  Stream<BistreEvent> subscribeEvents() => _events.stream;

  @override
  Future<void> shutdown() async {
    await _events.close();
  }
}
