import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/chat/cost_unavailable_button.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

/// Split diff toggle and quiet unavailable-cost popup (Spec 08 §3, `docs/design/design.md` §8).
void main() {
  const diff =
      '--- a/lib.rs\n+++ b/lib.rs\n@@ -1,3 +1,3 @@\n fn keep() {}\n-let old = 1;\n+let new = 2;\n+let extra = 3;\n tail();';

  test('split rows pair removals with the additions that follow them', () {
    final rows = pairSplitDiffRows(diff);
    expect(rows.where((r) => r.header).map((r) => r.left), <String>[
      '--- a/lib.rs',
      '+++ b/lib.rs',
      '@@ -1,3 +1,3 @@',
    ]);
    final body = rows.where((r) => !r.header).toList();
    expect(body.map((r) => (r.left, r.right)), <(String?, String?)>[
      (' fn keep() {}', ' fn keep() {}'),
      ('-let old = 1;', '+let new = 2;'),
      (null, '+let extra = 3;'),
      (' tail();', ' tail();'),
    ]);
  });

  Widget host(BistreLocalizationController l10n, Widget child) =>
      BistreLocalizations(
        controller: l10n,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: BistreTheme(
            data: BistreThemeData.warmSepia,
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(builder: (_) => Center(child: child)),
              ],
            ),
          ),
        ),
      );

  Future<void> pumpTimeline(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final l10n = loadDiskCatalogs();
    await tester.pumpWidget(
      host(
        l10n,
        SizedBox(
          width: width - 40,
          child: const ToolTimelineView(
            entries: <ToolActivityEntry>[
              ToolActivityEntry(
                id: 'e1',
                toolName: 'edit',
                summary: 'edit lib.rs',
                status: 'completed',
                diffText: diff,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.textContaining('edit lib.rs'));
    await tester.pumpAndSettle(); // the details disclosure grows open
  }

  testWidgets('wide layouts offer the Split diff toggle', (tester) async {
    await pumpTimeline(tester, 1200);
    final l10n = loadDiskCatalogs();
    expect(find.text('-let old = 1;'), findsOneWidget);
    await tester.tap(find.text(l10n.t(L10nKey.toolDiffSplit)));
    await tester.pump();
    final removed = tester.getTopLeft(find.text('-let old = 1;'));
    final added = tester.getTopLeft(find.text('+let new = 2;'));
    expect(removed.dy, added.dy, reason: 'paired lines share a row');
    expect(removed.dx, lessThan(added.dx));
    // Context lines appear once per side.
    expect(find.text(' fn keep() {}'), findsNWidgets(2));
    expect(find.text(l10n.t(L10nKey.toolDiffUnified)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow layouts keep the unified diff only', (tester) async {
    await pumpTimeline(tester, 520);
    final l10n = loadDiskCatalogs();
    expect(find.text(l10n.t(L10nKey.toolDiffSplit)), findsNothing);
    expect(find.text(' fn keep() {}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('cost_known false is parsed from node metadata', () {
    final meta = NodeUsageMeta.tryParse(
      '{"model_id":"m","input_tokens":10,"output_tokens":5,"cost_micros":0,"cost_known":false}',
    );
    expect(meta?.costKnown, isFalse);
    expect(NodeUsageMeta.tryParse('{"cost_micros":12}')?.costKnown, isTrue);
  });

  testWidgets('unavailable cost opens a quiet breakdown popup', (tester) async {
    final l10n = loadDiskCatalogs();
    await tester.pumpWidget(
      host(
        l10n,
        const CostUnavailableButton(
          usage: NodeUsageMeta(
            modelId: 'unpriced-model',
            inputTokens: 412,
            outputTokens: 198,
            costKnown: false,
          ),
        ),
      ),
    );
    expect(find.text(l10n.t(L10nKey.chatCostUnavailableBody)), findsNothing);
    await tester.tap(find.byType(CostUnavailableButton));
    await tester.pump();
    expect(find.text(l10n.t(L10nKey.chatCostUnavailableTitle)), findsOneWidget);
    expect(find.text(l10n.t(L10nKey.chatCostUnavailableBody)), findsOneWidget);
    expect(find.textContaining('unpriced-model'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
