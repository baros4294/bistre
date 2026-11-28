import 'package:bistre_app/design/bistre_controls.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// One Private requests switch in Safety & Budget decides whether providers may keep
/// chats; a provider's own storage switch (Advanced) only counts while it is off.
Finder _switch(String label) => find.byWidgetPredicate(
  (w) => w is BistreSwitch && w.semanticsLabel == label,
);

void main() {
  testWidgets(
    'Private requests is one switch, and it gates the provider switch',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;
      expect(ctrl.settings.providerStatelessDefault, isTrue);

      ctrl.openSettings(SettingsTab.trust);
      await tester.pumpAndSettle();
      final private = _switch(shell.t(L10nKey.settingsTrustStateless));
      await tester.ensureVisible(private);
      await tester.pumpAndSettle();
      await tester.tap(private);
      await tester.pumpAndSettle();
      expect(ctrl.settings.providerStatelessDefault, isFalse);

      // The provider's Advanced settings now offer storage, and chaining only once it is on.
      ctrl.openSettings();
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          EngravedButton,
          shell.t(L10nKey.settingsProviderAdvancedTitle),
        ),
      );
      await tester.pumpAndSettle();
      final storage = _switch(shell.t(L10nKey.settingsProviderStoreServer));
      expect(storage, findsOneWidget);
      expect(
        _switch(shell.t(L10nKey.settingsProviderStatefulChain)),
        findsNothing,
      );
      await tester.ensureVisible(storage);
      await tester.pumpAndSettle();
      await tester.tap(storage);
      await tester.pumpAndSettle();
      expect(ctrl.activeProvider?.useServerStateCache, isTrue);
      expect(
        _switch(shell.t(L10nKey.settingsProviderStatefulChain)),
        findsOneWidget,
      );

      // Back on: the provider switch is gone and says why.
      await ctrl.updateSettings(
        ctrl.settings.copyWith(providerStatelessDefault: true),
        quiet: true,
      );
      await tester.pumpAndSettle();
      expect(storage, findsNothing);
      expect(
        find.text(shell.t(L10nKey.settingsProviderStoreServerPrivate)),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 9));
    },
  );
}
