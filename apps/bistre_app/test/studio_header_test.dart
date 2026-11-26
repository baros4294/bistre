import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  for (final layout in ShellLayout.values) {
    testWidgets('the Studio button is always in the header (A-W 4a, $layout)', (
      tester,
    ) async {
      final shell = await ShellHarness.pump(tester, layout: layout);
      final semantics = tester.ensureSemantics();
      await tester.pump();
      final studio = find.bySemanticsLabel(shell.t(L10nKey.studioTitle));
      expect(studio, findsOneWidget, reason: 'reachable with no run active');
      expect(
        find.bySemanticsLabel(RegExp('Chat notes|Ghi chú')),
        findsNothing,
        reason: 'Chat notes were removed (A-W 4b)',
      );
      await tester.tap(studio);
      await tester.pumpAndSettle();
      expect(shell.controller.studioPaneOpen, isTrue);
      semantics.dispose();
    });
  }

  testWidgets('Studio has a Sources tab with an empty state (A-W 4a)', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.toggleStudioPane();
    shell.controller.setStudioTab(StudioTab.sources);
    await tester.pumpAndSettle();
    // The tab chip and the empty state's heading.
    expect(find.text(shell.t(L10nKey.studioTabSources)), findsWidgets);
    expect(find.text(shell.t(L10nKey.studioSourcesEmpty)), findsOneWidget);
  });
}
