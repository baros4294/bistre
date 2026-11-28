import 'dart:io';

import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/chat/cost_unavailable_button.dart';
import 'package:bistre_app/features/chat/tool_timeline_view.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

/// `just ui-gallery`, review sheets of single production widgets the shell only shows after
/// an interaction: every icon at 22 and 12 px (light and dark), the wide Split diff, and the
/// unavailable-cost popup. Own file (own isolate): the icon loader's static in-flight futures
/// must not cross widget-test zones.
void main() {
  testWidgets('gallery: icon, diff, and cost sheets', (tester) async {
    await loadBundledFonts();
    final outDir = Directory('build/ui_gallery')..createSync(recursive: true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1.0;
    final l10n = loadDiskCatalogs();

    Widget sheet(GlobalKey key, BistreThemeData theme, Widget child) =>
        RepaintBoundary(
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

    for (final (name, theme) in const <(String, BistreThemeData)>[
      ('sheet-icons-light', BistreThemeData.warmSepia),
      ('sheet-icons-dark', BistreThemeData.warmDark),
    ]) {
      tester.view.physicalSize = const Size(900, 380);
      final key = GlobalKey();
      await tester.pumpWidget(
        sheet(
          key,
          theme,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final size in const <double>[22, 12])
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final icon in BistreUiIcon.values)
                        BistreIcon(icon, size: size, color: theme.inkPrimary),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
      await capturePng(tester, key, outDir, '$name.png');
    }

    tester.view.physicalSize = const Size(1160, 420);
    final diffKey = GlobalKey();
    await tester.pumpWidget(
      sheet(
        diffKey,
        BistreThemeData.warmSepia,
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
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.t(L10nKey.toolDiffSplit)));
    await capturePng(tester, diffKey, outDir, 'sheet-split-diff.png');
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(560, 300);
    final costKey = GlobalKey();
    await tester.pumpWidget(
      sheet(
        costKey,
        BistreThemeData.warmSepia,
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
    await capturePng(tester, costKey, outDir, 'sheet-cost-unavailable.png');
    expect(tester.takeException(), isNull);
  });
}
