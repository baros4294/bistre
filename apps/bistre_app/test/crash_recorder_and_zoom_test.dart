import 'dart:convert';
import 'dart:io';

import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/chat/chat_overlays.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/platform/crash_recorder.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

const String _kTinyPngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  test('CrashRecorder scrubs secrets and persists/clears local report', () {
    final tmp = Directory.systemTemp.createTempSync('bistre_crash_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final secret = <String>['sk-', 'proj-', 'AbCdEf1234567890XyZ'].join();
    final gkey = <String>['AIza', 'Sy1234567890AbCdEfGhIjKlMnOp'].join();
    CrashRecorder.recordSync(
      tmp.path,
      StateError('Failed with Bearer secret_token_999 key=$gkey and $secret'),
      StackTrace.current,
    );

    final report = CrashRecorder.readAndClearPending(tmp.path);
    expect(report, isNotNull);
    expect(report, isNot(contains(secret)));
    expect(report, isNot(contains(gkey)));
    expect(report, isNot(contains('secret_token_999')));
    expect(report, contains('[REDACTED]'));
    expect(CrashRecorder.readAndClearPending(tmp.path), isNull);
  });

  testWidgets(
    'AttachmentPreviewModal supports pinch/wheel zoom via InteractiveViewer',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('bistre_zoom_test_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final img = File('${tmp.path}/photo.png')
        ..writeAsBytesSync(base64Decode(_kTinyPngB64));

      final shell = await ShellHarness.pump(tester);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: BistreLocalizations(
            controller: shell.l10n,
            child: BistreTheme(
              data: BistreThemeData.warmSepia,
              child: AttachmentViewerModal(
                attachment: ComposerAttachment(
                  id: 'att-1',
                  name: 'photo.png',
                  mimeType: 'image/png',
                  path: img.path,
                  sizeBytes: img.lengthSync(),
                  isImage: true,
                ),
                reduceMotionOverride: true,
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
    },
  );

  testWidgets(
    'next-launch crash banner shows Copy report, copies redacted text, and dismisses',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final shell = await ShellHarness.pump(tester);
      shell.controller.setPendingCrashReport(
        'Bistre local crash report\nStateError: [REDACTED]',
      );
      await tester.pumpAndSettle();

      expect(find.text(shell.t(L10nKey.shellCrashBanner)), findsOneWidget);
      final copyBtn = find.text(shell.t(L10nKey.shellCrashCopy));
      expect(copyBtn, findsOneWidget);
      await tester.tap(copyBtn);
      await tester.pumpAndSettle();

      expect(copied, contains('Bistre local crash report'));
      expect(copied, contains('[REDACTED]'));
      expect(shell.controller.pendingCrashReport, isNull);
      await tester.pump(const Duration(seconds: 9));
    },
  );
}
