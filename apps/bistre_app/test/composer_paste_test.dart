import 'dart:io';

import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// Ctrl+V in the composer: short text is typed, long text joins the message as a text
/// file, and copied files join it as attachments.
void main() {
  late String clipboardText;
  late List<String> clipboardFiles;
  late bool attachmentsFail;

  Future<ShellHarness> pump(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => switch (call.method) {
        'Clipboard.getData' => <String, Object?>{'text': clipboardText},
        'Clipboard.hasStrings' => <String, Object?>{'value': true},
        _ => null,
      },
    );
    const host = MethodChannel('bistre/desktop_host');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(host, (
      call,
    ) async {
      if (call.method != 'clipboardAttachments') return null;
      if (attachmentsFail) throw PlatformException(code: 'clipboard');
      return <String, Object?>{'files': clipboardFiles, 'png': ''};
    });
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
    attachmentsFail = false;
  });

  testWidgets('text still pastes when copied files cannot be read', (
    tester,
  ) async {
    // On Linux core reads the clipboard; outside the app it fails like a host error.
    attachmentsFail = true;
    clipboardText = 'hello there';
    final shell = await pump(tester);
    final typed = await tester.runAsync(
      () => shell.controller.takeComposerPaste(
        textFileName: 'Pasted text',
        imageFileName: 'Pasted picture',
      ),
    );
    expect(typed, 'hello there');
    expect(shell.controller.attachments, isEmpty);
    await tester.pump(const Duration(seconds: 9));
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

  testWidgets('the toolbar Paste takes the same path as Ctrl+V', (
    tester,
  ) async {
    final shell = await pump(tester);
    clipboardText = 'x' * (kPasteAsFileChars + 1);
    await tester.tap(find.byKey(const Key('composer_input')));
    await tester.pump();
    tester
        .state<EditableTextState>(
          find.descendant(
            of: find.byKey(const Key('composer_input')),
            matching: find.byType(EditableText),
          ),
        )
        .showToolbar();
    await tester.pump();
    await tester.tap(find.text(shell.t(L10nKey.shellSelectionPaste)));
    // The pasted text is written to a real temp file: let that I/O finish.
    for (var i = 0; i < 20 && shell.controller.attachments.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    final field = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('composer_input')),
        matching: find.byType(EditableText),
      ),
    );
    expect(
      field.controller.text,
      isEmpty,
      reason: 'long text is not typed into the field',
    );
    expect(
      shell.controller.attachments.map((a) => a.mimeType),
      <String>['text/plain'],
      reason:
          'long text from the touch toolbar joins as a file, as with Ctrl+V',
    );
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
