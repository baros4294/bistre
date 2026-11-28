import 'dart:io';

import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  testWidgets('the @ menu reads the workspace once, off the keystroke path', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('bistre_mention_'),
    );
    if (dir == null) throw StateError('no temp dir');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.runAsync(() async {
      await File('${dir.path}${Platform.pathSeparator}notes.md')
          .writeAsString('x');
      await shell.controller.setWorkspaceRootPath(dir.path);
    });
    expect(
      shell.controller.workspaceEntryLoads,
      0,
      reason: 'nothing is read before the @ menu is asked for',
    );
    final input = find.byType(EditableText).last;
    for (final text in ['@', '@n', '@no', '@not']) {
      await tester.enterText(input, text);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(
      shell.controller.workspaceEntryLoads,
      1,
      reason: 'one read, not one per key',
    );
    expect(find.text('notes.md'), findsOneWidget);
    await tester.enterText(input, '');
    await tester.pump(const Duration(seconds: 6));
  });
}
