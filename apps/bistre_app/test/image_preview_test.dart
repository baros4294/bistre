import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/chat/chat_overlays.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  testWidgets('an image preview is decoded at a bounded size', (tester) async {
    final shell = await ShellHarness.pump(tester);
    shell.controller.openSentAttachment(
      const EngineNodeAttachment(
        name: 'photo.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 12000000,
        blobRelPath: 'attachments/photo.jpg',
      ),
    );
    await tester.pump();
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image).last);
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    final resized = provider as ResizeImage;
    expect(resized.width, kMaxPreviewDecodePx);
    expect(resized.policy, ResizeImagePolicy.fit);
    shell.controller.closeAttachmentPreview();
    await tester.pump(const Duration(milliseconds: 400));
  });
}
