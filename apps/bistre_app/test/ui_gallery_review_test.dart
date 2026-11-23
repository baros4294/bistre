import 'dart:io';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/chat/cost_unavailable_button.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

/// `just ui-gallery` review sheets for the wide-desktop Split diff and the quiet
/// unavailable-cost popup (Spec 08 §3). Kept in its own file (own isolate) because the icon
/// loader's static in-flight futures must not cross widget-test zones.
void main() {
  testWidgets('captures the split diff and the unavailable-cost popup', (
    WidgetTester tester,
  ) async {
    await loadBundledFonts();
    final outDir = Directory('build/ui_gallery')..createSync(recursive: true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1.0;
    final l10n = loadDiskCatalogs();
    const theme = BistreThemeData.dayParchment;

    Widget sheet(GlobalKey key, Widget child) => RepaintBoundary(
      key: key,
      child: BistreLocalizations(
        controller: l10n,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: BistreTheme(
            data: theme,
            child: ColoredBox(
              color: theme.bgCanvas,
              child: Overlay(
                initialEntries: <OverlayEntry>[
                  OverlayEntry(
                    builder: (_) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: child,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    tester.view.physicalSize = const Size(1160, 420);
    final diffKey = GlobalKey();
    await tester.pumpWidget(
      sheet(
        diffKey,
        const ToolTimelineView(
          entries: <ToolActivityEntry>[
            ToolActivityEntry(
              id: 'gallery-edit',
              toolName: 'edit',
              summary: 'edit crates/bistre-core/src/process_util.rs',
              status: 'completed',
              diffText: '--- a/process_util.rs\n+++ b/process_util.rs\n@@ -12,6 +12,7 @@\n pub async fn run_bounded(mut cmd: Command, timeout: Duration) {\n-    let child = cmd.spawn()?;\n+    let (mut child, containment) = spawn_contained(&mut cmd)?;\n+    let stdout = child.stdout.take();\n     let pid = child.id();\n-    kill_process_tree(pid).await;\n+    kill_process_tree(pid).await;\n+    containment.kill_tree();\n }',
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.textContaining('process_util.rs').first);
    await tester.pump();
    await tester.tap(find.text(l10n.t(L10nKey.toolDiffSplit)));
    await capturePng(tester, diffKey, outDir, '34_desktop_split_diff.png');
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(560, 300);
    final costKey = GlobalKey();
    await tester.pumpWidget(
      sheet(
        costKey,
        const Align(
          alignment: AlignmentDirectional.bottomStart,
          child: CostUnavailableButton(
            usage: NodeUsageMeta(
              modelId: 'community-model-preview',
              inputTokens: 412,
              outputTokens: 198,
              costKnown: false,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(CostUnavailableButton));
    await capturePng(tester, costKey, outDir, '35_cost_unavailable_popup.png');
    expect(tester.takeException(), isNull);
  });
}
