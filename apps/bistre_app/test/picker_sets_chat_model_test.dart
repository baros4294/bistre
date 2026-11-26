import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  testWidgets(
    'the model picker sets the open chat\'s own model (owner decision)',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final ctrl = shell.controller;
      final provider = ctrl.providers.firstWhere((p) => p.isReady);
      expect(ctrl.activeThread!.modelIdOverride ?? '', isEmpty);
      await ctrl.setActiveProviderAndModel(
        provider.id,
        'picked-model',
        forOpenChat: true,
      );
      await tester.pump();
      expect(ctrl.activeThread!.modelIdOverride, 'picked-model');
      expect(ctrl.activeThread!.providerIdOverride, provider.id);
      await tester.pump(const Duration(seconds: 6));
    },
  );
}
