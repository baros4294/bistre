import 'dart:ui' show FrameTiming;

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/gallery_harness.dart';

/// Profile-mode streaming benchmark (Spec 11 §1; `flutter drive --profile`): streams the same
/// ~87 KB code fence as `test/perf/streaming_frame_probe_test.dart` at ~120 tok/s and reads the
/// engine's own frame timings. UI-thread build p99 above the 16 ms hard limit fails; raster p99
/// is reported, because CI rasterizes in software (xvfb + llvmpipe).
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('streaming 87 KB code fence, profile frame timings', (
    WidgetTester tester,
  ) async {
    final l10n = await BistreLocalizationController.loadBundled();
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

    final timings = <FrameTiming>[];
    void collect(List<FrameTiming> batch) => timings.addAll(batch);
    WidgetsBinding.instance.addTimingsCallback(collect);
    const chunk = 480; // ~120 tok/s at 16 ms batches with ~4 chars per token
    for (var i = 0; i < text.length; i += chunk) {
      final end = i + chunk > text.length ? text.length : i + chunk;
      gw.emit(
        DeltaBatchEvent(
          threadId: threadId,
          nodeId: 'probe',
          textDelta: text.substring(i, end),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    // The engine reports timings in batches (about once a second); let the last one arrive.
    // No pumpAndSettle here: the streaming cursor keeps animating until the run finishes.
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(seconds: 2));
    WidgetsBinding.instance.removeTimingsCallback(collect);

    double p99(Iterable<Duration> values) {
      final sorted = values.map((d) => d.inMicroseconds).toList()..sort();
      return sorted[((sorted.length - 1) * 0.99).round()] / 1000;
    }

    expect(timings, isNotEmpty, reason: 'no frame timings were reported');
    final build = p99(timings.map((t) => t.buildDuration));
    final raster = p99(timings.map((t) => t.rasterDuration));
    binding.reportData = <String, Object>{
      'frames': timings.length,
      'build_p99_ms': build,
      'raster_p99_ms': raster,
    };
    debugPrint(
      '[BISTRE_PERF] profile_frames=${timings.length} '
      'profile_build_p99_ms=${build.toStringAsFixed(2)} '
      'profile_raster_p99_ms=${raster.toStringAsFixed(2)}',
    );
    expect(ctrl.liveTurn.value?.text.length, text.length);
    expect(
      build,
      lessThanOrEqualTo(16),
      reason: 'UI-thread build p99 is over the 16 ms hard limit (Spec 11)',
    );

    gw.emit(
      RunFinishedEvent(threadId: threadId, nodeId: 'probe', cancelled: false),
    );
    await tester.pumpAndSettle();
    ctrl.dispose();
    await gw.shutdown();
  });
}
