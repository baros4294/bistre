import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

Finder _switch(String label) => find.byWidgetPredicate(
  (w) => w is BistreSwitch && w.semanticsLabel == label,
);

void main() {
  testWidgets(
    'first reply auto-titles the chat, translate adds a sibling version, and local-first toggles',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;
      final gw = shell.gateway;
      gw.generatedTitleOverride = 'Clean Auto Title';

      // Sending the first passage in a new chat marks it for auto-title on finish.
      final sent = await ctrl.submitPassage('Explain SQLite WAL checkpoints');
      expect(sent, isTrue);
      await tester.pumpAndSettle();

      expect(gw.callsTo('generateThreadTitle'), isNotEmpty);
      expect(ctrl.activeThread?.title, 'Clean Auto Title');

      // Translate action adds a sibling version on the same parent and selects it.
      final replyNode = ctrl.visibleBranchNodes.last;
      expect(replyNode.role, 'assistant');
      await ctrl.translateMessage(replyNode, targetLanguage: 'Vietnamese');
      await tester.pumpAndSettle();
      expect(gw.callsTo('translateNode'), isNotEmpty);
      final branch = ctrl.branchInfoFor(ctrl.visibleBranchNodes.last);
      expect(branch, isNotNull);
      expect(branch!.total, 2);
      expect(branch.index, 1);

      // Prefer free local models toggle in Safety & Budget writes walletLocalFirst.
      expect(ctrl.settings.walletLocalFirst, isTrue);
      ctrl.openSettings(SettingsTab.trust);
      await tester.pumpAndSettle();
      final localFirst = _switch(shell.t(L10nKey.settingsBudgetLocalFirst));
      await tester.ensureVisible(localFirst);
      await tester.pumpAndSettle();
      await tester.tap(localFirst);
      await tester.pumpAndSettle();
      expect(ctrl.settings.walletLocalFirst, isFalse);

      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets(
    'Prompt inspector shows the real credential-free request and surfaces blocked headers',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;
      final gw = shell.gateway;

      ctrl.setStudioTab(StudioTab.prompt);
      await tester.pumpAndSettle();
      expect(ctrl.inspectedRequest, isNotNull);
      expect(
        find.text(shell.t(L10nKey.storyInspectorRealRequest)),
        findsOneWidget,
      );
      await tester.tap(find.text(shell.t(L10nKey.storyInspectorRealRequest)));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('https://api.openai.com/v1/responses'),
        findsOneWidget,
      );

      // Invalid headers block the inspected request and surface the localized error.
      gw.inspectNextRequestError = StateError('diag.provider.headers_invalid');
      await ctrl.refreshPromptInspector();
      await tester.pumpAndSettle();
      expect(ctrl.inspectedRequest, isNull);
      expect(ctrl.inspectedRequestError, 'diag.provider.headers_invalid');
      expect(
        find.text(shell.t(L10nKey.diagProviderHeadersInvalid)),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 9));
    },
  );
}
