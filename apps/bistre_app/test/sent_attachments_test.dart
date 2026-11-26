import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

void main() {
  testWidgets('a sent message shows its files and opens them (P1)', (
    tester,
  ) async {
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
    final chat = gateway.seedThread(title: 'Files', updatedAtMs: 1000);
    await gateway.appendNode(
      threadId: chat.id,
      role: 'user',
      content: 'See the chart',
      attachments: const <EngineNodeAttachment>[
        EngineNodeAttachment(
          name: 'chart.png',
          mimeType: 'image/png',
          sizeBytes: 1200,
          blobRelPath: 'attachments/abc.png',
        ),
      ],
    );
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('chart.png'), findsOneWidget);
    await tester.tap(find.text('chart.png'));
    await tester.pump();
    final preview = shell.controller.previewingAttachment;
    expect(preview?.name, 'chart.png');
    expect(preview?.isImage, isTrue);
    expect(preview?.path, endsWith('abc.png'));
    shell.controller.closeAttachmentPreview();
    await tester.pump(const Duration(milliseconds: 400));
  });
}
