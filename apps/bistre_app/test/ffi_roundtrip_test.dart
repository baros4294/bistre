import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Real Rust FRB v2 Native Assets round-trip: Schema v6, durable runs & steering, deletable Big 3 providers, Unlimited budget, live HTTP/SSE usage metrics, edit/delete/export/backup & OTA', () async {
    final tmpDir = Directory.systemTemp.createTempSync('bistre_ffi_e2e_');
    addTearDown(() {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    final gateway = FrbBistreEngineGateway(
      externalLibrary: _locateBuiltLibrary(),
    );
    final health = await gateway.init(tmpDir.path);
    expect(health.coreVersion, '0.1.2');
    expect(health.schemaVersion, greaterThanOrEqualTo(6));
    expect(health.walModeActive, isTrue);
    expect(health.statusKey, 'diag.ok');

    // Fresh install seeds strictly 1 Default assistant + full CRUD.
    final initialAssistants = await gateway.listAssistants();
    expect(initialAssistants.length, 1);
    expect(initialAssistants.first.name, 'Default');
    final customAsst = await gateway.createAssistant(
      name: 'Rust Reviewer',
      roleSubtitle: 'Strict systems reviewer',
      systemPrompt: 'Focus on soundness and perf.',
      defaultMode: 'chat',
      badgeCode: 'RR',
    );
    final updatedAsst = await gateway.updateAssistant(
      assistantId: customAsst.id,
      name: 'Systems Reviewer',
      temperatureMilli: 300,
      maxOutputTokens: 2048,
    );
    expect(updatedAsst.name, 'Systems Reviewer');
    expect(updatedAsst.temperatureMilli, 300);
    expect(updatedAsst.maxOutputTokens, 2048);
    await gateway.deleteAssistant(customAsst.id);
    expect((await gateway.listAssistants()).length, 1);

    // Starter Big 3 seeded once; every provider (including Anthropic) is deletable.
    final providers = await gateway.listProviders();
    expect(providers.length, 3);
    expect(providers.map((p) => p.id).toSet(), <String>{
      'openai',
      'google_gemini',
      'anthropic',
    });
    await gateway.deleteProvider('anthropic');
    expect((await gateway.listProviders()).length, 2);

    // Store and clear an API key in real Windows DPAPI / OS vault via Rust FFI.
    final withKey = await gateway.setProviderApiKey(
      providerId: 'openai',
      apiKey: 'sk-live-test-key-4321',
    );
    expect(withKey.hasApiKey, isTrue);
    expect(withKey.keyHint, '••••4321');
    final cleared = await gateway.clearProviderApiKey('openai');
    expect(cleared.hasApiKey, isFalse);

    // Unconfigured send must fail cleanly with diag.provider.not_configured.
    final thread = await gateway.createThread(
      'Live FFI Chat',
      'chat',
      topic: 'general',
    );
    await expectLater(
      () => gateway.sendAndStreamReply(
        threadId: thread.id,
        userContent: 'Should require provider',
      ),
      throwsA(
        predicate<Object>(
          (e) => e.toString().contains('diag.provider.not_configured'),
        ),
      ),
    );

    // Spin up a real local HTTP/SSE mock provider returning stream chunks + usage.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    unawaited(() async {
      await for (final req in server) {
        if (req.method == 'GET') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(<String, Object?>{
              'data': <Map<String, String>>[
                <String, String>{'id': 'local-ffi-model'},
              ],
            }),
          );
          await req.response.close();
        } else {
          req.response.headers.set('content-type', 'text/event-stream');
          req.response.write(
            'data: {"choices":[{"delta":{"content":"Streamed over real Rust HTTP"}}],"usage":{"prompt_tokens":42,"completion_tokens":18}}\n\n'
            'data: [DONE]\n\n',
          );
          await req.response.close();
        }
      }
    }());

    final custom = await gateway.createProvider(
      name: 'Local Loopback',
      dialect: 'custom_openai',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      defaultModel: 'local-ffi-model',
      iconSlug: 'ollama',
      customIconPath: '',
    );
    expect(custom.iconSlug, 'ollama');
    final models = await gateway.fetchProviderModels(custom.id);
    expect(models.map((m) => m.id), contains('local-ffi-model'));

    // Persist Unlimited budget (null ceiling) + continuous typography settings.
    await gateway.saveSettings(
      EngineSettings(
        theme: 'night',
        layoutMode: 'open_folio',
        locale: 'vi',
        trustPreset: 'strict',
        walletDailyCeilingMicros: null,
        fontSizePx: 18,
        lineHeightBps: 17500,
        readingWidthPx: 880,
        activeProviderId: custom.id,
        activeModelId: 'local-ffi-model',
      ),
    );

    final finishCompleter = Completer<void>();
    final sub = gateway.subscribeEvents().listen((event) {
      if (event is RunFinishedEvent &&
          event.threadId == thread.id &&
          !finishCompleter.isCompleted) {
        finishCompleter.complete();
      }
    });

    final userNode = await gateway.sendAndStreamReply(
      threadId: thread.id,
      userContent: 'Tiếng Việt — مرحبا FTS5 native bridge',
    );
    await finishCompleter.future.timeout(const Duration(seconds: 5));
    await sub.cancel();

    final nodesAfterStream = await gateway.listNodes(thread.id);
    expect(nodesAfterStream.length, 2);
    expect(nodesAfterStream.last.content, 'Streamed over real Rust HTTP');
    expect(nodesAfterStream.last.usageMeta?.inputTokens, 42);
    expect(nodesAfterStream.last.usageMeta?.outputTokens, 18);
    // Typed cron DTOs round-trip through Rust, enums included.
    final savedJob = await gateway.upsertCronJob(
      const EngineCronJob(
        name: 'Nightly summary',
        scheduleExpr: '0 3 * * *',
        prompt: 'Summarize yesterday',
        mode: 'plan',
      ),
    );
    expect(savedJob.id, isNotEmpty);
    expect(savedJob.mode, 'plan');
    final jobs = await gateway.listCronJobs();
    expect(jobs.map((j) => j.id), contains(savedJob.id));
    expect(
      jobs.firstWhere((j) => j.id == savedJob.id).scheduleExpr,
      '0 3 * * *',
    );

    // Typed memory DTOs round-trip through Rust.
    final memory = await gateway.upsertMemoryEntry(
      scope: 'global',
      scopeId: 'default',
      key: 'tone',
      content: 'Prefers short answers',
      pinned: true,
    );
    expect(memory.id, isNotEmpty);
    expect(
      (await gateway.listMemoryEntries())
          .firstWhere((m) => m.id == memory.id)
          .pinned,
      isTrue,
    );

    // Core's offline BPE token count for the branch (the gauge's number).
    // "a draft of about forty characters long.." = 8 exact o200k_base tokens.
    final usage = await gateway.contextUsage(
      thread.id,
      nodesAfterStream.last.id,
      draft: 'a draft of about forty characters long..',
    );
    expect(usage.historyTokens, greaterThan(0));
    expect(usage.draftTokens, 8);
    expect(
      usage.totalTokens,
      usage.systemTokens +
          usage.storyTokens +
          usage.historyTokens +
          usage.draftTokens,
    );

    // Export conversation as Markdown and JSON, and run WAL-safe VACUUM INTO backup.
    final mdExport = await gateway.exportThread(
      threadId: thread.id,
      format: 'markdown',
    );
    expect(mdExport, contains('Streamed over real Rust HTTP'));
    final jsonExport = await gateway.exportThread(
      threadId: thread.id,
      format: 'json',
    );
    expect(jsonExport, contains('local-ffi-model'));

    final backupFile = File('${tmpDir.path}/backup.sqlite3');
    await gateway.backupDatabase(backupFile.path);
    expect(backupFile.existsSync(), isTrue);
    expect(backupFile.lengthSync(), greaterThan(4096));

    final stats = await gateway.getStorageStats();
    expect(stats.schemaVersion, greaterThanOrEqualTo(7));
    expect(stats.dbSizeBytes, greaterThan(0));

    // Live Rust FFI round-trip for Character Cards, Story Bible + Progressions, Chapters/Scenes & Prompt Inspector.
    final card = await gateway.upsertCharacterCard(
      const EngineCharacterCard(
        name: 'Lyra Vance',
        description: 'Archivist of the Sunken Library.',
        firstMessage: 'You brought the cipher.',
      ),
    );
    final exportedCcv3 = await gateway.exportCharacterCardCcv3(card.id);
    expect(exportedCcv3, contains('chara_card_v3'));
    expect(exportedCcv3, contains('Lyra Vance'));

    final entry = await gateway.upsertStoryEntry(
      const EngineStoryEntry(
        name: 'Sunken Library',
        keys: <String>['library', 'cipher'],
        content: 'Submerged vaults.',
        constant: true,
      ),
    );
    await gateway.addStoryProgression(
      EngineStoryProgression(
        entryId: entry.id,
        chapterOrder: 1,
        deltaText: 'Outer gate opened.',
      ),
    );
    await gateway.addStoryProgression(
      EngineStoryProgression(
        entryId: entry.id,
        chapterOrder: 5,
        deltaText: 'FUTURE SPOILER',
      ),
    );
    await gateway.saveStoryThreadState(
      EngineStoryThreadState(
        threadId: thread.id,
        activeCharacterIds: <String>[card.id],
        authorNote: 'Keep pacing sharp.',
        currentChapterOrder: 2,
      ),
    );
    final promptReport = await gateway.inspectStoryPrompt(threadId: thread.id);
    expect(promptReport.cacheBoundaryIndex, greaterThan(0));
    expect(promptReport.blocks.any((b) => !b.isStaticPrefix), isTrue);
    expect(
      promptReport.blocks.any((b) => b.content.contains('FUTURE SPOILER')),
      isFalse,
    );

    // Verify durable agent runs, mid-stream steering queue, and OS power guard over live FFI.
    final runs = await gateway.listAgentRuns(threadId: thread.id);
    expect(runs, isNotEmpty);
    final steered = await gateway.enqueueSteering(
      threadId: thread.id,
      content: 'Follow up cleanly after tool check',
    );
    final pendingSteers = await gateway.listPendingSteering(thread.id);
    expect(pendingSteers.length, 1);
    expect(pendingSteers.first.id, steered.id);
    await gateway.deleteSteering(steered.id);
    expect(await gateway.listPendingSteering(thread.id), isEmpty);
    final power = await gateway.powerGuardStatus();
    expect(power.platform, isNotEmpty);

    const draftText = 'Unsent draft persisted across Rust engine restart';
    await gateway.saveDraft(thread.id, draftText);

    final hits = await gateway.searchNodes('native', threadId: thread.id);
    expect(hits, isNotEmpty);
    expect(hits.first.nodeId, userNode.id);

    await expectLater(
      () => gateway.verifyDataPack(
        publicKeyB64:
            'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3',
        manifestBytes: <int>[123, 125],
        manifestSigText: 'invalid-sig',
        packPayload: <int>[1, 2, 3],
      ),
      throwsA(anything),
    );

    await gateway.shutdown();

    // Reopen DB: deleted starter provider Anthropic must STAY deleted!
    final reopenedHealth = await gateway.init(tmpDir.path);
    expect(reopenedHealth.schemaVersion, greaterThanOrEqualTo(6));
    expect(reopenedHealth.threadCount, 1);
    expect(reopenedHealth.nodeCount, 2);
    expect(
      (await gateway.listProviders()).any((p) => p.id == 'anthropic'),
      isFalse,
    );
    expect(await gateway.loadDraft(thread.id), draftText);

    final reloadedSettings = await gateway.loadSettings();
    expect(reloadedSettings.theme, 'night');
    expect(reloadedSettings.isWalletUnlimited, isTrue);
    expect(reloadedSettings.fontSizePx, 18);
    expect(reloadedSettings.readingWidthPx, 880);
    expect(reloadedSettings.activeModelId, 'local-ffi-model');
    await gateway.shutdown();
  });
}

/// On Linux the test host does not put hook-built native assets on the loader
/// path, so the round-trip loads the `libbistre_ffi.so` that the build hook
/// produced for this run. Other platforms use the default loader.
ExternalLibrary? _locateBuiltLibrary() {
  if (!Platform.isLinux) return null;
  final candidates = <File>[
    for (final dir in <String>['.dart_tool', 'build'])
      if (Directory(dir).existsSync())
        ...Directory(dir)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((f) => f.path.endsWith('/libbistre_ffi.so')),
  ]..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  if (candidates.isEmpty) return null;
  return ExternalLibrary.open(candidates.first.path);
}
