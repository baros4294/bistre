import 'dart:io';

import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// Ctrl+V in the composer: short text is typed, long text joins the message as a text
/// file, and copied files join it as attachments.
void main() {
  late String clipboardText;
  late List<String> clipboardFiles;

  Future<ShellHarness> pump(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': clipboardText}
          : null,
    );
    const host = MethodChannel('bistre/desktop_host');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      host,
      (call) async => call.method == 'clipboardAttachments'
          ? <String, Object?>{'files': clipboardFiles, 'png': ''}
          : null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
        ..setMockMethodCallHandler(SystemChannels.platform, null)
        ..setMockMethodCallHandler(host, null);
    });
    return ShellHarness.pump(tester);
  }

  setUp(() {
    clipboardText = '';
    clipboardFiles = <String>[];
  });

  testWidgets('short pasted text is typed at the cursor', (tester) async {
    clipboardText = 'hello there';
    final shell = await pump(tester);
    await tester.tap(find.byKey(const Key('composer_input')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('composer_input')),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.controller.text, 'hello there');
    expect(shell.controller.attachments, isEmpty);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('long pasted text and copied files become attachments', (
    tester,
  ) async {
    final shell = await pump(tester);
    final ctrl = shell.controller;
    clipboardText = 'x' * (kPasteAsFileChars + 1);
    final typed = await tester.runAsync(
      () => ctrl.takeComposerPaste(
        textFileName: 'Pasted text',
        imageFileName: 'Pasted picture',
      ),
    );
    expect(typed, isNull);
    expect(ctrl.attachments.single.name, 'Pasted text.txt');
    expect(ctrl.attachments.single.mimeType, 'text/plain');
    final saved = await tester.runAsync(
      () => File(ctrl.attachments.single.path).readAsString(),
    );
    expect(saved, clipboardText);

    // Copied files come from the Windows runner only (`clipboardAttachments`).
    if (Platform.isWindows) {
      clipboardFiles = <String>[r'C:\photos\cat.png', r'C:\docs\plan.pdf'];
      final none = await tester.runAsync(
        () => ctrl.takeComposerPaste(
          textFileName: 'Pasted text',
          imageFileName: 'Pasted picture',
        ),
      );
      expect(none, isNull);
      expect(
        ctrl.attachments.skip(1).map((a) => (a.name, a.mimeType, a.isImage)),
        <(String, String, bool)>[
          ('cat.png', 'image/png', true),
          ('plan.pdf', 'application/pdf', false),
        ],
      );
    }

    clipboardFiles = <String>[];
    clipboardText = 'short';
    final short = await tester.runAsync(
      () => ctrl.takeComposerPaste(
        textFileName: 'Pasted text',
        imageFileName: 'Pasted picture',
      ),
    );
    expect(short, 'short');
    await tester.pump(const Duration(seconds: 9));
  });
}
