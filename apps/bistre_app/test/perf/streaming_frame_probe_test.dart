import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/gallery_harness.dart';

/// `just perf` streaming probe (Spec 11 §5): streams an ~87 KB code fence into a seeded chat in
/// 16 ms delta batches and reports build + layout + paint time per frame (p50/p95).
/// Widget-test frames exclude GPU rasterization, so this tracks UI-thread regressions; it is
/// not a device frame-time measurement. It runs twice: with semantics off (the default on a
/// device without assistive technology) and with semantics on (a screen reader is active).
void main() {
  for (final screenReader in <bool>[false, true]) {
    testWidgets(
      'streaming 87 KB code fence frame probe (screen reader: $screenReader)',
      (WidgetTester tester) => _probe(tester, screenReader: screenReader),
      semanticsEnabled: screenReader,
    );
  }
}

Future<void> _probe(WidgetTester tester, {required bool screenReader}) async {
  tester.view.physicalSize = const Size(1320, 820);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final l10n = loadDiskCatalogs();
  final gw = GalleryGateway(connected: true);
  final ctrl = FolioController(
    gateway: gw,
    defaultThreadTitle: l10n.t(L10nKey.shellThreadDefaultTitle),
    onLocaleSynced: l10n.setLocale,
    isDevEnvironment: true,
  );
  await ctrl.bootstrap('memory');
  await tester.pumpWidget(
    BistreApp(l10nController: l10n, folioController: ctrl),
  );
  await tester.pumpAndSettle();

  final threadId = ctrl.activeThread!.id;
  gw.emit(RunStartedEvent(threadId: threadId, nodeId: 'probe'));
  await tester.pump();

  final line =
      '    let value_${'x' * 24} = compute_checkpoint(frames, budget);\n';
  final fence = StringBuffer('```rust\nfn probe() {\n');
  while (fence.length < 87 * 1024) {
    fence.write(line);
  }
  fence.write('}\n```\n');
  final text = fence.toString();

  const chunk = 480; // ~120 tok/s at 16 ms batches with ~4 chars per token
  final frameMicros = <int>[];
  final watch = Stopwatch();
  for (var i = 0; i < text.length; i += chunk) {
    final end = i + chunk > text.length ? text.length : i + chunk;
    gw.emit(
      DeltaBatchEvent(
        threadId: threadId,
        nodeId: 'probe',
        textDelta: text.substring(i, end),
      ),
    );
    watch
      ..reset()
      ..start();
    await tester.pump(const Duration(milliseconds: 16));
    watch.stop();
    frameMicros.add(watch.elapsedMicroseconds);
  }
  frameMicros.sort();
  double pct(double p) =>
      frameMicros[((frameMicros.length - 1) * p).round()] / 1000;
  final p50 = pct(0.50);
  final p95 = pct(0.95);
  // Machine-readable line parsed by `bistre_guard perf`.
  final prefix = screenReader ? 'stream_a11y' : 'stream';
  debugPrint(
    '[BISTRE_PERF] ${prefix}_frames=${frameMicros.length} ${prefix}_frame_p50_ms=${p50.toStringAsFixed(2)} ${prefix}_frame_p95_ms=${p95.toStringAsFixed(2)}',
  );
  expect(frameMicros, isNotEmpty);
  expect(ctrl.liveTurn.value?.text.length, text.length);

  gw.emit(
    RunFinishedEvent(threadId: threadId, nodeId: 'probe', cancelled: false),
  );
  await tester.pumpAndSettle();
  ctrl.dispose();
  await gw.shutdown();
}
