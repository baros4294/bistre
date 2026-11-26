import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets('a failed connection test names the URL it tried (P8)', (
    tester,
  ) async {
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true)
      ..fetchModelsFailure = 'diag.provider.auth_failed';
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    final provider = shell.controller.providers.first;
    await shell.controller.testProviderConnection(provider.id);
    await tester.pump();
    final toast = shell.controller.toast.value;
    expect(toast?.key, L10nKey.toastProviderConnectionFailed);
    final expected = gateway
        .resolveProviderEndpoint(provider.dialect, provider.baseUrl)
        .modelsUrl;
    expect(toast?.args?['url'], expected);
    expect(
      shell.t(L10nKey.toastProviderConnectionFailed, <String, Object?>{
        'url': expected,
      }),
      contains(expected),
    );
    await tester.pump(const Duration(seconds: 7));
  });
}
