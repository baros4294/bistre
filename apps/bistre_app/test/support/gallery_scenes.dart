/// One scene per capture for the `just ui-gallery` suite: a fresh engine fixture, the real
/// `BistreApp`, a fixed clock, bundled fonts, and an explicit size, text scale, locale, and
/// theme, so every PNG is reproducible and no capture leaks state into the next.
library;

import 'dart:convert';
import 'dart:io';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gallery_harness.dart';

/// Window sizes the gallery renders (logical px at device pixel ratio 1).
abstract final class GallerySize {
  static const Size desktop = Size(1320, 820);
  static const Size wide = Size(1680, 960);

  /// A desktop window snapped to half of a 1536 px screen.
  static const Size narrowSplit = Size(760, 820);
  static const Size phone = Size(390, 844);
}

/// What a scene's `prepare` step can drive: the live app, its controller, and its engine.
class GalleryScene {
  GalleryScene(this.tester, this.ctrl, this.gw, this.l10n);

  final WidgetTester tester;
  final FolioController ctrl;
  final GalleryGateway gw;
  final BistreLocalizationController l10n;

  String t(
    L10nKey key, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => l10n.t(key, args);

  /// Taps the first widget [finder] matches and lets the result settle.
  Future<void> tap(Finder finder) async {
    await tester.tap(finder.first);
    await tester.pumpAndSettle();
  }

  /// Opens the phone drawer the way a user does: the header's sidebar toggle.
  Future<void> openPhoneDrawer() =>
      tap(find.bySemanticsLabel(t(L10nKey.sidebarToggle)));

  /// Phone composer: opens the tray of occasional controls with its + button.
  Future<void> openComposerTray() => tap(
    find.byWidgetPredicate(
      (w) =>
          w is BistreIconButton &&
          w.semanticsLabel == t(L10nKey.composerToolsShow),
    ),
  );

  /// Emits engine events, then lets the shell take them in.
  Future<void> emit(List<BistreEvent> events) async {
    for (final e in events) {
      gw.emit(e);
    }
    await tester.pump();
    await tester.pump();
  }
}

/// Captures named scenes into `build/ui_gallery/` and records every file it wrote.
class GalleryShooter {
  GalleryShooter(this.tester);

  final WidgetTester tester;
  final Directory outDir = Directory('build/ui_gallery')
    ..createSync(recursive: true);
  final List<String> written = <String>[];

  /// Layout and build errors raised while rendering, one line per error.
  final List<String> problems = <String>[];

  /// Renders one scene and writes `<file>.png`. [fixtures] seeds the engine before the app
  /// boots; [prepare] drives the running app.
  ///
  /// [settle] is false for live states that animate forever (a streaming reply); those
  /// capture after a fixed frame budget instead of waiting for the animation to end.
  Future<void> shoot(
    String file, {
    Size size = GallerySize.desktop,
    double textScale = 1.0,
    String locale = 'en',
    String? theme,
    bool connected = true,
    bool seed = true,
    bool settle = true,
    void Function(GalleryGateway gw)? fixtures,
    Future<void> Function(GalleryScene scene)? prepare,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    // A fresh tree per scene: no widget keeps state from the previous capture.
    await tester.pumpWidget(const SizedBox.shrink());

    final l10n = loadDiskCatalogs();
    final gw = GalleryGateway(connected: connected, seedConversation: seed);
    fixtures?.call(gw);
    final ctrl = FolioController(
      gateway: gw,
      defaultThreadTitle: l10n.t(L10nKey.shellThreadDefaultTitle),
      onLocaleSynced: l10n.setLocale,
      isDevEnvironment: true,
      clock: galleryClock,
    );
    await ctrl.bootstrap('memory');
    if (theme != null) {
      await ctrl.updateSettings(
        ctrl.settings.copyWith(theme: theme),
        quiet: true,
      );
    }
    // Last: saving settings re-syncs the saved locale, so the requested one goes after it.
    l10n.setLocale(locale);
    final key = GlobalKey();
    // The error's details name the widget that broke; the thrown exception alone does not.
    final where = <String>[];
    final report = FlutterError.onError;
    FlutterError.onError = (details) {
      where.add(_creator(details.toString()));
      report?.call(details);
    };
    addTearDown(() => FlutterError.onError = report);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: BistreApp(l10nController: l10n, folioController: ctrl),
      ),
    );
    await tester.pumpAndSettle();
    await prepare?.call(GalleryScene(tester, ctrl, gw, l10n));
    final name = '$file.png';
    await capturePng(tester, key, outDir, name, settle: settle);
    FlutterError.onError = report;
    // Every layout error is collected, so one broken scene never hides the rest of the
    // gallery; [verify] fails once with the full list.
    for (
      Object? e = tester.takeException();
      e != null;
      e = tester.takeException()
    ) {
      problems.add('$name: ${_firstLines(e)}');
    }
    for (final w in where.toSet()) {
      if (w.isNotEmpty) problems.add('$name: at $w');
    }
    written.add(name);
    ctrl.dispose();
    await gw.shutdown();
    await tester.pumpWidget(const SizedBox.shrink());
  }

  /// Every capture exists, is non-trivial, no name repeats, and no scene raised an error.
  void verify() {
    expect(problems, isEmpty, reason: problems.join('\n'));
    expect(written.toSet().length, written.length, reason: 'duplicate names');
    for (final name in written) {
      final f = File('${outDir.path}/$name');
      expect(f.existsSync(), isTrue, reason: 'missing $name');
      expect(f.lengthSync(), greaterThan(5000), reason: 'blank $name');
    }
  }
}

/// Resets the window, text scale, and device pixel ratio after a gallery file.
void resetGalleryView(WidgetTester tester) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Reply metadata the way core writes it (model, provider, usage, thinking).
String replyMeta({
  String model = 'gpt-4.1',
  String provider = 'OpenAI',
  String icon = 'openai',
  int input = 412,
  int output = 198,
  int costMicros = 3100,
  String? thinking,
  int thinkingMs = 0,
}) => jsonEncode(<String, Object?>{
  'model_id': model,
  'provider_name': provider,
  'icon_slug': icon,
  'input_tokens': input,
  'output_tokens': output,
  'cost_micros': costMicros,
  'thinking_text': ?thinking,
  if (thinkingMs > 0) 'thinking_duration_ms': thinkingMs,
});

/// Messy real-world content: very long unbroken model ids, titles, and URLs, Vietnamese
/// diacritics, Arabic mixed with English, and several chats replying at once.
const String kLongModelId =
    'accounts/fireworks/models/llama-v3p1-405b-instruct-long-context-preview-2026-11-experimental-build-7f3a9c';
const String kLongTitle =
    'Quarterly_infrastructure_cost_reconciliation_for_eu-west-1_and_ap-southeast-2_clusters_final_v7_REVIEWED';
const String kLongUrl =
    'https://docs.example.org/very/deeply/nested/reference/section/with/an/extremely/long/path/that/never/breaks/naturally/index.html?query=sqlite-wal-checkpoint-truncate&lang=en';

/// Seeds the stress chats into [gw] (call before the app reads its lists).
void seedStressFixtures(GalleryGateway gw) {
  final now = galleryClock().millisecondsSinceEpoch;
  gw.seedProvider(
    const EngineProvider(
      id: 'fireworks',
      name: 'Fireworks AI (self-hosted gateway, eu-central)',
      dialect: 'custom_openai',
      baseUrl: 'https://gateway.internal.example.com/inference/v1',
      defaultModel: kLongModelId,
      keyHint: '••••f1r3',
      hasApiKey: true,
      isEnabled: true,
      isBuiltin: false,
      useServerStateCache: false,
      iconSlug: 'fireworks',
      createdAtMs: 9,
      updatedAtMs: 9,
    ),
  );
  gw
    ..seedThread(
      EngineThread(
        id: 't-long',
        workspaceId: 'ws',
        title: kLongTitle,
        mode: 'chat',
        createdAtMs: now - 120000,
        updatedAtMs: now - 30000,
      ),
    )
    ..seedThread(
      EngineThread(
        id: 't-vi',
        workspaceId: 'ws',
        title: 'Rà soát hợp đồng thuê nhà: điều khoản bồi thường',
        mode: 'chat',
        createdAtMs: now - 200000,
        updatedAtMs: now - 40000,
      ),
    )
    ..seedThread(
      EngineThread(
        id: 't-ar',
        workspaceId: 'ws',
        title: 'مراجعة واجهة SQLite WAL للفريق',
        mode: 'chat',
        createdAtMs: now - 300000,
        updatedAtMs: now - 50000,
      ),
    )
    ..seedNode(
      EngineNode(
        id: 'long-u',
        threadId: 't-long',
        role: 'user',
        content:
            'Summarize $kLongUrl and compare it with ${kLongTitle}_appendix.csv',
        createdAtMs: now - 110000,
        attachments: const <EngineNodeAttachment>[
          EngineNodeAttachment(
            name: 'cost_reconciliation_eu-west-1_ap-southeast-2_2026-Q3_final_REVIEWED_signed.xlsx',
            mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            sizeBytes: 482113,
            blobRelPath: 'blobs/long.xlsx',
          ),
        ],
      ),
    )
    ..seedNode(
      EngineNode(
        id: 'long-a',
        threadId: 't-long',
        parentId: 'long-u',
        role: 'assistant',
        content:
            'The page at $kLongUrl lists three causes.\n\n'
            '| Region | Spend (USD) | Change | Owner |\n|---|---:|---:|---|\n'
            '| eu-west-1 | 48,210.55 | +12.4% | platform-infrastructure-cost-governance-team |\n'
            '| ap-southeast-2 | 19,004.10 | -3.1% | apac-regional-operations |\n\n'
            '`$kLongModelId` produced this summary.',
        createdAtMs: now - 100000,
        providerMetaJson: replyMeta(
          model: kLongModelId,
          provider: 'Fireworks AI (self-hosted gateway, eu-central)',
          icon: 'fireworks',
        ),
      ),
    )
    ..seedNode(
      EngineNode(
        id: 'vi-u',
        threadId: 't-vi',
        role: 'user',
        content: 'Điều khoản bồi thường trong hợp đồng thuê nhà có áp dụng khi chủ nhà chậm sửa chữa không?',
        createdAtMs: now - 190000,
      ),
    )
    ..seedNode(
      EngineNode(
        id: 'vi-a',
        threadId: 't-vi',
        parentId: 'vi-u',
        role: 'assistant',
        content:
            '## Tóm tắt\n\nCó. Theo **Điều 7.2**, nếu chủ nhà chậm sửa chữa quá 15 ngày, '
            'người thuê được giảm tiền thuê tương ứng với thời gian không sử dụng được.\n\n'
            '- Gửi thông báo bằng văn bản.\n- Lưu biên nhận và ảnh chụp hư hỏng.',
        createdAtMs: now - 180000,
        providerMetaJson: replyMeta(thinking: 'Đọc Điều 7.2 và Phụ lục B.'),
      ),
    )
    ..seedNode(
      EngineNode(
        id: 'ar-u',
        threadId: 't-ar',
        role: 'user',
        content: 'كيف نمنع SQLITE_BUSY عند استخدام wal_checkpoint(TRUNCATE) مع قراء كثيرين؟',
        createdAtMs: now - 290000,
      ),
    )
    ..seedNode(
      EngineNode(
        id: 'ar-a',
        threadId: 't-ar',
        parentId: 'ar-u',
        role: 'assistant',
        content:
            'استخدم كاتبًا واحدًا (single writer) واجعل اتصالات القراءة قصيرة.\n\n'
            '```rust\nconn.pragma_update(None, "journal_mode", "WAL")?;\n```\n\n'
            'بعد ذلك شغّل `wal_checkpoint(TRUNCATE)` كل 8 MiB.',
        createdAtMs: now - 280000,
        providerMetaJson: replyMeta(
          model: 'gemini-2.5-pro',
          provider: 'Google Gemini',
          icon: 'gemini',
        ),
      ),
    );
}

/// The first few non-empty lines of a layout error, enough to name the broken widget.
String _firstLines(Object error) {
  final lines = error
      .toString()
      .split(String.fromCharCode(10))
      .where((l) => l.trim().isNotEmpty)
      .toList();
  final where = lines.where((l) => l.contains('/lib/')).take(1);
  return <String>[lines.first, ...where].join(' at ');
}

/// The app source line of the widget an error names ("The relevant error-causing widget").
String _creator(String details) {
  final lines = details.split(String.fromCharCode(10));
  for (final l in lines) {
    if (l.contains('/lib/') && l.contains('.dart:')) return l.trim();
  }
  return '';
}
